import 'package:fladder/util/mpv_subtitle_selection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ASS extracted from an original embedded track uses full ASS delivery during HLS playback', () {
    for (final codec in ['ass', 'ssa']) {
      expect(
        useExternalSubtitleSource(
          isExternal: false,
          transcoded: true,
          supportsExternalStream: true,
          codec: codec,
          url: 'https://test.invalid/Videos/id/source/Subtitles/3/Stream.$codec',
        ),
        isTrue,
        reason: 'Original IsExternal=false is not the delivery method of a transcoded video',
      );
    }
  });

  test('direct-play embedded ASS keeps native demuxing and attached fonts', () {
    expect(
      useExternalSubtitleSource(
        isExternal: false,
        transcoded: false,
        supportsExternalStream: true,
        codec: 'ass',
        url: 'https://test.invalid/Stream.ass',
      ),
      isFalse,
    );
  });

  test('unavailable delivery is not invented and SRT embedded behavior is unchanged', () {
    for (final candidate in [
      (codec: 'ass', supported: false, url: 'https://test.invalid/Stream.ass'),
      (codec: 'ass', supported: true, url: ''),
      (codec: 'ass', supported: true, url: null),
      (codec: 'srt', supported: true, url: 'https://test.invalid/Stream.srt'),
    ]) {
      expect(
        useExternalSubtitleSource(
          isExternal: false,
          transcoded: true,
          supportsExternalStream: candidate.supported,
          codec: candidate.codec,
          url: candidate.url,
        ),
        isFalse,
      );
    }
  });

  test('external files including offline ASS and SRT retain the external route', () {
    for (final codec in ['ass', 'ssa', 'srt']) {
      expect(
        useExternalSubtitleSource(
          isExternal: true,
          transcoded: false,
          supportsExternalStream: false,
          codec: codec,
          url: '/local/字幕.$codec',
        ),
        isTrue,
      );
    }
  });
}
