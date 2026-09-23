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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      SeerrSessionStore.channel,
      (call) async {
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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SeerrSessionStore.channel, null);
  });

  test('secure bridge roundtrip is scoped to server user and Seerr source',
      () async {
    await store.write(account, 'connect.sid=TEST_ONLY');
    expect(await store.read(account), 'connect.sid=TEST_ONLY');
    expect(await store.read(account.copyWith(id: 'second-user')), isNull);
    expect(
        await store.read(account.copyWith(
            credentials:
                account.credentials.copyWith(serverId: 'second-server'))),
        isNull);
    expect(
        await store.read(account.copyWith(
            seerrCredentials: account.seerrCredentials!
                .copyWith(serverUrl: 'https://other.invalid'))),
        isNull);
    await store.write(account, null);
    expect(stored, isEmpty);
  });

  test('login cookie stays in memory until verified session is committed',
      () async {
    final login =
        Uri.parse('https://seerr.example.invalid/api/v1/auth/jellyfin');
    final me = Uri.parse('https://seerr.example.invalid/api/v1/auth/me');
    expect(
        await store.stageFromResponse(
            account, login, ['jms_session=FIRST; Path=/; Secure; HttpOnly'],
            replaceExisting: true),
        isTrue);
    expect(store.readStagedForRequest(account, me), 'jms_session=FIRST');
    expect(await store.readForRequest(account, me), 'jms_session=FIRST');
    expect(
        await store.readForRequest(
            account, Uri.parse('https://seerr.example.invalid/api/v1/request')),
        isNull);
    expect(stored, isEmpty);
    expect(await SeerrSessionStore().readForRequest(account, me), isNull);

    expect(await store.commitStaged(account, me), isTrue);
    expect(await SeerrSessionStore().readForRequest(account, me),
        'jms_session=FIRST');
  });

  test('discarded login cookie never survives restart or crosses accounts',
      () async {
    final login =
        Uri.parse('https://seerr.example.invalid/api/v1/auth/jellyfin');
    final me = Uri.parse('https://seerr.example.invalid/api/v1/auth/me');
    await store.stageFromResponse(
        account, login, ['jms_session=UNVERIFIED; Path=/; Secure'],
        replaceExisting: true);
    expect(
        store.readStagedForRequest(account.copyWith(id: 'other'), me), isNull);
    expect(
        store.readStagedForRequest(
            account.copyWith(
                seerrCredentials: account.seerrCredentials!
                    .copyWith(serverUrl: 'https://another.invalid')),
            me),
        isNull);
    store.discardStaged(account, me);
    expect(await store.readForRequest(account, me), isNull);
    expect(await SeerrSessionStore().readForRequest(account, me), isNull);
    expect(stored, isEmpty);
  });

  test('expired staged cookie cannot expose a previously stored session',
      () async {
    final login =
        Uri.parse('https://seerr.example.invalid/api/v1/auth/jellyfin');
    final me = Uri.parse('https://seerr.example.invalid/api/v1/auth/me');
    await store.write(account, 'jms_session=PREVIOUS');
    await store.stageFromResponse(
        account, login, ['jms_session=NEW; Path=/; Secure'],
        replaceExisting: true);
    await store.stageFromResponse(
        account, me, ['jms_session=; Max-Age=0; Path=/; Secure']);
    expect(await store.readForRequest(account, me), isNull);
    expect(
        await store.readForRequest(
            account, Uri.parse('https://seerr.example.invalid/api/v1/request')),
        isNull);
    expect(await store.commitStaged(account, me), isFalse);
    expect(await SeerrSessionStore().readForRequest(account, me), isNull);
  });

  test('expired secure record is removed before use', () async {
    stored[SeerrSessionStore.key(account)] =
        jsonEncode({'expires': 0, 'cookie': 'connect.sid=EXPIRED'});
    expect(await store.read(account), isNull);
    expect(stored, isEmpty);
  });

  test('secure storage failure does not fall back to plaintext', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            SeerrSessionStore.channel,
            (call) async =>
                throw PlatformException(code: 'secure_storage_unavailable'));
    await expectLater(store.write(account, 'connect.sid=TEST_ONLY'),
        throwsA(isA<PlatformException>()));
    expect(stored, isEmpty);
  });

  test(
      'Set-Cookie metadata survives restart and is isolated by account and origin',
      () async {
    final login =
        Uri.parse('https://seerr.example.invalid/api/v1/auth/jellyfin');
    final me = Uri.parse('https://seerr.example.invalid/api/v1/auth/me');
    final request = Uri.parse('https://seerr.example.invalid/api/v1/request');
    expect(
        await store.writeFromResponse(account, login,
            ['jms_session=TEST_ONLY; Path=/; Secure; HttpOnly; SameSite=Lax']),
        isTrue);
    final restarted = SeerrSessionStore();
    expect(
        await restarted.readForRequest(account, me), 'jms_session=TEST_ONLY');
    expect(await restarted.readForRequest(account, request),
        'jms_session=TEST_ONLY');
    expect(await restarted.readForRequest(account.copyWith(id: 'other'), me),
        isNull);
    expect(
        await restarted.readForRequest(
            account.copyWith(
                credentials: account.credentials.copyWith(serverId: 'other')),
            me),
        isNull);
    expect(
        await restarted.readForRequest(
            account.copyWith(
                seerrCredentials: account.seerrCredentials!
                    .copyWith(serverUrl: 'https://other.invalid')),
            me),
        isNull);
    await restarted.write(account, null);
    expect(await restarted.readForRequest(account, me), isNull);
  });

  test('account JSON omits session values from preferences and backup payloads',
      () {
    final withCookie = account.copyWith(
        seerrCredentials: account.seerrCredentials!
            .copyWith(sessionCookie: 'PRIVATE_SESSION_VALUE'));
    expect(jsonEncode(withCookie.toJson()),
        isNot(contains('PRIVATE_SESSION_VALUE')));
  });

  test('clearing an old source leaves another source and user intact',
      () async {
    final oldLogin =
        Uri.parse('https://seerr.example.invalid/api/v1/auth/jellyfin');
    final oldMe = Uri.parse('https://seerr.example.invalid/api/v1/auth/me');
    final newAccount = account.copyWith(
        seerrCredentials: account.seerrCredentials!
            .copyWith(serverUrl: 'https://another.invalid'));
    final newLogin = Uri.parse('https://another.invalid/api/v1/auth/jellyfin');
    final newMe = Uri.parse('https://another.invalid/api/v1/auth/me');
    final otherUser = account.copyWith(id: 'another-user');
    await store
        .writeFromResponse(account, oldLogin, ['session=OLD; Path=/; Secure']);
    await store.writeFromResponse(
        newAccount, newLogin, ['session=NEW; Path=/; Secure']);
    await store.writeFromResponse(
        otherUser, oldLogin, ['session=OTHER; Path=/; Secure']);

    await store.write(account, null);

    expect(await store.readForRequest(account, oldMe), isNull);
    expect(await store.readForRequest(newAccount, newMe), 'session=NEW');
    expect(await store.readForRequest(otherUser, oldMe), 'session=OTHER');
  });
}
