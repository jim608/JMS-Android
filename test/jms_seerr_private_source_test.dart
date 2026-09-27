import 'package:fladder/models/seerr_credentials_model.dart';
import 'package:fladder/seerr/seerr_source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
