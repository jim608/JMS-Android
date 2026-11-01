import 'dart:async';
import 'dart:js_interop';

import 'package:media_kit/media_kit.dart' as mpv;
import 'package:web/web.dart' as web;

import 'subtitle_timeline.dart';
import 'subtitle_replacement.dart';
import 'subtitle_selection_failure.dart';

/// Reads only the current player's hidden text track. Video time and cue times
/// stay untouched, so timing changes apply during playback and while paused.
class WebSubtitleTiming {
  WebSubtitleTiming({required this.onText, required this.onAvailable});

  final void Function(String) onText;
  final void Function(bool) onAvailable;
  web.HTMLVideoElement? _element;
  web.TextTrack? _track;
  Timer? _timer;
  web.AbortController? _request;
  String? _preparedUrl;
  _BrowserSubtitleTrack? _pendingTrack;
  int _generation = 0;
  double _offset = 0;
  String _text = '';
  bool _available = false;
  final List<StreamSubscription<web.Event>> _events = [];
  late final _replacement = SubtitleReplacement<_BrowserSubtitleTrack>(
    activate: _activate,
    dispose: (track) => track.dispose(),
  );

  bool get supported => _element != null;
  bool get available => _available;
  String? get appliedSourceUrl => _replacement.current?.sourceUrl;

  void attach(Object? platform) {
    if (platform is! mpv.WebPlayer) return;
    final player = platform as dynamic;
    if (player.disposed as bool) return;
    attachElement(player.element as web.HTMLVideoElement);
  }

  /// Also used by the standalone browser probe, without a Flutter test host.
  void attachElement(web.HTMLVideoElement element) {
    dispose();
    _element = element;
    for (final event in [
      element.onTimeUpdate,
      element.onSeeked,
      element.onPause,
      element.onPlay
    ]) {
      _events.add(event.listen((_) => refresh()));
    }
  }

  /// A superseded request must not remove the subtitle currently being shown.
  void cancelPendingSelection() {
    _generation++;
    _replacement.cancelPending();
    _request?.abort();
    _request = null;
    final pending = _pendingTrack;
    if (pending != null && !identical(pending, _replacement.current)) {
      pending.dispose();
    }
    _pendingTrack = null;
  }

  /// Clear applied subtitles only for Off, a new media source, or disposal.
  void clearTrack() {
    cancelPendingSelection();
    _replacement.clear();
    _timer?.cancel();
    _timer = null;
    _track = null;
    final element = _element;
    if (element != null) {
      final tracks = element.querySelectorAll('track');
      for (var i = 0; i < tracks.length; i++) {
        final child = tracks.item(i) as web.HTMLTrackElement;
        child.track.oncuechange = null;
        child.track.mode = 'disabled';
        child.remove();
      }
    }
    final prepared = _preparedUrl;
    _preparedUrl = null;
    if (prepared != null) web.URL.revokeObjectURL(prepared);
    _publish('', false);
  }

  Future<String> prepareSubtitle(String url) async {
    final generation = _generation;
    final vtt = await _fetchSubtitle(url, generation);
    final blob = web.Blob(
        [vtt.toJS].toJS, web.BlobPropertyBag(type: 'text/vtt;charset=utf-8'));
    return _preparedUrl = web.URL.createObjectURL(blob);
  }

  Future<String> _fetchSubtitle(String url, int generation) async {
    final request = web.AbortController();
    _request = request;
    try {
      return await (() async {
        final response = await web.window
            .fetch(
                url.toJS,
                web.RequestInit(
                    signal: request.signal,
                    redirect: 'error',
                    credentials: 'same-origin'))
            .toDart;
        if (!response.ok) throw StateError('Subtitle request failed');
        final text = (await response.text().toDart).toDart;
        if (generation != _generation || !supported) {
          throw StateError('Subtitle selection changed');
        }
        return browserSubtitleVtt(text);
      })()
          .timeout(const Duration(seconds: 10), onTimeout: () {
        request.abort();
        throw TimeoutException('Subtitle request timed out');
      });
    } finally {
      if (generation == _generation) _request = null;
    }
  }

  /// Fetch and load a hidden candidate before replacing the applied track.
  /// The previous track and overlay keep running throughout a failed request.
  Future<void> replaceSubtitle(String url,
      {required bool Function() isCurrent}) async {
    cancelPendingSelection();
    final generation = _generation;
    final element = _element;
    if (element == null) throw _unavailable;
    try {
      await _replacement.replace(
        isCurrent: () =>
            generation == _generation &&
            identical(element, _element) &&
            isCurrent(),
        prepare: (current) async {
          final vtt = await _fetchSubtitle(url, generation);
          if (!current()) throw _unavailable;
          final blob = web.Blob([vtt.toJS].toJS,
              web.BlobPropertyBag(type: 'text/vtt;charset=utf-8'));
          final prepared = web.URL.createObjectURL(blob);
          final child = web.HTMLTrackElement()
            ..kind = 'subtitles'
            ..src = prepared;
          final candidate = _BrowserSubtitleTrack(child, prepared, url);
          _pendingTrack = candidate;
          element.appendChild(child);
          child.track.mode = 'hidden';
          return candidate;
        },
        load: _waitForTrack,
      );
    } catch (_) {
      // Browser request, conversion and text-track failures share a safe result.
      throw _unavailable;
    } finally {
      if (generation == _generation) {
        final pending = _pendingTrack;
        _pendingTrack = null;
        if (pending != null && !identical(pending, _replacement.current)) {
          pending.dispose();
        }
      }
    }
    // Notify overlay listeners after the replacement is committed and is no
    // longer marked pending; publication cannot roll back a loaded track.
    refresh();
  }

