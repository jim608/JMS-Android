import 'subtitle_selection_failure.dart';

/// Keeps the applied subtitle alive until a replacement has loaded completely.
/// Generation checks also prevent late work from changing a new media session.
class SubtitleReplacement<T extends Object> {
  SubtitleReplacement({required this.activate, required this.dispose});

  final void Function(T) activate;
  final void Function(T) dispose;
  int _generation = 0;
  T? _current;

  T? get current => _current;

  void cancelPending() => _generation++;

  Future<void> replace({
    required Future<T> Function(bool Function() isCurrent) prepare,
    required Future<void> Function(T, bool Function() isCurrent) load,
    required bool Function() isCurrent,
  }) async {
    final generation = ++_generation;
    bool current() => generation == _generation && isCurrent();
    T? candidate;
    try {
      if (!current()) throw _unavailable;
      candidate = await prepare(current);
      if (!current()) throw _unavailable;
      await load(candidate, current);
      if (!current()) throw _unavailable;
      final previous = _current;
      final committed = candidate;
      _current = committed;
      candidate = null;
      try {
        activate(committed);
      } catch (_) {
        if (identical(_current, committed)) {
          _current = previous;
          dispose(committed);
        } else if (previous != null) {
          dispose(previous);
        }
        rethrow;
      }
      if (previous != null) dispose(previous);
      if (!current()) throw _unavailable;
    } finally {
      if (candidate != null) dispose(candidate);
    }
  }

  /// Called only for explicit Off, media changes, and disposal.
  void clear() {
    cancelPending();
    final previous = _current;
    _current = null;
    if (previous != null) dispose(previous);
  }
}

const _unavailable =
    SubtitleSelectionFailure(SubtitleSelectionFailureReason.unavailable);
