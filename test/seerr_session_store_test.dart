import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fladder/seerr/seerr_session_store.dart';
import 'fixtures/seerr_test_scope.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final stored = <String, String>{};
  final account = seerrFixtureAccount();
  final store = SeerrSessionStore();
  setUp(() {
    stored.clear();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SeerrSessionStore.channel, (call) async {
        final key = call.arguments['key'] as String;
        expect(key, matches(RegExp(r'^[a-f0-9]{64}$')));
        if (call.method == 'read') return stored[key];
        final value = call.arguments['value'] as String?;
        if (value == null) {
          stored.remove(key);
        } else {
          stored[key] = value;
        }
        return null;
      },
    );
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SeerrSessionStore.channel, null);
  });

  test('secure bridge roundtrip is scoped to server user and Seerr source', () async {
    await store.write(account, 'connect.sid=TEST_ONLY');
    expect(await store.read(account), 'connect.sid=TEST_ONLY');
    expect(await store.read(account.copyWith(id: 'second-user')), isNull);
    expect(await store.read(account.copyWith(credentials: account.credentials.copyWith(serverId: 'second-server'))), isNull);
    expect(await store.read(account.copyWith(seerrCredentials: account.seerrCredentials!.copyWith(serverUrl: 'https://other.invalid'))), isNull);
    await store.write(account, null);
    expect(stored, isEmpty);
  });

  test('expired secure record is removed before use', () async {
    stored[SeerrSessionStore.key(account)] = jsonEncode({'expires': 0, 'cookie': 'connect.sid=EXPIRED'});
    expect(await store.read(account), isNull);
    expect(stored, isEmpty);
  });

  test('secure storage failure does not fall back to plaintext', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SeerrSessionStore.channel, (call) async => throw PlatformException(code: 'secure_storage_unavailable'));
    await expectLater(store.write(account, 'connect.sid=TEST_ONLY'), throwsA(isA<PlatformException>()));
    expect(stored, isEmpty);
  });
}
