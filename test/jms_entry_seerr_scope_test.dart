import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fladder/l10n/generated/app_localizations.dart';
import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/credentials_model.dart';
import 'package:fladder/models/seerr_credentials_model.dart';
import 'package:fladder/providers/jms_entry_provider.dart';
import 'package:fladder/providers/seerr_api_provider.dart';
import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/screens/seerr/seerr_link_panel.dart';
import 'package:fladder/screens/settings/widgets/seerr_connection_dialog.dart';
import 'package:fladder/seerr/seerr_connection.dart';
import 'package:fladder/seerr/seerr_session_store.dart';
import 'package:fladder/seerr/seerr_source.dart';
import 'package:fladder/services/jms_entry_discovery.dart';
import 'package:fladder/util/jms_service_config.dart';

const _fallback = 'https://fallback.example.invalid/seerr';
const _originalSource = 'https://service.example.invalid/seerr';

AccountModel _account(
        {String url = 'https://media.example.invalid/jellyfin',
        SeerrCredentialsModel? seerr}) =>
    AccountModel(
        name: 'Synthetic user',
        id: 'aabbcc',
        avatar: '',
        lastUsed: DateTime(2026),
        credentials:
            CredentialsModel.internal(serverId: 'synthetic-server', url: url),
        seerrCredentials: seerr);

