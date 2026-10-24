import 'dart:async';

import 'syncplay_clock.dart';
import 'syncplay_prebuffer.dart';

/// Samples media state independently from the server-clock/RTT loop. It sends
/// no player or room command; the controller owns those decisions.
class SyncPlayPrebufferCoordinator {
  SyncPlayPrebufferCoordinator({
    required bool Function() isCurrent,
    required bool Function() isActive,
    required Object Function() generation,
    required Future<SyncPlayBufferSample> Function() readSample,
    required void Function(SyncPlayPrebufferDecision decision) onDecision,
    Future<int?> Function()? verifiedForwardBudget,
    SyncPlayPrebufferConfig config = const SyncPlayPrebufferConfig(),
    SyncPlayScheduler scheduler = const SyncPlayTimerScheduler(),
    DateTime Function()? now,
    this.interval = const Duration(milliseconds: 500),
    this.readTimeout = const Duration(seconds: 2),
  })  : _isCurrent = isCurrent,
        _isActive = isActive,
        _generation = generation,
        _readSample = readSample,
        _onDecision = onDecision,
        _verifiedForwardBudget = verifiedForwardBudget,
        _requestedConfig = config,
        _config = config,
        _scheduler = scheduler,
        _now = now ?? DateTime.now {
    if (interval <= Duration.zero || readTimeout <= Duration.zero) {
      throw ArgumentError('Media polling must be bounded and non-zero');
    }
    _policy = SyncPlayPrebufferPolicy(config: config, now: _now);
  }

  final bool Function() _isCurrent, _isActive;
  final Object Function() _generation;
  final Future<SyncPlayBufferSample> Function() _readSample;
  final void Function(SyncPlayPrebufferDecision decision) _onDecision;
  final Future<int?> Function()? _verifiedForwardBudget;
  final SyncPlayScheduler _scheduler;
  final DateTime Function() _now;
  final Duration interval, readTimeout;
  final SyncPlayPrebufferConfig _requestedConfig;
  SyncPlayPrebufferConfig _config;
  late SyncPlayPrebufferPolicy _policy;
  SyncPlayCancellation? _job;
  Object? _currentGeneration;
  int _revision = 0, _jobTicket = 0;
  bool _disposed = false, _sampling = false;
  SyncPlayPrebufferDecision? _decision;
  DateTime? _decisionObservedAt;
  int? _confirmedBudget;

  bool get _sameContext =>
      _current &&
      _isActive() &&
      _currentGeneration != null &&
      _currentGeneration == _generation();

  SyncPlayPrebufferDecision? get decision {
    if (!_sameContext || _decisionObservedAt == null) {
      return null;
    }
    final age = _now().difference(_decisionObservedAt!);
    return age.isNegative || age > _config.freshness ? null : _decision;
  }

  bool get ready => decision?.ready ?? false;
  Duration? get ahead => decision?.ahead;
  Duration get target => decision?.target ?? _requestedConfig.initialTarget;
  int? get confirmedForwardBudget => _sameContext ? _confirmedBudget : null;

  bool get _current => !_disposed && _isCurrent();

  /// Call after an authoritative state change. An old queued callback cannot
  /// sample the replacement account, queue or seek generation.
  void refresh() {
    if (!_current) return;
    if (!_isActive()) {
      _invalidate();
      return;
    }
    final generation = _generation();
    if (generation != _currentGeneration) {
      _invalidate();
      _currentGeneration = generation;
    }
    if (!_sampling && _job == null) _schedule(Duration.zero);
  }

  void _invalidate() {
    _revision++;
    _jobTicket++;
    _job?.cancel();
    _job = null;
    _currentGeneration = null;
    _decision = null;
    _decisionObservedAt = null;
    _confirmedBudget = null;
    _config = _requestedConfig;
    _policy = SyncPlayPrebufferPolicy(config: _config, now: _now);
  }

  void _schedule(Duration delay) {
    final ticket = ++_jobTicket;
    final revision = _revision;
    _job = _scheduler.schedule(delay, () {
      if (_disposed || ticket != _jobTicket || revision != _revision) return;
      _job = null;
      unawaited(_sample(revision));
    });
  }

  void _acceptBudget(int? bytes) {
    if (bytes == null || bytes <= 0 || bytes > 150 * 1024 * 1024) return;
    _confirmedBudget = bytes;
    final effective = bytes < _requestedConfig.maximumForwardBytes
        ? bytes
        : _requestedConfig.maximumForwardBytes;
    if (effective == _config.maximumForwardBytes) {
      return;
    }
    final old = _requestedConfig;
    _config = SyncPlayPrebufferConfig(
      minimumTarget: old.minimumTarget,
      initialTarget: old.initialTarget,
      maximumTarget: old.maximumTarget,
      maximumWait: old.maximumWait,
      freshness: old.freshness,
      unknownGrace: old.unknownGrace,
      growthCooldown: old.growthCooldown,
      shrinkAfter: old.shrinkAfter,
      maximumForwardBytes: effective,
    );
    // A verified, smaller native cache budget takes precedence over the desired
    // media duration. This never raises a byte limit or changes browser cache.
    _policy = SyncPlayPrebufferPolicy(config: _config, now: _now);
  }

  Future<void> _sample(int revision) async {
    if (!_current || !_isActive() || revision != _revision || _sampling) return;
    _sampling = true;
    final generation = _currentGeneration;
    try {
      int? budget;
      SyncPlayBufferSample sample;
      try {
        // The backend caches this option verification per native player. An
        // unavailable/old backend returns null; that is not a verified bound.
        budget = await _verifiedForwardBudget?.call().timeout(readTimeout);
        if (!_sameContext ||
            revision != _revision ||
            generation != _currentGeneration) {
          return;
        }
        sample = await _readSample().timeout(readTimeout);
      } catch (_) {
        sample = SyncPlayBufferSample(
          position: Duration.zero,
          buffering: true,
          observedAt: _now(),
        );
      }
      if (!_current ||
          !_isActive() ||
          revision != _revision ||
          generation != _generation()) {
        return;
      }
      _acceptBudget(budget);
      final result = _policy.evaluate(sample, generation: generation!);
      _decision = result;
      _decisionObservedAt = sample.observedAt;
      _onDecision(result);
    } finally {
      _sampling = false;
      if (_current && _isActive()) {
        if (revision != _revision || _currentGeneration != _generation()) {
          refresh();
        } else if (_job == null) {
          _schedule(interval);
        }
      }
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _invalidate();
  }
}
