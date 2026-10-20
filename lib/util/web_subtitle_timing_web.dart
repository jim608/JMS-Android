import 'dart:async';
import 'dart:js_interop';

import 'package:media_kit/media_kit.dart' as mpv;
import 'package:web/web.dart' as web;

import 'subtitle_timeline.dart';

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
  int _generation = 0;
  double _offset = 0;
  String _text = '';
  bool _available = false;
  final List<StreamSubscription<web.Event>> _events = [];

  bool get supported => _element != null;
  bool get available => _available;

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

  /// Remove the previous media_kit track before its next selection is appended.
  void clearTrack() {
    _generation++;
    _request?.abort();
    _request = null;
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
    final request = web.AbortController();
    _request = request;
    try {
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
      final vtt = browserSubtitleVtt(text);
      final blob = web.Blob(
          [vtt.toJS].toJS, web.BlobPropertyBag(type: 'text/vtt;charset=utf-8'));
      return _preparedUrl = web.URL.createObjectURL(blob);
    } finally {
      if (generation == _generation) _request = null;
    }
  }

  void selectTrack() {
    final element = _element;
    if (element == null || element.textTracks.length == 0) return;
    _track = element.textTracks[element.textTracks.length - 1]
      ..oncuechange = null
      ..mode = 'hidden';
    // Cues may load after selection. Polling also refreshes adjusted text in a
    // paused video, where browsers need not dispatch cuechange or timeupdate.
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 50), (_) => refresh());
    refresh();
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
