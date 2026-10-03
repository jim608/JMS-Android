import 'dart:async';
import 'dart:convert';

import 'package:chopper/chopper.dart';
import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/l10n/generated/app_localizations.dart';
import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/login_screen_model.dart';
import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/auth_provider.dart';
import 'package:fladder/providers/discovery_provider.dart';
import 'package:fladder/providers/image_provider.dart';
import 'package:fladder/providers/jms_entry_provider.dart';
import 'package:fladder/providers/service_provider.dart';
import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/screens/login/login_screen_credentials.dart';
import 'package:fladder/services/jms_entry_cache.dart';
import 'package:fladder/services/jms_entry_discovery.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/fladder_config.dart';
import 'package:fladder/util/jms_service_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _entryA = 'https://example.invalid/entry-a';
const _entryB = 'https://example.invalid/entry-b';
const _mediaA = 'https://example.invalid/media-a';
const _mediaB = 'https://example.invalid/media-b';
const _seerrA = 'https://example.invalid/requests-a';
const _seerrB = 'https://example.invalid/requests-b';
const _idA = 'fixture-server-a';
const _idB = 'fixture-server-b';

Response<T> _response<T>(T body) => Response(http.Response('{}', 200), body);

JmsServiceConfig _config(String media, String seerr) =>
    JmsServiceConfig.fromJson({
      'baseUrl': media,
      'seerrBaseUrl': seerr,
      'diagnosticsEndpoint': null,
    });

Response<AuthenticationResult> _authentication(String serverId) =>
    _response(AuthenticationResult(
      user: const UserDto(id: 'fixture-user', name: 'Fixture user'),
      accessToken: 'fixture-access-token',
      serverId: serverId,
    ));

class _Accounts implements SharedUtility {
  final accounts = <AccountModel>[];

  @override
  List<AccountModel> getAccounts() => accounts.toList();

  void _save(AccountModel account) {
    accounts.removeWhere((saved) =>
        saved.sameIdentity(account) &&
        saved.credentials.url == account.credentials.url);
    accounts.add(account);
  }

  @override
  Future<bool?> addAccount(AccountModel account) async {
    _save(account);
    return true;
  }

  @override
  Future<void> updateAccountInfo(AccountModel account) async => _save(account);

  @override
  Future<int> migrateJmsSeerrAccounts() async => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
      'Unexpected account operation ${invocation.memberName}');
}

class _Images implements ImageNotifier {
  @override
  String getUserImageUrl(String id) => '';

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
      'Unexpected image operation ${invocation.memberName}');
}

class _NoDiscovery extends ServerDiscovery {
  @override
  Stream<List<DiscoveryInfo>> build() => Stream.value(const []);
}

class _Api extends JellyApi {
  _Api(this.service);
  final JellyService service;

  @override
  JellyService build() => service;
}

class _Service implements JellyService {
  _Service(this.fixture, this.url);
  final _Fixture fixture;
  final String url;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #systemInfoPublicGet:
        fixture.infoUrls.add(url);
        if (fixture.publicInfo != null) return fixture.publicInfo!(url);
        return Future.value(_response(PublicSystemInfo(
          id: fixture.serverIds[url] ?? _idA,
          serverName: 'Synthetic media server',
        )));
      case #usersPublicGet:
        return Future.value(_response(<AccountModel>[]));
      case #quickConnectEnabled:
        return Future.value(_response(false));
      case #getBranding:
        return Future.value(_response(const BrandingOptionsDto()));
      case #usersAuthenticateByNamePost:
      case #quickConnectAuthenticate:
        fixture.authUrls.add(url);
        fixture.authStarted?.complete();
        return fixture.authentication?.call(url) ??
            Future.value(_authentication(fixture.serverIds[url] ?? _idA));
      default:
        throw UnsupportedError(
            'Unexpected Jellyfin operation ${invocation.memberName}');
    }
  }
}

class _DelayedSettings extends JmsEntrySettings {
  _DelayedSettings(super.preferences);
  final savingAccount = Completer<void>();
  final releaseSave = Completer<void>();

