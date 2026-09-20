import 'package:fladder/l10n/generated/app_localizations.dart';
import 'package:fladder/util/locale_resolver.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Taiwan, Hong Kong and Macao select traditional Chinese resources', () {
    for (final country in ['TW', 'HK', 'MO']) {
      final selected = resolveSupportedLocale(Locale('zh', country), AppLocalizations.supportedLocales);
      expect(selected, const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'));
    }
  });
  test('explicit scripts, simplified Chinese and other locales retain their language', () {
    expect(resolveSupportedLocale(const Locale('zh', 'CN'), AppLocalizations.supportedLocales), const Locale('zh'));
    expect(
        resolveSupportedLocale(
                const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'), AppLocalizations.supportedLocales)
            .scriptCode,
        'Hant');
    expect(resolveSupportedLocale(const Locale('de', 'AT'), AppLocalizations.supportedLocales), const Locale('de'));
    expect(resolveSupportedLocale(null, AppLocalizations.supportedLocales), const Locale('en'));
  });
}
