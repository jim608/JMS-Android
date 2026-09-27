import 'package:fladder/util/mpv_subtitle_route.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('diagnostics inspect received ASS effects without exposing dialogue or URLs', () {
    expect(activeAssEffects(r'{\pos(10,20)\move(1,2,3,4)\fad(100,200)\t(\fs40)\clip(1,2,3,4)\p1\kf20}secret'),
        'clip, fad, kf, move, p, pos, t');
    expect(activeAssEffects(''), 'unknown / no active cue');
    expect(activeAssEffects('plain private dialogue'), 'none in active cue (not whole track)');
  });
  late Map<String, String> properties;
  late Map<String, String> writes;
  setUp(() {
    properties = {
      'sid': '2',
      'secondary-sid': '1',
      'track-list/count': '3',
      'track-list/0/type': 'video',
      'track-list/0/id': '1',
      'track-list/1/type': 'sub',
      'track-list/1/id': '1',
      'track-list/1/codec': 'subrip',
      'track-list/2/type': 'sub',
      'track-list/2/id': '2',
      'track-list/2/codec': 'ass',
      'sub-ass': 'no',
      'sub-visibility': 'no',
      'sub-ass-override': 'strip',
    };
    writes = {};
  });

  Future<MpvSubtitleRoute> configure({bool preference = false, String expected = 'ass', bool reject = false}) =>
      MpvSubtitleRoute.configure(
        read: (name) async => properties[name] ?? '',
        write: (name, value) async {
          writes[name] = value;
          if (!reject) properties[name] = value;
        },
        expectedCodec: expected,
        plainTextPreference: preference,
      );

  test('legacy false preference cannot strip selected primary ASS; secondary SRT is not primary', () async {
    final route = await configure();
    expect(route.codec, 'ass');
    expect(route.renderer, 'mpv native/libass');
    expect(route.plainOverlay, isFalse);
    expect(writes, {'sub-ass': 'yes', 'sub-ass-override': 'no', 'embeddedfonts': 'yes', 'sub-visibility': 'yes'});
    expect(properties['secondary-sid'], '1');
  });

  test('SSA is styled, bitmap and unknown codecs never enter a plain text overlay', () {
    for (final codec in ['ssa', 'ass', 'hdmv_pgs_subtitle', '', 'unknown']) {
      expect(useNativeSubtitle(codec, false), isTrue, reason: codec);
    }
  });

  test('native SRT has exactly one renderer, without a duplicate Flutter overlay', () async {
    properties['track-list/2/codec'] = 'subrip';
    final route = await configure(preference: true, expected: 'srt');
    expect(route.plainOverlay, isFalse);
    expect(route.visibility, 'yes');
  });

  test('plain SRT retains saved false preference and hides native rendering', () async {
    properties['track-list/2/codec'] = 'subrip';
    final route = await configure(expected: 'srt');
    expect(route.plainOverlay, isTrue);
    expect(route.renderer, 'Flutter text (native hidden)');
    expect(route.visibility, 'no');
  });

  test('runtime codec detects converted or incorrectly labelled ASS, not just metadata', () async {
    properties['track-list/2/codec'] = 'subrip';
    final route = await configure(expected: 'ass');
    expect(route.codec, 'subrip');
    expect(route.plainOverlay, isFalse);
    expect(route.visibility, 'yes');
    expect(route.renderer, 'ASS source format mismatch (subrip); effects unavailable');
  });

  test('unavailable runtime codec is unknown; ASS metadata never falls back to plain text', () async {
    properties['track-list/2/codec'] = '';
    final route = await configure();
    expect(route.codec, isEmpty);
    expect(route.renderer, 'unknown');
    expect(route.plainOverlay, isFalse);
  });

  test('silently rejected native options cannot be reported as applied', () async {
    final route = await configure(reject: true);
    expect(route.renderer, 'unknown');
    expect(route.plainOverlay, isFalse);
    properties['sub-visibility'] = 'yes';
    expect((await configure(reject: true)).renderer, 'ASS configuration mismatch');
  });

  test('deselecting subtitles is off, not an inferred ASS pass', () async {
    properties['sid'] = 'no';
    expect((await configure()).renderer, 'off');
  });
}
