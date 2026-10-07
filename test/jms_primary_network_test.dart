import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fladder/background/update_notifications_worker.dart';
import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/credentials_model.dart';
import 'package:fladder/models/login_screen_model.dart';
import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/auth_provider.dart';
import 'package:fladder/providers/connectivity_provider.dart';
import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/providers/user_provider.dart';

const _primary = 'https://media.example.invalid/jellyfin';
const _legacy = 'http://192.0.2.10:8096/jellyfin';

AccountModel _account({String primary = _primary, bool notifications = false}) => AccountModel(
      name: 'Synthetic user',
      id: 'synthetic-user',
      avatar: '',
      lastUsed: DateTime(2026),
      credentials: CredentialsModel.internal(
        url: primary,
        localUrl: _legacy,
        serverId: 'synthetic-server',
      ),
      updateNotificationsEnabled: notifications,
    );

class _TestUser extends User {
  _TestUser(this.initial);
  final AccountModel? initial;

  @override
  AccountModel? build() => initial;

  void changeAccount(AccountModel account) => state = account;
}

class _TestAuth extends AuthNotifier {
  _TestAuth(super.ref, String? primary) {
    if (primary != null) {
      state = LoginScreenModel(
        serverLoginModel: ServerLoginModel(
          tempCredentials: CredentialsModel.internal(url: primary),
        ),
      );
    }
  }
}

ProviderContainer _container(AccountModel? account, {String? loginUrl}) {
  final container = ProviderContainer(overrides: [
    userProvider.overrideWith(() => _TestUser(account)),
    authProvider.overrideWith((ref) => _TestAuth(ref, loginUrl)),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const connectivity = MethodChannel('dev.fluttercommunity.plus/connectivity');
  const connectivityEvents = MethodChannel('dev.fluttercommunity.plus/connectivity_status');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<String> hardware;

  setUp(() {
    hardware = ['wifi'];
    messenger.setMockMethodCallHandler(connectivity, (_) async => hardware);
    messenger.setMockMethodCallHandler(connectivityEvents, (_) async => null);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(connectivity, null);
    messenger.setMockMethodCallHandler(connectivityEvents, null);
  });

  test('stored legacy local URL stays readable but API uses the primary URL', () {
    final saved = AccountModel.fromJson(
      jsonDecode(jsonEncode(_account())) as Map<String, dynamic>,
    );
    expect(saved.credentials.localUrl, _legacy);
    expect(saved.credentials.serverId, 'synthetic-server');

    final container = _container(saved);
    expect(container.read(serverUrlProvider), _primary);
  });

  test('API never falls back to a legacy local URL when primary is empty', () {
    final container = _container(_account(primary: ''));
    expect(container.read(serverUrlProvider), '');
  });

  test('login primary URL remains available without a saved primary URL', () {
    final container = _container(_account(primary: ''), loginUrl: _primary);
    expect(container.read(serverUrlProvider), _primary);
  });

  test('a manually entered LAN primary URL remains supported', () {
    final container = _container(_account(primary: _legacy));
    expect(container.read(serverUrlProvider), _legacy);
  });

  test('changing primary URL updates API routing without using legacy URL', () {
    final container = _container(_account());
    expect(container.read(serverUrlProvider), _primary);
    const replacement = 'https://second.example.invalid/jellyfin';
    (container.read(userProvider.notifier) as _TestUser).changeAccount(_account(primary: replacement));
    expect(container.read(serverUrlProvider), replacement);
  });

  test('connectivity probes only primary and retains Wi-Fi classification', () async {
    final requests = <Uri>[];
    await http.runWithClient(() async {
      final container = _container(_account());
      final notifier = container.read(connectivityStatusProvider.notifier);
      await notifier.checkConnectivity(immediate: true);
      await notifier.waitForProbe();

      expect(requests, isNotEmpty);
      expect(requests.every((uri) => uri.host == 'media.example.invalid'), isTrue);
      expect(requests.every((uri) => uri.path == '/jellyfin/System/Info/Public'), isTrue);
      expect(container.read(connectivityStatusProvider), ConnectionState.wifi);
      expect(container.read(connectivityStatusProvider).homeInternet, isTrue);
    },
        () => MockClient((request) async {
              requests.add(request.url);
              return http.Response('{"Id":"synthetic-server"}', 200);
            }));
  });

  test('failed primary is offline even when the legacy server would respond', () async {
    final requests = <Uri>[];
    await http.runWithClient(() async {
      final container = _container(_account());
      final notifier = container.read(connectivityStatusProvider.notifier);
      await notifier.checkConnectivity(immediate: true);
      await notifier.waitForProbe();

      expect(requests, isNotEmpty);
      expect(requests.every((uri) => uri.host == 'media.example.invalid'), isTrue);
      expect(container.read(connectivityStatusProvider), ConnectionState.offline);
    },
        () => MockClient((request) async {
              requests.add(request.url);
              return request.url.host == 'media.example.invalid'
                  ? http.Response('', 503)
                  : http.Response('{"Id":"synthetic-server"}', 200);
            }));
  });

  test('primary changes trigger a new probe and retain mobile classification', () async {
    final requests = <Uri>[];
    await http.runWithClient(() async {
      final container = _container(_account());
      final notifier = container.read(connectivityStatusProvider.notifier);
      await notifier.checkConnectivity(immediate: true);
      await notifier.waitForProbe();

      hardware = ['mobile'];
      (container.read(userProvider.notifier) as _TestUser).changeAccount(
        _account(primary: 'https://second.example.invalid/jellyfin'),
      );
      await Future<void>.delayed(Duration.zero);
      await notifier.waitForProbe();

      expect(requests.last.host, 'second.example.invalid');
      expect(container.read(connectivityStatusProvider), ConnectionState.mobile);
      expect(container.read(connectivityStatusProvider).homeInternet, isFalse);
    },
        () => MockClient((request) async {
              requests.add(request.url);
              return http.Response('{"Id":"synthetic-server"}', 200);
            }));
  });

  test('background notifications skip a saved legacy-only Jellyfin account', () async {
    final preferences = await SharedPreferences.getInstance();
    final shared = SharedHelper(sharedPreferences: preferences);
    await shared.saveAccounts([_account(primary: '', notifications: true)]);
    final requests = <Uri>[];

    final result = await http.runWithClient(
      () => performHeadlessUpdateCheck(),
      () => MockClient((request) async {
        requests.add(request.url);
        return http.Response('{"Items":[],"TotalRecordCount":0}', 200);
      }),
    );

    expect(result, isNotNull);
    expect(requests, isEmpty);
    expect(shared.getAccounts().single.credentials.localUrl, _legacy);
  });

  test('background notifications use the saved primary Jellyfin URL', () async {
    final preferences = await SharedPreferences.getInstance();
    final shared = SharedHelper(sharedPreferences: preferences);
    await shared.saveAccounts([_account(notifications: true)]);
    final requests = <Uri>[];

    final result = await http.runWithClient(
      () => performHeadlessUpdateCheck(),
      () => MockClient((request) async {
        requests.add(request.url);
        return http.Response('{"Items":[],"TotalRecordCount":0}', 200);
      }),
    );

    expect(result, isNotNull);
    expect(requests, isNotEmpty);
    expect(requests.every((uri) => uri.host == 'media.example.invalid'), isTrue);
  });
}
