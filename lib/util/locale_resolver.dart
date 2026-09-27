import 'package:flutter/widgets.dart';

Locale resolveSupportedLocale(Locale? requested, Iterable<Locale> supportedLocales) {
  const fallback = Locale('en');
  if (requested == null) return fallback;
  if (supportedLocales.contains(requested)) return requested;
  final script = requested.scriptCode ??
      (requested.languageCode == 'zh' && {'TW', 'HK', 'MO'}.contains(requested.countryCode) ? 'Hant' : null);
  if (script != null) {
    for (final locale in supportedLocales) {
      if (locale.languageCode == requested.languageCode && locale.scriptCode == script) return locale;
    }
  }
  return supportedLocales.firstWhere(
    (locale) => locale.languageCode == requested.languageCode,
    orElse: () => fallback,
  );
}
