import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fladder/localization_delegates.dart';
import 'package:fladder/models/settings/home_settings_model.dart';
import 'package:fladder/providers/settings/home_settings_provider.dart';
import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/screens/settings/client_sections/client_settings_dashboard.dart';
import 'package:fladder/screens/settings/settings_list_tile.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout_model.dart';
import 'package:fladder/util/poster_defaults.dart';

void main() {
  testWidgets('classic banner switch restores from disk and appears only for supported styles', (tester) async {
    SharedPreferences.setMockInitialValues({'homeSettings': '{"homeBanner":"carousel","nextUp":"combined"}'});
    final prefs = await SharedPreferences.getInstance();
    final storage = SharedHelper(sharedPreferences: prefs);
    final legacy = storage.homeSettings;
    expect(legacy.useClassicBannerStyle, isFalse);
    expect(legacy.nextUp, HomeNextUp.combined);
    final container = ProviderContainer(
      overrides: [sharedUtilityProvider.overrideWith((ref) => SharedUtility(ref: ref, sharedPreferences: prefs))],
    );
    addTearDown(container.dispose);
    final notifier = container.read(homeSettingsProvider.notifier);
    notifier.update((_) => legacy);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: FladderLocalizations.localizationsDelegates,
          home: AdaptiveLayout(
            data: const AdaptiveLayoutModel(
              viewSize: ViewSize.desktop,
              layoutMode: LayoutMode.single,
              inputDevice: InputDevice.pointer,
              platform: TargetPlatform.windows,
              isDesktop: true,
              posterDefaults: PosterDefaults(size: 100, ratio: 0.7),
              controller: {},
              sideBarWidth: 0,
              topBarHeight: 0,
              statusBarHeight: 0,
            ),
            child: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => ListView(children: buildClientSettingsDashboard(context, ref)),
              ),
            ),
          ),
        ),
      ),
    );
    final toggle = find.widgetWithText(SettingsListTileCheckbox, 'Use classic banner style');
    expect(tester.widget<SettingsListTileCheckbox>(toggle).value, isFalse);
    await tester.tapAt(tester.getCenter(toggle));
    await tester.pumpAndSettle();
    await prefs.reload();
    expect(storage.homeSettings.toJson(), legacy.copyWith(useClassicBannerStyle: true).toJson());

    for (final banner in [HomeBanner.hide, HomeBanner.detailedBanner, HomeBanner.tvSliderBanner, HomeBanner.banner]) {
      notifier.update((settings) => settings.copyWith(homeBanner: banner));
      await tester.pumpAndSettle();
      expect(toggle, banner == HomeBanner.banner ? findsOneWidget : findsNothing);
    }
    expect(tester.widget<SettingsListTileCheckbox>(toggle).value, isTrue);
    await tester.tapAt(tester.getCenter(toggle));
    await tester.pumpAndSettle();
    await prefs.reload();
    expect(storage.homeSettings.toJson(), legacy.copyWith(homeBanner: HomeBanner.banner).toJson());
  });
}
