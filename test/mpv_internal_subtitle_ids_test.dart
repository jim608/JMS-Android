import 'package:fladder/util/dual_subtitle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
      'container ids exclude previously added external tracks and non-subtitles',
      () async {
    final properties = {
      'track-list/count': '5',
      'track-list/0/type': 'video',
      'track-list/1/type': 'sub',
      'track-list/1/id': '2',
      'track-list/1/external': 'no',
      'track-list/2/type': 'sub',
      'track-list/2/id': '8',
      'track-list/2/external': 'yes',
      'track-list/3/type': 'sub',
      'track-list/3/id': '4',
      'track-list/3/external': 'no',
      'track-list/4/type': 'audio',
    };
    expect(await internalMpvSubtitleIds((name) async => properties[name] ?? ''),
        ['2', '4']);
  });

  test(
      'unknown external flags and sentinel ids cannot be mistaken for container tracks',
      () async {
    final properties = {
      'track-list/count': '4',
      'track-list/0/type': 'sub',
      'track-list/0/id': '9',
      'track-list/1/type': 'sub',
      'track-list/1/id': 'no',
      'track-list/1/external': 'no',
      'track-list/2/type': 'sub',
      'track-list/2/id': 'auto',
      'track-list/2/external': 'false',
      'track-list/3/type': 'sub',
      'track-list/3/id': '7',
      'track-list/3/external': 'false',
    };
    expect(await internalMpvSubtitleIds((name) async => properties[name] ?? ''),
        ['7']);
  });

  test('unavailable track list fails without selecting an arbitrary track',
      () async {
    expect(await internalMpvSubtitleIds((_) async => ''), isEmpty);
  });
}
