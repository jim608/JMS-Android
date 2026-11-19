import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fladder/models/settings/client_settings_model.dart';
import 'package:fladder/providers/settings/client_settings_provider.dart';
import 'package:fladder/providers/settings/home_settings_provider.dart';
import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/widgets/shared/adaptive_color.dart';
import 'package:fladder/widgets/shared/theme_overwrite.dart';

void main() {
  testWidgets('the interface choice updates the light, dark and cached artwork themes together', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedUtilityProvider.overrideWith((ref) => SharedUtility(ref: ref, sharedPreferences: prefs)),
        clientSettingsProvider.overrideWith(
          (ref) => ClientSettingsNotifier(ref)
            ..applyRestoredSettings(
              ClientSettingsModel.defaultModel().copyWith(deriveColorsFromItem: true, amoledBlack: true),
            ),
        ),
      ],
    );
    addTearDown(container.dispose);

    late ThemeData light;
    late ThemeData dark;
    late ThemeData artwork;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: AdaptiveColor(
          child: (darkTheme, lightTheme) {
            dark = darkTheme;
            light = lightTheme;
            return MaterialApp(
              theme: light,
              darkTheme: dark,
              themeMode: ThemeMode.dark,
              home: ThemeOverwrite(
                color: Colors.teal,
                child: (context) {
                  artwork = Theme.of(context);
                  return const SizedBox.shrink();
                },
              ),
            );
          },
        ),
      ),
    );
    final settings = container.read(homeSettingsProvider.notifier);
    for (final classic in [false, true, false]) {
      settings.update((value) => value.copyWith(useClassicBannerStyle: classic));
      await tester.pumpAndSettle();
      for (final theme in [light, dark, artwork]) {
        expect(theme.cardTheme.elevation, classic ? 3 : 0);
        expect(theme.inputDecorationTheme.filled, !classic);
      }
      expect(artwork.colorScheme.surface, Colors.black);
      expect(artwork.colorScheme.primary, isNot(dark.colorScheme.primary));
    }
    expect(tester.takeException(), isNull);
  });
}