class _EntryUser extends User {
  _EntryUser(this.initial);
  final AccountModel? initial;
  @override
  AccountModel? build() => initial;
  @override
  set userState(AccountModel? value) => state = value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences preferences;
  late JmsEntrySettings settings;
  final records = <String, String>{};
  final reads = <String>[];
  final calls = <http.Request>[];
  final containers = <ProviderContainer>[];
  final store = SeerrSessionStore();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    settings = JmsEntrySettings(preferences);
    records.clear();
    reads.clear();
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SeerrSessionStore.channel, (call) async {
      final key = call.arguments['key'] as String;
      if (call.method == 'read') {
        reads.add(key);
        return records[key];
      }
      final value = call.arguments['value'] as String?;
      if (value == null) {
        records.remove(key);
      } else {
        records[key] = value;
      }
      return null;
    });
  });
  tearDown(() {
    for (final container in containers) {
      container.dispose();
    }
    containers.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SeerrSessionStore.channel, null);
  });

  Future<void> bind(AccountModel account, String? source) async {
    expect(
        await settings.accept(
            JmsEntryResolution(
                kind: JmsEntryResolutionKind.configured,
                entry: Uri.parse('https://entry.example.invalid/'),
                config: JmsServiceConfig(
                    baseUrl: account.credentials.url, seerrBaseUrl: source)),
            account.credentials.serverId),
        isTrue);
  }

  ProviderContainer scope(AccountModel? account) {
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      jmsEntrySettingsProvider.overrideWithValue(settings),
      userProvider.overrideWith(() => _EntryUser(account)),
      seerrSessionStoreProvider.overrideWithValue(store),
      seerrHttpClientFactoryProvider
          .overrideWithValue(() => MockClient((request) async {
                calls.add(request);
                return http.Response(
                    jsonEncode(request.url.path.endsWith('/auth/me')
                        ? {'id': 1, 'jellyfinUserId': 'aabbcc'}
                        : {'version': 'synthetic'}),
                    200,
                    headers: {'content-type': 'application/json'});
              })),
    ]);
    containers.add(container);
    container.listen(seerrApiProvider, (_, __) {});
    return container;
  }

  Matcher failure(String code) =>
      throwsA(isA<SeerrFailure>().having((value) => value.code, 'code', code));

  Future<void> show(
      WidgetTester tester, ProviderContainer container, Widget child) async {
    await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: child))));
    await tester.pumpAndSettle();
  }

  test('optional null blocks configured and compile defaults in production API',
      () async {
    final account = _account();
    await bind(account, null);
    expect(
        settings
            .effectiveSeerrCredentials(account, configuredSource: _fallback)
            .serverUrl,
        isEmpty);
    final container = scope(account);
    await expectLater(
        container.read(seerrApiProvider).status(), failure('not_configured'));
    expect(calls, isEmpty);
    expect(reads, isEmpty);
  });

  test('no active account cannot use a compile default', () async {
    final container = scope(null);
    await expectLater(
        container.read(seerrApiProvider).status(), failure('not_configured'));
    expect(calls, isEmpty);
  });

  test('manual source takes precedence only within its account scope',
      () async {
    final account = _account(
        seerr: const SeerrCredentialsModel(serverUrl: _originalSource));
    await bind(account, null);
    await settings.markManualSeerr(account);
    final container = scope(account);
    await container.read(seerrApiProvider).status();
    expect(calls.single.url.toString(), '$_originalSource/api/v1/status');
    final other = _account(url: 'https://other-media.example.invalid/jellyfin');
    await bind(other, null);
    container.read(userProvider.notifier).userState = other;
    await container.pump();
    await expectLater(
        container.read(seerrApiProvider).status(), failure('not_configured'));
    expect(calls, hasLength(1));
  });

  test('empty explicit manual source stays empty', () async {
    final account = _account(seerr: const SeerrCredentialsModel());
    await bind(account, _originalSource);
    await settings.markManualSeerr(account);
    final container = scope(account);
    await expectLater(
        container.read(seerrApiProvider).status(), failure('not_configured'));
    expect(calls, isEmpty);
  });

  test(
      'binding a changed automatic source retains provenance and clears old secrets',
      () async {
    const nextSource = 'https://new-service.example.invalid/seerr';
    final account = _account(
        seerr: const SeerrCredentialsModel(
            serverUrl: _originalSource,
            apiKey: 'TEST_ONLY',
            sessionCookie: 'connect.sid=TEST_ONLY',
            customHeaders: {'X-Synthetic-Session': 'SYNTHETIC_OLD_HEADER'},
            linkedServerId: 'synthetic-server'));
    await settings.markAutomaticSeerr(account, _originalSource);
    await bind(account, nextSource);
    final container = scope(account);
    await container.read(userProvider.notifier).bindSeerrAccount(nextSource);
    final updated = container.read(userProvider)!;
    expect(settings.hasManualSeerr(updated), isFalse);
    expect(settings.isServerProvided(updated), isTrue);
    final effective = settings.effectiveSeerrCredentials(updated);
    expect(effective.serverUrl, nextSource);
    expect(effective.linkedServerId, updated.credentials.serverId);
    expect(effective.apiKey, isEmpty);
    expect(effective.sessionCookie, isEmpty);
    expect(effective.customHeaders, isEmpty);
    expect(updated.seerrCredentials, effective);

    await settings.markManualSeerr(updated);
    await container
        .read(userProvider.notifier)
        .bindSeerrAccount(_originalSource);
    final manual = container.read(userProvider)!;
    expect(settings.hasManualSeerr(manual), isTrue);
    expect(settings.isServerProvided(manual), isFalse);
    expect(
        settings.effectiveSeerrCredentials(manual).serverUrl, _originalSource);
    expect(calls, isEmpty);
  });

  test('legacy unbound accounts retain configured and actual compile fallback',
      () async {
    final account = _account();
    expect(
        settings
            .effectiveSeerrCredentials(account, configuredSource: _fallback)
            .serverUrl,
        _fallback);
    final container = scope(account);
    if (jmsSeerrSource.isEmpty) {
      await expectLater(
          container.read(seerrApiProvider).status(), failure('not_configured'));
      expect(calls, isEmpty);
    } else {
      await container.read(seerrApiProvider).status();
      expect(calls.single.url.toString(), '$jmsSeerrSource/api/v1/status');
    }
  });

  for (final source in [
    'https://new-service.example.invalid/seerr',
    '$_originalSource/next'
  ]) {
    test(
        'changed automatic source never reads or sends the old secure session: $source',
        () async {
      final account = _account(
          seerr: const SeerrCredentialsModel(
              serverUrl: _originalSource, linkedServerId: 'synthetic-server'));
      await settings.markAutomaticSeerr(account, _originalSource);
      await store.write(account, 'connect.sid=SYNTHETIC_OLD_SESSION');
      final oldKey = SeerrSessionStore.key(account);
      expect(records.containsKey(oldKey), isTrue);
      await bind(account, source);
      reads.clear();
      final container = scope(account);
      await expectLater(
          container.read(seerrApiProvider).me(), failure('session_missing'));
      expect(calls.single.url.toString(), '$source/api/v1/auth/me');
      expect(calls.single.headers.keys.map((value) => value.toLowerCase()),
          isNot(contains('cookie')));
      expect(calls.single.headers.keys.map((value) => value.toLowerCase()),
          isNot(contains('x-api-key')));
      expect(reads, isNot(contains(oldKey)));
      expect(records.containsKey(oldKey), isTrue);
    });
  }

  test('same user/server id URL change invalidates the captured old client',
      () async {
    final first = _account();
    final second = _account(url: 'https://other-media.example.invalid/jellyfin');
    await bind(first, _originalSource);
    await bind(second, 'https://other-service.example.invalid/seerr');
    final container = scope(first);
    final previous = container.read(seerrApiProvider);
    container.read(userProvider.notifier).userState = second;
    await container.pump();
    await expectLater(previous.status(), failure('account_changed'));
    await container.read(seerrApiProvider).status();
    expect(calls.single.url.toString(),
        'https://other-service.example.invalid/seerr/api/v1/status');
  });

  testWidgets(
      'null entry dialog offers manual source without default or verification',
      (tester) async {
    final account = _account();
    await bind(account, null);
    final container = scope(account);
    await show(tester, container, const SeerrConnectionDialog());
    expect(find.byKey(const Key('seerr-service-url')), findsOneWidget);
    expect(find.byKey(const Key('seerr-save-service-url')), findsOneWidget);
    expect(find.textContaining('Service：Not configured'), findsOneWidget);
    expect(find.text('Link my Jellyfin account'), findsNothing);
    expect(find.text('Verify Jellyfin account'), findsNothing);
    expect(calls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no account dialog cannot start linking', (tester) async {
    final container = scope(null);
    await show(tester, container, const SeerrConnectionDialog());
    expect(find.byKey(const Key('seerr-service-url')), findsNothing);
    expect(find.text('Link my Jellyfin account'), findsNothing);
    expect(find.text('Verify Jellyfin account'), findsNothing);
    expect(calls, isEmpty);
  });

  testWidgets('manual source can be saved after entry disables integration',
      (tester) async {
    final account = _account();
    await bind(account, null);
    final container = scope(account);
    await show(tester, container, const SeerrConnectionDialog());
    await tester.enterText(
        find.byKey(const Key('seerr-service-url')), _originalSource);
    await tester.tap(find.byKey(const Key('seerr-save-service-url')));
    await tester.pumpAndSettle();
    final saved = container.read(userProvider)!;
    expect(settings.hasManualSeerr(saved), isTrue);
    expect(
        settings.effectiveSeerrCredentials(saved).serverUrl, _originalSource);
    expect(saved.seerrCredentials?.linkedServerId, isEmpty);
    expect(find.byKey(const Key('seerr-service-url')), findsNothing);
    expect(find.text('Link my Jellyfin account'), findsOneWidget);
    expect(calls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'stale link confirmation cannot bind after the effective source is disabled',
      (tester) async {
    final account = _account();
    await bind(account, _originalSource);
    final container = scope(account);
    await show(
        tester,
        container,
        Consumer(
            builder: (context, ref, _) => TextButton(
                onPressed: () => openSeerrAccountLink(context, ref),
                child: const Text('Open link'))));
    await tester.tap(find.text('Open link'));
    await tester.pumpAndSettle();
    expect(find.text('Confirm same service'), findsOneWidget);
    await bind(account, null);
    await tester.tap(find.text('Confirm same service'));
    await tester.pumpAndSettle();
    expect(container.read(userProvider)?.seerrCredentials, isNull);
    expect(calls, isEmpty);
  });
}
