import 'dart:convert';

import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/credentials_model.dart';
import 'package:fladder/models/seerr_credentials_model.dart';
import 'package:fladder/models/settings/client_settings_model.dart';
import 'package:fladder/models/settings/video_player_settings.dart';
import 'package:fladder/providers/jms_entry_provider.dart';
import 'package:fladder/providers/diagnostics_provider.dart';
import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/seerr/seerr_session_store.dart';
import 'package:fladder/seerr/seerr_source.dart';
import 'package:fladder/services/jms_entry_cache.dart';
import 'package:fladder/services/jms_entry_discovery.dart';
import 'package:fladder/util/jms_service_config.dart';
import 'package:fladder/util/settings_backup.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _media = 'https://media.example.invalid/jellyfin';
const _seerr = 'https://requests.example.invalid/seerr';
const _diagnostic = 'https://entry.example.invalid/api/jms/diagnostics/v1';

AccountModel _account({
  String id = 'fixture-account-a',
  String serverId = 'aabb-ccdd',
  String url = _media,
  SeerrCredentialsModel? seerr,
}) =>
    AccountModel(
      name: 'fixture account',
      id: id,
      avatar: '',
      lastUsed: DateTime.utc(2026, 1, 1),
      credentials: CredentialsModel.internal(
        url: url,
        serverId: serverId,
        token: 'fixture-jellyfin-value',
        deviceId: 'fixture-device',
      ),
      seerrCredentials: seerr,
    );

JmsEntryResolution _resolution({
  String entry = 'https://entry.example.invalid/app/',
  String baseUrl = _media,
  String? seerr = _seerr,
  String? diagnostic = _diagnostic,
  JmsEntryResolutionKind kind = JmsEntryResolutionKind.configured,
}) =>
    JmsEntryResolution(
      kind: kind,
      entry: JmsEntryDiscovery.normalizeEntry(entry),
      config: JmsServiceConfig(
          baseUrl: baseUrl,
          seerrBaseUrl: seerr,
          diagnosticsEndpoint: diagnostic),
      error:
          kind == JmsEntryResolutionKind.cached ? JmsEntryError.timeout : null,
    );

