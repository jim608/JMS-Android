import 'package:fladder/l10n/generated/app_localizations.dart';
import 'package:fladder/providers/discord_presence_provider.dart';
import 'package:fladder/screens/settings/widgets/settings_discord_presence.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeDiscordSettings extends ChangeNotifier
    implements DiscordPresenceSettings {
  _FakeDiscordSettings({this.supported = true, this.activeScope = 'account-a'});

  @override
  final bool supported;
  @override
  String? activeScope;
  @override
  bool get hasAccount => activeScope != null;
  @override
  bool enabled = false;
  @override
  bool shareTitle = false;
  @override
  bool busy = false;
  @override
  DiscordConnectionState status = DiscordConnectionState.disconnected;

  bool savesSucceed = true;
  int enableCalls = 0;
  int titleCalls = 0;

  void changeAccount(String? scope, {bool alreadyEnabled = false}) {
    activeScope = scope;
    enabled = alreadyEnabled;
    shareTitle = false;
    notifyListeners();
  }

  @override
  Future<bool> setEnabled(bool value) async {
    enableCalls++;
    if (!savesSucceed) return false;
    enabled = value;
    notifyListeners();
    return true;
  }

  @override
  Future<bool> setShareTitle(bool value) async {
    titleCalls++;
    if (!savesSucceed) return false;
    shareTitle = value;
    notifyListeners();
    return true;
  }

  @override
  String toString() => 'TEST_ONLY_TRANSPORT_ERROR_NOT_FOR_DISPLAY';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const enabledKey = ValueKey('discord-presence-enabled');
  const titleKey = ValueKey('discord-presence-share-title');

  Future<void> showSettings(WidgetTester tester, _FakeDiscordSettings settings,
      {Locale locale = const Locale('en')}) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        discordPresenceSettingsProvider.overrideWith((ref) => settings),
      ],
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: SettingsDiscordPresence()),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> accept(WidgetTester tester) async {
    await tester.tap(find.text('Agree and share'));
    await tester.pumpAndSettle();
  }

  testWidgets('unsupported platforms do not expose Discord settings',
      (tester) async {
    final settings = _FakeDiscordSettings(supported: false);
    await showSettings(tester, settings);
    expect(find.byType(SwitchListTile), findsNothing);
    expect(settings.enableCalls, 0);
  });

  testWidgets('without an account neither sharing option can be enabled',
      (tester) async {
    final settings = _FakeDiscordSettings(activeScope: null);
    await showSettings(tester, settings);
    expect(tester.widget<SwitchListTile>(find.byKey(enabledKey)).onChanged,
        isNull);
    expect(
        tester.widget<SwitchListTile>(find.byKey(titleKey)).onChanged, isNull);
    expect(find.textContaining('Sign in to a JMS account'), findsOneWidget);
    expect(settings.enableCalls, 0);
    expect(settings.titleCalls, 0);
  });

  testWidgets('status consent is explicit and can be cancelled or withdrawn',
      (tester) async {
    final settings = _FakeDiscordSettings();
    await showSettings(tester, settings);
    expect(settings.enabled, false);
    expect(settings.shareTitle, false);
    await tester.tap(find.byKey(enabledKey));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('your Discord profile and friends'),
        findsOneWidget);
    expect(settings.enableCalls, 0);
    expect(tester.widget<SwitchListTile>(find.byKey(enabledKey)).onChanged,
        isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(settings.enableCalls, 0);
    await tester.tap(find.byKey(enabledKey));
    await tester.pumpAndSettle();
    await accept(tester);
    expect(settings.enabled, true);
    expect(settings.shareTitle, false);
    expect(settings.enableCalls, 1);
    await tester.tap(find.byKey(enabledKey));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(settings.enabled, false);
    expect(settings.enableCalls, 2);
  });

  testWidgets('video titles require their own consent and can be withdrawn',
      (tester) async {
    final settings = _FakeDiscordSettings();
    await showSettings(tester, settings);
    expect(
        tester.widget<SwitchListTile>(find.byKey(titleKey)).onChanged, isNull);
    await tester.tap(find.byKey(enabledKey));
    await tester.pumpAndSettle();
    await accept(tester);
    await tester.tap(find.byKey(titleKey));
    await tester.pumpAndSettle();
    expect(find.textContaining('the video title you watch'), findsOneWidget);
    expect(settings.titleCalls, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(settings.shareTitle, false);
    await tester.tap(find.byKey(titleKey));
    await tester.pumpAndSettle();
    await accept(tester);
    expect(settings.shareTitle, true);
    expect(settings.titleCalls, 1);
    await tester.tap(find.byKey(titleKey));
    await tester.pumpAndSettle();
    expect(settings.shareTitle, false);
    expect(settings.enabled, true);
    expect(settings.titleCalls, 2);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('a status dialog cannot give consent to a different account',
      (tester) async {
    final settings = _FakeDiscordSettings();
    await showSettings(tester, settings);
    await tester.tap(find.byKey(enabledKey));
    await tester.pumpAndSettle();
    settings.changeAccount('account-b');
    await tester.pumpAndSettle();
    await accept(tester);
    expect(settings.enableCalls, 0);
    expect(settings.enabled, false);
  });

  testWidgets('title consent can be withdrawn while all status sharing is off',
      (tester) async {
    final settings = _FakeDiscordSettings()..shareTitle = true;
    await showSettings(tester, settings);
    expect(settings.enabled, false);
    await tester.tap(find.byKey(titleKey));
    await tester.pumpAndSettle();
    expect(settings.shareTitle, false);
    expect(settings.titleCalls, 1);
    expect(find.byType(AlertDialog), findsNothing);
    expect(
        tester.widget<SwitchListTile>(find.byKey(titleKey)).onChanged, isNull);
  });

  testWidgets('a title dialog cannot give consent to a different account',
      (tester) async {
    final settings = _FakeDiscordSettings()..enabled = true;
    await showSettings(tester, settings);
    await tester.tap(find.byKey(titleKey));
    await tester.pumpAndSettle();
    settings.changeAccount('account-b', alreadyEnabled: true);
    await tester.pumpAndSettle();
    await accept(tester);
    expect(settings.titleCalls, 0);
    expect(settings.shareTitle, false);
  });

  testWidgets('logout while consent is open prevents saving', (tester) async {
    final settings = _FakeDiscordSettings();
    await showSettings(tester, settings);
    await tester.tap(find.byKey(enabledKey));
    await tester.pumpAndSettle();
    settings.changeAccount(null);
    await tester.pumpAndSettle();
    await accept(tester);
    expect(settings.enableCalls, 0);
  });

  testWidgets('connection states use fixed messages without transport details',
      (tester) async {
    final settings = _FakeDiscordSettings()..enabled = true;
    await showSettings(tester, settings);
    expect(find.textContaining('Not connected to Discord'), findsOneWidget);
    settings.status = DiscordConnectionState.connecting;
    settings.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('Connecting to Discord…'), findsOneWidget);
    settings.status = DiscordConnectionState.connected;
    settings.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('Connected to Discord'), findsOneWidget);
    settings.status = DiscordConnectionState.error;
    settings.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.textContaining('JMS playback is unaffected'), findsOneWidget);
    expect(find.textContaining('TEST_ONLY_TRANSPORT_ERROR'), findsNothing);
  });

  testWidgets('a failed preference save shows a fixed message and stays off',
      (tester) async {
    final settings = _FakeDiscordSettings()..savesSucceed = false;
    await showSettings(tester, settings);
    await tester.tap(find.byKey(enabledKey));
    await tester.pumpAndSettle();
    await accept(tester);
    expect(settings.enabled, false);
    expect(
        find.text('Unable to save this sharing preference. Please try again.'),
        findsOneWidget);
  });

  testWidgets('Traditional Chinese includes separate consent explanations',
      (tester) async {
    final settings = _FakeDiscordSettings();
    await showSettings(tester, settings,
        locale:
            const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'));
    expect(find.text('在 Discord 顯示播放狀態'), findsOneWidget);
    expect(find.text('分享影片名稱'), findsOneWidget);
    await tester.tap(find.byKey(enabledKey));
    await tester.pumpAndSettle();
    expect(find.textContaining('您的 Discord 個人檔案與朋友可能看見'), findsOneWidget);
    expect(find.text('同意並分享'), findsOneWidget);
    expect(settings.enableCalls, 0);
  });
}
