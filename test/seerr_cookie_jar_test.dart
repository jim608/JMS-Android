import 'package:flutter_test/flutter_test.dart';
import 'package:fladder/seerr/seerr_cookie_jar.dart';

void main() {
  final login = Uri.parse('https://seerr.example.invalid/api/v1/auth/jellyfin');
  final me = Uri.parse('https://seerr.example.invalid/api/v1/auth/me');
  final request = Uri.parse('https://seerr.example.invalid/api/v1/request');

  test('combined Set-Cookie preserves Expires and all usable cookies', () {
    final jar = SeerrCookieJar(login);
    expect(
        jar.ingest(login, [
          'csrf=one; Expires=Wed, 21 Oct 2037 07:28:00 GMT; Path=/; Secure, '
              'jms_session=two; Path=/; Domain=seerr.example.invalid; Secure; HttpOnly'
        ]),
        isTrue);
    expect(jar.headerFor(me), 'csrf=one; jms_session=two');
    expect(jar.headerFor(request), 'csrf=one; jms_session=two');
    expect(SeerrCookieJar.fromJson(login, jar.toJson()).headerFor(me),
        'csrf=one; jms_session=two');
  });

  test('origin, path, secure, expiry and replacement are enforced', () {
    final jar = SeerrCookieJar(login);
    final now = DateTime.utc(2026, 9, 23);
    jar.ingest(
        login,
        [
          'jms_session=one; Path=/api/v1; Max-Age=60; Secure; HttpOnly',
          'auth_only=two; Path=/api/v1/auth; Secure'
        ],
        now: now);
    expect(jar.headerFor(request, now: now), 'jms_session=one');
    expect(jar.headerFor(me, now: now), 'auth_only=two; jms_session=one');
    expect(
        jar.headerFor(Uri.parse('https://other.invalid/api/v1/auth/me'),
            now: now),
        isNull);
    expect(
        jar.headerFor(Uri.parse('http://seerr.example.invalid/api/v1/auth/me'),
            now: now),
        isNull);
    expect(
        jar.headerFor(
            Uri.parse('https://seerr.example.invalid/api/v10/request'),
            now: now),
        isNull);
    expect(jar.headerFor(request, now: now.add(const Duration(seconds: 61))),
        isNull);
    jar.ingest(login, ['jms_session=renewed; Path=/api/v1; Secure'], now: now);
    expect(jar.headerFor(request, now: now), 'jms_session=renewed');
    jar.ingest(login, ['jms_session=gone; Path=/api/v1; Max-Age=0; Secure'],
        now: now);
    expect(jar.headerFor(request, now: now), isNull);
  });

  test(
      'invalid domain, insecure Secure cookie and control characters are ignored',
      () {
    final jar = SeerrCookieJar(login);
    expect(jar.ingest(login, ['jms_session=bad; Domain=other.invalid; Path=/']),
        isFalse);
    expect(
        jar.ingest(
            Uri.parse('http://seerr.example.invalid/api/v1/auth/jellyfin'),
            ['jms_session=bad; Path=/; Secure']),
        isFalse);
    expect(jar.ingest(login, ['jms_session=bad\r\nInjected=yes; Path=/']),
        isFalse);
    expect(jar.headerFor(me), isNull);
  });
}
