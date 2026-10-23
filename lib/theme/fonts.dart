import 'package:flutter/material.dart';

class FladderFonts {
  /// A restrained UI scale with real weights so widget-level emphasis still works.
  static TextTheme interfaceTextTheme(TextTheme base, {Locale? locale}) {
    final traditionalChinese = locale?.languageCode == 'zh' &&
        (locale?.scriptCode == 'Hant' ||
            (locale?.scriptCode == null &&
                const {'TW', 'HK', 'MO'}.contains(locale?.countryCode)));
    final family = traditionalChinese ? 'NotoSansTC' : 'OpenSans';
    final text = base.apply(
      fontFamily: family,
      fontFamilyFallback: traditionalChinese
          ? const ['OpenSans', 'sans-serif']
          : const ['sans-serif'],
    );

    TextStyle? style(TextStyle? source, FontWeight weight, double height) =>
        source?.copyWith(
          fontWeight: weight,
          height: height,
          letterSpacing: 0,
        );

    return text.copyWith(
      displayLarge: style(text.displayLarge, FontWeight.w600, 1.2),
      displayMedium: style(text.displayMedium, FontWeight.w600, 1.2),
      displaySmall: style(text.displaySmall, FontWeight.w600, 1.25),
      headlineLarge: style(text.headlineLarge, FontWeight.w600, 1.3),
      headlineMedium: style(text.headlineMedium, FontWeight.w600, 1.3),
      headlineSmall: style(text.headlineSmall, FontWeight.w600, 1.3),
      titleLarge: style(text.titleLarge, FontWeight.w600, 1.35),
      titleMedium: style(text.titleMedium, FontWeight.w600, 1.4),
      titleSmall: style(text.titleSmall, FontWeight.w500, 1.4),
      bodyLarge: style(text.bodyLarge, FontWeight.w400, 1.5),
      bodyMedium: style(text.bodyMedium, FontWeight.w400, 1.5),
      bodySmall: style(text.bodySmall, FontWeight.w400, 1.5),
      labelLarge: style(text.labelLarge, FontWeight.w500, 1.35),
      labelMedium: style(text.labelMedium, FontWeight.w500, 1.35),
      labelSmall: style(text.labelSmall, FontWeight.w500, 1.35),
    );
  }
}
