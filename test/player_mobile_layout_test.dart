import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iconsax_plus/iconsax_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/l10n/generated/app_localizations.dart';
import 'package:fladder/localization_delegates.dart';
import 'package:fladder/models/items/chapters_model.dart';
import 'package:fladder/models/items/media_streams_model.dart';
import 'package:fladder/models/items/movie_model.dart';
import 'package:fladder/models/media_playback_model.dart';
import 'package:fladder/models/playback/playback_model.dart';
import 'package:fladder/models/settings/subtitle_settings_model.dart';
import 'package:fladder/providers/pip_provider.dart';
import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/screens/video_player/video_player_controls.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout_model.dart';
import 'package:fladder/util/poster_defaults.dart';
import 'package:fladder/util/subtitle_position_calculator.dart';
import 'package:fladder/widgets/dual_subtitle_text.dart';
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

  GlobalKey? subtitleControlsKey;

  @override
  Widget? subtitleWidget(bool showOverlay, {GlobalKey? controlsKey}) {
    subtitleControlsKey = controlsKey;
    return null;
  }

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

Future<void> _pumpTouchControls(WidgetTester tester, {bool largeChinese = false}) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final item = MovieModel.fromBaseDto(
    BaseItemDto(
      id: 'mobile-layout-fixture',
      name: largeChinese ? '這是一段在手機播放器中需要保留章節與播放按鈕的長片名' : 'Synthetic video',
    ),
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
            chapters: largeChinese
                ? [
                    Chapter(name: '開場', imageUrl: '', startPosition: Duration.zero),
                    Chapter(name: '第二幕', imageUrl: '', startPosition: const Duration(minutes: 5)),
                  ]
                : null,
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
      localizationsDelegates: FladderLocalizations.localizationsDelegates,
      locale: largeChinese ? const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant') : const Locale('en'),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(largeChinese ? 2 : 1)),
        child: child!,
      ),
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
  test('missing video metadata has no display label', () {
    expect(MediaStreamsModel(versionStreams: []).mediaInfoTag, isNull);
  });

  testWidgets('landscape keeps chapter and playback controls reachable with large Traditional Chinese text', (tester) async {
    const size = Size(740, 360);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await _pumpTouchControls(tester, largeChinese: true);
    _expectControlsInViewport(tester, size);
    expect(find.byKey(const ValueKey('next-chapter')).hitTestable(), findsOneWidget);
    expect(find.textContaining('null'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }, variant: const TargetPlatformVariant({TargetPlatform.iOS}));

  for (final largeText in [false, true]) {
    testWidgets('subtitles clear the visible player controls and return to the lower screen (large text $largeText)',
        (tester) async {
      const viewport = Size(740, 360);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = viewport;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await _pumpTouchControls(tester, largeChinese: largeText);
      final playerContext = tester.element(find.byType(DesktopControls));
      final player = ProviderScope.containerOf(playerContext).read(videoPlayerProvider) as _IdlePlayer;
      final controls = tester.getRect(find.byKey(player.subtitleControlsKey!));
      expect(controls.bottom, closeTo(viewport.height, 0.01));
      expect(controls.height, lessThan(viewport.height));
      const cue = '字幕';
      const settings = SubtitleSettingsModel();
      for (final dual in [false, true]) {
        for (final visible in [true, false]) {
          final inset = visible ? controls.height : 0.0;
          final offset = SubtitlePositionCalculator.calculateOffset(
            settings: settings, showOverlay: visible, screenHeight: viewport.height, menuHeight: controls.height,
          );
          final entry = OverlayEntry(
            builder: (_) => Positioned.fill(
              child: dual
                  ? DualSubtitleText(primaryText: cue, secondaryText: 'Second', settings: settings,
                      bottomOffset: offset, minimumBottomInset: inset)
                  : SubtitleText(subModel: settings, padding: EdgeInsets.zero, text: cue,
                      offset: offset, minimumBottomInset: inset),
            ),
          );
          Overlay.of(playerContext).insert(entry);
          await tester.pump();
          final bottom = tester.getRect(dual ? find.byKey(const Key('secondary-subtitle')) : find.text(cue).last).bottom;
          if (visible) {
            expect(bottom, lessThanOrEqualTo(controls.top + 0.01));
          } else {
            expect(bottom, greaterThan(controls.top));
          }
          entry.remove();
          entry.dispose();
          await tester.pump();
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }, variant: const TargetPlatformVariant({TargetPlatform.iOS}));
  }

  testWidgets('short landscape measures the visible toolbar even when the chapter buttons require scrolling',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(568, 320);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await _pumpTouchControls(tester, largeChinese: true);
    final context = tester.element(find.byType(DesktopControls));
    final player = ProviderScope.containerOf(context).read(videoPlayerProvider) as _IdlePlayer;
    final viewport = find.byKey(player.subtitleControlsKey!);
    final bar = tester.getRect(viewport);
    final scroll = tester.state<ScrollableState>(
      find.descendant(of: viewport, matching: find.byType(Scrollable)).first,
    );
    expect(scroll.position.maxScrollExtent, greaterThan(0));
    expect(bar.height, closeTo(scroll.position.viewportDimension, 0.01));
    expect(find.byIcon(IconsaxPlusBold.pause).hitTestable(), findsOneWidget);
    final next = find.byKey(const ValueKey('next-chapter'));
    await tester.ensureVisible(next);
    await tester.pump();
    expect(next.hitTestable(), findsOneWidget);
    expect(tester.getRect(viewport), bar);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }, variant: const TargetPlatformVariant({TargetPlatform.iOS}));

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
