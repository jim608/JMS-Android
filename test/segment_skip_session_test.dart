import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/models/items/media_segments_model.dart';
import 'package:fladder/providers/segment_skip_provider.dart';
import 'package:fladder/services/syncplay/syncplay_models.dart';
import 'package:fladder/services/playback/segment_skip_policy.dart';

void main() {
  test('fresh playback after completion resets while intentional seek replay preserves occurrence', () {
    final session = SegmentSkipSession()..bindItem('one');
    final first = session.playbackId;
    session.markCompleted();
    session.bindItem('one');
    expect(identical(session.playbackId, first), isFalse);
    final second = session.playbackId;
    session.markCompleted();
    session.manualSeek(const Duration(minutes: 1), Duration.zero);
    session.bindItem('one');
    expect(identical(session.playbackId, second), isTrue);
  });
  final group = SyncPlayGroup(groupId: 'group', groupName: 'room', lastUpdatedAt: DateTime.utc(2026));
  final segment = MediaSegment(
    type: MediaSegmentType.intro,
    start: const Duration(seconds: 5),
    end: const Duration(seconds: 20),
    explicitBounds: true,
  );

  test('solo permits manual and automatic skip unless a room transition is busy', () {
    const idle = SyncPlayControllerState(status: SyncPlayStatus.idle);
    expect(segmentSkipCanAuto(idle, wrapperActive: false), isTrue);
    expect(segmentSkipCanSeek(idle, wrapperActive: false), isTrue);
    expect(segmentSkipCanAuto(idle, wrapperActive: false, busy: true), isFalse);
    expect(segmentSkipCanSeek(idle, wrapperActive: false, busy: true), isFalse);
    expect(segmentSkipCanAuto(idle, wrapperActive: true), isFalse);
    expect(segmentSkipCanSeek(idle, wrapperActive: true), isFalse);
  });

  test('transitional and disconnected rooms never authorize segment seeks', () {
    for (final status
        in SyncPlayStatus.values.where((value) => value != SyncPlayStatus.idle && value != SyncPlayStatus.joined)) {
      final room = SyncPlayControllerState(status: status, group: group, clockSynchronized: true);
      for (final active in [false, true]) {
        expect(segmentSkipCanAuto(room, wrapperActive: active), isFalse, reason: '$status active=$active');
        expect(segmentSkipCanSeek(room, wrapperActive: active), isFalse, reason: '$status active=$active');
      }
    }
  });

  test('joined group allows only authorized manual room seeks and suppresses auto', () {
    for (final connected in [false, true]) {
      for (final synchronized in [false, true]) {
        for (final active in [false, true]) {
          final room = SyncPlayControllerState(
            status: SyncPlayStatus.joined,
            group: group,
            connected: connected,
            clockSynchronized: synchronized,
          );
          expect(segmentSkipCanAuto(room, wrapperActive: active), isFalse);
          expect(segmentSkipCanSeek(room, wrapperActive: active), connected && synchronized && active);
          expect(segmentSkipCanSeek(room, wrapperActive: active, busy: true), isFalse);
        }
      }
    }
  });

  test('same item renderer reload preserves consumed skip; new item and reset start a fresh occurrence', () {
    final session = SegmentSkipSession()..bindItem('one');
    final firstId = session.playbackId;
    SegmentSkipDecision? evaluate() => session.policy.evaluate(
          playbackId: session.playbackId,
          segments: [segment],
          position: const Duration(seconds: 7),
          duration: const Duration(minutes: 2),
          modes: {MediaSegmentType.intro: SegmentSkip.skipOnce},
          playing: true,
          canAutoSkip: true,
        );
    expect(evaluate()?.autoSkip, isTrue);
    expect(evaluate(), isNull);
    session.bindItem('one');
    expect(identical(session.playbackId, firstId), isTrue);
    expect(evaluate(), isNull);

    session.bindItem('two');
    expect(identical(session.playbackId, firstId), isFalse);
    expect(evaluate()?.autoSkip, isTrue);
    session.reset();
    final resetId = session.playbackId;
    expect(evaluate()?.autoSkip, isTrue);
    session.bindItem('two');
    expect(identical(session.playbackId, resetId), isFalse);
    expect(evaluate()?.autoSkip, isTrue);
  });
}