  Future<void> _waitForTrack(
      _BrowserSubtitleTrack candidate, bool Function() current) async {
    final loaded = Completer<void>();
    void fail() {
      if (!loaded.isCompleted) loaded.completeError(_unavailable);
    }

    void check() {
      if (loaded.isCompleted) return;
      if (!current() ||
          candidate.element.readyState == web.HTMLTrackElement.ERROR) {
        fail();
      } else if (candidate.element.readyState == web.HTMLTrackElement.LOADED) {
        final cues = candidate.element.track.cues;
        if (cues == null || cues.length == 0) {
          fail();
        } else {
          loaded.complete();
        }
      }
    }

    final onLoad = candidate.element.onLoad.listen((_) => check());
    final onError = candidate.element.onError.listen((_) => fail());
    // Also observe cancellation and a load completed before event registration.
    final timer =
        Timer.periodic(const Duration(milliseconds: 20), (_) => check());
    check();
    try {
      await loaded.future.timeout(const Duration(seconds: 5));
    } finally {
      timer.cancel();
      await onLoad.cancel();
      await onError.cancel();
    }
  }

  void _activate(_BrowserSubtitleTrack candidate) {
    if (identical(_pendingTrack, candidate)) _pendingTrack = null;
    final element = _element!;
    final tracks = element.querySelectorAll('track');
    for (var i = 0; i < tracks.length; i++) {
      final child = tracks.item(i) as web.HTMLTrackElement;
      if (identical(child, candidate.element)) continue;
      child.track.oncuechange = null;
      child.track.mode = 'disabled';
      child.remove();
    }
    final prepared = _preparedUrl;
    _preparedUrl = null;
    if (prepared != null) web.URL.revokeObjectURL(prepared);
    _track = candidate.element.track
      ..oncuechange = null
      ..mode = 'hidden';
    _startRefreshTimer();
  }

  void selectTrack() {
    final element = _element;
    if (element == null || element.textTracks.length == 0) return;
    _track = element.textTracks[element.textTracks.length - 1]
      ..oncuechange = null
      ..mode = 'hidden';
    // Cues may load after selection. Polling also refreshes adjusted text in a
    // paused video, where browsers need not dispatch cuechange or timeupdate.
    _startRefreshTimer();
    refresh();
  }

  void _startRefreshTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 50), (_) => refresh());
  }

  void refresh() {
    final element = _element;
    final cues = _track?.cues;
    if (element == null || cues == null || cues.length == 0) {
      _publish('', false);
      return;
    }
    final active = <String>[];
    for (var i = 0; i < cues.length; i++) {
      final cue = cues[i];
      if (subtitleCueIsActive(
          start: cue.startTime,
          end: cue.endTime,
          position: element.currentTime,
          offset: _offset)) {
        final text = (cue as web.VTTCue).getCueAsHTML().textContent ?? '';
        if (text.isNotEmpty) active.add(text);
      }
    }
    _publish(active.join('\n'), true);
  }

  Future<void> write(String property, String value) async {
    final offset = double.tryParse(value);
    if (!supported ||
        property != 'sub-delay' ||
        offset == null ||
        !offset.isFinite ||
        offset.abs() > 60) {
      throw StateError('Browser subtitle timing is unavailable');
    }
    if (offset != 0 && !_available) {
      throw StateError('No loaded subtitle track');
    }
    _offset = offset;
    refresh();
  }

  Future<String> read(String property) async =>
      supported && property == 'sub-delay' ? _offset.toStringAsFixed(3) : '';

  void _publish(String text, bool available) {
    if (_text != text) {
      _text = text;
      onText(text);
    }
    if (_available != available) {
      _available = available;
      onAvailable(available);
    }
  }

  void dispose() {
    clearTrack();
    for (final event in _events) {
      unawaited(event.cancel());
    }
    _events.clear();
    _element = null;
    _offset = 0;
  }
}

class _BrowserSubtitleTrack {
  _BrowserSubtitleTrack(this.element, this.url, this.sourceUrl);

  final web.HTMLTrackElement element;
  final String url;
  final String sourceUrl;
  bool _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    element.track.oncuechange = null;
    element.track.mode = 'disabled';
    element.remove();
    web.URL.revokeObjectURL(url);
  }
}

const _unavailable =
    SubtitleSelectionFailure(SubtitleSelectionFailureReason.unavailable);
