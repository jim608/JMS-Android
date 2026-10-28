import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart' as dto;
import 'package:fladder/models/items/chapters_model.dart';
import 'package:fladder/models/media_playback_model.dart';
import 'package:fladder/models/playback/playback_model.dart';
import 'package:fladder/providers/image_provider.dart';
import 'package:fladder/providers/settings/video_player_settings_provider.dart';
import 'package:fladder/providers/syncplay_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/services/syncplay/syncplay_models.dart';
import 'package:fladder/wrappers/media_control_wrapper.dart';
import 'package:fladder/wrappers/players/player_states.dart';

class _Ref extends Fake implements Ref {
  _Ref() {
    values[syncPlayProvider] = const SyncPlayViewState();
  }
  final values = <Object, Object?>{};
  @override
  T read<T>(ProviderListenable<T> provider) => values[provider] as T;
}

class _Images extends Fake implements ImageNotifier {
  @override
  String getChapterUrl(String itemId, int chapterIndex,
          {dto.ImageType type = dto.ImageType.primary,
          int maxHeight = 576,
          int maxWidth = 384,
          int quality = 90}) =>
      '$itemId/$chapterIndex';
}

class _Playback extends Fake implements PlaybackModel {
  _Playback(this.chapters);
  @override
  final List<Chapter> chapters;
}

class _Player extends Fake implements MediaControlsWrapper {
  bool roomActive = false;
  @override
  bool get syncPlayActive => roomActive;
  @override
  final PlayerState lastState = PlayerState();
  final seeks = <Duration>[];
  Completer<void>? pending;
  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    await pending?.future;
    lastState.position = position;
  }
}

Chapter chapter(int seconds, {String? name}) => Chapter(
      name: name ?? '$seconds',
      imageUrl: '',
      startPosition: Duration(seconds: seconds),
    );

