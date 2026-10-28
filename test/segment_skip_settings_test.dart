import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/models/items/media_segments_model.dart';
import 'package:fladder/util/segment_skip_settings.dart';

void main() {
  test('opening and ending each offer exactly off, prompt and automatic', () {
    for (final type in [MediaSegmentType.intro, MediaSegmentType.outro]) {
      expect(selectableSegmentSkipModes(type), [SegmentSkip.none, SegmentSkip.askToSkip, SegmentSkip.skipOnce]);
      expect(displayedSegmentSkipMode(type, null), SegmentSkip.askToSkip);
      expect(displayedSegmentSkipMode(type, SegmentSkip.skip), SegmentSkip.skipOnce);
      expect(displayedSegmentSkipMode(type, SegmentSkip.skipOnce), SegmentSkip.skipOnce);
    }
  });

  test('restoring incomplete settings preserves independent choices and fills prompt defaults', () {
    final restored = completeSegmentSkipSettings({MediaSegmentType.intro: SegmentSkip.none});
    expect(restored[MediaSegmentType.intro], SegmentSkip.none);
    expect(restored[MediaSegmentType.outro], SegmentSkip.askToSkip);
    final changed = {...restored, MediaSegmentType.outro: SegmentSkip.skipOnce};
    expect(changed[MediaSegmentType.intro], SegmentSkip.none);
    expect(changed[MediaSegmentType.outro], SegmentSkip.skipOnce);
  });

  test('other media types retain all existing modes', () {
    expect(selectableSegmentSkipModes(MediaSegmentType.recap), SegmentSkip.values);
    expect(displayedSegmentSkipMode(MediaSegmentType.recap, SegmentSkip.skip), SegmentSkip.skip);
  });
}
