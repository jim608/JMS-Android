import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iconsax_plus/iconsax_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/l10n/generated/app_localizations.dart';
import 'package:fladder/models/items/movie_model.dart';
import 'package:fladder/models/media_playback_model.dart';
import 'package:fladder/models/playback/playback_model.dart';
import 'package:fladder/providers/pip_provider.dart';
import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/screens/video_player/video_player_controls.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout_model.dart';
import 'package:fladder/util/poster_defaults.dart';
import 'package:fladder/wrappers/media_control_wrapper.dart';

class _NoHttp extends HttpOverrides {
  int requests = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    requests++;
    throw StateError('HTTP is forbidden in the mobile player layout test');
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

Future<void> _pumpTouchControls(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final item = MovieModel.fromBaseDto(
    const BaseItemDto(id: 'mobile-layout-fixture', name: 'Synthetic video'),
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
      home: Builder(builder: (context) {
        final size = MediaQuery.sizeOf(context);
        return AdaptiveLayout(
          data: AdaptiveLayoutModel(
            viewSize: size.width < 600 ? ViewSize.phone : ViewSize.tablet,
            layoutMode: LayoutMode.single,
            inputDevice: InputDevice.touch,
            controllerMode: false,
            platform: TargetPlatform.iOS,
            isDesktop: false,
            posterDefaults: const PosterDefaults(size: 280, ratio: 0.55),
            controller: const {},
            sideBarWidth: 0,
            topBarHeight: 0,
            statusBarHeight: 0,
          ),
          child: const Scaffold(body: DesktopControls()),
        );
      }),
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

void _expectControlsInViewport(WidgetTester tester, Size size) {
  expect(tester.takeException(), isNull);
  for (final icon in [IconsaxPlusLinear.more, IconsaxPlusBold.pause]) {
    final control = find.byIcon(icon);
    expect(control, findsOneWidget);
    final rect = tester.getRect(control);
    expect(rect.left, greaterThanOrEqualTo(0), reason: '$icon must remain inside the touch viewport');
    expect(rect.right, lessThanOrEqualTo(size.width), reason: '$icon must remain inside the touch viewport');
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(size.height));
    expect(control.hitTestable(), findsOneWidget);
  }
}

void main() {
  for (final size in [const Size(390, 844), const Size(844, 390), const Size(1280, 720)]) {
    testWidgets('touch player controls fit $size without controller mode', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final previousHttp = HttpOverrides.current;
      final noHttp = _NoHttp();
      HttpOverrides.global = noHttp;
      addTearDown(() => HttpOverrides.global = previousHttp);

      await _pumpTouchControls(tester);
      _expectControlsInViewport(tester, size);
      expect(noHttp.requests, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }, variant: const TargetPlatformVariant({TargetPlatform.iOS}));
  }

  testWidgets('visible touch controls remain reachable through portrait/landscape resizing', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final previousHttp = HttpOverrides.current;
    final noHttp = _NoHttp();
    HttpOverrides.global = noHttp;
    addTearDown(() => HttpOverrides.global = previousHttp);

    await _pumpTouchControls(tester);
    for (final size in [const Size(390, 844), const Size(844, 390), const Size(390, 844)]) {
      tester.view.physicalSize = size;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      _expectControlsInViewport(tester, size);
    }
    expect(noHttp.requests, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }, variant: const TargetPlatformVariant({TargetPlatform.iOS}));
}
