// Standalone: dart compile js test/fixtures/web_subtitle_timing_probe.dart.
// Serve beside fixture.mp4, captions.srt and replacement.srt. The bounded
// loopback test server supplies slow.srt, redirect.srt and a second CORS origin.
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'package:fladder/util/web_subtitle_timing_web.dart';

Future<void> main() async {
  final output = web.document.querySelector('#result')!;
  final records = <Map<String, Object?>>[];
  var text = '';
  var available = false;
  final timing = WebSubtitleTiming(
    onText: (value) {
      text = value;
      web.document.querySelector('#subtitle')!.textContent = value;
    },
    onAvailable: (value) => available = value,
  );
  final video = web.document.querySelector('video') as web.HTMLVideoElement;
  void check(String name, bool passed,
      [Map<String, Object?> values = const {}]) {
    records.add({'check': name, 'passed': passed, ...values});
    if (!passed) throw StateError(name);
  }

  Future<void> until(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 4));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('Probe condition timed out');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<void> select(String url) async {
    final prepared = await timing.prepareSubtitle(url);
    video.appendChild(web.HTMLTrackElement()
      ..kind = 'subtitles'
      ..src = prepared);
    timing.selectTrack();
    await until(() => available);
  }

  Future<void> seek(double value) async {
    video.currentTime = value;
    await until(
        () => (video.currentTime - value).abs() < .04 && !video.seeking);
    timing.refresh();
  }

  Future<bool> rejected(String url) async {
    try {
      await timing.prepareSubtitle(url);
      return false;
    } catch (_) {
      return true;
    }
  }

  try {
    final videoResponse = await web.window.fetch('fixture.mp4'.toJS).toDart;
    final videoBlob = await videoResponse.blob().toDart;
    video
      ..muted = true
      ..src = web.URL.createObjectURL(videoBlob);
    await until(() => video.readyState >= web.HTMLMediaElement.HAVE_METADATA);
    check('local real video loaded', video.duration >= 2,
        {'duration': video.duration});
    timing.attachElement(video);
    await select('captions.srt');
    check('real SRT fetched and normalized into a loaded hidden browser track',
        available && video.textTracks.length == 1);
    await seek(1.05);
    await timing.write('sub-delay', '0.100');
    check('paused +100ms delays subtitle', video.paused && text == '第一段',
        {'text': text, 'time': video.currentTime});
    await timing.write('sub-delay', '-0.100');
    check('paused -100ms advances subtitle', video.paused && text == '第二段',
        {'text': text, 'time': video.currentTime});
    check('offset readback', await timing.read('sub-delay') == '-0.100');
    video.playbackRate = .25;
    await video.play().toDart;
    await seek(1.05);
    final before = video.currentTime;
    await timing.write('sub-delay', '0.100');
    check('playing +100ms applies without pause or seek',
        !video.paused && text == '第一段' && video.currentTime >= before);
    await timing.write('sub-delay', '-0.100');
    check('playing -100ms applies without pause or seek',
        !video.paused && text == '第二段' && video.currentTime >= before);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    check('video keeps advancing after timing changes',
        !video.paused && video.currentTime > before);
    video.pause();
    await timing.write('sub-delay', '60.000');
    check('positive 60 second bound is supported',
        text.isEmpty && await timing.read('sub-delay') == '60.000');
    await timing.write('sub-delay', '-60.000');
    check('negative 60 second bound is supported',
        text.isEmpty && await timing.read('sub-delay') == '-60.000');
    await timing.write('sub-delay', '0.000');
    timing.clearTrack();
    check(
        'media reset clears text and previous browser track',
        !available &&
            text.isEmpty &&
            video.querySelectorAll('track').length == 0);
    await select('replacement.srt');
    await seek(.5);
    check(
        'replacement uses its own cues and reset offset',
        text == '替換字幕' &&
            video.querySelectorAll('track').length == 1 &&
            await timing.read('sub-delay') == '0.000');
    timing.clearTrack();
    final pending = rejected('slow.srt');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    timing.clearTrack();
    check(
        'cancelled late source cannot attach a track',
        await pending &&
            !available &&
            text.isEmpty &&
            video.querySelectorAll('track').length == 0);
    await video.play().toDart;
    await seek(.4);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    check(
        'stopped subtitle session stays cleared when retained video emits later time events',
        timing.supported &&
            !available &&
            text.isEmpty &&
            video.querySelectorAll('track').length == 0);
    video.pause();
    check('HTTP error is rejected', await rejected('missing.srt'));
    check('redirect is rejected before attaching any track',
        await rejected('redirect.srt'));
    final cors = Uri.parse(web.window.location.href)
        .replace(host: 'localhost', path: '/captions.srt')
        .toString();
    check('cross-origin source without CORS is rejected', await rejected(cors));
    await select('captions.srt');
    timing.dispose();
    final disposedText = text;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    check(
        'dispose removes track and stops callbacks',
        !timing.supported &&
            !available &&
            disposedText.isEmpty &&
            text.isEmpty &&
            video.querySelectorAll('track').length == 0);
    output.textContent = jsonEncode({'passed': true, 'checks': records});
    output.setAttribute('data-state', 'complete');
  } catch (error) {
    timing.dispose();
    output.textContent =
        jsonEncode({'passed': false, 'failure': '$error', 'checks': records});
    output.setAttribute('data-state', 'failed');
  }
}
