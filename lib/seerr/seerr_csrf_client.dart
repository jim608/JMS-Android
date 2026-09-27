import 'package:http/http.dart' as http;

import 'package:fladder/seerr/seerr_connection.dart';
import 'package:fladder/seerr/seerr_cookie_jar.dart';

/// Transport-local CSRF state, discarded when the account or source changes.
/// Authentication cookies remain owned by the identity-verified session store.
class SeerrCsrfClient extends http.BaseClient {
  SeerrCsrfClient(this.inner, String source, this.active)
      : base = seerrBaseUri(source),
        cookies = SeerrCookieJar(seerrBaseUri(source));

  final http.Client inner;
  final Uri base;
  final bool Function() active;
  final SeerrCookieJar cookies;
  static const names = {'_csrf', 'XSRF-TOKEN'};
  Future<void>? _pending;
  bool _initialized = false;
  bool _protected = false;
  bool _closed = false;

  void _check(Uri uri) {
    if (_closed || !active()) throw const SeerrFailure('account_changed');
    if (uri.origin != base.origin ||
        !uri.path.startsWith('${base.path}/api/v1/')) {
      throw const SeerrFailure('cross_origin_rejected');
    }
  }

  Map<String, String> _pairs(Uri uri) => {
        for (final part in (cookies.headerFor(uri) ?? '').split('; '))
          if (part.contains('='))
            part.substring(0, part.indexOf('=')):
                part.substring(part.indexOf('=') + 1),
      };

  void _receive(Uri uri, http.StreamedResponse response) {
    if (response.statusCode < 200 || response.statusCode >= 300) return;
    cookies.ingest(uri, seerrSetCookieHeaders(response.headers),
        onlyNames: names);
    _protected = _protected || _pairs(uri).isNotEmpty;
    _initialized = true;
  }

  Future<void> _bootstrap() async {
    final uri = base.replace(path: '${base.path}/api/v1/status');
    _check(uri);
    final request = http.Request('GET', uri)..followRedirects = false;
    final response =
        await inner.send(request).timeout(const Duration(seconds: 10));
    await response.stream.drain<void>().timeout(const Duration(seconds: 5));
    _check(uri);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const SeerrFailure('csrf_unavailable');
    }
    _receive(uri, response);
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    _check(request.url);
    final unsafe = !const {'GET', 'HEAD', 'OPTIONS'}.contains(request.method);
    if (unsafe &&
        (!_initialized || (_protected && _pairs(request.url).length != 2))) {
      final pending = _pending ??= _bootstrap();
      try {
        await pending;
      } finally {
        if (identical(_pending, pending)) _pending = null;
      }
    }
    _check(request.url);
    final pairs = _pairs(request.url);
    request.headers.removeWhere((key, _) =>
        const {'x-xsrf-token', 'x-csrf-token'}.contains(key.toLowerCase()));
    if (unsafe && _protected) {
      if (pairs.length != 2) throw const SeerrFailure('csrf_unavailable');
      String token;
      try {
        token = Uri.decodeComponent(pairs['XSRF-TOKEN']!);
      } on FormatException {
        throw const SeerrFailure('csrf_unavailable');
      }
      if (token.isEmpty || token.contains(RegExp(r'[\r\n]'))) {
        throw const SeerrFailure('csrf_unavailable');
      }
      request.headers['X-XSRF-TOKEN'] = token;
    }
    final authCookies = <String>[];
    request.headers.removeWhere((key, value) {
      if (key.toLowerCase() != 'cookie') return false;
      authCookies.addAll(value.split(';').map((part) => part.trim()).where(
          (part) =>
              part.contains('=') && !names.contains(part.split('=').first)));
      return true;
    });
    authCookies
        .addAll(pairs.entries.map((pair) => '${pair.key}=${pair.value}'));
    if (authCookies.isNotEmpty) {
      request.headers['Cookie'] = authCookies.join('; ');
    }
    request.followRedirects = false;
    final response = await inner.send(request);
    _check(request.url);
    _receive(request.url, response);
    return response;
  }

  @override
  void close() {
    _closed = true;
    inner.close();
  }
}
