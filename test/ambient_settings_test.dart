import 'dart:convert';

import 'package:fladder/l10n/generated/app_localizations.dart';
import 'package:fladder/models/settings/video_player_settings.dart';
import 'package:fladder/providers/settings/video_player_settings_provider.dart';
import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout_model.dart';
import 'package:fladder/util/poster_defaults.dart';
import 'package:fladder/util/ambient_interval.dart';
import 'package:fladder/widgets/shared/ambient_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('old preferences gain appearance defaults without clearing any playback preference', () {
    final model = VideoPlayerSettingsModel.fromJson(
        {'ambientBlur': true, 'useLibass': false, 'hardwareAccel': false, 'internalVolume': 83.0});
    expect(model.ambientIntensity, 0.8);
    expect(model.ambientSpread, 0.9);
    expect(model.ambientIntervalSeconds, 4);
    expect(model.ambientSyncToPlayback, isFalse);
    expect(model.ambientBlur, isTrue);
    expect(model.useLibass, isFalse);
    expect(model.hardwareAccel, isFalse);
    expect(model.internalVolume, 83);
    expect(
        model
            .copyWith(
                ambientIntensity: 1, ambientSpread: 0.3, ambientIntervalSeconds: 0.75, ambientSyncToPlayback: true)
            .playerSame(model),
        isTrue);
  });

  test('appearance survives the existing SharedPreferences path and unrelated data remains intact', () async {
    SharedPreferences.setMockInitialValues({
      'test-account-sentinel': 'unchanged',
      'videoPlayerSettings': jsonEncode({'ambientBlur': true, 'useLibass': false})
    });
    final preferences = await SharedPreferences.getInstance();
    final storage = SharedHelper(sharedPreferences: preferences);
    storage.videoPlayerSettings = storage.videoPlayerSettings.copyWith(
        ambientIntensity: 0.95, ambientSpread: 0.55, ambientIntervalSeconds: 0.75, ambientSyncToPlayback: true);
    final reopened = SharedHelper(sharedPreferences: await SharedPreferences.getInstance()).videoPlayerSettings;
    expect(reopened.ambientIntensity, 0.95);
    expect(reopened.ambientSpread, 0.55);
    expect(reopened.ambientIntervalSeconds, 0.75);
    expect(reopened.ambientSyncToPlayback, isTrue);
    expect(reopened.useLibass, isFalse);
    expect(preferences.getString('test-account-sentinel'), 'unchanged');
  });

  test('interval bounds preserve the default and exact decimal seconds', () {
    expect(VideoPlayerSettingsModel(ambientIntervalSeconds: -3).effectiveAmbientIntervalSeconds, 4);
    expect(VideoPlayerSettingsModel(ambientIntervalSeconds: 0).effectiveAmbientIntervalSeconds, 4);
    expect(VideoPlayerSettingsModel(ambientIntervalSeconds: 0.0001).effectiveAmbientIntervalSeconds, 0.001);
    expect(VideoPlayerSettingsModel(ambientIntervalSeconds: 61).effectiveAmbientIntervalSeconds, 60);
    for (final value in [double.nan, double.infinity, double.negativeInfinity]) {
      expect(VideoPlayerSettingsModel(ambientIntervalSeconds: value).effectiveAmbientIntervalSeconds, 4);
    }
    expect(ambientIntervalDuration(0.75), const Duration(milliseconds: 750));
    expect(ambientIntervalDuration(0.001), const Duration(milliseconds: 1));
  });

  test('out of range appearance values are bounded without changing blur or decoding', () {
    final model = VideoPlayerSettingsModel(ambientIntensity: -3, ambientSpread: 2);
    expect(model.effectiveAmbientIntensity, 0);
    expect(model.effectiveAmbientSpread, 1);
    final invalid = VideoPlayerSettingsModel(ambientIntensity: double.nan, ambientSpread: double.infinity);
    expect(invalid.effectiveAmbientIntensity, 0.8);
    expect(invalid.effectiveAmbientSpread, 0.9);
  });

  test('live preview does not mutate persisted settings or recreate the player', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final subscription = container.listen(ambientAppearanceProvider, (_, next) {}, fireImmediately: true);
    addTearDown(subscription.close);
    final initial = container.read(videoPlayerSettingsProvider);
    container.read(ambientPreviewProvider.notifier).state = (intensity: 0.95, spread: 0.4);
    expect(container.read(ambientAppearanceProvider), (intensity: 0.95, spread: 0.4));
    expect(identical(container.read(videoPlayerSettingsProvider), initial), isTrue);
    container.read(ambientPreviewProvider.notifier).state = null;
    expect(container.read(ambientAppearanceProvider), (intensity: 0.8, spread: 0.9));
  });

  test('interval preview is bounded and does not save or recreate the player', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final subscription = container.listen(ambientIntervalProvider, (_, next) {}, fireImmediately: true);
    addTearDown(subscription.close);
    final initial = container.read(videoPlayerSettingsProvider);
    container.read(ambientIntervalPreviewProvider.notifier).state = 0.75;
    expect(container.read(ambientIntervalProvider), 0.75);
    expect(identical(container.read(videoPlayerSettingsProvider), initial), isTrue);
    container.read(ambientIntervalPreviewProvider.notifier).state = 0;
    expect(container.read(ambientIntervalProvider), 4);
    container.read(ambientIntervalPreviewProvider.notifier).state = null;
    expect(container.read(ambientIntervalProvider), 4);
  });

  testWidgets('appearance sliders preview during drag and persist only on release', (tester) async {
    SharedPreferences.setMockInitialValues({'test-account-sentinel': 'unchanged'});
    final preferences = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [
      sharedUtilityProvider.overrideWith((ref) => SharedUtility(ref: ref, sharedPreferences: preferences)),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        locale: Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AdaptiveLayout(
          data: AdaptiveLayoutModel(
            viewSize: ViewSize.phone,
            layoutMode: LayoutMode.single,
            inputDevice: InputDevice.touch,
            platform: TargetPlatform.android,
            isDesktop: false,
            posterDefaults: PosterDefaults(size: 100, ratio: 0.7),
            controller: {},
            sideBarWidth: 0,
            topBarHeight: 0,
            statusBarHeight: 0,
          ),
          child: Scaffold(body: SingleChildScrollView(child: AmbientControls())),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    for (final control in ['ambient-intensity', 'ambient-spread', 'ambient-interval']) {
      final saved = container.read(videoPlayerSettingsProvider);
      final slider = find.byKey(Key(control));
      await tester.ensureVisible(slider);
      final gesture = await tester.startGesture(tester.getCenter(slider));
      await gesture.moveBy(const Offset(-60, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-60, 0));
      await tester.pump();
      final preview = container.read(ambientAppearanceProvider);
      final intervalPreview = container.read(ambientIntervalProvider);
      expect(
          control == 'ambient-interval'
              ? container.read(ambientIntervalPreviewProvider)
              : container.read(ambientPreviewProvider),
          isNotNull);
      expect(identical(container.read(videoPlayerSettingsProvider), saved), isTrue);
      await gesture.up();
      await tester.pumpAndSettle();
      final persisted = SharedHelper(sharedPreferences: preferences).videoPlayerSettings;
      expect(persisted.ambientIntensity, preview.intensity);
      expect(persisted.ambientSpread, preview.spread);
      expect(persisted.effectiveAmbientIntervalSeconds, intervalPreview);
      expect(persisted.playerSame(saved), isTrue);
      expect(container.read(ambientPreviewProvider), isNull);
      expect(container.read(ambientIntervalPreviewProvider), isNull);
    }
    await tester.ensureVisible(find.byKey(const Key('ambient-interval-edit')));
    await tester.tap(find.byKey(const Key('ambient-interval-edit')));
    await tester.pumpAndSettle();
    final input = find.byKey(const Key('ambient-interval-input'));
    await tester.enterText(input, '0');
    await tester.tap(find.byKey(const Key('ambient-interval-save')));
    await tester.pumpAndSettle();
    expect(find.text('請輸入 0.001～60.000 秒，最多三位小數。'), findsOneWidget);
    await tester.enterText(input, '0.075');
    await tester.tap(find.byKey(const Key('ambient-interval-save')));
    await tester.pumpAndSettle();
    expect(SharedHelper(sharedPreferences: preferences).videoPlayerSettings.ambientIntervalSeconds, 0.075);
    expect(find.byKey(const Key('ambient-fast-warning')), findsOneWidget);
    final mode = find.byKey(const Key('ambient-sync-to-playback'));
    await tester.ensureVisible(mode);
    await tester.tap(mode);
    await tester.pumpAndSettle();
    expect(SharedHelper(sharedPreferences: preferences).videoPlayerSettings.ambientSyncToPlayback, isTrue);
    expect(find.byKey(const Key('ambient-interval')), findsOneWidget);
    expect(find.byKey(const Key('ambient-fast-warning')), findsOneWidget);
    await tester.tap(mode);
    await tester.pumpAndSettle();
    expect(container.read(ambientIntervalProvider), 0.075);
    expect(preferences.getString('test-account-sentinel'), 'unchanged');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