void main() {
  test('no chapters has no available directions', () {
    final navigation = <Chapter>[].navigationAt(const Duration(seconds: 10));
    expect(navigation.chapters, isEmpty);
    expect(navigation.previous, isNull);
    expect(navigation.next, isNull);
  });

  test(
      'unsorted duplicate and invalid starts are normalized without changing source',
      () {
    final first = chapter(10, name: 'first');
    final source = [
      chapter(30),
      first,
      chapter(-1),
      chapter(0),
      chapter(10, name: 'duplicate'),
      chapter(60),
      chapter(80)
    ];
    final navigation = source.navigationAt(const Duration(seconds: 10),
        duration: const Duration(seconds: 60));
    expect(
        navigation.chapters.map((chapter) => chapter.startPosition.inSeconds),
        [0, 10, 30]);
    expect(navigation.chapters[1], same(first));
    expect(source.first.startPosition.inSeconds, 30);
    expect(() => navigation.chapters.clear(), throwsUnsupportedError);
  });

  test('unknown media duration does not discard server timestamps', () {
    final chapters = [chapter(0), chapter(100)];
    expect(chapters.navigationAt(Duration.zero).next?.startPosition,
        const Duration(seconds: 100));
    expect(
        chapters
            .navigationAt(Duration.zero, duration: Duration.zero)
            .next
            ?.startPosition,
        const Duration(seconds: 100));
  });

  test(
      'strict directions before first, on boundaries and after final do not wrap',
      () {
    final chapters = [chapter(10), chapter(20), chapter(30)];
    for (final entry in <(int, int?, int?)>[
      (0, null, 10),
      (10, null, 20),
      (15, 10, 20),
      (20, 10, 30),
      (30, 20, null),
      (40, 30, null),
    ]) {
      final navigation = chapters.navigationAt(Duration(seconds: entry.$1));
      expect(navigation.previous?.startPosition.inSeconds, entry.$2,
          reason: 'previous at ${entry.$1}');
      expect(navigation.next?.startPosition.inSeconds, entry.$3,
          reason: 'next at ${entry.$1}');
    }
  });

  test(
      'server timestamps must exist and be nonnegative; original thumbnail index is retained',
      () {
    final ref = _Ref()..values[imageUtilityProvider] = _Images();
    final chapters = Chapter.chaptersFromInfo(
        'item',
        [
          const dto.ChapterInfo(name: 'missing'),
          const dto.ChapterInfo(name: 'negative', startPositionTicks: -1),
          const dto.ChapterInfo(name: 'zero', startPositionTicks: 0),
          const dto.ChapterInfo(name: 'valid', startPositionTicks: 100000010),
        ],
        ref);
    expect(chapters.map((chapter) => chapter.name), ['zero', 'valid']);
    expect(chapters.map((chapter) => chapter.imageUrl), ['item/2', 'item/3']);
    expect(chapters.last.startPosition, const Duration(microseconds: 10000001));
  });

  test(
      'provider seeks through wrapper once while pending and can navigate after completion',
      () async {
    final player = _Player()..pending = Completer<void>();
    final ref = _Ref()
      ..values[videoPlayerProvider] = player
      ..values[playBackModel] = _Playback([
        chapter(30),
        chapter(0),
        chapter(10),
        chapter(10),
        chapter(-1),
        chapter(60)
      ])
      ..values[mediaPlaybackProvider] =
          MediaPlaybackModel(duration: const Duration(seconds: 60));
    final settings = VideoPlayerSettingsProviderNotifier(ref);
    addTearDown(settings.dispose);
    final first = settings.nextChapter();
    await settings.nextChapter();
    await settings.prevChapter();
    expect(player.seeks, [const Duration(seconds: 10)]);
    player.pending!.complete();
    await first;
    player.pending = null;
    await settings.nextChapter();
    expect(player.seeks,
        [const Duration(seconds: 10), const Duration(seconds: 30)]);
    await settings.nextChapter();
    expect(player.seeks, hasLength(2));
    await settings.prevChapter();
    expect(player.seeks.last, const Duration(seconds: 10));
  });

  test('provider no-ops with no valid chapter or unavailable direction',
      () async {
    final player = _Player();
    final ref = _Ref()
      ..values[videoPlayerProvider] = player
      ..values[playBackModel] = _Playback([])
      ..values[mediaPlaybackProvider] =
          MediaPlaybackModel(duration: const Duration(seconds: 60));
    final settings = VideoPlayerSettingsProviderNotifier(ref);
    addTearDown(settings.dispose);
    await settings.nextChapter();
    await settings.prevChapter();
    ref.values[playBackModel] =
        _Playback([chapter(0), chapter(-1), chapter(60)]);
    await settings.nextChapter();
    await settings.prevChapter();
    expect(player.seeks, isEmpty);
  });

  test('failed seek releases the repeated-input guard', () async {
    final player = _Player()..pending = Completer<void>();
    final ref = _Ref()
      ..values[videoPlayerProvider] = player
      ..values[playBackModel] = _Playback([chapter(0), chapter(10)])
      ..values[mediaPlaybackProvider] =
          MediaPlaybackModel(duration: const Duration(seconds: 60));
    final settings = VideoPlayerSettingsProviderNotifier(ref);
    addTearDown(settings.dispose);
    final failed = expectLater(settings.nextChapter(), throwsStateError);
    player.pending!.completeError(StateError('synthetic seek failure'));
    await failed;
    player.pending = null;
    await settings.nextChapter();
    expect(player.seeks,
        [const Duration(seconds: 10), const Duration(seconds: 10)]);
  });

  test('room transitions cannot fall back to a local chapter seek', () async {
    final player = _Player();
    final ref = _Ref()
      ..values[videoPlayerProvider] = player
      ..values[playBackModel] = _Playback([chapter(0), chapter(10)])
      ..values[mediaPlaybackProvider] =
          MediaPlaybackModel(duration: const Duration(seconds: 60));
    final settings = VideoPlayerSettingsProviderNotifier(ref);
    addTearDown(settings.dispose);
    for (final view in [
      const SyncPlayViewState(busy: true),
      const SyncPlayViewState(preparingPlayback: true),
      const SyncPlayViewState(recoveryActive: true),
      const SyncPlayViewState(leavePending: true),
      const SyncPlayViewState(
          room: SyncPlayControllerState(status: SyncPlayStatus.joining)),
      const SyncPlayViewState(
          room: SyncPlayControllerState(status: SyncPlayStatus.joined)),
      const SyncPlayViewState(
          room: SyncPlayControllerState(status: SyncPlayStatus.disconnected)),
    ]) {
      ref.values[syncPlayProvider] = view;
      for (final active in [false, true]) {
        player.roomActive = active;
        await settings.nextChapter();
        await settings.prevChapter();
      }
    }
    expect(player.seeks, isEmpty);
    player.roomActive = true;
    ref.values[syncPlayProvider] = SyncPlayViewState(
        room: SyncPlayControllerState(
      status: SyncPlayStatus.joined,
      clockSynchronized: true,
      group: SyncPlayGroup(
          groupId: 'group',
          groupName: 'room',
          lastUpdatedAt: DateTime.utc(2026)),
    ));
    await settings.nextChapter();
    expect(player.seeks, [const Duration(seconds: 10)]);
  });
}
