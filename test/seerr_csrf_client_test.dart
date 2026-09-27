import 'package:fladder/seerr/seerr_connection.dart';
import 'package:fladder/seerr/seerr_csrf_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const source = 'https://seerr.example.invalid/service';
final login = Uri.parse('$source/api/v1/auth/jellyfin');
const csrfHeaders = {
  'set-cookie': '_csrf=synthetic-secret; Path=/service; Secure; HttpOnly, '
      'XSRF-TOKEN=synthetic%2Btoken; Path=/service; Secure, '
      'session=unverified; Path=/service; Secure'
};

void main() {
  test('prepares CSRF without adopting a preauth session or replaying 403',
      () async {
    final requests = <http.Request>[];
    final client = SeerrCsrfClient(MockClient((request) async {
      requests.add(request);
      if (request.method == 'GET') {
        expect(request.headers['cookie'], isNull);
        expect(request.body, isEmpty);
        return http.Response('{}', 200, headers: csrfHeaders);
      }
      expect(request.headers['x-xsrf-token'], 'synthetic+token');
      expect(request.headers['cookie'], contains('_csrf=synthetic-secret'));
      expect(request.headers['cookie'], isNot(contains('unverified')));
      expect(request.followRedirects, isFalse);
      return http.Response('{"message":"invalid csrf token"}', 403);
    }), source, () => true);
    addTearDown(client.close);
    expect((await client.post(login, body: '{}')).statusCode, 403);
    expect(requests.map((request) => request.method), ['GET', 'POST']);
  });

  test('shares concurrent bootstrap and preserves verified session cookies',
      () async {
    var gets = 0;
    final client = SeerrCsrfClient(MockClient((request) async {
      if (request.method == 'GET') {
        gets++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return http.Response('{}', 200, headers: csrfHeaders);
      }
      expect(request.headers['cookie'], contains('session=verified'));
      expect(request.headers['cookie'], isNot(contains('stale')));
      return http.Response('{}', 200);
    }), source, () => true);
    addTearDown(client.close);
    await Future.wait(List.generate(
        2,
        (_) => client.post(login, headers: {
              'Cookie': 'session=verified; XSRF-TOKEN=stale; _csrf=stale',
              'X-XSRF-TOKEN': 'stale'
            })));
    expect(gets, 1);
  });

  test('account change during bootstrap prevents password transmission',
      () async {
    var active = true;
    var posts = 0;
    final client = SeerrCsrfClient(MockClient((request) async {
      if (request.method == 'POST') posts++;
      active = false;
      return http.Response('{}', 200, headers: csrfHeaders);
    }), source, () => active);
    addTearDown(client.close);
    await expectLater(client.post(login), throwsA(isA<SeerrFailure>()));
    expect(posts, 0);
  });

  test('rejects cross-origin and sibling base paths before transport',
      () async {
    var calls = 0;
    final client = SeerrCsrfClient(MockClient((request) async {
      calls++;
      return http.Response('{}', 200);
    }), source, () => true);
    addTearDown(client.close);
    for (final url in [
      'https://other.example.invalid/service/api/v1/auth/jellyfin',
      'https://seerr.example.invalid/service-other/api/v1/auth/jellyfin'
    ]) {
      await expectLater(
          client.post(Uri.parse(url)), throwsA(isA<SeerrFailure>()));
    }
    expect(calls, 0);
  });

  test('supports servers without CSRF protection', () async {
    final methods = <String>[];
    final client = SeerrCsrfClient(MockClient((request) async {
      methods.add(request.method);
      expect(request.headers['x-xsrf-token'], isNull);
      return http.Response('{}', 200);
    }), source, () => true);
    addTearDown(client.close);
    await client.post(login);
    expect(methods, ['GET', 'POST']);
  });

  for (final headers in [
    {'set-cookie': '_csrf=synthetic; Path=/service; Secure'},
    {
      'set-cookie':
          '_csrf=synthetic; Path=/service; Secure, XSRF-TOKEN=%0A; Path=/service; Secure'
    },
  ]) {
    test('incomplete or unsafe CSRF pair prevents login: ${headers.length}',
        () async {
      var posts = 0;
      final client = SeerrCsrfClient(MockClient((request) async {
        if (request.method == 'POST') posts++;
        return http.Response('{}', 200, headers: headers);
      }), source, () => true);
      addTearDown(client.close);
      await expectLater(client.post(login), throwsA(isA<SeerrFailure>()));
      expect(posts, 0);
    });
  }

  test('redirect bootstrap never sends login', () async {
    var calls = 0;
    final client = SeerrCsrfClient(MockClient((request) async {
      calls++;
      expect(request.followRedirects, isFalse);
      return http.Response('', 302, headers: {'location': '/login'});
    }), source, () => true);
    addTearDown(client.close);
    await expectLater(client.post(login), throwsA(isA<SeerrFailure>()));
    expect(calls, 1);
  });
}
