import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:iconsax_plus/iconsax_plus.dart';

import 'package:fladder/l10n/generated/app_localizations.dart';
import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/models/items/movie_model.dart';
import 'package:fladder/models/playback/playback_model.dart';
import 'package:fladder/models/media_playback_model.dart';
import 'package:fladder/providers/pip_provider.dart';
import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/screens/video_player/video_player_controls.dart';
import 'package:fladder/screens/video_player/components/video_player_options_sheet.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout_model.dart';
import 'package:fladder/util/poster_defaults.dart';
import 'package:fladder/util/bitrate_helper.dart';
import 'package:fladder/wrappers/media_control_wrapper.dart';
import 'package:fladder/widgets/shared/controller_navigation.dart';

class _NoHttp extends HttpOverrides {
  int requests = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    requests++;
    throw StateError('HTTP is forbidden in the isolated player control test');
  }
}

class _IdlePlayer extends MediaControlsWrapper {
  _IdlePlayer(Ref ref) : super(ref: ref);
  @override
  bool get hasPlayer => true;
  @override
  Future<void> dispose() async {}
  @override
  Future<void> stop({bool preserveSleepTimer = false}) async {}
}

class _IdleNotifier extends VideoPlayerNotifier {
  _IdleNotifier(super.ref) {
    state = _IdlePlayer(ref);
  }
}

