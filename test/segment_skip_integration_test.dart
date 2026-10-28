import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/l10n/generated/app_localizations.dart';
import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/items/media_segments_model.dart';
import 'package:fladder/models/media_playback_model.dart';
import 'package:fladder/models/playback/playback_model.dart';
import 'package:fladder/models/settings/video_player_settings.dart';
import 'package:fladder/providers/segment_skip_provider.dart';
import 'package:fladder/providers/settings/video_player_settings_provider.dart';
import 'package:fladder/providers/syncplay_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/screens/video_player/components/segment_skip_overlay.dart';
import 'package:fladder/services/syncplay/syncplay_models.dart';
import 'package:fladder/services/syncplay/syncplay_player_commands.dart';
import 'package:fladder/wrappers/media_control_wrapper.dart';

class _User extends User {
  @override
  AccountModel? build() => null;
}

class _Room extends SyncPlayNotifier {
  _Room(super.ref);
  void view(SyncPlayViewState value) => state = value;
}

class _Playback extends Fake implements PlaybackModel {
  _Playback(List<MediaSegment> segments) : mediaSegments = MediaSegmentsModel(segments: segments);
  @override
  final MediaSegmentsModel mediaSegments;
}

/// Keep the production manual/automatic seek entry points and room routing.
/// Only the final backend operation is replaced, so no native player starts.
class _Player extends MediaControlsWrapper {
  _Player(Ref ref) : super(ref: ref);
  final localSeeks = <Duration>[];
  var automaticCalls = 0;
  Completer<void>? pending;

  @override
  Future<void> seekFromSyncPlay(Duration position) async {
    localSeeks.add(position);
    await pending?.future;
    ref.read(mediaPlaybackProvider.notifier).update((state) => state.copyWith(position: position));
  }

  @override
  Future<void> seekSegmentAutomatically(Duration position) {
    automaticCalls++;
    return super.seekSegmentAutomatically(position);
  }

  @override
  Future<void> dispose() async {}
}

class _Video extends VideoPlayerNotifier {
  _Video(super.ref) {
    state = _Player(ref);
  }
}

class _Commands extends Fake implements SyncPlayPlayerCommands {
  @override
  bool active = true;
  final seeks = <Duration>[];
  @override
  Future<void> seek(Duration position) async => seeks.add(position);
}

MediaSegment _intro({bool explicit = true, int start = 10, int end = 60}) => MediaSegment(
      type: MediaSegmentType.intro,
      start: Duration(seconds: start),
      end: Duration(seconds: end),
      explicitBounds: explicit,
    );

SyncPlayViewState _joined() => SyncPlayViewState(
      room: SyncPlayControllerState(
        status: SyncPlayStatus.joined,
        connected: true,
        clockSynchronized: true,
        group: SyncPlayGroup(groupId: 'fixture-group', groupName: 'fixture', lastUpdatedAt: DateTime.utc(2026)),
      ),
    );

class _Harness {
  _Harness({required List<MediaSegment> segments, SegmentSkip mode = SegmentSkip.askToSkip, int position = 15}) {
    container = ProviderContainer(overrides: [
      userProvider.overrideWith(_User.new),
      syncPlayProvider.overrideWith(_Room.new),
      videoPlayerProvider.overrideWith(_Video.new),
      videoPlayerSettingsProvider.overrideWith((ref) => VideoPlayerSettingsProviderNotifier(ref)
        ..applyRestoredSettings(VideoPlayerSettingsModel(segmentSkipSettings: {MediaSegmentType.intro: mode}))),
      playBackModel.overrideWith((ref) => _Playback(segments)),
      mediaPlaybackProvider.overrideWith((ref) => MediaPlaybackModel(
            state: VideoPlayerState.fullScreen,
            playing: true,
            duration: const Duration(seconds: 120),
            position: Duration(seconds: position),
          )),
    ]);
  }

  late final ProviderContainer container;
  final controlsVisible = ValueNotifier(true);
  final focus = FocusNode();
  var videoTaps = 0;
  var interactions = 0;
  _Player get player => container.read(videoPlayerProvider) as _Player;
  _Room get room => container.read(syncPlayProvider.notifier) as _Room;

  void position(int seconds) => container.read(mediaPlaybackProvider.notifier).update(
        (state) => state.copyWith(position: Duration(seconds: seconds)),
      );

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Stack(fit: StackFit.expand, children: [
            GestureDetector(
              key: const ValueKey('video-surface'),
              behavior: HitTestBehavior.opaque,
              onTap: () {
                videoTaps++;
                controlsVisible.value = !controlsVisible.value;
              },
              child: const ColoredBox(color: Colors.black),
            ),
            ValueListenableBuilder<bool>(
              valueListenable: controlsVisible,
              builder: (_, visible, __) => Align(
                alignment: Alignment.bottomLeft,
                child: IgnorePointer(
                  ignoring: !visible,
                  child: Opacity(
                    opacity: visible ? 1 : 0,
                    child: TextButton(focusNode: focus, onPressed: () {}, child: const Text('Player controls')),
                  ),
                ),
              ),
            ),
            SegmentSkipOverlay(onInteraction: () => interactions++),
          ]),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    controlsVisible.dispose();
    focus.dispose();
  }
}

