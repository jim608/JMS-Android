import 'dart:math' as math;

/// Engineering defaults, independently configurable from room coordination.
class SyncPlayPrebufferConfig {
  const SyncPlayPrebufferConfig({
    this.minimumTarget = const Duration(seconds: 2),
    this.initialTarget = const Duration(seconds: 4),
    this.maximumTarget = const Duration(seconds: 30),
    this.maximumWait = const Duration(seconds: 12),
    this.freshness = const Duration(seconds: 3),
    this.unknownGrace = const Duration(seconds: 2),
    this.growthCooldown = const Duration(seconds: 5),
    this.shrinkAfter = const Duration(seconds: 30),
    this.maximumForwardBytes = 150 * 1024 * 1024,
  });

  final Duration minimumTarget, initialTarget, maximumTarget, maximumWait;
  final Duration freshness, unknownGrace, growthCooldown, shrinkAfter;
  final int maximumForwardBytes;
}

/// Copy scalar values at observation time; do not retain mutable PlayerState.
/// bufferEnd is an absolute media timestamp, not a duration of downloaded data.
class SyncPlayBufferSample {
  const SyncPlayBufferSample({
    required this.position,
    required this.buffering,
    required this.observedAt,
    this.bufferEnd,
    this.duration,
    this.forwardBytes,
    this.preparing = false,
  });
  final Duration position;
  final Duration? bufferEnd, duration;
  final bool buffering, preparing;
  final DateTime observedAt;
  final int? forwardBytes;
}

enum SyncPlayPrebufferStatus { ready, fallbackReady, needsBuffer, playerWaiting, preparing, unknown, stale, timedOut }

class SyncPlayPrebufferDecision {
  const SyncPlayPrebufferDecision({
    required this.status,
    required this.ready,
    required this.needsBuffer,
    required this.timedOut,
    required this.target,
    required this.waited,
    required this.ahead,
    required this.deliveryRate,
    required this.byteBudgetLimited,
  });
  final SyncPlayPrebufferStatus status;
  final bool ready, needsBuffer, timedOut, byteBudgetLimited;
  final Duration target, waited;
  final Duration? ahead;

  /// Media seconds delivered per wall second, not RTT or a bandwidth estimate.
  final double? deliveryRate;

  /// ready may use hysteresis or a labelled fallback. It never means that an
  /// unknown buffer has actually reached the requested duration.
  bool get measuredTargetReached => ahead != null && ahead! >= target;
}

/// Pure decision state. The caller owns pause/resume, room IgnoreWait and
/// timers. Poll evaluate while waiting; it never sends a room/player command.
class SyncPlayPrebufferPolicy {
  SyncPlayPrebufferPolicy({this.config = const SyncPlayPrebufferConfig(), DateTime Function()? now})
      : now = now ?? DateTime.now,
        _target = config.initialTarget {
    if (config.minimumTarget <= Duration.zero ||
        config.initialTarget < config.minimumTarget ||
        config.maximumTarget < config.initialTarget ||
        config.maximumWait <= Duration.zero ||
        config.freshness <= Duration.zero ||
        config.unknownGrace < Duration.zero ||
        config.growthCooldown <= Duration.zero ||
        config.shrinkAfter <= Duration.zero ||
        config.maximumForwardBytes <= 0 ||
        config.maximumForwardBytes > 150 * 1024 * 1024) {
      throw ArgumentError('Invalid or unbounded prebuffer configuration');
    }
  }

  final SyncPlayPrebufferConfig config;
  final DateTime Function() now;
  Object? _generation;
  Duration _target;
  Duration? _readyTarget;
  DateTime? _waitingSince, _stableSince, _lastGrowth, _lastClock;
  SyncPlayBufferSample? _previous;
  SyncPlayBufferSample? _rateSample;
  double? _rate;
  bool _ready = false;

  void reset() {
    _generation = null;
    _target = config.initialTarget;
    _readyTarget = null;
    _waitingSince = _stableSince = _lastGrowth = _lastClock = null;
    _previous = null;
    _rateSample = null;
    _rate = null;
    _ready = false;
  }

