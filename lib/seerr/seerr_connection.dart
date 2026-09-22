import 'dart:async';
import 'package:intl/intl.dart';

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
    throw SeerrFailure(mutation ? 'timeout_check_history' : 'connection_timeout');
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
  final match = RegExp(r'(?:^|,\s*)(connect\.sid=[^;,\s]+)(?=;|,|$)', caseSensitive: false).firstMatch(header);
  if (match == null) return null;
  var attributes = header.substring(match.end);
  final next = RegExp(r',\s*[A-Za-z0-9_-]+=').firstMatch(attributes);
  if (next != null) attributes = attributes.substring(0, next.start);
  for (final attribute in attributes.split(';').skip(1)) {
    final field = attribute.trim().split('=');
    if (field.length < 2) continue;
    final key = field.first.trim().toLowerCase();
    final value = field.skip(1).join('=').trim();
    if (key == 'max-age' && (int.tryParse(value) ?? 0) <= 0) return null;
    if (key == 'domain') {
      final domain = value.replaceFirst(RegExp(r'^\.'), '').toLowerCase();
      if (host.toLowerCase() != domain && !host.toLowerCase().endsWith('.$domain')) return null;
    }
    if (key == 'path' && !(value.startsWith('/') &&
        ['/api/v1/auth/me', '/api/v1/request', '/api/v1/issue']
            .every((route) => route.startsWith(value)))) {
      return null;
    }
    if (key == 'expires') {
      try {
        final expiry = DateFormat('EEE, dd MMM yyyy HH:mm:ss', 'en_US')
            .parseUtc(value.replaceFirst(RegExp(r'\s+GMT$', caseSensitive: false), ''));
        if (!expiry.isAfter(DateTime.now().toUtc())) return null;
      } catch (_) {
        return null;
      }
    }
  }
  if (!secureConnection && RegExp(r'(?:^|;)\s*Secure(?:;|$)', caseSensitive: false).hasMatch(attributes)) return null;
  return match.group(1);
}