void main() {
  final skip = find.byKey(const ValueKey('skip-segment'));
  final dismiss = find.byKey(const ValueKey('dismiss-segment'));

  testWidgets('prompt survives touch controls hiding and time; card actions do not tap through', (tester) async {
    final harness = _Harness(segments: [_intro()]);
    addTearDown(() => harness.dispose(tester));
    await harness.mount(tester);
    expect(skip, findsOneWidget);
    harness.focus.requestFocus();
    await tester.pump();
    await tester.tapAt(const Offset(60, 100));
    await tester.pump();
    expect(harness.controlsVisible.value, isFalse);
    expect(harness.videoTaps, 1);
    expect(skip, findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    expect(skip, findsOneWidget);
    expect(harness.focus.hasFocus, isTrue);
    await tester.tap(dismiss);
    await tester.pumpAndSettle();
    expect(skip, findsNothing);
    expect(harness.interactions, 1);
    expect(harness.videoTaps, 1);
    expect(harness.player.localSeeks, isEmpty);
    harness.position(16);
    await tester.pumpAndSettle();
    expect(skip, findsNothing);
  });

  testWidgets('automatic skip happens once under duplicate position and rebuild events while pending', (tester) async {
    final harness = _Harness(segments: [_intro()], mode: SegmentSkip.skip);
    final pending = Completer<void>();
    harness.player.pending = pending;
    addTearDown(() => harness.dispose(tester));
    await harness.mount(tester);
    expect(harness.player.automaticCalls, 1);
    expect(harness.player.localSeeks, [const Duration(seconds: 60)]);
    for (var i = 0; i < 4; i++) {
      harness.position(15);
      harness.controlsVisible.value = !harness.controlsVisible.value;
      await tester.pump();
      await tester.pump();
    }
    expect(harness.player.automaticCalls, 1);
    expect(skip, findsNothing);
    pending.complete();
    await tester.pumpAndSettle();
    harness.position(15); // A delayed old backend notification cannot retry.
    await tester.pumpAndSettle();
    expect(harness.player.automaticCalls, 1);
    expect(harness.player.localSeeks, hasLength(1));
  });

  testWidgets('manual seek back across opening offers a prompt instead of automatic reentry skip', (tester) async {
    final harness = _Harness(segments: [_intro()], mode: SegmentSkip.skip, position: 70);
    addTearDown(() => harness.dispose(tester));
    await harness.mount(tester);
    expect(skip, findsNothing);
    await harness.player.seek(const Duration(seconds: 15));
    await tester.pumpAndSettle();
    expect(skip, findsOneWidget);
    expect(harness.player.automaticCalls, 0);
    expect(harness.player.localSeeks, [const Duration(seconds: 15)]);
    await tester.tap(skip);
    await tester.pumpAndSettle();
    expect(harness.player.localSeeks, [const Duration(seconds: 15), const Duration(seconds: 60)]);
    expect(harness.interactions, 1);
    expect(harness.videoTaps, 0);
    expect(skip, findsNothing);
  });

  testWidgets('group automatic preference offers manual prompt and routes seek only to room commands', (tester) async {
    final harness = _Harness(segments: [_intro()], mode: SegmentSkip.skip);
    final commands = _Commands();
    harness.player.syncPlayCommands = commands;
    harness.room.view(_joined());
    addTearDown(() => harness.dispose(tester));
    await harness.mount(tester);
    expect(skip, findsOneWidget);
    expect(harness.player.automaticCalls, 0);
    await tester.tap(skip);
    await tester.pumpAndSettle();
    expect(commands.seeks, [const Duration(seconds: 60)]);
    expect(harness.player.localSeeks, isEmpty);
    expect(harness.player.automaticCalls, 0);
    expect(harness.videoTaps, 0);
  });

  testWidgets('room transitions disable prompt action until authorized room routing is ready', (tester) async {
    final harness = _Harness(segments: [_intro()]);
    final commands = _Commands()..active = false;
    harness.player.syncPlayCommands = commands;
    addTearDown(() => harness.dispose(tester));
    await harness.mount(tester);
    for (final view in [
      const SyncPlayViewState(busy: true),
      const SyncPlayViewState(preparingPlayback: true),
      const SyncPlayViewState(recoveryActive: true),
      const SyncPlayViewState(leavePending: true),
      const SyncPlayViewState(room: SyncPlayControllerState(status: SyncPlayStatus.joining)),
      const SyncPlayViewState(room: SyncPlayControllerState(status: SyncPlayStatus.disconnected)),
      _joined(), // Active room hook is still absent; never seek locally.
    ]) {
      harness.room.view(view);
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(skip).onPressed, isNull);
      await tester.tap(skip);
      await tester.pump();
    }
    expect(commands.seeks, isEmpty);
    expect(harness.player.localSeeks, isEmpty);
    commands.active = true;
    harness.room.view(_joined());
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(skip).onPressed, isNotNull);
    await tester.tap(skip);
    await tester.pumpAndSettle();
    expect(commands.seeks, [const Duration(seconds: 60)]);
    expect(harness.player.localSeeks, isEmpty);
  });

  testWidgets('missing invalid or untrusted metadata creates no prompt or automatic seek', (tester) async {
    final harness = _Harness(segments: [], mode: SegmentSkip.skip);
    addTearDown(() => harness.dispose(tester));
    await harness.mount(tester);
    for (final segments in <List<MediaSegment>>[
      [],
      [_intro(explicit: false)],
      [_intro(start: -1)],
      [_intro(start: 10, end: 10)],
      [_intro(start: 20, end: 10)],
      [_intro(end: 121)],
      [
        MediaSegment(
            type: MediaSegmentType.unknown,
            start: Duration.zero,
            end: const Duration(seconds: 60),
            explicitBounds: true)
      ],
    ]) {
      harness.container.read(playBackModel.notifier).state = _Playback(segments);
      await tester.pumpAndSettle();
      expect(skip, findsNothing);
      expect(dismiss, findsNothing);
    }
    harness.container.read(playBackModel.notifier).state = null;
    await tester.pumpAndSettle();
    expect(skip, findsNothing);
    harness.container.read(mediaPlaybackProvider.notifier).update((state) => state.copyWith(duration: Duration.zero));
    harness.container.read(playBackModel.notifier).state = _Playback([_intro()]);
    await tester.pumpAndSettle();
    expect(skip, findsNothing);
    expect(harness.player.localSeeks, isEmpty);
    expect(harness.player.automaticCalls, 0);
  });

  testWidgets('stale prompt callback revalidates Off and missing or conflicting metadata before any seek',
      (tester) async {
    for (final group in [false, true]) {
      for (final change in ['off', 'missing', 'conflicting', 'replacement']) {
        final harness = _Harness(segments: [_intro()]);
        final commands = _Commands();
        if (group) {
          harness.player.syncPlayCommands = commands;
          harness.room.view(_joined());
        }
        try {
          await harness.mount(tester);
          final staleAction = tester.widget<FilledButton>(skip).onPressed!;
          switch (change) {
            case 'off':
              harness.container.read(videoPlayerSettingsProvider.notifier).applyRestoredSettings(
                    VideoPlayerSettingsModel(segmentSkipSettings: {MediaSegmentType.intro: SegmentSkip.none}),
                  );
            case 'missing':
              harness.container.read(playBackModel.notifier).state = null;
            case 'conflicting':
              harness.container.read(playBackModel.notifier).state = _Playback([
                _intro(),
                _intro(start: 20, end: 70),
              ]);
            case 'replacement':
              // Identical endpoints on a replacement model cannot authorize
              // a callback captured from the previous playback item.
              harness.container.read(playBackModel.notifier).state = _Playback([_intro()]);
          }
          // Simulate a release delivered to the old button before its rebuild.
          staleAction();
          await tester.pumpAndSettle();
          expect(harness.player.localSeeks, isEmpty, reason: '$group/$change');
          expect(commands.seeks, isEmpty, reason: '$group/$change');
          expect(harness.player.automaticCalls, 0);
          expect(harness.interactions, 0);
          expect(skip, change == 'replacement' ? findsOneWidget : findsNothing);
        } finally {
          await harness.dispose(tester);
        }
      }
    }
  });

  testWidgets('stale prompt callback cannot seek after explicit-stop occurrence reset or a new item', (tester) async {
    for (final group in [false, true]) {
      final harness = _Harness(segments: [_intro()]);
      final commands = _Commands();
      if (group) {
        harness.player.syncPlayCommands = commands;
        harness.room.view(_joined());
      }
      final session = harness.container.read(segmentSkipSessionProvider)..bindItem('first-item');
      try {
        await harness.mount(tester);
        final oldPlaybackAction = tester.widget<FilledButton>(skip).onPressed!;
        final firstOccurrence = session.playbackId;
        // Exercise the actual explicit-stop entry point without a native
        // backend or item teardown, then restore identical metadata before the
        // stale release. Only its old playback occurrence is now invalid.
        harness.container.read(playBackModel.notifier).state = null;
        await harness.player.stop(preserveSleepTimer: true);
        harness.container.read(playBackModel.notifier).state = _Playback([_intro()]);
        expect(session.playbackId, isNot(same(firstOccurrence)));
        oldPlaybackAction();
        harness.position(15);
        await tester.pumpAndSettle();
        expect(harness.player.localSeeks, isEmpty);
        expect(commands.seeks, isEmpty);
        expect(skip, findsOneWidget); // The fresh occurrence still has its own prompt.

        final priorItemAction = tester.widget<FilledButton>(skip).onPressed!;
        final stoppedOccurrence = session.playbackId;
        session.bindItem('replacement-item');
        expect(session.playbackId, isNot(same(stoppedOccurrence)));
        priorItemAction();
        harness.position(15);
        await tester.pumpAndSettle();
        expect(harness.player.localSeeks, isEmpty);
        expect(commands.seeks, isEmpty);
        expect(harness.player.automaticCalls, 0);
        expect(harness.interactions, 0);
        expect(skip, findsOneWidget);
      } finally {
        await harness.dispose(tester);
      }
    }
  });
}
