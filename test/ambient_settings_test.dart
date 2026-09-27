import 'dart:convert';

import 'package:fladder/l10n/generated/app_localizations.dart';
import 'package:fladder/models/settings/video_player_settings.dart';
import 'package:fladder/providers/settings/video_player_settings_provider.dart';
import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout_model.dart';
import 'package:fladder/util/poster_defaults.dart';
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
    expect(model.ambientBlur, isTrue);
    expect(model.useLibass, isFalse);
    expect(model.hardwareAccel, isFalse);
    expect(model.internalVolume, 83);
    expect(model.copyWith(ambientIntensity: 1, ambientSpread: 0.3).playerSame(model), isTrue);
  });

  test('appearance survives the existing SharedPreferences path and unrelated data remains intact', () async {
    SharedPreferences.setMockInitialValues({
      'test-account-sentinel': 'unchanged',
      'videoPlayerSettings': jsonEncode({'ambientBlur': true, 'useLibass': false})
    });
    final preferences = await SharedPreferences.getInstance();
    final storage = SharedHelper(sharedPreferences: preferences);
    storage.videoPlayerSettings = storage.videoPlayerSettings.copyWith(ambientIntensity: 0.95, ambientSpread: 0.55);
    final reopened = SharedHelper(sharedPreferences: await SharedPreferences.getInstance()).videoPlayerSettings;
    expect(reopened.ambientIntensity, 0.95);
    expect(reopened.ambientSpread, 0.55);
    expect(reopened.useLibass, isFalse);
    expect(preferences.getString('test-account-sentinel'), 'unchanged');
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
          child: Scaffold(body: AmbientControls()),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    for (final control in ['ambient-intensity', 'ambient-spread']) {
      final saved = container.read(videoPlayerSettingsProvider);
      final slider = find.byKey(Key(control));
      final gesture = await tester.startGesture(tester.getCenter(slider));
      await gesture.moveBy(const Offset(-60, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-60, 0));
      await tester.pump();
      final preview = container.read(ambientAppearanceProvider);
      expect(container.read(ambientPreviewProvider), isNotNull);
      expect(identical(container.read(videoPlayerSettingsProvider), saved), isTrue);
      await gesture.up();
      await tester.pumpAndSettle();
      final persisted = SharedHelper(sharedPreferences: preferences).videoPlayerSettings;
      expect(persisted.ambientIntensity, preview.intensity);
      expect(persisted.ambientSpread, preview.spread);
      expect(persisted.playerSame(saved), isTrue);
      expect(container.read(ambientPreviewProvider), isNull);
    }
    expect(preferences.getString('test-account-sentinel'), 'unchanged');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
