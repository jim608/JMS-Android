import 'package:fladder/l10n/generated/app_localizations.dart';
import 'package:fladder/providers/diagnostics_provider.dart';
import 'package:fladder/screens/settings/widgets/settings_diagnostics_information.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<void> showSettings(
          WidgetTester tester, DiagnosticsSettings settings) =>
      tester.pumpWidget(ProviderScope(
          overrides: [
            diagnosticsProvider.overrideWith((ref) => settings),
          ],
          child: const MaterialApp(
            locale: Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: SettingsDiagnosticsInformation()),
          )));

  testWidgets(
      'enabling requires explicit consent; cancelling and switching off persist safely',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final settings = DiagnosticsSettings(
        preferences: prefs,
        version: '0.11.1-jms.25',
        buildId: 'JMS-0.11.1-jms.25-123456abcdef',
        platform: 'android',
        configuredEndpoint:
            'https://diagnostics.example.org/api/jms/diagnostics/v1');
    await settings.activateServer(null, null);
    await tester.pumpWidget(ProviderScope(
        overrides: [
          diagnosticsProvider.overrideWith((ref) => settings),
        ],
        child: const MaterialApp(
          locale: Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: SettingsDiagnosticsInformation()),
        )));
    expect(settings.enabled, false);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(settings.enabled, false);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(settings.enabled, false);
    expect(prefs.getBool(DiagnosticsSettings.consentKey), isNull);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Agree and enable'));
    await tester.pumpAndSettle();
    expect(settings.enabled, true);
    expect(prefs.getBool(DiagnosticsSettings.consentKey), true);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(settings.enabled, false);
    expect(prefs.getBool(DiagnosticsSettings.consentKey), false);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'server receiver is visible and a stale consent dialog cannot enable another scope',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = DiagnosticsSettings(
      preferences: await SharedPreferences.getInstance(),
      version: '0.11.1-jms.28',
      buildId: 'JMS-0.11.1-jms.28-123456abcdef',
      platform: 'android',
    );
    const receiverA = 'https://a.example.org/api/jms/diagnostics/v1';
    const receiverB = 'https://b.example.org/api/jms/diagnostics/v1';
    await settings.activateServer('server-a', receiverA);
    await showSettings(tester, settings);
    expect(find.text(receiverA), findsOneWidget);
    expect(find.text('Server'), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await settings.activateServer('server-b', receiverB);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Agree and enable'));
    await tester.pumpAndSettle();
    expect(settings.endpointValue, receiverB);
    expect(settings.enabled, false);
    expect(find.text(receiverB), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'endpoint edits opened for one scope cannot overwrite another scope',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = DiagnosticsSettings(
      preferences: await SharedPreferences.getInstance(),
      version: '0.11.1-jms.28',
      buildId: 'JMS-0.11.1-jms.28-123456abcdef',
      platform: 'android',
    );
    const receiverA = 'https://a.example.org/api/jms/diagnostics/v1';
    const receiverB = 'https://b.example.org/api/jms/diagnostics/v1';
    await settings.activateServer('server-a', receiverA);
    await showSettings(tester, settings);
    await tester.tap(find.text('Diagnostic endpoint'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField),
        'https://manual.example.org/api/jms/diagnostics/v1');
    await settings.activateServer('server-b', receiverB);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(settings.endpointValue, receiverB);
    expect(settings.serverProvided, true);
    expect(settings.enabled, false);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
