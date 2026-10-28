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
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout_model.dart';
import 'package:fladder/util/input_detector.dart';
import 'package:fladder/util/poster_defaults.dart';
import 'package:fladder/wrappers/media_control_wrapper.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iconsax_plus/iconsax_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Player extends MediaControlsWrapper {
  _Player(Ref ref) : super(ref: ref);
  int toggles = 0;
  @override
  bool get hasPlayer => true;
  @override
  Future<void> playOrPause() async {
    toggles++;
    ref.read(mediaPlaybackProvider.notifier).update((s) => s.copyWith(playing: !s.playing));
  }

  @override
  Future<void> dispose() async {}
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

Future<ProviderContainer> _mount(WidgetTester tester, {bool initialPointer = false}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(844, 390);
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
            viewSize: ViewSize.phone,
            layoutMode: LayoutMode.single,
            inputDevice: device,
            platform: TargetPlatform.iOS,
            isDesktop: false,
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

void main() {
  testWidgets('first Web-style pointer to touch transition reveals controls without pausing', (tester) async {
    final container = await _mount(tester, initialPointer: true);
    await tester.pump(const Duration(seconds: 6));
    expect(_opacity(tester), 0);
    for (var i = 0; i < 3; i++) {
      await tester.tapAt(const Offset(422, 170));
      await tester.pump(const Duration(milliseconds: 400));
      expect(_opacity(tester), 1);
      expect((container.read(videoPlayerProvider) as _Player).toggles, 0);
      await tester.pump(const Duration(seconds: 6));
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
    await tester.pump(const Duration(seconds: 6));
    region.onEnter!(const PointerEnterEvent(kind: PointerDeviceKind.touch));
    await tester.pump();
    expect(_opacity(tester), 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('touch controls refresh inactivity and stay visible while paused or a menu is open', (tester) async {
    final container = await _mount(tester);
    await tester.pump(const Duration(seconds: 4));
    await tester.tap(find.byIcon(IconsaxPlusBold.pause));
    await tester.pump(const Duration(seconds: 6));
    expect(container.read(mediaPlaybackProvider).playing, isFalse);
    expect(_opacity(tester), 1);
    await tester.tap(find.byIcon(IconsaxPlusBold.play));
    await tester.pump(const Duration(seconds: 4));
    expect(_opacity(tester), 1);
    await tester.tap(find.byIcon(IconsaxPlusLinear.more));
    await tester.pumpAndSettle();
    expect(find.byType(VideoOptions), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    expect(_opacity(tester), 1);
    Navigator.of(tester.element(find.byType(VideoOptions))).pop();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 6));
    expect(_opacity(tester), 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('mouse hover refreshes the full inactivity window', (tester) async {
    await _mount(tester, initialPointer: true);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(400, 150));
    await tester.pump(const Duration(seconds: 4));
    await mouse.moveTo(const Offset(410, 150));
    await tester.pump(const Duration(seconds: 2));
    expect(_opacity(tester), 1);
    await tester.pump(const Duration(seconds: 4));
    expect(_opacity(tester), 0);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
