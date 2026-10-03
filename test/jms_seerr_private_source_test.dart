import 'package:fladder/models/seerr_credentials_model.dart';
import 'package:fladder/seerr/seerr_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fladder/providers/seerr_link_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'fixtures/seerr_test_scope.dart';
import 'package:fladder/providers/auth_provider.dart';
import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:http/testing.dart';

void main() {
  test('first JMS login links the selected source using transient credentials',
      () async {
    final fixture = SeerrFixture()
      ..advertisedJellyfin = 'https://jellyfin.example.invalid';
    await fixture.initializePreferences();
    final container = ProviderContainer(overrides: [
      ...fixture.overrides(
          account: seerrFixtureAccount().copyWith(
              seerrCredentials: const SeerrCredentialsModel(
                  serverUrl: 'https://selected.example.invalid'))),
      seerrJellyfinLinkFactoryProvider
          .overrideWithValue((account, {anonymous = false}) {
        expect(anonymous, isTrue);
        expect(account.credentials.token, isEmpty);
        return JellyfinOpenApi.create(
            baseUrl: Uri.parse(account.credentials.url),
            httpClient: MockClient(
                (request) async => fixture.json({'Id': 'fixture-server'})));
      }),
    ]);
    addTearDown(container.dispose);
    addTearDown(fixture.dispose);
    final auth = container.read(authProvider.notifier);
    auth.setTempSeerrUrl('https://another.example.invalid');
    await auth.beginSeerrSession(username: 'fixture', password: 'TEST_ONLY');
    expect(container.read(seerrLinkProvider), 'connected');
    expect(
        fixture.calls
            .where((call) => call.url.path == '/api/v1/auth/jellyfin')
            .length,
        1);
    expect(
        fixture.calls
            .every((call) => call.url.host == 'selected.example.invalid'),
        isTrue);
    expect(fixture.calls.any((call) => call.url.path == '/api/v1/auth/me'),
        isTrue);
    await auth.beginSeerrSession();
    expect(fixture.calls.where((call) => call.method == 'POST').length, 1);
  });

  test(
      'login source selection preserves saved source and supports runtime configuration',
      () {
    final fresh = seerrFixtureAccount().copyWith(seerrCredentials: null);
    expect(
        seerrSourceForLogin(fresh,
            configuredSource: 'https://runtime.example.invalid'),
        'https://runtime.example.invalid');
    expect(
        seerrSourceForLogin(fresh,
            loginSource: 'https://selected.example.invalid',
            configuredSource: 'https://runtime.example.invalid'),
        'https://selected.example.invalid');
    final saved = fresh.copyWith(
        seerrCredentials: const SeerrCredentialsModel(
            serverUrl: 'https://saved.example.invalid'));
    expect(
        seerrSourceForLogin(saved,
            loginSource: 'https://selected.example.invalid'),
        'https://saved.example.invalid');
  });

  test('saved bound source connects without a compiled default', () async {
    final fixture = SeerrFixture();
    await fixture.initializePreferences();
    final account = seerrFixtureAccount().copyWith(
        seerrCredentials: const SeerrCredentialsModel(
            serverUrl: 'https://saved.example.invalid',
            linkedServerId: 'fixture-server'));
    final container =
        ProviderContainer(overrides: fixture.overrides(account: account));
    addTearDown(container.dispose);
    addTearDown(fixture.dispose);
    await container
        .read(seerrLinkProvider.notifier)
        .ensure(username: 'fixture', password: 'TEST_ONLY');
    expect(container.read(seerrLinkProvider), 'connected');
    expect(container.read(userProvider)!.seerrCredentials!.serverUrl,
        'https://saved.example.invalid');
    expect(
        fixture.calls.every((call) => call.url.host == 'saved.example.invalid'),
        isTrue);
  });

  test('saved user source and identity remain unchanged', () {
    const saved = SeerrCredentialsModel(
      serverUrl: 'https://saved.example.invalid',
      linkedServerId: 'fixture-server',
      sessionCookie: 'fixture-session',
    );
    expect(identical(effectiveJmsSeerrCredentials(saved), saved), isTrue);
  });

  test(
      'build source follows explicit configuration and never migrates empty origin',
      () {
    expect(jmsSeerrSource, const String.fromEnvironment('JMS_SEERR_SOURCE'));
    expect(legacyJmsSeerrSource,
        const String.fromEnvironment('JMS_LEGACY_SEERR_SOURCE'));
    expect(isLegacyJmsSeerrSource(''), isFalse);
    expect(effectiveJmsSeerrCredentials(null).serverUrl, jmsSeerrSource);
    expect(
      effectiveJmsSeerrCredentials(null,
              configuredSource: 'https://configured.example.invalid')
          .serverUrl,
      'https://configured.example.invalid',
    );
  });
}
