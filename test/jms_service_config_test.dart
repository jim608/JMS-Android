import 'package:fladder/util/jms_service_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uses only the three existing public config fields', () {
    final value = JmsServiceConfig.fromJson({
      'baseUrl': 'https://media.example.invalid/jellyfin/',
      'seerrBaseUrl': 'https://request.example.invalid/seerr/',
      'diagnosticsEndpoint':
          'https://entry.example.invalid/api/jms/diagnostics/v1',
    });
    expect(value.baseUrl, 'https://media.example.invalid/jellyfin');
    expect(value.seerrBaseUrl, 'https://request.example.invalid/seerr');
    expect(value.toJson().keys.toSet(),
        {'baseUrl', 'seerrBaseUrl', 'diagnosticsEndpoint'});
    expect(JmsServiceConfig.fromJson(value.toJson()), value);
  });

  test('optional fields may be absent or null', () {
    final value =
        JmsServiceConfig.fromJson({'baseUrl': 'https://media.example.invalid'});
    expect(value.seerrBaseUrl, isNull);
    expect(value.diagnosticsEndpoint, isNull);
  });

  test('encoded subpaths remain unchanged when appending config filename', () {
    for (final path in ['a%20b', 'a%2Fb', 'sub/app']) {
      final entry = normalizeJmsEntry('entry.example.invalid/$path');
      expect(entry.resolve('jms-config.json').toString(),
          'https://entry.example.invalid/$path/jms-config.json');
    }
  });

  for (final fields in <Map<String, dynamic>>[
    {},
    {'baseUrl': null},
    {'baseUrl': 42},
    {'baseUrl': ''},
    {'baseUrl': 'https://media.example.invalid', 'seerrBaseUrl': true},
    {'baseUrl': 'https://media.example.invalid', 'seerrBaseUrl': ''},
    {'baseUrl': 'https://media.example.invalid', 'diagnosticsEndpoint': []},
    {
      'baseUrl': 'https://media.example.invalid',
      'token': 'fixture-placeholder'
    },
    {'baseUrl': 'https://media.example.invalid', 'unexpected': 'fixture'},
  ]) {
    test('rejects absent, incorrectly typed or extra fields ${fields.keys}',
        () {
      expect(() => JmsServiceConfig.fromJson(fields), throwsFormatException);
    });
  }

  for (final address in [
    'http://media.example.invalid',
    'media.example.invalid',
    Uri(
            scheme: 'https',
            host: 'media.example.invalid',
            userInfo: 'fixture-user:fixture-value')
        .toString(),
    'https://media.example.invalid?fixture=1',
    'https://media.example.invalid#fixture',
    'https://media.example.invalid:0',
    'https://media.example.invalid:65536',
    'https://media.example.invalid/a b',
    'https://media.example.invalid\\fixture',
  ]) {
    test('rejects unsafe service address ${address.indexOf('://')}', () {
      expect(() => JmsServiceConfig(baseUrl: address), throwsFormatException);
      expect(
          () => JmsServiceConfig(
              baseUrl: 'https://media.example.invalid', seerrBaseUrl: address),
          throwsFormatException);
    });
  }

  test('diagnostic endpoint reuses its exact existing purpose restriction', () {
    for (final endpoint in [
      'https://entry.example.invalid/other',
      'https://entry.example.invalid/api/jms/diagnostics/v1?fixture=1',
      'http://entry.example.invalid/api/jms/diagnostics/v1',
      '/api/jms/diagnostics/v1',
    ]) {
      expect(
          () => JmsServiceConfig(
              baseUrl: 'https://media.example.invalid',
              diagnosticsEndpoint: endpoint),
          throwsFormatException);
    }
  });

  test('normalizes scheme, root, slash and subpath consistently', () {
    expect(normalizeJmsEntry(' entry.example.invalid ').toString(),
        'https://entry.example.invalid/');
    expect(normalizeJmsEntry('https://ENTRY.example.invalid/jms///').toString(),
        'https://entry.example.invalid/jms/');
    expect(normalizeJmsEntry('entry.example.invalid/jms').toString(),
        'https://entry.example.invalid/jms/');
    expect(normalizeJmsEntry('http://lan.example.invalid:8096/jellyfin').scheme,
        'http');
  });

  test(
      'direct config retains explicitly entered HTTP without auxiliary sources',
      () {
    final value = JmsServiceConfig.direct(
        Uri.parse('http://lan.example.invalid/jellyfin'));
    expect(value.baseUrl, 'http://lan.example.invalid/jellyfin');
    expect(value.seerrBaseUrl, isNull);
    expect(value.diagnosticsEndpoint, isNull);
  });
}