  SyncPlayPrebufferDecision evaluate(SyncPlayBufferSample sample, {required Object generation}) {
    if (_generation != generation) {
      reset();
      _generation = generation;
    }
    final clock = now();
    // Local clock rollback starts a new bounded wait rather than extending an
    // old deadline indefinitely or carrying throughput across time domains.
    if (_lastClock != null && clock.isBefore(_lastClock!)) {
      _waitingSince = clock;
      _stableSince = _lastGrowth = null;
      _previous = null;
      _rateSample = null;
      _rate = null;
      _ready = false;
      _readyTarget = null;
    }
    _lastClock = clock;
    final age = clock.difference(sample.observedAt);
    final invalid = sample.position < Duration.zero ||
        (sample.duration != null && sample.duration! < Duration.zero) ||
        (sample.bufferEnd != null && sample.bufferEnd! < Duration.zero) ||
        (sample.forwardBytes != null && sample.forwardBytes! < 0);
    final stale = age.isNegative ||
        age > config.freshness ||
        (_previous != null && sample.observedAt.isBefore(_previous!.observedAt));
    Duration? ahead;
    if (!invalid && !stale && sample.bufferEnd != null) {
      var end = sample.bufferEnd!;
      if (sample.duration != null && sample.duration! > Duration.zero && end > sample.duration!) end = sample.duration!;
      ahead = end > sample.position ? end - sample.position : Duration.zero;
    }
    final previous = _previous;
    if (sample.preparing || invalid || stale) {
      _previous = null;
      _rateSample = null;
      _rate = null;
      _stableSince = null;
    }
    if (sample.bufferEnd == null) {
      _rate = null;
      _rateSample = null;
    }
    if (!invalid && !stale && !sample.preparing) {
      final rateSample = _rateSample;
      if (rateSample != null && rateSample.bufferEnd != null && sample.bufferEnd != null) {
        final elapsed = sample.observedAt.difference(rateSample.observedAt).inMicroseconds / 1000000;
        final progressed = (sample.bufferEnd! - rateSample.bufferEnd!).inMicroseconds / 1000000;
        // Ignore duplicate observations and cache eviction/rebase. A seek must
        // also change generation; a backwards media jump defensively resets.
        if (sample.position < rateSample.position || progressed < 0) {
          _rate = null;
          _stableSince = null;
          _rateSample = sample;
        } else if (elapsed >= 0.25) {
          final rate = progressed / elapsed;
          _rate = _rate == null ? rate : _rate! * 0.75 + rate * 0.25;
          _rateSample = sample;
        }
      } else {
        _rateSample = sample;
      }
      final underflow = ahead != null && ahead < _target && sample.buffering && previous?.buffering == false;
      final slow = ahead != null && ahead < _target && (_rate ?? 1) < 0.95 && sample.buffering;
      if ((underflow || slow) && (_lastGrowth == null || clock.difference(_lastGrowth!) >= config.growthCooldown)) {
        _target = _min(_target + const Duration(seconds: 2), config.maximumTarget);
        _lastGrowth = clock;
      }
      _previous = sample;
    }
    var target = _target;
    if (sample.duration != null && sample.duration! > Duration.zero && sample.position >= Duration.zero) {
      target = _min(target, sample.position < sample.duration! ? sample.duration! - sample.position : Duration.zero);
    }
    final byteLimited = ahead != null &&
        ahead > Duration.zero &&
        (sample.forwardBytes ?? 0) >= config.maximumForwardBytes &&
        ahead < target;
    if (byteLimited) target = ahead;
    // Keep the threshold actually reached under a byte ceiling. Otherwise a
    // two-second cache can become unready immediately after resuming because
    // the unconstrained four-second target has a two-second low-water mark.
    final lowWater = Duration(microseconds: (_ready ? _readyTarget ?? target : target).inMicroseconds ~/ 2);
    final sufficient = ahead != null && ahead >= (_ready ? lowWater : target);
    var ready = !invalid && !stale && !sample.preparing && !sample.buffering && sufficient;
    if (ready && ahead >= _target + const Duration(seconds: 1) && !byteLimited) {
      _stableSince ??= clock;
      if (clock.difference(_stableSince!) >= config.shrinkAfter) {
        _target = _max(config.minimumTarget, _target - const Duration(seconds: 1));
        target = _min(target, _target);
        _stableSince = clock;
      }
    } else {
      _stableSince = null;
    }
    _waitingSince = ready ? null : (_waitingSince ?? clock);
    var waited = _waitingSince == null ? Duration.zero : clock.difference(_waitingSince!);
    var status = sample.preparing
        ? SyncPlayPrebufferStatus.preparing
        : stale
            ? SyncPlayPrebufferStatus.stale
            : invalid || ahead == null
                ? SyncPlayPrebufferStatus.unknown
                : ready
                    ? SyncPlayPrebufferStatus.ready
                    : ahead < target
                        ? SyncPlayPrebufferStatus.needsBuffer
                        : SyncPlayPrebufferStatus.playerWaiting;
    // Missing metrics may fall back only to a fresh, non-waiting player, after
    // a bounded grace. Stale/invalid/decoder-preparing input never proves ready.
    if (!ready &&
        !invalid &&
        !stale &&
        ahead == null &&
        !sample.buffering &&
        !sample.preparing &&
        (_ready || waited >= config.unknownGrace)) {
      ready = true;
      status = SyncPlayPrebufferStatus.fallbackReady;
      _waitingSince = null;
      waited = Duration.zero;
    }
    final timedOut = !ready && waited >= config.maximumWait;
    final needsBuffer = !ready && !invalid && !stale && !sample.preparing && ahead != null && ahead < target;
    if (timedOut) status = SyncPlayPrebufferStatus.timedOut;
    if (ready && ahead != null && (!_ready || ahead >= target)) _readyTarget = target;
    if (!ready) _readyTarget = null;
    _ready = ready;
    return SyncPlayPrebufferDecision(
      status: status,
      ready: ready,
      needsBuffer: needsBuffer,
      timedOut: timedOut,
      target: target,
      waited: waited,
      ahead: ahead,
      deliveryRate: _rate,
      byteBudgetLimited: byteLimited,
    );
  }

  static Duration _min(Duration a, Duration b) => Duration(microseconds: math.min(a.inMicroseconds, b.inMicroseconds));
  static Duration _max(Duration a, Duration b) => Duration(microseconds: math.max(a.inMicroseconds, b.inMicroseconds));
}
