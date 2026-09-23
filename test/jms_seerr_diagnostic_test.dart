import 'dart:convert';

import 'package:chopper/chopper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:fladder/seerr/seerr_connection.dart';
import 'package:fladder/seerr/seerr_diagnostic.dart';

SeerrAssessment assess(String path, int status, Object body,
    {String contentType = 'application/json',
    bool cookie = false,
    bool verified = false,
    Map<String, String> headers = const {}}) {
  final response = Response<dynamic>(
      http.Response(body is String ? body : jsonEncode(body), status,
          headers: {'content-type': contentType, ...headers}),
      null);
  return seerrAssessResponse(
      response: response,
      method: 'GET',
      path: path,
      hasCookie: cookie,
      identityVerified: verified);
}

void main() {
  const authError = {
    'status': 403,
    'error': 'You do not have permission to access this endpoint'
  };

  test(
      'auth/me 401 and 403 distinguish missing and expired sessions from permissions',
      () {
    expect(assess('/api/v1/auth/me', 401, {'status': 401}).failureCode,
        'session_missing');
    expect(
        assess('/api/v1/auth/me', 401, {'status': 401}, cookie: true)
            .failureCode,
        'session_expired');
    expect(assess('/api/v1/auth/me', 403, authError).failureCode,
        'session_missing');
    expect(assess('/api/v1/auth/me', 403, authError, cookie: true).failureCode,
        'session_expired');
    expect(assess('/api/v1/status', 403, authError).failureCode, 'unknown');
    expect(assess('/api/v1/issue', 403, authError, cookie: true).failureCode,
        'unknown');
    expect(
        assess('/api/v1/issue', 403, authError, cookie: true, verified: true)
            .failureCode,
        'permission_denied');
  });

  test('Jellyfin auth rejection and unavailable service stay separate', () {
    expect(assess('/api/v1/auth/jellyfin', 401, {'status': 401}).failureCode,
        'authentication_failed');
    expect(assess('/api/v1/auth/jellyfin', 400, {'status': 400}).failureCode,
        'authentication_failed');
    expect(assess('/api/v1/auth/jellyfin', 403, authError).failureCode,
        'authentication_failed');
    expect(assess('/api/v1/status', 503, {'error': 'unavailable'}).failureCode,
        'service_unavailable');
  });

  test('unknown JSON rejection, HTML, challenge and redirect remain distinct',
      () {
    expect(assess('/api/v1/status', 403, {'error': 'blocked'}).failureCode,
        'unknown');
    expect(
        assess('/api/v1/status', 403, '<html>Denied</html>',
                contentType: 'text/html')
            .failureCode,
        'unexpected_html');
    expect(
        assess('/api/v1/status', 200, '<html>Sign in</html>',
                contentType: 'text/html')
            .failureCode,
        'unexpected_html');
    expect(
        assess('/api/v1/status', 403, '<html>Challenge</html>',
            contentType: 'text/html',
            headers: {'cf-mitigated': 'challenge'}).failureCode,
        'proxy_challenge');
    expect(
        assess('/api/v1/status', 302, '',
            headers: {'location': 'https://private.invalid/login'}).failureCode,
        'redirect_rejected');
    expect(assess('/api/v1/status', 200, {'version': '3.4.1'}).failureCode,
        isNull);
    expect(assess('/api/v1/status', 200, {}).failureCode, 'invalid_response');
  });

  test(
      'Cloudflare Error 1000 is an edge DNS failure, not a Seerr permission denial',
      () {
    final json = assess('/api/v1/status', 403, {
      'status': 403,
      'cloudflare_error': true,
      'error_code': 1000,
      'error_name': 'dns_loop',
      'ray_id': 'a3f503042d217d73'
    });
    expect(json.failureCode, 'edge_dns_error');
    expect(json.diagnostic.serverCode, 'CF_1000');
    expect(json.diagnostic.requestId, 'a3f503042d217d73');
    final html = assess('/api/v1/status', 403,
        '<html><title>Error 1000</title>DNS points to prohibited IP</html>',
        contentType: 'text/html');
    expect(html.failureCode, 'edge_dns_error');
    expect(
        assess('/api/v1/discover', 200,
            {'results': List.filled(4000, 'poster')}).failureCode,
        isNull);
  });

  test('diagnostic only exports allowlisted metadata', () {
    final result = assess('/api/v1/issue/91', 403,
        {'error': 'https://private.invalid/?token=SECRET', 'code': 'FORBIDDEN'},
        cookie: true,
        headers: {
          'cf-ray': 'a3f4e47d3f8c0959-HKG',
          'set-cookie': 'connect.sid=SECRET'
        });
    final report = result.diagnostic.report;
    expect(report, contains('GET /api/v1/issue/{id}'));
    expect(report, contains('HTTP: 403'));
    expect(report, contains('Session cookie attached: true'));
    expect(report, contains('Identity check: unavailable'));
    expect(report, isNot(contains('SECRET')));
    expect(report, isNot(contains('private.invalid')));
    expect(report, isNot(contains('a3f4e47d3f8c0959-HKG')));
    expect(seerrPathTemplate('/api/v1/user/private-name/requests'),
        '/api/v1/user/{value}/requests');
  });

  test('diagnostic flow fields retain only safe booleans and status codes', () {
    final original =
        assess('/api/v1/auth/me', 401, {'error': 'expired'}).diagnostic;
    final report = original
        .copyWith(
          jellyfinAuthSuccess: true,
          seerrAuthAttempted: true,
          seerrAuthHttp: 200,
          sessionCookieReceived: true,
          sessionCookieStored: true,
          sessionCookieRestored: false,
          sessionCookieAttached: false,
          identityCheckHttp: 401,
          identityMatched: false,
          recoveryAttempted: true,
        )
        .report;
    expect(report, contains('Seerr auth HTTP: 200'));
    expect(report, contains('Session cookie restored: false'));
    expect(report, contains('Identity matched: false'));
    expect(report, contains('Classification: session_missing'));
    expect(report, isNot(contains('Set-Cookie')));
    expect(report, isNot(contains('Request ID')));
  });

  test('diagnostic sanitizes caller supplied path and labels', () {
    final report = const SeerrDiagnostic(
      stage: 'identity_check\nPassword: SECRET',
      method: 'GET\nAuthorization: SECRET',
      path: '/api/v1/auth/me?token=SECRET',
      status: 401,
      contentType: 'application/json; token=SECRET',
      redirected: false,
      jsonResponse: true,
      hasCookie: false,
      reason: 'session_missing\nSECRET',
    ).report;
    expect(report, contains('Request: UNKNOWN /api/v1/auth/{value}'));
    expect(report, isNot(contains('SECRET')));
  });

  test('session cookie parses multiple Set-Cookie without splitting Expires',
      () {
    final header =
        'csrf=ignored; Expires=Wed, 21 Oct 2037 07:28:00 GMT; Path=/, '
        'connect.sid=TEST_ONLY; Path=/; Domain=seerr.example.invalid; Secure; HttpOnly';
    expect(seerrSessionCookieFromHeader(header, 'seerr.example.invalid'),
        'csrf=ignored; connect.sid=TEST_ONLY');
    expect(
        seerrSessionCookieFromHeader(
            'jms_session=TEST_ONLY; Path=/; Secure; HttpOnly',
            'seerr.example.invalid'),
        'jms_session=TEST_ONLY');
    expect(seerrSessionCookieFromHeader(header, 'legacy-seerr.example.invalid'),
        'csrf=ignored');
    expect(
        seerrSessionCookieFromHeader('connect.sid=TEST_ONLY; Max-Age=0; Path=/',
            'seerr.example.invalid'),
        isNull);
    expect(
        seerrSessionCookieFromHeader(
            'connect.sid=TEST_ONLY; Domain=other.invalid',
            'seerr.example.invalid'),
        isNull);
    expect(
        seerrSessionCookieFromHeader(
            'connect.sid=TEST_ONLY; Path=/other', 'seerr.example.invalid'),
        isNull);
    expect(
        seerrSessionCookieFromHeader('connect.sid=TEST_ONLY; Path=/api/v1/auth',
            'seerr.example.invalid'),
        isNull);
    expect(
        seerrSessionCookieFromHeader(
            'connect.sid=TEST_ONLY; Secure', 'seerr.example.invalid',
            secureConnection: false),
        isNull);
    expect(
        seerrSessionCookieFromHeader(
            'connect.sid=TEST_ONLY; Expires=Wed, 21 Oct 2015 07:28:00 GMT',
            'seerr.example.invalid'),
        isNull);
  });
}
