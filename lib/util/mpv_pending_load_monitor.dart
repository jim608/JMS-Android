import 'dart:async';

/// Initial state follows the backend when readiness was already observed
/// synchronously. Otherwise it continues to cover a pending media load.
bool mpvInitialBuffering({
  required bool readinessCompleted,
  required bool hdrGated,
  required bool backendBuffering,
}) =>
    (readinessCompleted || hdrGated) ? backendBuffering : true;

/// A single startup budget. A slow network stream must retain its current
/// demuxer/cache instead of being reopened every retry interval.
class MpvPendingLoadMonitor {
  MpvPendingLoadMonitor({
    required this.networkStream,
    required this.isCurrent,
    required this.retryLocal,
    required this.onTimeout,
    required this.onFailure,
    this.interval = const Duration(seconds: 5),
    this.budget = const Duration(minutes: 1),
  });

  final bool networkStream;
  final bool Function() isCurrent;
  final Future<void> Function() retryLocal;
  final void Function() onTimeout;
  final void Function(Object error) onFailure;
  final Duration interval;
  final Duration budget;
  Timer? _deadline;
  Timer? _retry;
  bool _cancelled = false;
  bool _started = false;
  bool _retryInFlight = false;

  void start() {
    if (_started || _cancelled) return;
    _started = true;
    _deadline = Timer(budget > Duration.zero ? budget : Duration.zero, () {
      final current = !_cancelled && isCurrent();
      cancel();
      if (current) onTimeout();
    });
    // mpv owns HTTP retry/read-ahead. Reopening a still-pending network load
    // discards that work and can keep a high-latency source in startup forever.
    if (!networkStream) {
      _retry = Timer.periodic(interval, (_) => unawaited(_tick()));
    }
  }

  Future<void> _tick() async {
    if (_cancelled || !isCurrent()) {
      cancel();
      return;
    }
    if (_retryInFlight) return;
    _retryInFlight = true;
    try {
      await retryLocal();
    } catch (error) {
      final current = !_cancelled && isCurrent();
      cancel();
      if (current) onFailure(error);
    } finally {
      _retryInFlight = false;
    }
  }

  void cancel() {
    _cancelled = true;
    _retry?.cancel();
    _deadline?.cancel();
    _retry = null;
    _deadline = null;
  }
}
