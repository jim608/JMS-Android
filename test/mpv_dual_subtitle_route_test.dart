import 'package:fladder/util/mpv_subtitle_route.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Map<String, String> properties;
  late Map<String, String> writes;

  setUp(() {
    properties = {
      'sid': '2',
      'secondary-sid': '3',
      'track-list/count': '2',
      'track-list/0/type': 'sub',
      'track-list/0/id': '2',
      'track-list/0/codec': 'subrip',
      'track-list/1/type': 'sub',
      'track-list/1/id': '3',
      'track-list/1/codec': 'webvtt',
      'sub-ass': 'yes',
      'sub-ass-override': 'no',
      'sub-visibility': 'yes',
    };
    writes = {};
  });

  Future<MpvSubtitleRoute> configure({
    String expected = 'srt',
    bool dualText = true,
    bool preference = true,
    bool rejectVisibility = false,
  }) =>
      MpvSubtitleRoute.configure(
        read: (name) async => properties[name] ?? '',
        write: (name, value) async {
          writes[name] = value;
          if (name != 'sub-visibility' || !rejectVisibility) {
            properties[name] = value;
          }
        },
        expectedCodec: expected,
        plainTextPreference: preference,
        dualText: dualText,
      );

  test(
      'confirmed plain tracks enable dual overlay without duplicating native subtitles',
      () async {
    for (final pair in [
      (expected: 'srt', runtime: 'subrip'),
      (expected: ' WEBVTT ', runtime: 'vtt'),
      (expected: 'text', runtime: 'text'),
    ]) {
      properties['track-list/0/codec'] = pair.runtime;
      final route = await configure(expected: pair.expected);
      expect(route.dualText, isTrue);
      expect(route.plainOverlay, isTrue);
      expect(route.visibility, 'no');
      expect(writes['sub-visibility'], 'no');
      expect(writes['sub-ass'], 'yes');
      expect(writes['sub-ass-override'], 'no');
      expect(properties['sid'], '2');
      expect(properties['secondary-sid'], '3');
    }
  });

  test('disabling dual mode restores the existing primary native preference',
      () async {
    expect((await configure()).dualText, isTrue);
    final route = await configure(dualText: false);
    expect(route.dualText, isFalse);
    expect(route.plainOverlay, isFalse);
    expect(route.visibility, 'yes');
    expect(route.renderer, 'mpv native/libass');
  });

  test('ASS and SSA metadata cannot be flattened by a dual text request',
      () async {
    for (final expected in ['ass', 'SSA']) {
      final route = await configure(expected: expected, preference: false);
      expect(route.dualText, isFalse, reason: expected);
      expect(route.plainOverlay, isFalse, reason: expected);
      expect(route.visibility, 'yes', reason: expected);
      expect(writes['sub-ass'], 'yes');
      expect(writes['sub-ass-override'], 'no');
    }
  });

  test('runtime styled and bitmap codecs stay native despite plain metadata',
      () async {
    for (final codec in ['ass', 'ssa', 'hdmv_pgs_subtitle', 'dvd_subtitle']) {
      properties['track-list/0/codec'] = codec;
      final route = await configure(preference: false);
      expect(route.dualText, isFalse, reason: codec);
      expect(route.plainOverlay, isFalse, reason: codec);
      expect(route.visibility, 'yes', reason: codec);
    }
  });

  test(
      'non-text metadata is insufficient for dual mode even when runtime is text',
      () async {
    for (final expected in [
      'hdmv_pgs_subtitle',
      'dvd_subtitle',
      'unknown',
      ''
    ]) {
      final route = await configure(expected: expected);
      expect(route.dualText, isFalse, reason: expected);
      expect(route.plainOverlay, isFalse, reason: expected);
      expect(route.visibility, 'yes', reason: expected);
    }
  });

  test(
      'unavailable runtime codec cannot confirm dual mode and preserves single text behavior',
      () async {
    properties['track-list/0/codec'] = '';
    final native = await configure();
    expect(native.dualText, isFalse);
    expect(native.plainOverlay, isFalse);
    expect(native.visibility, 'yes');

    final text = await configure(preference: false);
    expect(text.dualText, isFalse);
    expect(text.plainOverlay, isTrue);
    expect(text.visibility, 'no');
  });

  test('subtitle off never reports dual rendering as active', () async {
    properties['sid'] = 'no';
    final route = await configure();
    expect(route.dualText, isFalse);
    expect(route.renderer, 'off');
  });

  test(
      'rejected native hiding cannot report the requested dual overlay as active',
      () async {
    final route = await configure(rejectVisibility: true);
    expect(writes['sub-visibility'], 'no');
    expect(route.visibility, 'yes');
    expect(route.plainOverlay, isFalse);
    expect(route.dualText, isFalse);
  });
}
