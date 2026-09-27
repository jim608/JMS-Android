import 'package:fladder/models/seerr_credentials_model.dart';
import 'package:fladder/seerr/seerr_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fladder/providers/seerr_link_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'fixtures/seerr_test_scope.dart';

void main() {
  test('saved bound source connects without a compiled default', () async {
    final fixture = SeerrFixture();
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
