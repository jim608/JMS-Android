import 'dart:async';
import 'package:fladder/seerr/seerr_cookie_jar.dart';

class SeerrFailure implements Exception {
  final String code;
  const SeerrFailure(this.code);
  @override
  String toString() => 'Seerr: $code';
}

Uri seerrBaseUri(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      !['https', 'http'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      uri.pathSegments.any((segment) => segment == '..' || segment == '.')) {
    throw const SeerrFailure('invalid_address');
  }
  return uri.replace(path: uri.path.replaceAll(RegExp(r'/+$'), ''));
}

Uri seerrRequestUri(String server, Uri route) {
  final base = seerrBaseUri(server);
  if (route.hasAuthority ||
      route.hasScheme ||
      !route.path.startsWith('/api/v1/')) {
    throw const SeerrFailure('cross_origin_rejected');
  }
  return base.replace(
      path: '${base.path}${route.path}',
      query: route.hasQuery ? route.query : null);
}

void seerrCheckStatus(int status) {
  if (status >= 200 && status < 300) return;
  throw SeerrFailure(switch (status) {
    401 => 'session_expired',
    403 => 'request_rejected_unknown',
    404 || 405 => 'unsupported_or_missing',
    409 => 'already_exists',
    429 => 'quota_or_rate_limit',
    400 => 'invalid_or_quota',
    >= 300 && < 400 => 'redirect_rejected',
    _ => 'server_error',
  });
}

Future<T> seerrBounded<T>(Future<T> operation, {bool mutation = false}) async {
  try {
    return await operation.timeout(const Duration(seconds: 20));
  } on SeerrFailure {
    rethrow;
  } on TimeoutException {
    throw SeerrFailure(
        mutation ? 'timeout_check_history' : 'connection_timeout');
  } catch (error) {
    final type = error.runtimeType.toString();
    if (type.contains('HandshakeException') || type.contains('TlsException')) {
      throw const SeerrFailure('tls_error');
    }
    if (type.contains('SocketException') &&
        error.toString().contains('Failed host lookup')) {
      throw const SeerrFailure('dns_error');
    }
    throw const SeerrFailure('network_error');
  }
}

bool seerrSafeMessage(String value) =>
    value.trim().isNotEmpty &&
    value.length <= 2000 &&
    !RegExp(r'https?://|www\.|authorization|bearer\s|cookie\s*[:=]|token\s*[:=]|api[_-]?key\s*[:=]|password\s*[:=]|[A-Za-z]:[\\/]|/(?:storage|data|home|Users|mnt)/',
            caseSensitive: false)
        .hasMatch(value);

String seerrTrackAttribute(String? value) =>
    value != null && RegExp(r'^[A-Za-z0-9_-]{1,20}$').hasMatch(value)
        ? value
        : 'unavailable';

String? seerrSessionCookieFromHeader(String header, String host,
    {bool secureConnection = true}) {
  final uri = Uri(
      scheme: secureConnection ? 'https' : 'http',
      host: host,
      path: '/api/v1/auth/jellyfin');
  final jar = SeerrCookieJar(uri);
  jar.ingest(uri, [header]);
  final auth = jar.headerFor(uri.replace(path: '/api/v1/auth/me'));
  final request = jar.headerFor(uri.replace(path: '/api/v1/request'));
  final issue = jar.headerFor(uri.replace(path: '/api/v1/issue'));
  return auth != null && auth == request && auth == issue ? auth : null;
}
