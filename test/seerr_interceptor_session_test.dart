import 'dart:async';
import 'dart:convert';

import 'package:chopper/chopper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fladder/models/account_model.dart';
import 'package:fladder/providers/seerr_api_provider.dart';
import 'package:fladder/seerr/seerr_chopper_service.dart';
import 'package:fladder/seerr/seerr_connection.dart';
import 'package:fladder/seerr/seerr_diagnostic.dart';
import 'package:fladder/seerr/seerr_json_converter.dart';
import 'package:fladder/seerr/seerr_models.dart';
import 'package:fladder/seerr/seerr_session_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/seerr_test_scope.dart';

void main() {
  test('auth Set-Cookie is stored and attached to auth/me, then rotated',
      () async {
    final account = seerrFixtureAccount();
    final store = SeerrFixtureStore();
    final diagnostics = <SeerrDiagnostic>[];
    final calls = <http.Request>[];
    final client = ChopperClient(
      client: MockClient((request) async {
        calls.add(request);
        final user = {
          'id': 1,
          'displayName': 'Test',
          'jellyfinUserId': account.id,
          'permissions': 32,
        };
        if (request.url.path == '/api/v1/auth/jellyfin') {
          expect(request.headers.containsKey('Cookie'), isFalse);
          return http.Response(jsonEncode(user), 200, headers: {
            'content-type': 'application/json',
            'set-cookie':
                'csrf=one; Expires=Wed, 21 Oct 2037 07:28:00 GMT; Path=/; Secure, '
                    'jms_session=first; Path=/; Secure; HttpOnly',
          });
        }
        expect(request.url.path, '/api/v1/auth/me');
        expect(request.headers['Cookie'], 'csrf=one; jms_session=first');
        return http.Response(jsonEncode(user), 200, headers: {
          'content-type': 'application/json',
          'set-cookie': 'jms_session=renewed; Path=/; Secure; HttpOnly',
        });
      }),
      converter: const SeerrJsonConverter(),
      interceptors: [
        SeerrRequest('https://seerr.example.invalid', {}, {}, () => true,
            account: account,
            sessionStore: store,
            expectedJellyfinUserId: account.id,
            onDiagnostic: diagnostics.add),
      ],
    );
    addTearDown(client.dispose);
    final service = SeerrChopperService.create(client);
    await service.authenticateJellyfin(SeerrAuthJellyfinBody(
        username: 'test-user', password: 'PRIVATE_PASSWORD'));
    expect(store.values, isEmpty);
    expect(
        store.readStagedForRequest(
            account, Uri.parse('https://seerr.example.invalid/api/v1/auth/me')),
        'csrf=one; jms_session=first');
    await service.getMe();

    expect(calls, hasLength(2));
    expect(diagnostics.first.sessionCookieReceived, isTrue);
    expect(diagnostics.first.sessionCookieAccepted, isTrue);
    expect(diagnostics.first.sessionCookieStored, isFalse);
    expect(diagnostics.last.sessionCookieAttached, isTrue);
    expect(diagnostics.last.sessionCookieStored, isTrue);
    expect(diagnostics.last.identityCheckHttp, 200);
    expect(diagnostics.last.identityMatched, isTrue);
    expect(
        await store.readForRequest(
            account, Uri.parse('https://seerr.example.invalid/api/v1/request')),
        'csrf=one; jms_session=renewed');
    expect(diagnostics.map((diagnostic) => diagnostic.report).join(),
        isNot(contains('PRIVATE_PASSWORD')));
    expect(diagnostics.map((diagnostic) => diagnostic.report).join(),
        isNot(contains('jms_session')));
    expect(diagnostics.map((diagnostic) => diagnostic.report).join(),
        isNot(contains('renewed')));
  });

  test('403 challenge cookie and anonymous status cookie are never sessions',
      () async {
    final account = seerrFixtureAccount();
    final store = SeerrFixtureStore();
    final diagnostics = <SeerrDiagnostic>[];
    final client = ChopperClient(
      client: MockClient((request) async {
        if (request.url.path == '/api/v1/status') {
          return http.Response(jsonEncode({'version': '3.4.1'}), 200, headers: {
            'content-type': 'application/json',
            'set-cookie': 'anonymous=VALUE; Path=/; Secure'
          });
        }
        return http.Response(jsonEncode({'status': 403}), 403, headers: {
          'content-type': 'application/json',
          'set-cookie': 'challenge=VALUE; Path=/; Secure'
        });
      }),
      converter: const SeerrJsonConverter(),
      interceptors: [
        SeerrRequest('https://seerr.example.invalid', {}, {}, () => true,
            account: account,
            sessionStore: store,
            expectedJellyfinUserId: account.id,
            onDiagnostic: diagnostics.add),
      ],
    );
    addTearDown(client.dispose);
    final service = SeerrChopperService.create(client);
    await service.getStatus();
    await expectLater(service.initiateLink(), throwsA(isA<SeerrFailure>()));
    expect(store.values, isEmpty);
    expect(
        await store.readForRequest(
            account, Uri.parse('https://seerr.example.invalid/api/v1/auth/me')),
        isNull);
    expect(diagnostics.last.sessionCookieReceived, isTrue);
    expect(diagnostics.last.sessionCookieAccepted, isFalse);
    expect(diagnostics.last.sessionCookieStored, isFalse);
  });

  test('401 identity check discards the unverified login cookie', () async {
    final account = seerrFixtureAccount();
    final store = SeerrFixtureStore();
    final client = ChopperClient(
      client: MockClient((request) async => http.Response(
              jsonEncode({
                'status': request.url.path == '/api/v1/auth/me' ? 401 : 200
              }),
              request.url.path == '/api/v1/auth/me' ? 401 : 200,
              headers: {
                'content-type': 'application/json',
                if (request.url.path == '/api/v1/auth/jellyfin')
                  'set-cookie': 'jms_session=UNVERIFIED; Path=/; Secure'
              })),
      converter: const SeerrJsonConverter(),
      interceptors: [
        SeerrRequest('https://seerr.example.invalid', {}, {}, () => true,
            account: account,
            sessionStore: store,
            expectedJellyfinUserId: account.id),
      ],
    );
    addTearDown(client.dispose);
    final service = SeerrChopperService.create(client);
    await service.authenticateJellyfin(SeerrAuthJellyfinBody(
        username: 'test-user', password: 'PRIVATE_PASSWORD'));
    final meUri = Uri.parse('https://seerr.example.invalid/api/v1/auth/me');
    expect(
        store.readStagedForRequest(account, meUri), 'jms_session=UNVERIFIED');
    await expectLater(service.getMe(), throwsA(isA<SeerrFailure>()));
    expect(store.readStagedForRequest(account, meUri), isNull);
    expect(await store.readForRequest(account, meUri), isNull);
    expect(store.values, isEmpty);
  });

  test('unverified login cookie is not sent to ordinary API requests',
      () async {
    final account = seerrFixtureAccount();
    final store = SeerrFixtureStore();
    final client = ChopperClient(
      client: MockClient((request) async {
        if (request.url.path == '/api/v1/auth/jellyfin') {
          return http.Response(jsonEncode({'id': 1}), 200, headers: {
            'content-type': 'application/json',
            'set-cookie': 'jms_session=UNVERIFIED; Path=/; Secure'
          });
        }
        expect(request.url.path, '/api/v1/issue');
        expect(request.headers.containsKey('Cookie'), isFalse);
        return http.Response(jsonEncode({'status': 403}), 403,
            headers: {'content-type': 'application/json'});
      }),
      converter: const SeerrJsonConverter(),
      interceptors: [
        SeerrRequest('https://seerr.example.invalid', {}, {}, () => true,
            account: account,
            sessionStore: store,
            expectedJellyfinUserId: account.id),
      ],
    );
    addTearDown(client.dispose);
    final service = SeerrChopperService.create(client);
    await service.authenticateJellyfin(SeerrAuthJellyfinBody(
        username: 'test-user', password: 'PRIVATE_PASSWORD'));
    await expectLater(service.getIssues(), throwsA(isA<SeerrFailure>()));
    expect(store.values, isEmpty);
  });

  test('auth/me deleting the staged session fails closed despite HTTP 200',
      () async {
    final account = seerrFixtureAccount();
    final store = SeerrFixtureStore();
    final client = ChopperClient(
      client: MockClient((request) async {
        if (request.url.path == '/api/v1/auth/jellyfin') {
          return http.Response(jsonEncode({'id': 1}), 200, headers: {
            'content-type': 'application/json',
            'set-cookie': 'jms_session=UNVERIFIED; Path=/; Secure'
          });
        }
        expect(request.url.path, '/api/v1/auth/me');
        expect(request.headers['Cookie'], 'jms_session=UNVERIFIED');
        return http.Response(
            jsonEncode({'id': 1, 'jellyfinUserId': account.id}), 200,
            headers: {
              'content-type': 'application/json',
              'set-cookie': 'jms_session=; Max-Age=0; Path=/; Secure'
            });
      }),
      converter: const SeerrJsonConverter(),
      interceptors: [
        SeerrRequest('https://seerr.example.invalid', {}, {}, () => true,
            account: account,
            sessionStore: store,
            expectedJellyfinUserId: account.id),
      ],
    );
    addTearDown(client.dispose);
    final service = SeerrChopperService.create(client);
    await service.authenticateJellyfin(SeerrAuthJellyfinBody(
        username: 'test-user', password: 'PRIVATE_PASSWORD'));
    await expectLater(
        service.getMe(),
        throwsA(predicate((error) =>
            error is SeerrFailure && error.code == 'session_expired')));
    final meUri = Uri.parse('https://seerr.example.invalid/api/v1/auth/me');
    expect(store.readStagedForRequest(account, meUri), isNull);
    expect(await store.readForRequest(account, meUri), isNull);
    expect(store.values, isEmpty);
  });

  test('verified identity classifies later 403 and resets on 401', () async {
    final account = seerrFixtureAccount();
    final store = SeerrFixtureStore();
    await store.write(account, 'jms_session=TEST_ONLY');
    var issueStatus = 403;
    final client = ChopperClient(
      client: MockClient((request) async {
        if (request.url.path == '/api/v1/auth/me') {
          return http.Response(
              jsonEncode({'id': 1, 'jellyfinUserId': account.id}), 200,
              headers: {'content-type': 'application/json'});
        }
        return http.Response(jsonEncode({'status': issueStatus}), issueStatus,
            headers: {'content-type': 'application/json'});
      }),
      converter: const SeerrJsonConverter(),
      interceptors: [
        SeerrRequest('https://seerr.example.invalid', {}, {}, () => true,
            account: account,
            sessionStore: store,
            expectedJellyfinUserId: account.id),
      ],
    );
    addTearDown(client.dispose);
    final service = SeerrChopperService.create(client);
    await service.getMe();
    await expectLater(
        service.getIssues(),
        throwsA(predicate((error) =>
            error is SeerrFailure && error.code == 'permission_denied')));
    issueStatus = 401;
    await expectLater(
        service.getIssues(),
        throwsA(predicate((error) =>
            error is SeerrFailure && error.code == 'session_expired')));
    issueStatus = 403;
    await expectLater(
        service.getIssues(),
        throwsA(predicate(
            (error) => error is SeerrFailure && error.code == 'unknown')));
  });

  test('identity mismatch clears verified state and blocks the response',
      () async {
    final account = seerrFixtureAccount();
    final store = SeerrFixtureStore();
    await store.write(account, 'jms_session=TEST_ONLY');
    var meUserId = account.id;
    final client = ChopperClient(
      client: MockClient((request) async => http.Response(
          jsonEncode(request.url.path == '/api/v1/auth/me'
              ? {'id': 1, 'jellyfinUserId': meUserId}
              : {'status': 403}),
          request.url.path == '/api/v1/auth/me' ? 200 : 403,
          headers: {'content-type': 'application/json'})),
      converter: const SeerrJsonConverter(),
      interceptors: [
        SeerrRequest('https://seerr.example.invalid', {}, {}, () => true,
            account: account,
            sessionStore: store,
            expectedJellyfinUserId: account.id),
      ],
    );
    addTearDown(client.dispose);
    final service = SeerrChopperService.create(client);
    await service.getMe();
    meUserId = 'another-user';
    await expectLater(
        service.getMe(),
        throwsA(predicate((error) =>
            error is SeerrFailure && error.code == 'identity_mismatch')));
    await expectLater(
        service.getIssues(),
        throwsA(predicate(
            (error) => error is SeerrFailure && error.code == 'unknown')));
  });

  test('account disposal during secure read never sends an outbound request',
      () async {
    final account = seerrFixtureAccount();
    final store = _BlockingStore();
    var active = true;
    var outbound = 0;
    final client = ChopperClient(
      client: MockClient((request) async {
        outbound++;
        return http.Response('{}', 200,
            headers: {'content-type': 'application/json'});
      }),
      converter: const SeerrJsonConverter(),
      interceptors: [
        SeerrRequest('https://seerr.example.invalid', {}, {}, () => active,
            account: account, sessionStore: store),
      ],
    );
    addTearDown(client.dispose);
    final pending = SeerrChopperService.create(client).getMe();
    await store.started.future;
    active = false;
    store.release.complete(null);
    await expectLater(
        pending,
        throwsA(predicate((error) =>
            error is SeerrFailure && error.code == 'account_changed')));
    expect(outbound, 0);
  });
}

class _BlockingStore extends SeerrSessionStore {
  final started = Completer<void>();
  final release = Completer<String?>();

  @override
  Future<String?> readForRequest(AccountModel account, Uri requestUri) {
    started.complete();
    return release.future;
  }
}
