import 'syncplay_clock.dart';

/// Debounces the raw player waiting signal before coordinating a room.
///
/// Jellyfin Web's HtmlVideoPlayer uses a 3000 ms waiting notification delay:
/// https://github.com/jellyfin/jellyfin-web/blob/c06cb17b274c10f9015412305edb0afdc010ae7a/src/plugins/syncPlay/ui/players/HtmlVideoPlayer.js
/// A ready edge is immediate. Each queue instance gets its own edge history.
class SyncPlayBufferingReporter {
  SyncPlayBufferingReporter({
    required bool Function() isCurrent,
    required bool Function() isBuffering,
    required Object? Function() queueKey,
    required void Function(bool) report,
    SyncPlayScheduler scheduler = const SyncPlayTimerScheduler(),
  })  : _isCurrent = isCurrent,
        _isBuffering = isBuffering,
        _queueKey = queueKey,
        _report = report,
        _scheduler = scheduler;

  final bool Function() _isCurrent;
  final bool Function() _isBuffering;
  final Object? Function() _queueKey;
  final void Function(bool) _report;
  final SyncPlayScheduler _scheduler;
  SyncPlayCancellation? _waiting;
  Object? _queue;
  bool? _raw;
  bool _disposed = false;
  int _generation = 0;

  /// Observe one raw player edge. Repeated waiting events do not extend it.
  void update(bool buffering) {
    if (!_current()) return;
    final key = _queueKey();
    if (!_current()) return;
    _adoptQueue(key);
    if (key != null) _update(buffering);
  }

  /// Rebind after an authoritative queue change, using the current raw state.
  void refreshQueue() {
    if (!_current()) return;
    final key = _queueKey();
    if (!_current()) return;
    _adoptQueue(key);
    if (key == null) return;
    final buffering = _isBuffering();
    if (!_current()) return;
    _update(buffering);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _clearQueue();
  }

  bool _current() {
    if (_disposed) return false;
    if (_isCurrent()) return true;
    _clearQueue();
    return false;
  }

  void _adoptQueue(Object? key) {
    if (key == _queue) return;
    _clearQueue();
    _queue = key;
  }

  void _clearQueue() {
    _cancelWaiting();
    _queue = null;
    _raw = null;
  }

  void _cancelWaiting() {
    _generation++;
    _waiting?.cancel();
    _waiting = null;
  }

  void _update(bool buffering) {
    if (_raw == buffering) return;
    _raw = buffering;
    _cancelWaiting();
    if (!buffering) {
      _report(false);
      return;
    }
    final generation = _generation;
    final queue = _queue;
    _waiting = _scheduler.schedule(const Duration(milliseconds: 3000), () {
      if (!_current() || generation != _generation) return;
      final currentQueue = _queueKey();
      if (!_current()) return;
      if (currentQueue != queue) {
        refreshQueue();
        return;
      }
      final buffering = _isBuffering();
      if (!_current() || generation != _generation) return;
      _waiting = null;
      if (buffering) {
        _report(true);
      } else {
        _update(false);
      }
    });
  }
}
