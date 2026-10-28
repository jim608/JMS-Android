import 'package:fladder/models/items/media_segments_model.dart';

bool usesOpeningEndingModes(MediaSegmentType type) => type == MediaSegmentType.intro || type == MediaSegmentType.outro;

List<SegmentSkip> selectableSegmentSkipModes(MediaSegmentType type) => usesOpeningEndingModes(type)
    ? const [SegmentSkip.none, SegmentSkip.askToSkip, SegmentSkip.skipOnce]
    : SegmentSkip.values;

/// Retain the saved enum values while presenting one automatic mode for OP/ED.
SegmentSkip displayedSegmentSkipMode(MediaSegmentType type, SegmentSkip? saved) {
  final value = saved ?? defaultSegmentSkipValues[type] ?? SegmentSkip.askToSkip;
  return usesOpeningEndingModes(type) && value == SegmentSkip.skip ? SegmentSkip.skipOnce : value;
}

/// Older settings can omit a media type. Opening and ending still get their
/// independent prompt defaults and remain configurable in the settings page.
Map<MediaSegmentType, SegmentSkip> completeSegmentSkipSettings(Map<MediaSegmentType, SegmentSkip> saved) =>
    {...defaultSegmentSkipValues, ...saved};
