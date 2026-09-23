import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fladder/models/seerr_credentials_model.dart';
import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/seerr/seerr_session_store.dart';
import 'package:fladder/seerr/seerr_source.dart';
import 'package:fladder/util/fladder_config.dart';

import 'fixtures/seerr_test_scope.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final storedSessions = <String, String>{};

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    storedSessions.clear();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SeerrSessionStore.channel,
      (call) async {
        final key = call.arguments['key'] as String;
        if (call.method == 'read') return storedSessions[key];
        final value = call.arguments['value'] as String?;
        if (value == null) {
          storedSessions.remove(key);
        } else {
          storedSessions[key] = value;
        }
        return null;
      },
    );
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SeerrSessionStore.channel, null);
  });

  test('new installs and empty sources use correct default without carrying credentials', () {
    expect(effectiveJmsSeerrCredentials(null).serverUrl, jmsSeerrSource);
    final empty = effectiveJmsSeerrCredentials(
      const SeerrCredentialsModel(apiKey: 'OLD_ONLY', customHeaders: {'Authorization': 'OLD_ONLY'}),
    );
    expect(empty.serverUrl, jmsSeerrSource);
    expect(empty.apiKey, isEmpty);
    expect(empty.customHeaders, isEmpty);
    expect(effectiveJmsSeerrCredentials(null, configuredSource: 'https://custom.invalid').serverUrl,
        'https://custom.invalid');
    FladderConfig.seerrBaseUrl = legacyJmsSeerrSource;
    expect(FladderConfig.seerrBaseUrl, jmsSeerrSource);
    FladderConfig.fromJson({'baseUrl': 'https://jellyfin.invalid', 'seerrBaseUrl': legacyJmsSeerrSource});
    expect(FladderConfig.seerrBaseUrl, jmsSeerrSource);
    expect(FladderConfig.baseUrl, 'https://jellyfin.invalid');
    FladderConfig.seerrBaseUrl = null;
    FladderConfig.baseUrl = null;
  });

  test('legacy source migrates once, removes old session and preserves other accounts', () async {
    final preferences = await SharedPreferences.getInstance();
    final helper = SharedHelper(sharedPreferences: preferences);
    await preferences.setString('ambient-sentinel', 'unchanged');
    final oldAccount = seerrFixtureAccount().copyWith(
      seerrCredentials: const SeerrCredentialsModel(
        serverUrl: legacyJmsSeerrSource,
        linkedServerId: 'fixture-server',
        apiKey: 'OLD_ONLY',
        sessionCookie: 'connect.sid=OLD_ONLY',
        customHeaders: {'Authorization': 'OLD_ONLY'},
      ),
    );
    final customAccount = seerrFixtureAccount(id: 'custom-user').copyWith(
      seerrCredentials: const SeerrCredentialsModel(
          serverUrl: 'https://custom.invalid', linkedServerId: 'fixture-server', apiKey: 'CUSTOM_ONLY'),
    );
    await helper.saveAccounts([oldAccount, customAccount]);
    final store = SeerrSessionStore();
    await store.write(oldAccount, 'connect.sid=OLD_ONLY');
    await store.write(customAccount, 'connect.sid=CUSTOM_ONLY');

    expect(helper.getAccounts().first.seerrCredentials?.serverUrl, jmsSeerrSource);
    expect(helper.getAccounts().first.seerrCredentials?.apiKey, isEmpty);
    expect(await helper.migrateJmsSeerrAccounts(), 1);
    final migrated = helper.getAccounts().first;
    expect(migrated.seerrCredentials?.serverUrl, jmsSeerrSource);
    expect(migrated.seerrCredentials?.linkedServerId, isEmpty);
    expect(migrated.seerrCredentials?.apiKey, isEmpty);
    expect(migrated.seerrCredentials?.customHeaders, isEmpty);
    expect(migrated.credentials.toJson(), oldAccount.credentials.toJson());
    expect(migrated.id, oldAccount.id);
    expect(await store.read(oldAccount), isNull);
    expect(await store.read(migrated), isNull);
    expect(await store.read(customAccount), 'connect.sid=CUSTOM_ONLY');
    expect(helper.getAccounts().last.seerrCredentials?.toJson(), customAccount.seerrCredentials?.toJson());
    expect(await helper.migrateJmsSeerrAccounts(), 0);
    expect(jsonEncode(helper.getAccounts().first), isNot(contains(legacyJmsSeerrSource)));
    expect(preferences.getString('ambient-sentinel'), 'unchanged');
  });

  test('only exact historical origin is migrated', () {
    expect(isLegacyJmsSeerrSource('$legacyJmsSeerrSource/'), isTrue);
    expect(isLegacyJmsSeerrSource('$legacyJmsSeerrSource/api'), isFalse);
    expect(isLegacyJmsSeerrSource('https://example.invalid'), isFalse);
    expect(normalizeConfiguredSeerrSource('https://custom.invalid'), 'https://custom.invalid');
  });
}
