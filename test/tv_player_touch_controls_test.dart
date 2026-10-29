import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/l10n/generated/app_localizations.dart';
import 'package:fladder/models/items/channel_model.dart';
import 'package:fladder/models/media_playback_model.dart';
import 'package:fladder/models/playback/tv_playback_model.dart';
import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/screens/video_player/components/video_player_options_sheet.dart';
import 'package:fladder/screens/video_player/tv_player_controls.dart';
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
  int plays = 0;

  @override
  bool get hasPlayer => true;

  @override
  Future<void> playOrPause() async {
    toggles++;
    ref.read(mediaPlaybackProvider.notifier).update((state) => state.copyWith(playing: !state.playing));
  }

  @override
  Future<void> play({bool userInitiated = true}) async {
    plays++;
    ref.read(mediaPlaybackProvider.notifier).update((state) => state.copyWith(playing: true));
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

Future<ProviderContainer> _mount(
  WidgetTester tester, {
  bool initialPointer = false,
  bool controllerMode = false,
  bool desktop = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(844, 390);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final channel = ChannelModel.fromBaseDto(
    const BaseItemDto(id: 'tv-touch-fixture', name: 'Synthetic channel'),
    null,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        sharedUtilityProvider.overrideWith(
          (ref) => SharedUtility(ref: ref, sharedPreferences: preferences),
        ),
        videoPlayerProvider.overrideWith((ref) => _Notifier(ref)),
        playBackModel.overrideWith(
          (ref) => TvPlaybackModel(channel: channel, item: channel),
        ),
        mediaPlaybackProvider.overrideWith(
          (ref) => MediaPlaybackModel(
            state: VideoPlayerState.fullScreen,
            playing: true,
            duration: const Duration(minutes: 10),
          ),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => InputDetector(
          isDesktop: initialPointer,
          htpcMode: false,
          controllerMode: controllerMode,
          child: (device) => AdaptiveLayout(
            data: AdaptiveLayoutModel(
              viewSize: ViewSize.phone,
              layoutMode: LayoutMode.single,
              inputDevice: device,
              platform: TargetPlatform.iOS,
              isDesktop: desktop,
              controllerMode: controllerMode,
              posterDefaults: const PosterDefaults(size: 280, ratio: 0.55),
              controller: const {},
              sideBarWidth: 0,
              topBarHeight: 0,
              statusBarHeight: 0,
            ),
            child: child!,
          ),
        ),
        home: Scaffold(body: TvPlayerControls(showGuide: (_) {})),
      ),
    ),
  );
  await tester.pump();
  return ProviderScope.containerOf(
    tester.element(find.byType(TvPlayerControls)),
  );
}

void main() {
  testWidgets('TV paused desktop resume button hides and cannot consume the next reveal tap', (tester) async {
    final container = await _mount(tester, desktop: true);
    container.read(mediaPlaybackProvider.notifier).update((state) => state.copyWith(playing: false));
    await tester.pump();
    final resume = find.byTooltip('Resume video');
    final scale = find.ancestor(of: resume, matching: find.byType(AnimatedScale));
    final position = tester.getCenter(resume);
    expect(tester.widget<AnimatedScale>(scale).scale, 1);
    await tester.pump(const Duration(seconds: 10));
    expect(_opacity(tester), 0);
    expect(tester.widget<AnimatedScale>(scale).scale, 0);
    await tester.tapAt(position);
    await tester.pump();
    expect(_opacity(tester), 1);
    expect((container.read(videoPlayerProvider) as _Player).plays, 0);
    expect(container.read(mediaPlaybackProvider).playing, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('TV route pushed immediately before expiry prevents stale timer hiding', (tester) async {
    await _mount(tester);
    await tester.pump(const Duration(milliseconds: 9999));
    final context = tester.element(find.byType(TvPlayerControls));
    final navigator = Navigator.of(context);
    showDialog<void>(context: context, builder: (_) => const AlertDialog(content: Text('Covered player')));
    await tester.pump(const Duration(milliseconds: 1));
    expect(_opacity(tester), 1);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 20));
    expect(_opacity(tester), 1);
    navigator.pop();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 9));
    expect(_opacity(tester), 1);
    await tester.pump(const Duration(seconds: 2));
    expect(_opacity(tester), 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'TV touch toggles visible controls and first pointer-to-touch tap never pauses',
    (tester) async {
      final container = await _mount(tester, initialPointer: true);
      await tester.pump(const Duration(seconds: 10));
      expect(_opacity(tester), 0);
      await tester.tapAt(const Offset(422, 170));
      await tester.pump();
      expect(_opacity(tester), 1);
      expect((container.read(videoPlayerProvider) as _Player).toggles, 0);
      await tester.tapAt(const Offset(422, 170));
      await tester.pump();
      expect(_opacity(tester), 0);
      await tester.tapAt(const Offset(422, 170));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 9999));
      expect(_opacity(tester), 1);
      await tester.pump(const Duration(milliseconds: 1));
      expect(_opacity(tester), 0);
      expect((container.read(videoPlayerProvider) as _Player).toggles, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'TV controls reset inactivity after a control tap and hide while paused',
    (tester) async {
      final container = await _mount(tester);
      await tester.pump(const Duration(seconds: 8));
      await tester.tap(find.byIcon(IconsaxPlusBold.pause));
      await tester.pump();
      expect(container.read(mediaPlaybackProvider).playing, isFalse);
      expect(_opacity(tester), 1);
      await tester.pump(const Duration(seconds: 9));
      expect(_opacity(tester), 1);
      await tester.pump(const Duration(seconds: 1));
      expect(_opacity(tester), 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'TV menu suspension restores a full inactivity window on return',
    (tester) async {
      await _mount(tester);
      await tester.pump(const Duration(seconds: 8));
      await tester.tap(find.byIcon(IconsaxPlusLinear.more));
      await tester.pumpAndSettle();
      expect(find.byType(VideoOptions), findsOneWidget);
      await tester.pump(const Duration(seconds: 22));
      expect(_opacity(tester), 1);
      Navigator.of(tester.element(find.byType(VideoOptions))).pop();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 9));
      expect(_opacity(tester), 1);
      await tester.pump(const Duration(seconds: 2));
      expect(_opacity(tester), 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'TV held or cancelled pointer does not toggle or exhaust inactivity',
    (tester) async {
      await _mount(tester);
      final gesture = await tester.startGesture(const Offset(422, 170));
      await gesture.moveBy(const Offset(60, 0));
      await tester.pump(const Duration(seconds: 15));
      expect(_opacity(tester), 1);
      await gesture.cancel();
      await tester.pump(const Duration(seconds: 9));
      expect(_opacity(tester), 1);
      await tester.pump(const Duration(seconds: 1));
      expect(_opacity(tester), 0);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 20));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('TV touch enter and exit cannot show or hide controls', (
    tester,
  ) async {
    await _mount(tester);
    final region = tester
        .widgetList<MouseRegion>(
          find.descendant(
            of: find.byType(TvPlayerControls),
            matching: find.byType(MouseRegion),
          ),
        )
        .firstWhere(
          (region) => region.onExit != null && region.onEnter != null,
        );
    region.onExit!(const PointerExitEvent(kind: PointerDeviceKind.touch));
    await tester.pump();
    expect(_opacity(tester), 1);
    await tester.pump(const Duration(seconds: 10));
    region.onEnter!(const PointerEnterEvent(kind: PointerDeviceKind.touch));
    await tester.pump();
    expect(_opacity(tester), 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'TV mouse click keeps play/pause behavior and hover refreshes inactivity',
    (tester) async {
      final container = await _mount(tester, initialPointer: true);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(422, 170));
      await mouse.down(const Offset(422, 170));
      await mouse.up();
      await tester.pump(const Duration(milliseconds: 400));
      expect((container.read(videoPlayerProvider) as _Player).toggles, 1);
      expect(_opacity(tester), 1);
      await tester.pump(const Duration(seconds: 8));
      await mouse.moveTo(const Offset(410, 150));
      await tester.pump(const Duration(seconds: 9));
      expect(_opacity(tester), 1);
      await tester.pump(const Duration(seconds: 1));
      expect(_opacity(tester), 0);
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('TV controller mode retains visible controls', (tester) async {
    await _mount(tester, controllerMode: true);
    await tester.pump(const Duration(seconds: 30));
    expect(_opacity(tester), 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
