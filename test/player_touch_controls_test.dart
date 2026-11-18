import 'dart:async';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/l10n/generated/app_localizations.dart';
import 'package:fladder/models/items/movie_model.dart';
import 'package:fladder/models/media_playback_model.dart';
import 'package:fladder/models/playback/playback_model.dart';
import 'package:fladder/providers/pip_provider.dart';
import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/screens/video_player/components/video_player_options_sheet.dart';
import 'package:fladder/screens/video_player/video_player_controls.dart';
import 'package:fladder/services/syncplay/syncplay_player_commands.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout_model.dart';
import 'package:fladder/util/input_detector.dart';
import 'package:fladder/util/poster_defaults.dart';
import 'package:fladder/wrappers/media_control_wrapper.dart';
import 'package:fladder/wrappers/players/player_states.dart';
import 'package:fladder/widgets/shared/fladder_slider.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iconsax_plus/iconsax_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Player extends MediaControlsWrapper {
  _Player(Ref ref) : super(ref: ref);
  int toggles = 0;
  int plays = 0;
  final seeks = <Duration>[];
  final pendingSeeks = <Completer<void>>[];
  Completer<void>? pauseReport;
  bool syncActive = false;
  @override
  bool get syncPlayActive => syncActive || super.syncPlayActive;
  @override
  bool get hasPlayer => true;
  @override
  Future<void> playOrPause() async {
    toggles++;
    ref.read(mediaPlaybackProvider.notifier).update((s) => s.copyWith(playing: !s.playing));
  }

  @override
  Future<void> play({bool userInitiated = true}) async {
    plays++;
    ref.read(mediaPlaybackProvider.notifier).update((s) => s.copyWith(playing: true));
  }

  @override
  Future<void> pause() async {
    ref.read(mediaPlaybackProvider.notifier).update((s) => s.copyWith(playing: false));
    await pauseReport?.future;
  }

  @override
  PlayerState get lastState => PlayerState(playing: ref.read(mediaPlaybackProvider).playing);

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    if (pendingSeeks.isNotEmpty) await pendingSeeks.removeAt(0).future;
  }

  @override
  Future<void> dispose() async {}
}

class _RoomCommands implements SyncPlayPlayerCommands {
  @override
  bool get active => true;

  @override
  Future<void> pause() async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> stop() async {}
}

class _Notifier extends VideoPlayerNotifier {
  _Notifier(super.ref) {
    state = _Player(ref);
  }
}

Finder get _overlay => find
    .ancestor(
      of: find.byIcon(IconsaxPlusLinear.more),
      matching: find.byType(AnimatedOpacity),
    )
    .first;

double _opacity(WidgetTester tester) => tester.widget<AnimatedOpacity>(_overlay).opacity;

Future<ProviderContainer> _mount(
  WidgetTester tester, {
  bool initialPointer = false,
  TargetPlatform platform = TargetPlatform.iOS,
  bool desktop = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = desktop ? const Size(1280, 720) : const Size(844, 390);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final item = MovieModel.fromBaseDto(const BaseItemDto(id: 'touch-fixture', name: 'Synthetic touch fixture'), null);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      sharedUtilityProvider.overrideWith((ref) => SharedUtility(ref: ref, sharedPreferences: preferences)),
      videoPlayerProvider.overrideWith((ref) => _Notifier(ref)),
      playBackModel.overrideWith((ref) => PlaybackModel(item: item, media: null, playbackInfo: null)),
      mediaPlaybackProvider.overrideWith((ref) => MediaPlaybackModel(
            state: VideoPlayerState.fullScreen,
            playing: true,
            duration: const Duration(minutes: 10),
          )),
      pipStateProvider.overrideWith((ref) => Stream.value(false)),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => InputDetector(
        isDesktop: initialPointer,
        htpcMode: false,
        child: (device) => AdaptiveLayout(
          data: AdaptiveLayoutModel(
            viewSize: desktop ? ViewSize.desktop : ViewSize.phone,
            layoutMode: LayoutMode.single,
            inputDevice: device,
            platform: platform,
            isDesktop: desktop,
            controllerMode: false,
            posterDefaults: const PosterDefaults(size: 280, ratio: 0.55),
            controller: const {},
            sideBarWidth: 0,
            topBarHeight: 0,
            statusBarHeight: 0,
          ),
          child: child!,
        ),
      ),
      home: const Scaffold(body: DesktopControls()),
    ),
  ));
  await tester.pump();
  return ProviderScope.containerOf(tester.element(find.byType(DesktopControls)));
}