  @override
  Future<AccountModel> configureNewAccount(AccountModel account,
      {bool manual = false, String? manualSource}) async {
    savingAccount.complete();
    await releaseSave.future;
    return super.configureNewAccount(account,
        manual: manual, manualSource: manualSource);
  }
}

class _Fixture {
  _Fixture(this.preferences, {JmsEntrySettings? settings}) {
    discovery = JmsEntryDiscovery(
      client: MockClient((request) async {
        requests.add(request.url);
        if (request.url.path.endsWith('/jms-config.json')) {
          if (invalidConfig) {
            return http.Response('{', 200,
                headers: {'content-type': 'application/json'});
          }
          final config =
              request.url.path.startsWith('/entry-b/') ? configB : configA;
          return http.Response(jsonEncode(config.toJson()), 200,
              headers: {'content-type': 'application/json'});
        }
        if (request.url.path.endsWith('/System/Info/Public')) {
          return http.Response(
              jsonEncode({
                'ProductName': 'Jellyfin Server',
                'Version': '10.11.0',
                'Id': _idA,
              }),
              200,
              headers: {'content-type': 'application/json'});
        }
        throw StateError('Unexpected synthetic discovery route');
      }),
      cache: JmsEntryCache(preferences),
    );
    entrySettings = settings ?? JmsEntrySettings(preferences);
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      sharedUtilityProvider.overrideWithValue(accounts),
      imageUtilityProvider.overrideWithValue(_Images()),
      jmsEntryDiscoveryProvider.overrideWithValue(discovery),
      jmsEntrySettingsProvider.overrideWithValue(entrySettings),
      jmsLoginConnectionProvider.overrideWithValue((credentials) {
        connectionUrls.add(credentials.url);
        return JmsLoginConnection(_Service(this, credentials.url),
            () => closedUrls.add(credentials.url));
      }),
      jellyApiProvider.overrideWith(() => _Api(_Service(this, _mediaA))),
      serverDiscoveryProvider.overrideWith(_NoDiscovery.new),
    ]);
  }

  final SharedPreferences preferences;
  final accounts = _Accounts();
  late final JmsEntryDiscovery discovery;
  late final JmsEntrySettings entrySettings;
  late final ProviderContainer container;
  JmsServiceConfig configA = _config(_mediaA, _seerrA);
  JmsServiceConfig configB = _config(_mediaB, _seerrB);
  bool invalidConfig = false;
  final requests = <Uri>[];
  final connectionUrls = <String>[];
  final closedUrls = <String>[];
  final infoUrls = <String>[];
  final authUrls = <String>[];
  final serverIds = {_mediaA: _idA, _mediaB: _idB, _entryA: _idA};
  Completer<void>? authStarted;
  Future<Response<AuthenticationResult>> Function(String)? authentication;
  Future<Response<PublicSystemInfo>> Function(String)? publicInfo;
  AuthNotifier get auth => container.read(authProvider.notifier);

  void dispose() {
    container.dispose();
    discovery.close();
  }
}

Future<_Fixture> _fixture({JmsEntrySettings? settings}) async {
  final fixture =
      _Fixture(await SharedPreferences.getInstance(), settings: settings);
  addTearDown(fixture.dispose);
  return fixture;
}

