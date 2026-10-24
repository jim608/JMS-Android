import 'package:fladder/theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.windows);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test(
      'Windows Traditional Chinese has a consistent TC fallback across both text themes',
      () {
    final light = FladderTheme.theme(
        FladderTheme.defaultScheme(Brightness.light),
        DynamicSchemeVariant.tonalSpot);
    final dark = FladderTheme.theme(FladderTheme.defaultScheme(Brightness.dark),
        DynamicSchemeVariant.tonalSpot);
    for (final locale in [
      const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
      const Locale('zh', 'TW'),
      const Locale('zh', 'HK'),
      const Locale('zh', 'MO'),
    ]) {
      final themes = [
        FladderTheme.applyChineseFontToTheme(
            lightTheme: light, darkTheme: dark, locale: locale),
        FladderTheme.applyChineseFontToDarkTheme(
            darkTheme: dark, locale: locale),
      ];
      for (final theme in themes) {
        for (final textTheme in [theme.textTheme, theme.primaryTextTheme]) {
          for (final style in _styles(textTheme)) {
            expect(style?.fontFamilyFallback?.first, 'Microsoft JhengHei UI');
          }
        }
      }
      expect(themes.first.textTheme.bodyMedium?.fontFamily,
          light.textTheme.bodyMedium?.fontFamily);
      expect(themes.first.textTheme.titleMedium?.fontWeight,
          light.textTheme.titleMedium?.fontWeight);
      expect(themes.first.textTheme.titleMedium?.fontSize,
          light.textTheme.titleMedium?.fontSize);
    }
  }, skip: kIsWeb);

  test(
      'Switching from Traditional to Simplified does not retain the TC fallback',
      () {
    final base = ThemeData.light();
    final traditional = FladderTheme.applyChineseFontToTheme(
        lightTheme: base,
        darkTheme: ThemeData.dark(),
        locale: const Locale('zh', 'TW'));
    final simplified = FladderTheme.applyChineseFontToTheme(
        lightTheme: base,
        darkTheme: ThemeData.dark(),
        locale: const Locale('zh', 'CN'));
    expect(traditional.textTheme.bodyMedium?.fontFamilyFallback?.first,
        'Microsoft JhengHei UI');
    expect(simplified.textTheme.bodyMedium?.fontFamilyFallback,
        isNot(contains('Microsoft JhengHei UI')));
    expect(simplified.textTheme.bodyMedium?.fontFamilyFallback,
        contains('Microsoft YaHei'));
  }, skip: kIsWeb);

  test(
      'Explicit Simplified script takes precedence over a Traditional Chinese region',
      () {
    final base = ThemeData.light();
    final theme = FladderTheme.applyChineseFontToTheme(
        lightTheme: base,
        darkTheme: ThemeData.dark(),
        locale: const Locale.fromSubtags(
            languageCode: 'zh', scriptCode: 'Hans', countryCode: 'TW'));
    expect(theme.textTheme.bodyMedium?.fontFamilyFallback,
        isNot(contains('Microsoft JhengHei UI')));
  }, skip: kIsWeb);
}

List<TextStyle?> _styles(TextTheme theme) => [
      theme.displayLarge,
      theme.displayMedium,
      theme.displaySmall,
      theme.headlineLarge,
      theme.headlineMedium,
      theme.headlineSmall,
      theme.titleLarge,
      theme.titleMedium,
      theme.titleSmall,
      theme.bodyLarge,
      theme.bodyMedium,
      theme.bodySmall,
      theme.labelLarge,
      theme.labelMedium,
      theme.labelSmall,
    ];
