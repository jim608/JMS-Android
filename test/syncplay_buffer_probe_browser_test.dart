@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:fladder/util/web_syncplay_buffer_probe_web.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' as mpv;
import 'package:web/web.dart' as web;

@JS('Object.defineProperty')
external JSObject _defineProperty(JSObject object, JSString name, JSObject descriptor);

void _property(JSObject object, String name, JSAny? value) {
  final descriptor = JSObject()
    ..['value'] = value
    ..['configurable'] = true.toJS;
  _defineProperty(object, name.toJS, descriptor);
}

void _fixture(
  web.HTMLVideoElement element, {
  double time = 10,
  double duration = 100,
  int ready = 4,
  bool seeking = false,
  List<List<double>> ranges = const [
    [0, 12],
    [20, 100],
  ],
}) {
  final buffered = JSObject()..['length'] = ranges.length.toJS;
  buffered['start'] = ((JSNumber index) => ranges[index.toDartInt][0].toJS).toJS;
  buffered['end'] = ((JSNumber index) => ranges[index.toDartInt][1].toJS).toJS;
  _property(element, 'currentTime', time.toJS);
  _property(element, 'duration', duration.toJS);
  _property(element, 'readyState', ready.toJS);
  _property(element, 'seeking', seeking.toJS);
  _property(element, 'buffered', buffered);
}

void main() {
  test('DOM sampling reads the playhead-containing range, not the final range', () {
    final element = web.HTMLVideoElement();
    _fixture(element);
    final sample = readWebSyncPlayElement(element);
    expect(sample.position, const Duration(seconds: 10));
    expect(sample.bufferEnd, const Duration(seconds: 12));
    expect(sample.buffering, isFalse);
    expect(sample.forwardBytes, isNull);
    expect(element.currentSrc, isEmpty);
    _fixture(
      element,
      ranges: [
        [0, 5],
        [20, 100],
      ],
    );
    expect(readWebSyncPlayElement(element).bufferEnd, const Duration(seconds: 10));
    expect(sample.bufferEnd, const Duration(seconds: 12));
  });
  test('DOM seeking/readyState and unknown duration never require loading media', () {
    final element = web.HTMLVideoElement();
    _fixture(element, ready: 2, seeking: true, duration: double.nan);
    final sample = readWebSyncPlayElement(element);
    expect(sample.preparing, isTrue);
    expect(sample.buffering, isTrue);
    expect(sample.duration, isNull);
    _fixture(element, time: double.nan);
    expect(readWebSyncPlayElement(element).position, lessThan(Duration.zero));
    expect(element.currentSrc, isEmpty);
  });
  test('missing or malformed browser ranges remain unknown', () {
    final element = web.HTMLVideoElement();
    _fixture(element);
    _property(element, 'buffered', null);
    expect(readWebSyncPlayElement(element).bufferEnd, isNull);
    _fixture(
      element,
      ranges: [
        [10, double.infinity],
      ],
    );
    expect(readWebSyncPlayElement(element).bufferEnd, isNull);
  });
  test('only the current live WebPlayer element is sampled; no media source is assigned', () async {
    expect(readWebSyncPlayBufferSample(Object()), isNull);
    final player = mpv.WebPlayer(configuration: const mpv.PlayerConfiguration());
    final element = (player as dynamic).element as web.HTMLVideoElement;
    _fixture(element);
    expect(readWebSyncPlayBufferSample(player)!.bufferEnd, const Duration(seconds: 12));
    expect(element.currentSrc, isEmpty);
    await player.dispose();
    expect(readWebSyncPlayBufferSample(player), isNull);
  });
}
