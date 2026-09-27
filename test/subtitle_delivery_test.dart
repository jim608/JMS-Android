import 'package:fladder/util/subtitle_delivery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Jellyfin query format cannot override the ASS route extension back to plain text', () {
    for (final codec in ['ass', 'ssa']) {
      final requested = Uri.parse(
          subtitleDeliveryUrl('/Videos/id/source/Subtitles/3/Stream.vtt?format=vtt&api_key=test-only', codec)!);
      expect(requested.path, endsWith('/Stream.$codec'));
      expect(requested.queryParameters['format'], codec);
      expect(requested.queryParameters['api_key'], 'test-only');
    }
  });

  test('ASS and SSA retain their format on Jellyfin delivery endpoints', () {
    expect(subtitleDeliveryUrl('/Videos/id/Subtitles/2/Stream.vtt', 'ass'), '/Videos/id/Subtitles/2/Stream.ass');
    expect(subtitleDeliveryUrl('/Videos/id/Subtitles/3/Stream.vtt', 'SSA'), '/Videos/id/Subtitles/3/Stream.ssa');
  });
  test('case-insensitive duplicate format keys cannot force a text conversion; other query values survive', () {
    final result = Uri.parse(subtitleDeliveryUrl(
        '/Videos/id/source/Subtitles/3/Stream.vtt?Format=vtt&format=srt&name=%E4%B8%AD%E6%96%87&tag=a&tag=b&api_key=a%2Bb%26c',
        'ASS')!);
    expect(result.queryParametersAll['Format'], ['ass']);
    expect(result.queryParametersAll['format'], ['ass']);
    expect(result.queryParametersAll['tag'], ['a', 'b']);
    expect(result.queryParameters['name'], '中文');
    expect(result.queryParameters['api_key'], 'a+b&c');
  });
  test('Unicode paths and authentication query are preserved', () {
    final result = Uri.parse(subtitleDeliveryUrl('/測試/繁體.vtt?api_key=test-only&startPositionTicks=100', 'ass')!);
    expect(result.pathSegments, ['測試', '繁體.ass']);
    expect(result.queryParameters, {'api_key': 'test-only', 'startPositionTicks': '100'});
  });
  test('SRT delivery remains supported and original ASS endpoints are untouched', () {
    expect(subtitleDeliveryUrl('/Stream.vtt', 'subrip'), '/Stream.srt');
    expect(subtitleDeliveryUrl('/字幕.ass?name=original.vtt', 'ass'), '/%E5%AD%97%E5%B9%95.ass?name=original.vtt');
    expect(subtitleDeliveryUrl(null, 'ass'), isNull);
    expect(subtitleDeliveryUrl('', 'ass'), isNull);
  });
}
