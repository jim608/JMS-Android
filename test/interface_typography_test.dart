import 'package:fladder/l10n/generated/app_localizations.dart';
import 'package:fladder/models/settings/client_settings_model.dart';
import 'package:fladder/providers/settings/client_settings_provider.dart';
import 'package:fladder/theme.dart';
import 'package:fladder/theme/fonts.dart';
import 'package:fladder/widgets/shared/theme_overwrite.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    for (final entry in {
      'MaterialIcons': ['fonts/MaterialIcons-Regular.otf'],
      'OpenSans': ['assets/fonts/opensans/OpenSans.ttf'],
      'NotoSansTC': [
        for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold'])
          'assets/fonts/notosanstc/NotoSansTC-$weight.ttf',
      ],
    }.entries) {
      final loader = FontLoader(entry.key);
      for (final path in entry.value) {
        loader.addFont(rootBundle.load(path));
      }
      await loader.load();
    }
  });

  test('Traditional Chinese selects the bundled family with script precedence',
      () {
    for (final locale in [
      const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
      const Locale.fromSubtags(
          languageCode: 'zh', scriptCode: 'Hant', countryCode: 'CN'),
      const Locale('zh', 'TW'),
      const Locale('zh', 'HK'),
      const Locale('zh', 'MO'),
    ]) {
      final theme = FladderFonts.interfaceTextTheme(ThemeData.light().textTheme,
          locale: locale);
      expect(_styles(theme).every((style) => style.fontFamily == 'NotoSansTC'),
          isTrue,
          reason: '$locale');
    }
    for (final locale in [
      null,
      const Locale('en'),
      const Locale('zh', 'CN'),
      const Locale.fromSubtags(
          languageCode: 'zh', scriptCode: 'Hans', countryCode: 'TW'),
    ]) {
      final theme = FladderFonts.interfaceTextTheme(ThemeData.light().textTheme,
          locale: locale);
      expect(_styles(theme).every((style) => style.fontFamily == 'OpenSans'),
          isTrue,
          reason: '$locale');
    }
  });

  test('Typography preserves inherited size, color and custom emphasis', () {
    final base = ThemeData.light().textTheme.copyWith(
          bodyMedium: const TextStyle(
            fontSize: 19,
            color: Colors.deepPurple,
            fontStyle: FontStyle.italic,
            decoration: TextDecoration.underline,
            inherit: false,
          ),
        );
    final theme = FladderFonts.interfaceTextTheme(base);
    final before = _styles(base).toList();
    final after = _styles(theme).toList();
    for (var index = 0; index < after.length; index++) {
      expect(after[index].fontSize, before[index].fontSize);
      expect(after[index].color, before[index].color);
      expect(after[index].fontVariations, isNull);
    }
    expect(theme.bodyMedium?.fontStyle, FontStyle.italic);
    expect(theme.bodyMedium?.decoration, TextDecoration.underline);
    expect(theme.bodyMedium?.inherit, isFalse);
    expect(theme.bodyMedium?.fontWeight, FontWeight.w400);
    expect(theme.bodyMedium?.height, 1.5);
    expect(theme.titleMedium?.fontWeight, FontWeight.w600);
    expect(theme.labelLarge?.fontWeight, FontWeight.w500);
  });

  testWidgets('Artwork colors retain the Traditional Chinese interface family',
      (tester) async {
    final parent = FladderTheme.theme(
        FladderTheme.defaultScheme(Brightness.light),
        DynamicSchemeVariant.tonalSpot,
        locale: const Locale('zh', 'TW'));
    ThemeData? derived;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        clientSettingsProvider.overrideWith((ref) => ClientSettingsNotifier(ref)
          ..applyRestoredSettings(ClientSettingsModel.defaultModel()
              .copyWith(deriveColorsFromItem: true))),
      ],
      child: MaterialApp(
        theme: parent,
        locale: const Locale('zh', 'TW'),
        supportedLocales: const [Locale('zh', 'TW')],
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: ThemeOverwrite(
          color: Colors.teal,
          child: (context) {
            derived = Theme.of(context);
            return const Text('作品資訊');
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(derived!.colorScheme.primary, isNot(parent.colorScheme.primary));
    expect(derived!.textTheme.bodyMedium?.fontFamily, 'NotoSansTC');
    expect(derived!.primaryTextTheme.titleMedium?.fontFamily, 'NotoSansTC');
  });

  for (final brightness in Brightness.values) {
    test('$brightness retains readable colors in both Material text themes',
        () {
      final theme = FladderTheme.theme(FladderTheme.defaultScheme(brightness),
          DynamicSchemeVariant.tonalSpot,
          locale: const Locale('zh', 'TW'));
      final base =
          ThemeData(useMaterial3: true, colorScheme: theme.colorScheme);
      for (final pair in [
        (theme.textTheme, base.textTheme),
        (theme.primaryTextTheme, base.primaryTextTheme),
      ]) {
        final original = _styles(pair.$2).toList();
        final actual = _styles(pair.$1).toList();
        for (var index = 0; index < actual.length; index++) {
          expect(actual[index].fontFamily, 'NotoSansTC');
          expect(actual[index].color, original[index].color);
          expect(actual[index].fontSize, original[index].fontSize);
          expect(actual[index].fontVariations, isNull);
        }
      }
    });

    for (final viewport in [
      (const Size(1280, 900), 1.0),
      (const Size(320, 900), 2.0)
    ]) {
      testWidgets(
          '$brightness controls fit ${viewport.$1.width}px at ${viewport.$2}x',
          (tester) async {
        tester.view.physicalSize = viewport.$1;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final theme = FladderTheme.theme(FladderTheme.defaultScheme(brightness),
            DynamicSchemeVariant.tonalSpot,
            locale: const Locale('zh', 'TW'));
        await tester.pumpWidget(MaterialApp(
          theme: theme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(viewport.$2)),
            child: child!,
          ),
          home: Scaffold(
            appBar: AppBar(title: const Text('JMS 設定')),
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('外觀與播放', style: theme.textTheme.headlineSmall),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('深色模式'),
                  subtitle: const Text('自動配合系統外觀'),
                  value: true,
                  onChanged: (_) {},
                ),
                const TextField(
                  decoration:
                      InputDecoration(labelText: '伺服器', hintText: 'Jellyfin'),
                ),
                const SizedBox(height: 16),
                FilledButton(onPressed: () {}, child: const Text('儲存設定')),
                OutlinedButton(onPressed: () {}, child: const Text('返回媒體庫')),
              ],
            ),
            bottomNavigationBar: NavigationBar(destinations: const [
              NavigationDestination(
                  icon: Icon(Icons.home_outlined), label: '首頁'),
              NavigationDestination(
                  icon: Icon(Icons.settings_outlined), label: '設定'),
            ]),
          ),
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('返回媒體庫'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('儲存設定'), findsOneWidget);
      });
    }
  }
}

Iterable<TextStyle> _styles(TextTheme theme) => [
      theme.displayLarge!,
      theme.displayMedium!,
      theme.displaySmall!,
      theme.headlineLarge!,
      theme.headlineMedium!,
      theme.headlineSmall!,
      theme.titleLarge!,
      theme.titleMedium!,
      theme.titleSmall!,
      theme.bodyLarge!,
      theme.bodyMedium!,
      theme.bodySmall!,
      theme.labelLarge!,
      theme.labelMedium!,
      theme.labelSmall!,
    ];
