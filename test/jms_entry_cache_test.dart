import 'dart:convert';

import 'package:fladder/services/jms_entry_cache.dart';
import 'package:fladder/util/jms_service_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class _FailingPreferences implements SharedPreferences {
  @override
  String? getString(String key) => throw StateError('fixture read failure');

  @override
  Future<bool> setString(String key, String value) =>
      Future<bool>.error(StateError('fixture write failure'));

  @override
  Future<bool> remove(String key) =>
      Future<bool>.error(StateError('fixture remove failure'));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({
        'fixture-account-sentinel': 'unchanged',
      }));

  test('cache isolates origins and subpaths while matching normalized slash',
      () async {
    final preferences = await SharedPreferences.getInstance();
    final cache = JmsEntryCache(preferences);
    final entry = Uri.parse('https://entry.example.invalid/app');
    final value = JmsServiceConfig(
        baseUrl: 'https://media.example.invalid',
        diagnosticsEndpoint:
            'https://entry.example.invalid/api/jms/diagnostics/v1');
    expect(await cache.write(entry, value), isTrue);
    expect(await cache.read(Uri.parse('https://entry.example.invalid/app/')),
        value);
    expect(await cache.read(Uri.parse('https://other.example.invalid/app')),
        isNull);
    expect(await cache.read(Uri.parse('https://entry.example.invalid/other')),
        isNull);
    expect(preferences.getString('fixture-account-sentinel'), 'unchanged');
    expect(await cache.remove(entry), isTrue);
    expect(await cache.read(entry), isNull);
    expect(preferences.getString('fixture-account-sentinel'), 'unchanged');
  });

  test('invalid cache does not delete preferences or account state', () async {
    final preferences = await SharedPreferences.getInstance();
    final entry = Uri.parse('https://entry.example.invalid/');
    final key = JmsEntryCache.keyFor(entry);
    await preferences.setString(key, '{fixture');
    expect(await JmsEntryCache(preferences).read(entry), isNull);
    expect(preferences.getString(key), '{fixture');
    expect(preferences.getString('fixture-account-sentinel'), 'unchanged');
  });

  test('cache rejects changed entry identity, unknown fields and secrets',
      () async {
    final preferences = await SharedPreferences.getInstance();
    final entry = Uri.parse('https://entry.example.invalid/');
    final key = JmsEntryCache.keyFor(entry);
    for (final record in [
      {
        'version': 1,
        'entry': 'https://other.example.invalid/',
        'config': {'baseUrl': 'https://media.example.invalid'}
      },
      {
        'version': 1,
        'entry': entry.toString(),
        'config': {
          'baseUrl': 'https://media.example.invalid',
          'cookie': 'fixture-cookie'
        }
      },
      {
        'version': 2,
        'entry': entry.toString(),
        'config': {'baseUrl': 'https://media.example.invalid'}
      },
    ]) {
      await preferences.setString(key, jsonEncode(record));
      expect(await JmsEntryCache(preferences).read(entry), isNull);
      expect(preferences.getString(key), isNotNull);
    }
  });

  test('non-string and oversized cached values fail safely', () async {
    final preferences = await SharedPreferences.getInstance();
    final entry = Uri.parse('https://entry.example.invalid/');
    final key = JmsEntryCache.keyFor(entry);
    await preferences.setInt(key, 1);
    expect(await JmsEntryCache(preferences).read(entry), isNull);
    await preferences.setString(key, 'a' * 8193);
    expect(await JmsEntryCache(preferences).read(entry), isNull);
  });

  test('an HTTP direct address cannot be written as an HTTPS entry config',
      () async {
    final preferences = await SharedPreferences.getInstance();
    final entry = Uri.parse('https://entry.example.invalid/');
    final cache = JmsEntryCache(preferences);
    final original = JmsServiceConfig(baseUrl: 'https://media.example.invalid');
    await cache.write(entry, original);
    expect(
        await cache.write(entry,
            JmsServiceConfig.direct(Uri.parse('http://lan.example.invalid'))),
        isFalse);
    expect(await cache.read(entry), original);
  });

  test('sync reads and async preference failures return safe cache results',
      () async {
    final cache = JmsEntryCache(_FailingPreferences());
    final entry = Uri.parse('https://entry.example.invalid/');
    expect(await cache.read(entry), isNull);
    expect(
        await cache.write(
            entry, JmsServiceConfig(baseUrl: 'https://media.example.invalid')),
        isFalse);
    expect(await cache.remove(entry), isFalse);
  });
}
