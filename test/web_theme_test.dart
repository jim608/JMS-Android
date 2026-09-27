import 'package:fladder/theme.dart';
import 'package:fladder/l10n/generated/app_localizations.dart';
import 'package:fladder/providers/sync/background_download_provider.dart';
import 'package:fladder/util/localization_helper.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  testWidgets('Web themes preserve browser font fallback without native file access', (tester) async {
    final lightTheme = ThemeData.light();
    final darkTheme = ThemeData.dark();
    final resolvedLight = FladderTheme.applyChineseFontToTheme(lightTheme: lightTheme, darkTheme: darkTheme);
    final resolvedDark = FladderTheme.applyChineseFontToDarkTheme(darkTheme: darkTheme);

    await tester.pumpWidget(MaterialApp(theme: resolvedLight, darkTheme: resolvedDark, home: const Text('繁體中文')));
    await tester.pumpAndSettle();

    expect(find.text('繁體中文'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (kIsWeb) {
      expect(resolvedLight.textTheme, lightTheme.textTheme);
      expect(resolvedDark.textTheme, darkTheme.textTheme);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: LocalizationContextWrapper(currentLocale: Locale('zh', 'TW'), child: Text('JMS')),
        ),
      ));
      await tester.pumpAndSettle();
      expect(container.exists(backgroundDownloaderProvider), isFalse);
      expect(container.read(localizationContextProvider), isNotNull);
      expect(tester.takeException(), isNull);
    } else {
      expect(resolvedLight.textTheme.bodyMedium?.fontFamilyFallback, isNotEmpty);
      expect(resolvedDark.textTheme.bodyMedium?.fontFamilyFallback, isNotEmpty);
    }
  });
}