Future<void> _pumpLogin(WidgetTester tester, _Fixture fixture) async {
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: fixture.container,
    child: AdaptiveLayoutBuilder(
      child: (_) => const MaterialApp(
        locale: Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: Center(
              child: SizedBox(width: 600, child: LoginScreenCredentials()),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

Future<void> _submitEntry(WidgetTester tester, String entry) async {
  await tester.enterText(find.byType(TextField).first, entry);
  await tester.testTextInput.receiveAction(TextInputAction.go);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  String? originalBaseUrl;
  String? originalSeerr;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    originalBaseUrl = FladderConfig.baseUrl;
    originalSeerr = FladderConfig.seerrBaseUrl;
    FladderConfig.baseUrl = null;
    FladderConfig.seerrBaseUrl = null;
  });
  tearDown(() {
    FladderConfig.baseUrl = originalBaseUrl;
    FladderConfig.seerrBaseUrl = originalSeerr;
  });

  testWidgets(
      'entry resolves services while login field preserves original input',
      (tester) async {
    final fixture = await _fixture();
    await _pumpLogin(tester, fixture);
    await _submitEntry(tester, _entryA);
    final model = fixture.container.read(authProvider);
    expect(model.serverLoginModel?.tempCredentials.url, _mediaA);
    expect(model.serverLoginModel?.tempCredentials.serverId, _idA);
    expect(model.tempSeerrUrl, _seerrA);
    expect(fixture.auth.entryInput, _entryA);
    expect(
        tester.widget<TextField>(find.byType(TextField).first).controller?.text,
        _entryA);
    expect(fixture.infoUrls, [_mediaA]);
    expect(fixture.closedUrls, [_mediaA]);
    expect(
        fixture.requests.map((uri) => uri.path), ['/entry-a/jms-config.json']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid config offers retry and explicit direct connection',
      (tester) async {
    final fixture = await _fixture()
      ..invalidConfig = true;
    await _pumpLogin(tester, fixture);
    await _submitEntry(tester, _entryA);
    expect(fixture.container.read(authProvider).serverLoginModel, isNull);
    expect(fixture.infoUrls, isEmpty);
    expect(find.byKey(const Key('jms-entry-retry')), findsOneWidget);
    await tester.tap(find.byKey(const Key('jms-entry-retry')));
    await tester.pumpAndSettle();
    expect(fixture.requests, hasLength(2));
    await tester.tap(find.byKey(const Key('jms-entry-direct')));
    await tester.pumpAndSettle();
    expect(fixture.requests.last.path, '/entry-a/System/Info/Public');
    expect(
        fixture.container
            .read(authProvider)
            .serverLoginModel
            ?.tempCredentials
            .url,
        _entryA);
    expect(fixture.auth.entryInput, _entryA);
    expect(fixture.container.read(authProvider).tempSeerrUrl, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('changed services stay pending until the user confirms',
      (tester) async {
    final fixture = await _fixture();
    await JmsEntryCache(fixture.preferences)
        .write(JmsEntryDiscovery.normalizeEntry(_entryA), fixture.configA);
    fixture.configA = _config(_mediaB, _seerrB);
    await _pumpLogin(tester, fixture);
    await _submitEntry(tester, _entryA);
    expect(fixture.auth.pendingEntryChange, isNotNull);
    expect(fixture.infoUrls, isEmpty);
    expect(fixture.container.read(authProvider).serverLoginModel, isNull);
    await tester.tap(find.byKey(const Key('jms-entry-confirm-change')));
    await tester.pumpAndSettle();
    expect(find.text(_mediaB), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(fixture.auth.pendingEntryChange, isNotNull);
    expect(
        (await JmsEntryCache(fixture.preferences)
                .read(JmsEntryDiscovery.normalizeEntry(_entryA)))
            ?.baseUrl,
        _mediaA);
    await tester.tap(find.byKey(const Key('jms-entry-confirm-change')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use these services'));
    await tester.pumpAndSettle();
    expect(fixture.auth.pendingEntryChange, isNull);
    expect(
        fixture.container
            .read(authProvider)
            .serverLoginModel
            ?.tempCredentials
            .url,
        _mediaB);
    expect(fixture.container.read(authProvider).tempSeerrUrl, _seerrB);
    expect(fixture.auth.entryInput, _entryA);
    expect(
        (await JmsEntryCache(fixture.preferences)
                .read(JmsEntryDiscovery.normalizeEntry(_entryA)))
            ?.baseUrl,
        _mediaB);
    expect(tester.takeException(), isNull);
  });

  test('an old confirmation cannot connect after a newer entry is selected',
      () async {
    final fixture = await _fixture();
    await JmsEntryCache(fixture.preferences)
        .write(JmsEntryDiscovery.normalizeEntry(_entryA), fixture.configA);
    fixture.configA = _config(_mediaB, _seerrB);
    await fixture.auth.setServer(_entryA);
    final oldPending = fixture.auth.pendingEntryChange!;
    await fixture.auth.setServer(_entryB);
    final previousCalls = fixture.connectionUrls.length;
    await fixture.auth.confirmEntryChange(expected: oldPending);
    expect(fixture.connectionUrls, hasLength(previousCalls));
    expect(fixture.auth.entryInput, _entryB);
    expect(
        fixture.container
            .read(authProvider)
            .serverLoginModel
            ?.tempCredentials
            .url,
        _mediaB);
  });

  test('confirmed entry initialization uses the immutable snapshot only once',
      () async {
    final fixture = await _fixture();
    final confirmed = await fixture.discovery.discover(_entryA);
    expect(confirmed.config?.baseUrl, _mediaA);
    expect(await fixture.auth.prepareEntryLogin(confirmed), isTrue);
    fixture.configA = _config(_mediaB, _seerrB);
    await fixture.auth.initModel();
    expect(
        fixture.container
            .read(authProvider)
            .serverLoginModel
            ?.tempCredentials
            .url,
        _mediaA);
    expect(fixture.container.read(authProvider).tempSeerrUrl, _seerrA);
    expect(fixture.infoUrls, [_mediaA]);
    expect(fixture.requests, hasLength(1));
    await fixture.auth.initModel();
    expect(fixture.infoUrls, [_mediaA]);
    expect(fixture.requests, hasLength(1));
    expect(fixture.container.read(userProvider), isNull);
  });

  test(
      'a different entry with the same Jellyfin and new Seerr needs confirmation',
      () async {
    final fixture = await _fixture();
    await fixture.auth.setServer(_entryA);
    fixture.configB = _config(_mediaA, _seerrB);
    await fixture.auth.setServer(_entryB);
    final pending = fixture.auth.pendingEntryChange;
    expect(pending, isNotNull);
    expect(fixture.container.read(authProvider).serverLoginModel, isNull);
    expect(fixture.entrySettings.forServer(_mediaA, _idA)?.config.seerrBaseUrl,
        _seerrA);
    expect(
        await JmsEntryCache(fixture.preferences)
            .read(JmsEntryDiscovery.normalizeEntry(_entryB)),
        isNull);
    await fixture.auth.confirmEntryChange(expected: pending);
    expect(fixture.auth.pendingEntryChange, isNull);
    expect(
        fixture.container
            .read(authProvider)
            .serverLoginModel
            ?.tempCredentials
            .url,
        _mediaA);
    expect(fixture.container.read(authProvider).tempSeerrUrl, _seerrB);
    expect(fixture.entrySettings.forServer(_mediaA, _idA)?.config.seerrBaseUrl,
        _seerrB);
    expect(fixture.auth.entryInput, _entryB);
  });

  test('returning to accounts rejects a late public server response', () async {
    final fixture = await _fixture();
    final probing = Completer<void>();
    final response = Completer<Response<PublicSystemInfo>>();
    fixture.publicInfo = (_) {
      probing.complete();
      return response.future;
    };
    final connecting = fixture.auth.setServer(_entryA);
    await probing.future;
    fixture.auth.goUserSelect();
    response.complete(_response(const PublicSystemInfo(
        id: _idA, serverName: 'Synthetic media server')));
    await connecting;
    final model = fixture.container.read(authProvider);
    expect(model.serverLoginModel, isNull);
    expect(model.screen, LoginScreenType.users);
    expect(model.loading, isFalse);
    expect(model.tempSeerrUrl, isNull);
    expect(fixture.auth.pendingEntryChange, isNull);
    expect(fixture.entrySettings.forServer(_mediaA, _idA), isNull);
    expect(fixture.closedUrls, [_mediaA]);
  });

  for (final quickConnect in [false, true]) {
    test(
        'late ${quickConnect ? 'Quick Connect' : 'password'} result cannot bind A token to B',
        () async {
      final fixture = await _fixture();
      await fixture.auth.setServer(_entryA);
      final result = Completer<Response<AuthenticationResult>>();
      fixture.authStarted = Completer<void>();
      fixture.authentication = (_) => result.future;
      final authentication = quickConnect
          ? fixture.auth.authenticateUsingSecret('fixture-quick-connect')
          : fixture.auth.authenticateByName('fixture-user', 'fixture-password');
      await fixture.authStarted!.future;
      await fixture.auth.setServer(_entryB);
      result.complete(_authentication(_idA));
      await authentication;
      expect(fixture.authUrls, [_mediaA]);
      expect(fixture.container.read(userProvider), isNull);
      expect(fixture.accounts.accounts, isEmpty);
      final credentials = fixture.container
          .read(authProvider)
          .serverLoginModel!
          .tempCredentials;
      expect(credentials.url, _mediaB);
      expect(credentials.serverId, _idB);
      expect(credentials.token, isEmpty);
      expect(fixture.container.read(authProvider).tempSeerrUrl, _seerrB);
    });
  }

  for (final timeout in [false, true]) {
    testWidgets(
        'password ${timeout ? 'timeout' : 'network failure'} restores the login button and closes the connection',
        (tester) async {
      final fixture = await _fixture();
      await _pumpLogin(tester, fixture);
      await _submitEntry(tester, _entryA);
      final pending = Completer<Response<AuthenticationResult>>();
      fixture.authentication = (_) => pending.future;
      await tester.enterText(find.byType(TextField).at(1), 'fixture-user');
      await tester.enterText(find.byType(TextField).at(2), 'fixture-password');
      await tester.pump();
      final loginButton = find.byType(FilledButton);
      expect(loginButton, findsOneWidget);
      await tester.tap(loginButton);
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      if (timeout) {
        // Advance the actual AuthNotifier deadline without waiting in real time.
        await tester.pump(const Duration(seconds: 31));
      } else {
        pending.completeError(
            http.ClientException('Synthetic network unavailable'));
      }
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.widget<FilledButton>(loginButton).onPressed, isNotNull);
      expect(fixture.authUrls, [_mediaA]);
      expect(fixture.closedUrls, [_mediaA, _mediaA]);
      expect(fixture.container.read(userProvider), isNull);
      expect(fixture.accounts.accounts, isEmpty);
      expect(
          fixture.container
              .read(authProvider)
              .serverLoginModel
              ?.tempCredentials
              .token,
          isEmpty);
      if (timeout) {
        pending.complete(_authentication(_idA));
        await tester.pump();
        expect(fixture.container.read(userProvider), isNull);
        expect(fixture.accounts.accounts, isEmpty);
      }
      // Let the actual error snackbar expire before disposing this widget tree.
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  test('successful login stores the proved URL and its Seerr source', () async {
    final fixture = await _fixture();
    await fixture.auth.setServer(_entryA);
    final result = await fixture.auth
        .authenticateByName('fixture-user', 'fixture-password');
    expect(result?.body?.credentials.url, _mediaA);
    expect(result?.body?.credentials.serverId, _idA);
    expect(result?.body?.seerrCredentials?.serverUrl, _seerrA);
    expect(fixture.container.read(userProvider)?.credentials.url, _mediaA);
    expect(fixture.accounts.accounts.single.credentials.url, _mediaA);
    expect(fixture.authUrls, [_mediaA]);
    expect(fixture.infoUrls, [_mediaA, _mediaA]);
  });

  test('a server switch during account settings save rejects the stale account',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final settings = _DelayedSettings(prefs);
    final fixture = await _fixture(settings: settings);
    await fixture.auth.setServer(_entryA);
    final authentication =
        fixture.auth.authenticateByName('fixture-user', 'fixture-password');
    await settings.savingAccount.future;
    await fixture.auth.setServer(_entryB);
    settings.releaseSave.complete();
    final result = await authentication;
    expect(result?.body, isNull);
    expect(fixture.container.read(userProvider), isNull);
    expect(fixture.accounts.accounts, isEmpty);
    expect(
        fixture.container
            .read(authProvider)
            .serverLoginModel
            ?.tempCredentials
            .url,
        _mediaB);
  });

  test('authentication from a different server identity is never stored',
      () async {
    final fixture = await _fixture();
    await fixture.auth.setServer(_entryA);
    fixture.authentication = (_) async => _authentication(_idB);
    final result = await fixture.auth
        .authenticateByName('fixture-user', 'fixture-password');
    expect(result?.body, isNull);
    expect(fixture.container.read(userProvider), isNull);
    expect(fixture.accounts.accounts, isEmpty);
    expect(fixture.infoUrls, [_mediaA]);
  });
}
