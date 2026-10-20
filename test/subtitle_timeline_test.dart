import 'package:fladder/util/subtitle_timeline.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SRT conversion preserves cue identifiers, text and line breaks', () {
    expect(
      browserSubtitleVtt(
          '\uFEFF1\r\n00:00:01,100 --> 00:00:02,250\r\n<b>你好</b>\r\n第二行\r\n'),
      'WEBVTT\n\n1\n00:00:01.100 --> 00:00:02.250\n<b>你好</b>\n第二行\n',
    );
  });

  test('existing WebVTT is retained and unsupported formats fail clearly', () {
    const vtt = 'WEBVTT\n\n00:01.000 --> 00:02.000\nHello';
    expect(browserSubtitleVtt(vtt), vtt);
    expect(() => browserSubtitleVtt('[Script Info]\nASS text'),
        throwsFormatException);
    expect(() => browserSubtitleVtt('<html>Server error</html>'),
        throwsFormatException);
  });

  test('positive offset delays cues and negative offset advances cues', () {
    bool active(double position, double offset) => subtitleCueIsActive(
        start: 1, end: 2, position: position, offset: offset);
    expect(active(1, 0), isTrue);
    expect(active(2, 0), isFalse);
    expect(active(1, .1), isFalse);
    expect(active(1.1, .1), isTrue);
    expect(active(.9, -.1), isTrue);
    expect(active(1.9, -.1), isFalse);
    expect(active(61, 60), isTrue);
    expect(active(0, -60), isFalse);
    expect(active(double.nan, 0), isFalse);
    expect(
        subtitleCueIsActive(
            start: double.infinity, end: 2, position: 1, offset: 0),
        isFalse);
  });
}