Future<TestGesture> _startProgressDrag(WidgetTester tester, double delta) async {
  final slider = tester.getRect(find.byType(FladderSlider).first);
  final drag = await tester.startGesture(slider.center);
  await drag.moveTo(slider.center + Offset(delta, 0));
  await tester.pump();
  return drag;
}

Future<void> _dragProgress(WidgetTester tester, double delta) async {
  final drag = await _startProgressDrag(tester, delta);
  await drag.up();
  await tester.pump();
}

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS, TargetPlatform.windows, TargetPlatform.linux]) {
    testWidgets('$platform touch blank area toggles without sending playback commands', (tester) async {
      final container = await _mount(tester, platform: platform);
      final player = container.read(videoPlayerProvider) as _Player;
      player.syncActive = true;
      for (final visible in [false, true, false, true]) {
        await tester.tapAt(const Offset(422, 170));
        // Two distinct single taps must clear the existing double-tap window.
        await tester.pump(kDoubleTapTimeout);
        expect(_opacity(tester), visible ? 1 : 0);
      }
      expect(player.toggles, 0);
      expect(player.seeks, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('controls hide at exactly ten seconds of inactivity', (tester) async {
    await _mount(tester);
    await tester.pump(const Duration(milliseconds: 9999));
    expect(_opacity(tester), 1);
    await tester.pump(const Duration(milliseconds: 1));
    expect(_opacity(tester), 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('first Web-style pointer to touch transition reveals controls without pausing', (tester) async {
    final container = await _mount(tester, initialPointer: true);
    await tester.pump(const Duration(seconds: 10));
    expect(_opacity(tester), 0);
    for (var i = 0; i < 3; i++) {
      await tester.tapAt(const Offset(422, 170));
      await tester.pump(const Duration(milliseconds: 400));
      expect(_opacity(tester), 1);
      expect((container.read(videoPlayerProvider) as _Player).toggles, 0);
      await tester.pump(const Duration(seconds: 10));
      expect(_opacity(tester), 0);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('touch enter and exit do not act as mouse hover', (tester) async {
    await _mount(tester);
    final region = tester
        .widgetList<MouseRegion>(find.descendant(
          of: find.byType(DesktopControls),
          matching: find.byType(MouseRegion),
        ))
        .firstWhere((r) => r.onExit != null && r.onEnter != null);
    region.onExit!(const PointerExitEvent(kind: PointerDeviceKind.touch));
    await tester.pump();
    expect(_opacity(tester), 1);
    await tester.pump(const Duration(seconds: 10));
    region.onEnter!(const PointerEnterEvent(kind: PointerDeviceKind.touch));
    await tester.pump();
    expect(_opacity(tester), 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('pause button refreshes inactivity and paused controls still hide after ten seconds', (tester) async {
    final container = await _mount(tester);
    await tester.pump(const Duration(seconds: 9));
    await tester.tap(find.byIcon(IconsaxPlusBold.pause));
    await tester.pump(const Duration(milliseconds: 9999));
    expect(container.read(mediaPlaybackProvider).playing, isFalse);
    expect(_opacity(tester), 1);
    await tester.pump(const Duration(milliseconds: 1));
    expect(_opacity(tester), 0);
    await tester.tapAt(const Offset(422, 170));
    await tester.pump(kDoubleTapTimeout);
    await tester.tap(find.byIcon(IconsaxPlusBold.play));
    await tester.pump(const Duration(seconds: 9));
    expect(_opacity(tester), 1);
    expect(container.read(mediaPlaybackProvider).playing, isTrue);
    expect((container.read(videoPlayerProvider) as _Player).toggles, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('menu keeps controls visible and returning starts a full ten seconds', (tester) async {
    await _mount(tester);
    await tester.pump(const Duration(seconds: 9));
    await tester.tap(find.byIcon(IconsaxPlusLinear.more));
    await tester.pumpAndSettle();
    expect(find.byType(VideoOptions), findsOneWidget);
    await tester.pump(const Duration(seconds: 21));
    expect(_opacity(tester), 1);
    Navigator.of(tester.element(find.byType(VideoOptions))).pop();
    await tester.pump();
    await tester.pump(const Duration(seconds: 9));
    expect(_opacity(tester), 1);
    await tester.pump(const Duration(seconds: 1));
    expect(_opacity(tester), 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('mouse hover refreshes the full inactivity window', (tester) async {
    await _mount(tester, initialPointer: true);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(400, 150));
    await tester.pump(const Duration(seconds: 9));
    await mouse.moveTo(const Offset(410, 150));
    await tester.pump(const Duration(seconds: 2));
    expect(_opacity(tester), 1);
    await tester.pump(const Duration(seconds: 8));
    expect(_opacity(tester), 0);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('progress drag stays visible while held and resets inactivity on release', (tester) async {
    final container = await _mount(tester);
    final slider = tester.getRect(find.byType(FladderSlider).first);
    final drag = await tester.startGesture(slider.center);
    await drag.moveTo(slider.center + const Offset(40, 0));
    await tester.pump(const Duration(seconds: 12));
    expect(_opacity(tester), 1);
    await drag.up();
    await tester.pump(const Duration(milliseconds: 300));
    expect((container.read(videoPlayerProvider) as _Player).seeks, hasLength(1));
    await tester.pump(const Duration(seconds: 9));
    expect(_opacity(tester), 1);
    await tester.pump(const Duration(seconds: 2));
    expect(_opacity(tester), 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('progress drag resumes only after its seek finishes', (tester) async {
    final container = await _mount(tester);
    final player = container.read(videoPlayerProvider) as _Player;
    final seek = Completer<void>();
    player.pendingSeeks.add(seek);

    await _dragProgress(tester, 40);
    await tester.pump(const Duration(milliseconds: 300));
    expect(player.seeks, hasLength(1));
    expect(player.plays, 0);

    seek.complete();
    await tester.pump();
    expect(player.plays, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('progress seek does not wait for the pause report', (tester) async {
    final container = await _mount(tester);
    final player = container.read(videoPlayerProvider) as _Player;
    final report = Completer<void>();
    player.pauseReport = report;

    await _dragProgress(tester, 40);
    final seeksBeforeReport = player.seeks.length;
    report.complete();
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(seeksBeforeReport, 1);
  });

  testWidgets('exiting during a progress seek discards pending playback and UI updates', (tester) async {
    final container = await _mount(tester);
    final player = container.read(videoPlayerProvider) as _Player;
    final seek = Completer<void>();
    player.pendingSeeks.add(seek);

    await _dragProgress(tester, 40);
    expect(player.seeks, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    seek.complete();
    await tester.pump(const Duration(milliseconds: 300));
    expect(player.plays, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a second progress drag wins and keeps the original playing intent', (tester) async {
    final container = await _mount(tester);
    final player = container.read(videoPlayerProvider) as _Player;
    final first = Completer<void>();
    final second = Completer<void>();
    player.pendingSeeks.addAll([first, second]);

    await _dragProgress(tester, 40);
    await _dragProgress(tester, 80);
    expect(player.seeks, hasLength(1));

    first.complete();
    await tester.pump();
    expect(player.seeks, hasLength(2));
    expect(player.seeks.last, greaterThan(player.seeks.first));
    expect(player.plays, 0);

    second.complete();
    await tester.pump();
    expect(player.plays, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('cancelling a progress drag resumes without performing the seek', (tester) async {
    final container = await _mount(tester);
    final player = container.read(videoPlayerProvider) as _Player;
    final drag = await _startProgressDrag(tester, 40);

    await drag.cancel();
    await tester.pump();
    expect(player.seeks, isEmpty);
    expect(player.plays, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('leaving a room during a progress seek never resumes solo playback', (tester) async {
    final container = await _mount(tester);
    final player = container.read(videoPlayerProvider) as _Player;
    final seek = Completer<void>();
    player.syncPlayCommands = _RoomCommands();
    player.pendingSeeks.add(seek);

    await _dragProgress(tester, 40);
    expect(player.seeks, hasLength(1));
    player.syncPlayCommands = null;
    seek.complete();
    await tester.pump();

    expect(player.plays, 0);
    expect(container.read(mediaPlaybackProvider).playing, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('cancelled touch releases the held-pointer timer guard', (tester) async {
    await _mount(tester);
    final touch = await tester.startGesture(const Offset(422, 170));
    await tester.pump(const Duration(seconds: 12));
    expect(_opacity(tester), 1);
    await touch.cancel();
    await tester.pump(const Duration(seconds: 9));
    expect(_opacity(tester), 1);
    await tester.pump(const Duration(seconds: 1));
    expect(_opacity(tester), 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('double tap keeps its playback action without toggling the overlay', (tester) async {
    final container = await _mount(tester);
    await tester.tapAt(const Offset(422, 170));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(const Offset(422, 170));
    await tester.pump(kDoubleTapTimeout);
    expect((container.read(videoPlayerProvider) as _Player).toggles, 1);
    expect(_opacity(tester), 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('mouse click and keyboard shortcut keep playback behavior', (tester) async {
    final container = await _mount(tester, initialPointer: true);
    await tester.tapAt(const Offset(422, 170), kind: PointerDeviceKind.mouse);
    await tester.pump(kDoubleTapTimeout);
    expect((container.read(videoPlayerProvider) as _Player).toggles, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect((container.read(videoPlayerProvider) as _Player).toggles, 2);
    expect(_opacity(tester), 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('paused desktop center control follows overlay visibility', (tester) async {
    final container = await _mount(tester, desktop: true);
    container.read(mediaPlaybackProvider.notifier).update((s) => s.copyWith(playing: false));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(milliseconds: 9750));
    expect(_opacity(tester), 0);
    expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale).first).scale, 0);
    // The scale animation is just starting: a hidden control must already
    // pass this touch through to the background instead of resuming playback.
    await tester.tapAt(const Offset(640, 360));
    await tester.pump(kDoubleTapTimeout);
    expect(_opacity(tester), 1);
    expect((container.read(videoPlayerProvider) as _Player).plays, 0);
    expect(container.read(mediaPlaybackProvider).playing, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('route opened at inactivity deadline keeps controls visible', (tester) async {
    await _mount(tester);
    await tester.pump(const Duration(milliseconds: 9999));
    final context = tester.element(find.byType(DesktopControls));
    final navigator = Navigator.of(context);
    navigator.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('Menu'))));
    await tester.pump(const Duration(milliseconds: 1));
    expect(_opacity(tester), 1);
    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(seconds: 9));
    expect(_opacity(tester), 1);
    await tester.pump(const Duration(seconds: 1));
    expect(_opacity(tester), 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('leaving the route cancels inactivity without later callbacks', (tester) async {
    await _mount(tester);
    final context = tester.element(find.byType(DesktopControls));
    Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('Left'))));
    await tester.pumpAndSettle();
    expect(find.byType(DesktopControls), findsNothing);
    await tester.pump(const Duration(seconds: 20));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