final class _FailingPreferences implements SharedPreferences {
  @override
  String? getString(String key) => throw StateError('fixture storage read');
  @override
  Future<bool> setString(String key, String value) =>
      Future<bool>.error(StateError('fixture storage write'));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

List<MethodCall> _stubSecureSessionStore() {
  final calls = <MethodCall>[];
  final previousPlatform = debugDefaultTargetPlatformOverride;
  debugDefaultTargetPlatformOverride = TargetPlatform.android;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SeerrSessionStore.channel, (call) async {
    calls.add(call);
    return null;
  });
  addTearDown(() {
    debugDefaultTargetPlatformOverride = previousPlatform;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SeerrSessionStore.channel, null);
  });
  return calls;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({
        'fixture-account-sentinel': 'unchanged',
      }));

  test('confirmed bindings match normalized URL and public server id together',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final settings = JmsEntrySettings(prefs);
    final resolution = _resolution();
    expect(await settings.accept(resolution, 'AA-BB-CC-DD'), isTrue);
    expect(
        settings.forServer('$_media/', 'aabbccdd')?.config, resolution.config);
    expect(settings.forServer(_media, 'different-id'), isNull);
    expect(
        settings.forServer(
            'https://other.example.invalid/jellyfin', 'aabbccdd'),
        isNull);
    expect(
        settings.forServer('https://media.example.invalid/other', 'aabbccdd'),
        isNull);
    expect(settings.forServer(_media, ''), isNull);
    expect(settings.forAccount(_account())?.entry, resolution.entry);
    expect(
        await JmsEntryCache(prefs).read(resolution.entry!), resolution.config);
    expect(prefs.getString('fixture-account-sentinel'), 'unchanged');
  });

  test('multiple URL and id bindings do not overwrite another server scope',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final settings = JmsEntrySettings(prefs);
    final first = _resolution();
    final second = _resolution(
        entry: 'https://other-entry.example.invalid/',
        baseUrl: 'https://other-media.example.invalid',
        seerr: 'https://other-requests.example.invalid');
    await settings.accept(first, 'fixture-server-a');
    await settings.accept(second, 'fixture-server-b');
    expect(
        settings.forServer(_media, 'fixture-server-a')?.config, first.config);
    expect(
        settings
            .forServer(
                'https://other-media.example.invalid', 'fixture-server-b')
            ?.config,
        second.config);
    expect(settings.forServer(_media, 'fixture-server-b'), isNull);
    expect(await JmsEntryCache(prefs).read(first.entry!), first.config);
    expect(await JmsEntryCache(prefs).read(second.entry!), second.config);
  });

  test('direct connections create no website cache or binding', () async {
    final prefs = await SharedPreferences.getInstance();
    final settings = JmsEntrySettings(prefs);
    final before = prefs.getKeys();
    expect(
        await settings.accept(
            JmsEntryResolution(
                kind: JmsEntryResolutionKind.direct,
                config: JmsServiceConfig.direct(Uri.parse(_media)),
                serverId: 'aabbccdd'),
            'aabbccdd'),
        isTrue);
    expect(prefs.getKeys(), before);
    expect(settings.forServer(_media, 'aabbccdd'), isNull);
  });

  test('invalid binding scope and cache write failure preserve existing data',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final settings = JmsEntrySettings(prefs);
    final original = _resolution();
    await settings.accept(original, 'aabbccdd');
    expect(await settings.accept(_resolution(), ''), isFalse);
    expect(
        await settings.accept(
            _resolution(entry: 'http://lan.example.invalid/'), 'aabbccdd'),
        isFalse);
    expect(settings.forAccount(_account())?.config, original.config);
    final broken = JmsEntrySettings(_FailingPreferences());
    expect(broken.forServer(_media, 'aabbccdd'), isNull);
    expect(await broken.accept(original, 'aabbccdd'), isFalse);
    expect(prefs.getString('fixture-account-sentinel'), 'unchanged');
  });

  test('corrupt saved binding cannot silently replace account sources',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final settings = JmsEntrySettings(prefs);
    await settings.accept(_resolution(), 'aabbccdd');
    final key = prefs
        .getKeys()
        .singleWhere((key) => key.startsWith(JmsEntrySettings.bindingPrefix));
    final account = _account();
    for (final text in ['{fixture', '[]', '{"entry":42}']) {
      await prefs.setString(key, text);
      expect(settings.forAccount(account), isNull);
      expect(await settings.configureNewAccount(account), account);
      expect(prefs.getString(key), text);
    }
  });

  test('legacy manual source and credentials take precedence over entry config',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final settings = JmsEntrySettings(prefs);
    await settings.accept(_resolution(), 'aabbccdd');
    final legacy = _account(
        seerr: const SeerrCredentialsModel(
      serverUrl: 'https://manual.example.invalid/seerr',
      sessionCookie: 'fixture-legacy-session',
      linkedServerId: 'fixture-legacy-link',
    ));
    expect(settings.hasManualSeerr(legacy), isTrue);
    expect(settings.isServerProvided(legacy), isFalse);
    expect(await settings.configureNewAccount(legacy), legacy);
    expect(legacy.seerrCredentials?.sessionCookie, 'fixture-legacy-session');
  });

  test('manual markers isolate accounts and explicit empty source stays manual',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final settings = JmsEntrySettings(prefs);
    await settings.accept(_resolution(), 'aabbccdd');
    final first = _account();
    final second = _account(id: 'fixture-account-b');
    final manual = await settings.configureNewAccount(first,
        manual: true, manualSource: 'https://manual.example.invalid/seerr');
    expect(settings.hasManualSeerr(manual), isTrue);
    expect(manual.seerrCredentials?.serverUrl,
        'https://manual.example.invalid/seerr');
    expect(settings.hasManualSeerr(second), isFalse);
    expect(
        (await settings.configureNewAccount(second))
            .seerrCredentials
            ?.serverUrl,
        _seerr);
    final disabled = await settings.configureNewAccount(first,
        manual: true, manualSource: '');
    expect(disabled.seerrCredentials, isNull);
    expect(settings.hasManualSeerr(disabled), isTrue);
    expect(settings.isServerProvided(disabled), isFalse);
  });

  test(
      'automatic config creates fresh Seerr credentials without carrying secrets',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final settings = JmsEntrySettings(prefs);
    await settings.accept(_resolution(), 'aabbccdd');
    final previous = _account(
        seerr: const SeerrCredentialsModel(
      serverUrl: _seerr,
      apiKey: 'fixture-api-value',
      sessionCookie: 'fixture-session-value',
      linkedServerId: 'fixture-old-link',
      customHeaders: {'x-fixture': 'fixture-header'},
    ));
    await settings.markAutomaticSeerr(previous, _seerr);
    final configured = await settings.configureNewAccount(previous);
    expect(configured.seerrCredentials?.serverUrl, _seerr);
    expect(configured.seerrCredentials?.apiKey, isEmpty);
    expect(configured.seerrCredentials?.sessionCookie, isEmpty);
    expect(configured.seerrCredentials?.linkedServerId, isEmpty);
    expect(configured.seerrCredentials?.customHeaders, isEmpty);
    expect(configured.credentials, previous.credentials);
    expect(settings.isServerProvided(configured), isTrue);
    final other =
        await settings.configureNewAccount(_account(id: 'fixture-account-b'));
    expect(other.seerrCredentials?.sessionCookie, isEmpty);
    expect(other.credentials.token, 'fixture-jellyfin-value');
  });

  test(
      'missing optional services clear automatic values but retain manual values',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final settings = JmsEntrySettings(prefs);
    await settings.accept(_resolution(), 'aabbccdd');
    final automatic =
        _account(seerr: const SeerrCredentialsModel(serverUrl: _seerr));
    await settings.markAutomaticSeerr(automatic, _seerr);
    await settings.accept(
        _resolution(seerr: null, diagnostic: null), 'aabbccdd');
    final updated = await settings.configureNewAccount(automatic);
    expect(updated.seerrCredentials, isNull);
    expect(updated.credentials, automatic.credentials);
    expect(settings.forAccount(updated)?.config.diagnosticsEndpoint, isNull);
    final manual = _account(
        id: 'fixture-account-b',
        seerr: const SeerrCredentialsModel(
            serverUrl: 'https://manual.example.invalid/seerr'));
    expect(await settings.configureNewAccount(manual), manual);
  });

  test(
      'actual stored binding and cache are excluded from backup and survive restore',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final settings = JmsEntrySettings(prefs);
    await settings.accept(_resolution(), 'aabbccdd');
    await settings.markAutomaticSeerr(_account(), _seerr);
    await settings.markManualSeerr(_account(id: 'fixture-account-b'));
    final local = <String, dynamic>{
      for (final key in prefs.getKeys())
        if (key.startsWith('jms.entry.')) key: prefs.get(key)
    };
    expect(local.keys.any((key) => key.startsWith(JmsEntryCache.keyPrefix)),
        isTrue);
    expect(
        local.keys.any((key) => key.startsWith(JmsEntrySettings.bindingPrefix)),
        isTrue);
    final client = ClientSettingsModel.defaultModel().toJson();
    final player = VideoPlayerSettingsModel().toJson();
    final backup =
        SettingsBackup.capture({...client, ...local}, {...player, ...local});
    final text = utf8.decode(backup.encode());
    for (final key in local.keys) {
      expect(text.contains(key), isFalse);
    }
    for (final address in [
      _media,
      _seerr,
      _diagnostic,
      'entry.example.invalid'
    ]) {
      expect(text.contains(address), isFalse);
    }
    expect(
        () => SettingsBackup.parse(utf8.encode(jsonEncode({
              'schemaVersion': 1,
              'settings': {'client': local}
            }))),
        throwsA(isA<SettingsBackupFailure>()));
    await SettingsBundleStore(prefs).replace(client, player);
    for (final item in local.entries) {
      expect(prefs.get(item.key), item.value);
    }
    expect(settings.forAccount(_account())?.config.seerrBaseUrl, _seerr);
    expect(prefs.getString('fixture-account-sentinel'), 'unchanged');
  });

  test(
      'effective source uses explicit build fallback only without an entry binding',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final settings = JmsEntrySettings(prefs);
    const fallback = 'https://build-config.example.invalid/seerr';
    expect(
        settings
            .effectiveSeerrCredentials(null, configuredSource: fallback)
            .serverUrl,
        isEmpty);
    expect(
        settings
            .effectiveSeerrCredentials(_account(), configuredSource: fallback)
            .serverUrl,
        fallback);
    await settings.accept(_resolution(seerr: null), 'aabbccdd');
    expect(
        settings
            .effectiveSeerrCredentials(_account(), configuredSource: fallback)
            .serverUrl,
        isEmpty);
  });

  test('effective source change drops old credentials without mutating account',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final settings = JmsEntrySettings(prefs);
    const saved = SeerrCredentialsModel(
      serverUrl: _seerr,
      apiKey: 'fixture-api-value',
      sessionCookie: 'fixture-session-value',
      linkedServerId: 'fixture-old-link',
      customHeaders: {'x-fixture': 'fixture-header'},
    );
    final account = _account(seerr: saved);
    await settings.markAutomaticSeerr(account, _seerr);
    await settings.accept(
        _resolution(seerr: 'https://new-requests.example.invalid'), 'aabbccdd');
    final effective = settings.effectiveSeerrCredentials(account,
        configuredSource: 'https://build-config.example.invalid');
    expect(effective.serverUrl, 'https://new-requests.example.invalid');
    expect(effective.apiKey, isEmpty);
    expect(effective.sessionCookie, isEmpty);
    expect(effective.linkedServerId, isEmpty);
    expect(effective.customHeaders, isEmpty);
    expect(account.seerrCredentials, saved);
    expect(account.credentials.token, 'fixture-jellyfin-value');
  });

  test('effective matching automatic source retains this account session',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final settings = JmsEntrySettings(prefs);
    const saved = SeerrCredentialsModel(
      serverUrl: _seerr,
      sessionCookie: 'fixture-current-session',
      linkedServerId: 'fixture-current-link',
    );
    final account = _account(seerr: saved);
    await settings.markAutomaticSeerr(account, _seerr);
    await settings.accept(_resolution(), 'aabbccdd');
    expect(settings.effectiveSeerrCredentials(account), saved);
  });

  test('effective optional null disables automatic fallback while manual stays',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final settings = JmsEntrySettings(prefs);
    final automatic =
        _account(seerr: const SeerrCredentialsModel(serverUrl: _seerr));
    await settings.markAutomaticSeerr(automatic, _seerr);
    await settings.accept(_resolution(seerr: null), 'aabbccdd');
    expect(
        settings.effectiveSeerrCredentials(automatic,
            configuredSource: 'https://build-config.example.invalid/seerr'),
        const SeerrCredentialsModel());
    const savedManual = SeerrCredentialsModel(
        serverUrl: 'https://manual.example.invalid/seerr',
        sessionCookie: 'fixture-manual-session');
    final manual = _account(id: 'fixture-account-b', seerr: savedManual);
    expect(
        settings.effectiveSeerrCredentials(manual,
            configuredSource: 'https://build-config.example.invalid/seerr'),
        savedManual);
  });

  test('different accounts on same server and receiver require fresh consent',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final first = _account();
    final second = _account(id: 'fixture-account-b');
    expect(entryServerScope(first.credentials.url, first.credentials.serverId),
        entryServerScope(second.credentials.url, second.credentials.serverId));
    expect(entryDiagnosticsScope(first), isNot(entryDiagnosticsScope(second)));
    var requests = 0;
    final diagnostics = DiagnosticsSettings(
      preferences: prefs,
      version: '0.11.1-jms.28',
      buildId: 'JMS-0.11.1-jms.28-123456abcdef',
      platform: 'android',
      clientFactory: () => MockClient((request) async {
        requests++;
        return http.Response('', 202);
      }),
    );
    addTearDown(diagnostics.dispose);
    expect(
        await diagnostics.activateServer(
            entryDiagnosticsScope(first), _diagnostic),
        isTrue);
    expect(await diagnostics.setEnabled(true), isTrue);
    expect(diagnostics.enabled, isTrue);
    final oldConsentKeys = prefs
        .getKeys()
        .where((key) =>
            key.startsWith('jms.diagnostics.') &&
            key.endsWith('.consent') &&
            prefs.getBool(key) == true)
        .toList();
    expect(oldConsentKeys, hasLength(1));
    expect(
        await diagnostics.activateServer(
            entryDiagnosticsScope(second), _diagnostic),
        isTrue);
    expect(diagnostics.enabled, isFalse);
    for (final key in oldConsentKeys) {
      expect(prefs.getBool(key), isFalse);
    }
    expect(
        await diagnostics.activateServer(
            entryDiagnosticsScope(first), _diagnostic),
        isTrue);
    expect(diagnostics.enabled, isFalse);
    expect(requests, 0);
  });

  test('bound account load preserves source while startup scrubs old plaintext',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final settings = JmsEntrySettings(prefs);
    final helper = SharedHelper(sharedPreferences: prefs);
    final storeCalls = _stubSecureSessionStore();
    final source = legacyJmsSeerrSource.isEmpty
        ? 'https://legacy.example.invalid/seerr'
        : legacyJmsSeerrSource;
    final account = _account(
        seerr: SeerrCredentialsModel(
            serverUrl: source,
            apiKey: 'fixture-retained-value',
            linkedServerId: 'fixture-retained-link'));
    expect(await settings.accept(_resolution(seerr: null), 'aabbccdd'), isTrue);
    final encoded = jsonDecode(jsonEncode(account)) as Map<String, dynamic>;
    (encoded['seerrCredentials'] as Map<String, dynamic>)['sessionCookie'] =
        'fixture-plaintext-value';
    await prefs.setStringList('loginCredentialsKey', [jsonEncode(encoded)]);

    final loaded = helper.getAccounts().single;
    expect(loaded.seerrCredentials?.serverUrl, source);
    expect(loaded.seerrCredentials?.apiKey, 'fixture-retained-value');
    expect(loaded.seerrCredentials?.sessionCookie, isEmpty);
    expect(loaded.credentials.toJson(), account.credentials.toJson());
    expect(await helper.migrateJmsSeerrAccounts(), 0);
    final saved = jsonDecode(prefs.getStringList('loginCredentialsKey')!.single)
        as Map<String, dynamic>;
    final savedSeerr = saved['seerrCredentials'] as Map<String, dynamic>;
    expect(savedSeerr.containsKey('sessionCookie'), isFalse);
    expect(savedSeerr['serverUrl'], source);
    expect(savedSeerr['apiKey'], 'fixture-retained-value');
    expect(helper.getAccounts().single.seerrCredentials?.linkedServerId,
        'fixture-retained-link');
    expect(storeCalls, isEmpty);
    expect(await helper.migrateJmsSeerrAccounts(), 0);
    expect(prefs.getString('fixture-account-sentinel'), 'unchanged');
  });

  test('entry binding cannot suppress legacy migration in another server scope',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final settings = JmsEntrySettings(prefs);
    final helper = SharedHelper(sharedPreferences: prefs);
    final storeCalls = _stubSecureSessionStore();
    final source = legacyJmsSeerrSource.isEmpty
        ? 'https://legacy.example.invalid/seerr'
        : legacyJmsSeerrSource;
    final bound = _account(
        seerr: SeerrCredentialsModel(
            serverUrl: source, apiKey: 'fixture-retained-value'));
    final other = bound.copyWith(
        id: 'fixture-account-b',
        credentials: bound.credentials.copyWith(serverId: 'different-id'));
    await settings.accept(_resolution(seerr: null), 'aabbccdd');
    await helper.saveAccounts([bound, other]);
    final shouldMigrate = needsJmsSeerrSourceMigration(other);
    expect(helper.getAccounts().first.seerrCredentials?.serverUrl, source);
    expect(helper.getAccounts().last.seerrCredentials?.serverUrl,
        shouldMigrate ? jmsSeerrSource : source);
    expect(await helper.migrateJmsSeerrAccounts(), shouldMigrate ? 1 : 0);
    expect(helper.getAccounts().first.seerrCredentials?.apiKey,
        'fixture-retained-value');
    expect(helper.getAccounts().last.seerrCredentials?.apiKey,
        shouldMigrate ? isEmpty : 'fixture-retained-value');
    expect(helper.getAccounts().last.credentials.toJson(),
        other.credentials.toJson());
    expect(storeCalls.isNotEmpty, shouldMigrate);
    expect(await helper.migrateJmsSeerrAccounts(), 0);
  });

  test(
      'optional null stays unset across load and migration with build defaults',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final settings = JmsEntrySettings(prefs);
    final helper = SharedHelper(sharedPreferences: prefs);
    final storeCalls = _stubSecureSessionStore();
    final account = _account();
    await settings.accept(_resolution(seerr: null), 'aabbccdd');
    await helper.saveAccounts([account]);
    expect(helper.getAccounts().single.seerrCredentials, isNull);
    expect(await helper.migrateJmsSeerrAccounts(), 0);
    expect(helper.getAccounts().single.seerrCredentials, isNull);
    expect(
        settings.effectiveSeerrCredentials(helper.getAccounts().single,
            configuredSource: 'https://build-config.example.invalid/seerr'),
        const SeerrCredentialsModel());
    expect(storeCalls, isEmpty);
  });
}