void main() {
  for (final textScale in [1.0, 1.8]) {
    testWidgets('hovered actual player menu keeps controller focus after Enter and Escape at text scale $textScale',
        (tester) async {
      // Match the real app's bundled font when checking long titles and large
      // text, instead of measuring every letter as an Ahem square glyph.
      final font = FontLoader('OpenSans')..addFont(rootBundle.load('assets/fonts/opensans/OpenSans.ttf'));
      await font.load();
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final previousHttp = HttpOverrides.current;
      final noHttp = _NoHttp();
      HttpOverrides.global = noHttp;
      addTearDown(() => HttpOverrides.global = previousHttp);
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final title = textScale == 1
          ? 'Synthetic movie for menu focus restoration'
          : 'A deliberately long synthetic movie title that must remain accessible in the playback menu '
              'while large text wraps within two lines on a handheld display without moving the information icon offscreen';
      final item = MovieModel.fromBaseDto(
        BaseItemDto(id: 'handheld-menu-fixture', name: title),
        null,
      );
      final navigator = GlobalKey<NavigatorState>();
      final focusObserver = ControllerFocusObserver(enabled: () => true);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          sharedUtilityProvider.overrideWith((ref) => SharedUtility(ref: ref, sharedPreferences: preferences)),
          videoPlayerProvider.overrideWith((ref) => _IdleNotifier(ref)),
          playBackModel.overrideWith((ref) => PlaybackModel(
                item: item,
                media: null,
                playbackInfo: null,
                mediaStreams: item.mediaStreams,
                bitRateOptions: {Bitrate.original: true},
              )),
          mediaPlaybackProvider.overrideWith((ref) => MediaPlaybackModel(
                state: VideoPlayerState.fullScreen,
                playing: true,
                duration: const Duration(minutes: 24),
                position: const Duration(minutes: 2),
              )),
          pipStateProvider.overrideWith((ref) => Stream.value(false)),
        ],
        child: AdaptiveLayout(
          data: const AdaptiveLayoutModel(
            viewSize: ViewSize.tablet,
            layoutMode: LayoutMode.single,
            inputDevice: InputDevice.dPad,
            controllerMode: true,
            platform: TargetPlatform.linux,
            isDesktop: true,
            posterDefaults: PosterDefaults(size: 280, ratio: 0.55),
            controller: {},
            sideBarWidth: 64,
            topBarHeight: 0,
            statusBarHeight: 0,
          ),
          child: MaterialApp(
            theme: ThemeData(fontFamily: 'OpenSans'),
            navigatorKey: navigator,
            navigatorObservers: [focusObserver],
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            locale: const Locale('en'),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
              child: ControllerNavigation(
                onBack: () => navigator.currentState!.maybePop(),
                child: child!,
              ),
            ),
            home: const Scaffold(body: DesktopControls()),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      final menuIcon = find.byIcon(IconsaxPlusLinear.more);
      expect(menuIcon, findsOneWidget);
      final opener = Focus.of(tester.element(menuIcon));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(menuIcon));
      await tester.pumpAndSettle();
      opener.requestFocus();
      await tester.pump();
      expect(opener.hasPrimaryFocus, isTrue);

      for (var attempt = 0; attempt < 2; attempt++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.byType(VideoOptions), findsOneWidget);
        final titleFinder = find.descendant(of: find.byType(VideoOptions), matching: find.text(title)).first;
        final titleText = tester.widget<Text>(titleFinder);
        expect(titleText.maxLines, 2);
        expect(titleText.overflow, TextOverflow.ellipsis);
        expect(titleText.semanticsLabel, title);
        // A modal covers the hovered player and generates MouseRegion.onExit.
        // Controller controls must stay visible so their opener remains eligible
        // for focus restoration, without re-running initial play-button focus.
        final overlay = tester.widget<AnimatedOpacity>(
          find.ancestor(of: menuIcon, matching: find.byType(AnimatedOpacity)).first,
        );
        expect(overlay.opacity, 1);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(VideoOptions), findsNothing);
        expect(opener.hasPrimaryFocus, isTrue);
        expect(tester.takeException(), isNull);
      }
      expect(noHttp.requests, 0);
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }, variant: const TargetPlatformVariant({TargetPlatform.linux}));
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.linux]) {
    for (final size in [const Size(1280, 800), const Size(1280, 720), const Size(853, 533)]) {
      testWidgets('actual player controls fit $size on ${platform.name} without a native player', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final item = MovieModel.fromBaseDto(
          const BaseItemDto(
              id: 'handheld-layout-fixture', name: 'Synthetic movie title for handheld playback controls'),
          null,
        );
        await tester.pumpWidget(ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(preferences),
            sharedUtilityProvider.overrideWith((ref) => SharedUtility(ref: ref, sharedPreferences: preferences)),
            videoPlayerProvider.overrideWith((ref) => _IdleNotifier(ref)),
            playBackModel.overrideWith((ref) => PlaybackModel(
                  item: item,
                  media: null,
                  playbackInfo: null,
                  mediaStreams: item.mediaStreams,
                  bitRateOptions: {Bitrate.original: true},
                )),
            mediaPlaybackProvider.overrideWith((ref) => MediaPlaybackModel(
                  state: VideoPlayerState.fullScreen,
                  playing: true,
                  duration: const Duration(minutes: 24),
                  position: const Duration(minutes: 2),
                )),
            pipStateProvider.overrideWith((ref) => Stream.value(false)),
          ],
          child: MaterialApp(
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            locale: const Locale('en'),
            home: AdaptiveLayout(
              data: AdaptiveLayoutModel(
                viewSize: ViewSize.tablet,
                layoutMode: LayoutMode.single,
                inputDevice: InputDevice.dPad,
                controllerMode: true,
                platform: platform,
                isDesktop: platform == TargetPlatform.linux,
                posterDefaults: const PosterDefaults(size: 280, ratio: 0.55),
                controller: const {},
                sideBarWidth: 64,
                topBarHeight: 0,
                statusBarHeight: 0,
              ),
              child: const Scaffold(body: DesktopControls()),
            ),
          ),
        ));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(tester.takeException(), isNull);
        expect(FocusManager.instance.primaryFocus?.debugLabel, 'Player play/pause');
        // Controller navigation keeps a visible control focused while a movie
        // is playing; the pointer-mode five-second timeout must not hide it.
        await tester.pump(const Duration(seconds: 6));
        expect(FocusManager.instance.primaryFocus?.canRequestFocus, isTrue);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }, variant: TargetPlatformVariant({platform}));
    }
  }
}
