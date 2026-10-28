import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart' as dto;
import 'package:fladder/models/items/media_segments_model.dart';
import 'package:fladder/services/playback/segment_skip_policy.dart';

MediaSegment _segment(int start, int end, {MediaSegmentType type = MediaSegmentType.intro}) => MediaSegment(
      type: type,
      start: Duration(seconds: start),
      end: Duration(seconds: end),
      explicitBounds: true,
    );

void main() {
  late SegmentSkipPolicy policy;
  final intro = _segment(10, 30);
  final outro = _segment(70, 90, type: MediaSegmentType.outro);

  SegmentSkipDecision? evaluate({
    Object playbackId = 'first play',
    Iterable<MediaSegment>? segments,
    int position = 15,
    int duration = 100,
    Map<MediaSegmentType, SegmentSkip> modes = const {},
    bool playing = true,
    bool canAutoSkip = true,
  }) =>
      policy.evaluate(
        playbackId: playbackId,
        segments: segments ?? [intro, outro],
        position: Duration(seconds: position),
        duration: Duration(seconds: duration),
        modes: modes,
        playing: playing,
        canAutoSkip: canAutoSkip,
      );

  setUp(() => policy = SegmentSkipPolicy());

  test('missing metadata and unknown duration never create a skip target', () {
    expect(evaluate(segments: []), isNull);
    expect(evaluate(duration: 0), isNull);
    expect(evaluate(duration: -1), isNull);
  });

  test('requires valid explicit bounds and deduplicates sorted targets', () {
    final valid = SegmentSkipPolicy.validSegments([
      outro,
      _segment(-1, 20),
      _segment(15, 15),
      _segment(20, 10),
      _segment(0, 101),
      _segment(10, 30, type: MediaSegmentType.unknown),
      MediaSegment(type: MediaSegmentType.intro, start: Duration.zero, end: const Duration(seconds: 30)),
      intro,
      _segment(10, 30),
    ], duration: const Duration(seconds: 100));
    expect(valid, [intro, outro]);
  });

  test('start is inclusive and end is exclusive, including adjacent boundaries', () {
    expect(evaluate(position: 9), isNull);
    expect(evaluate(position: 10)?.segment, intro);
    expect(evaluate(position: 30), isNull);
    final adjacent = _segment(30, 50, type: MediaSegmentType.outro);
    expect(evaluate(segments: [intro, adjacent], position: 30)?.segment, adjacent);
    expect(evaluate(segments: [_segment(90, 100)], position: 100), isNull);
  });

  test('conflicting overlaps are rejected rather than choosing an arbitrary skip endpoint', () {
    expect(SegmentSkipPolicy.validSegments([intro, _segment(20, 35), outro], duration: const Duration(seconds: 100)),
        [outro]);
    expect(
        evaluate(
            segments: [intro, _segment(10, 30, type: MediaSegmentType.outro)],
            modes: {MediaSegmentType.intro: SegmentSkip.skip}),
        isNull);
  });

  test('opening and ending default independently to prompt, and off disables only its type', () {
    expect(evaluate()?.autoSkip, isFalse);
    expect(evaluate(modes: {MediaSegmentType.intro: SegmentSkip.none}), isNull);
    expect(evaluate(position: 75, modes: {MediaSegmentType.intro: SegmentSkip.none})?.segment, outro);
    expect(evaluate(position: 75)?.autoSkip, isFalse);
  });

  for (final autoMode in [SegmentSkip.skip, SegmentSkip.skipOnce]) {
    test('$autoMode reserves exactly one auto attempt through duplicate events and reentry', () {
      final modes = {MediaSegmentType.intro: autoMode};
      expect(evaluate(modes: modes)?.autoSkip, isTrue);
      expect(evaluate(modes: modes), isNull);
      expect(evaluate(position: 31, modes: modes), isNull);
      expect(evaluate(position: 12, modes: modes), isNull);
      expect(evaluate(playbackId: 'next play', modes: modes)?.autoSkip, isTrue);
    });
  }

  test('paused playback prompts and auto starts only when playing', () {
    final modes = {MediaSegmentType.intro: SegmentSkip.skip};
    expect(evaluate(modes: modes, playing: false)?.autoSkip, isFalse);
    expect(evaluate(modes: modes)?.autoSkip, isTrue);
  });

  test('manual seek into a segment or backwards across it offers replay without auto', () {
    final modes = {MediaSegmentType.intro: SegmentSkip.skip};
    evaluate(position: 5, modes: modes);
    policy.manualSeek(const Duration(seconds: 5), const Duration(seconds: 20));
    expect(evaluate(position: 20, modes: modes)?.autoSkip, isFalse);
    policy.reset();
    evaluate(position: 50, modes: modes);
    policy.manualSeek(const Duration(seconds: 50), Duration.zero);
    expect(evaluate(position: 11, modes: modes)?.autoSkip, isFalse);
  });

  test('manual seek before a future segment still permits its natural automatic skip', () {
    final modes = {MediaSegmentType.intro: SegmentSkip.skip};
    evaluate(position: 1, modes: modes);
    policy.manualSeek(const Duration(seconds: 1), const Duration(seconds: 5));
    expect(evaluate(position: 11, modes: modes)?.autoSkip, isTrue);
  });

  test('manual seek before the first metadata evaluation suppresses destination auto skip', () {
    policy.manualSeek(Duration.zero, const Duration(seconds: 15));
    expect(evaluate(modes: {MediaSegmentType.intro: SegmentSkip.skip})?.autoSkip, isFalse);
  });

  test('manual replay before duration or late segment metadata arrives remains a prompt', () {
    final modes = {MediaSegmentType.intro: SegmentSkip.skip};
    expect(evaluate(position: 50, duration: 0, modes: modes), isNull);
    policy.manualSeek(const Duration(seconds: 50), Duration.zero);
    expect(evaluate(segments: [], position: 5, modes: modes), isNull);
    expect(evaluate(position: 15, modes: modes)?.autoSkip, isFalse);
    expect(evaluate(playbackId: 'next playback', position: 15, modes: modes)?.autoSkip, isTrue);
  });

  test('multiple pending manual seek ranges preserve earlier replay choices', () {
    policy.reset('first play');
    policy.manualSeek(const Duration(seconds: 50), const Duration(seconds: 5));
    policy.manualSeek(const Duration(seconds: 5), const Duration(seconds: 65));
    policy.manualSeek(const Duration(seconds: 65), const Duration(seconds: 75));
    final modes = {MediaSegmentType.intro: SegmentSkip.skip, MediaSegmentType.outro: SegmentSkip.skip};
    expect(evaluate(position: 15, modes: modes)?.autoSkip, isFalse);
    expect(evaluate(position: 75, modes: modes)?.autoSkip, isFalse);
  });

  test('cancellation survives duplicates, reentry and mode changes until a new playback', () {
    expect(evaluate()?.autoSkip, isFalse);
    policy.cancel(intro);
    expect(evaluate(), isNull);
    expect(evaluate(position: 35), isNull);
    policy.manualSeek(const Duration(seconds: 35), const Duration(seconds: 15));
    expect(evaluate(modes: {MediaSegmentType.intro: SegmentSkip.skip}), isNull);
    expect(evaluate(playbackId: 'replay')?.autoSkip, isFalse);
  });

  test('explicit skip suppresses stale position events and replay prompts for that occurrence', () {
    evaluate();
    policy.markSkipped(intro);
    expect(evaluate(), isNull);
    expect(evaluate(position: 40), isNull);
    expect(evaluate(position: 15), isNull);
  });

  test('turning auto on inside a segment offers a prompt, applying auto to later segments', () {
    evaluate();
    final modes = {MediaSegmentType.intro: SegmentSkip.skip, MediaSegmentType.outro: SegmentSkip.skip};
    expect(evaluate(modes: modes)?.autoSkip, isFalse);
    expect(evaluate(position: 75, modes: modes)?.autoSkip, isTrue);
  });

  test('followers offer prompts and a later authority change cannot produce a surprise seek', () {
    final modes = {MediaSegmentType.intro: SegmentSkip.skip};
    expect(evaluate(modes: modes, canAutoSkip: false)?.autoSkip, isFalse);
    expect(evaluate(modes: modes, canAutoSkip: false)?.autoSkip, isFalse);
    expect(evaluate(modes: modes, canAutoSkip: true)?.autoSkip, isFalse);
    expect(evaluate(playbackId: 'authorized solo playback', modes: modes)?.autoSkip, isTrue);
  });

  test('unavailable authority never consumes a user prompt or seeks a player', () {
    expect(evaluate(canAutoSkip: false)?.autoSkip, isFalse);
    policy.markSkipped(intro);
    expect(evaluate(canAutoSkip: false), isNull);
  });

  test('DTOs require both explicit endpoints and a recognized segment type', () {
    expect(const dto.MediaSegmentDto(type: dto.MediaSegmentType.intro, endTicks: 300000000).validToSegment, isNull);
    expect(const dto.MediaSegmentDto(type: dto.MediaSegmentType.intro, startTicks: 100000000).validToSegment, isNull);
    expect(
        const dto.MediaSegmentDto(type: dto.MediaSegmentType.intro, startTicks: -1, endTicks: 300000000).validToSegment,
        isNull);
    expect(
        const dto.MediaSegmentDto(type: dto.MediaSegmentType.intro, startTicks: 300000000, endTicks: 100000000)
            .validToSegment,
        isNull);
    expect(const dto.MediaSegmentDto(startTicks: 100000000, endTicks: 300000000).validToSegment, isNull);
    expect(
        const dto.MediaSegmentDto(type: dto.MediaSegmentType.intro, startTicks: 0, endTicks: 300000000)
            .validToSegment
            ?.toJson(),
        _segment(0, 30).toJson());
  });

  test('cached metadata preserves explicit provenance and old caches remain untrusted', () {
    final restored = MediaSegment.fromJson(intro.toJson());
    expect(restored.explicitBounds, isTrue);
    expect(evaluate(segments: [restored])?.segment.toJson(), intro.toJson());
    final oldCache = Map<String, dynamic>.from(intro.toJson())..remove('explicitBounds');
    final untrusted = MediaSegment.fromJson(oldCache);
    expect(untrusted.explicitBounds, isFalse);
    expect(evaluate(segments: [untrusted]), isNull);
  });
}
