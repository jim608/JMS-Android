import 'dart:convert';

import 'package:chopper/chopper.dart';
import 'package:fladder/util/build_info.dart';

class SeerrDiagnostic {
  const SeerrDiagnostic({
    required this.stage,
    required this.method,
    required this.path,
    required this.status,
    required this.contentType,
    required this.redirected,
    required this.jsonResponse,
    required this.hasCookie,
    required this.reason,
    this.jellyfinAuthSuccess,
    this.seerrAuthAttempted,
    this.seerrAuthHttp,
    this.sessionCookieReceived,
    this.sessionCookieStored,
    this.sessionCookieRestored,
    this.sessionCookieAttached,
    this.identityCheckHttp,
    this.identityMatched,
    this.recoveryAttempted,
    this.requestId,
    this.serverCode,
  });

  final String stage;
  final String method;
  final String path;
  final int? status;
  final String contentType;
  final bool redirected;
  final bool jsonResponse;
  final bool hasCookie;
  final String reason;
  final bool? jellyfinAuthSuccess;
  final bool? seerrAuthAttempted;
  final int? seerrAuthHttp;
  final bool? sessionCookieReceived;
  final bool? sessionCookieStored;
  final bool? sessionCookieRestored;
  final bool? sessionCookieAttached;
  final int? identityCheckHttp;
  final bool? identityMatched;
  final bool? recoveryAttempted;
  final String? requestId;
  final String? serverCode;

  SeerrDiagnostic copyWith({
    String? stage,
    String? method,
    String? path,
    int? status,
    String? contentType,
    bool? redirected,
    bool? jsonResponse,
    bool? hasCookie,
    String? reason,
    bool? jellyfinAuthSuccess,
    bool? seerrAuthAttempted,
    int? seerrAuthHttp,
    bool? sessionCookieReceived,
    bool? sessionCookieStored,
    bool? sessionCookieRestored,
    bool? sessionCookieAttached,
    int? identityCheckHttp,
    bool? identityMatched,
    bool? recoveryAttempted,
  }) =>
      SeerrDiagnostic(
        stage: stage ?? this.stage,
        method: method ?? this.method,
        path: path ?? this.path,
        status: status ?? this.status,
        contentType: contentType ?? this.contentType,
        redirected: redirected ?? this.redirected,
        jsonResponse: jsonResponse ?? this.jsonResponse,
        hasCookie: hasCookie ?? this.hasCookie,
        reason: reason ?? this.reason,
        jellyfinAuthSuccess: jellyfinAuthSuccess ?? this.jellyfinAuthSuccess,
        seerrAuthAttempted: seerrAuthAttempted ?? this.seerrAuthAttempted,
        seerrAuthHttp: seerrAuthHttp ?? this.seerrAuthHttp,
        sessionCookieReceived:
            sessionCookieReceived ?? this.sessionCookieReceived,
        sessionCookieStored: sessionCookieStored ?? this.sessionCookieStored,
        sessionCookieRestored:
            sessionCookieRestored ?? this.sessionCookieRestored,
        sessionCookieAttached:
            sessionCookieAttached ?? this.sessionCookieAttached,
        identityCheckHttp: identityCheckHttp ?? this.identityCheckHttp,
        identityMatched: identityMatched ?? this.identityMatched,
        recoveryAttempted: recoveryAttempted ?? this.recoveryAttempted,
        requestId: requestId,
        serverCode: serverCode,
      );

  String get report => [
        'Build: ${JmsBuildInfo.id}',
        'Stage: ${_diagnosticCode(stage)}',
        'Request: ${_diagnosticMethod(method)} ${seerrPathTemplate(path)}',
        'HTTP: ${status ?? 'unavailable'}',
        'Content-Type: ${RegExp(r'^[a-z0-9.+-]+/[a-z0-9.+-]+$').hasMatch(contentType) ? contentType : 'unknown'}',
        'Redirect: $redirected',
        'JSON response: $jsonResponse',
        'Jellyfin auth success: ${jellyfinAuthSuccess ?? 'unknown'}',
        'Seerr auth attempted: ${seerrAuthAttempted ?? 'unknown'}',
        'Seerr auth HTTP: ${seerrAuthHttp ?? 'unavailable'}',
        'Session cookie received: ${sessionCookieReceived ?? 'unknown'}',
        'Session cookie stored: ${sessionCookieStored ?? 'unknown'}',
        'Session cookie restored: ${sessionCookieRestored ?? 'unknown'}',
        'Session cookie attached: ${sessionCookieAttached ?? hasCookie}',
        'Identity check: ${identityCheckHttp ?? 'unavailable'}',
        'Identity matched: ${identityMatched ?? 'unknown'}',
        'Recovery attempted: ${recoveryAttempted ?? 'unknown'}',
        'Classification: ${_diagnosticCode(reason)}',
      ].join('\n');
}

String _diagnosticCode(String value) =>
    RegExp(r'^[a-z][a-z0-9_]{0,40}$').hasMatch(value) ? value : 'unknown';

String _diagnosticMethod(String value) =>
    {'GET', 'POST', 'PUT', 'PATCH', 'DELETE'}.contains(value.toUpperCase())
        ? value.toUpperCase()
        : 'UNKNOWN';

class SeerrAssessment {
  const SeerrAssessment(this.diagnostic, this.failureCode);
  final SeerrDiagnostic diagnostic;
  final String? failureCode;
}

String seerrPathTemplate(String path) {
  const allowed = {
    'api',
    'v1',
    'status',
    'settings',
    'public',
    'auth',
    'me',
    'jellyfin',
    'quickconnect',
    'initiate',
    'check',
    'authenticate',
    'logout',
    'request',
    'issue',
    'comment',
    'open',
    'resolved',
    'user',
    'requests',
    'movie',
    'tv',
    'quota',
    'search',
    'discover',
    'trending',
    'popular',
    'regions',
    'watchproviders',
    'ratings',
    'media',
    'similar',
    'recommendations'
  };
  if (!path.startsWith('/api/v1/')) return '/api/v1/{unknown}';
  return '/${path.split('/').skip(1).map((segment) {
    if (RegExp(r'^\d+$').hasMatch(segment)) return '{id}';
    if (segment == '{id}' || segment == '{value}') return segment;
    return allowed.contains(segment) ? segment : '{value}';
  }).join('/')}';
}

String seerrStage(String path) {
  if (path == '/api/v1/status' || path == '/api/v1/settings/public') {
    return 'status_probe';
  }
  if (path == '/api/v1/auth/me') return 'identity_check';
  if (path.startsWith('/api/v1/auth/')) return 'login';
  if (path.startsWith('/api/v1/request') ||
      path.startsWith('/api/v1/issue') ||
      path.contains('/requests')) {
    return 'records';
  }
  return 'service_request';
}

SeerrAssessment seerrAssessResponse({
  required Response response,
  required String method,
  required String path,
  required bool hasCookie,
  required bool identityVerified,
}) {
  final headers = <String, String>{
    for (final entry in response.base.headers.entries)
      entry.key.toLowerCase(): entry.value
  };
  final contentType =
      headers['content-type']?.split(';').first.trim().toLowerCase() ??
          'unknown';
  final isJsonType =
      contentType == 'application/json' || contentType.endsWith('+json');
  final redirected = response.statusCode >= 300 && response.statusCode < 400 ||
      headers.containsKey('location');
  final challenged = headers['cf-mitigated']?.toLowerCase() == 'challenge';
  final body = response.bodyString;
  Object? parsed;
  final shapeRequired = {
    '/api/v1/status',
    '/api/v1/settings/public',
    '/api/v1/auth/me'
  }.contains(path);
  final shouldDecode = isJsonType &&
      body.length <= 32768 &&
      (shapeRequired || response.statusCode >= 400);
  if (shouldDecode) {
    try {
      parsed = jsonDecode(body);
    } catch (_) {}
  }
  final data = parsed is Map<String, dynamic> ? parsed : <String, dynamic>{};
  final jsonResponse = isJsonType &&
      (parsed is Map<String, dynamic> || !shouldDecode && !shapeRequired);
  final edgeDnsError = data['cloudflare_error'] == true &&
          (data['error_code'] == 1000 || data['error_code'] == '1000') ||
      !isJsonType &&
          body.contains('Error 1000') &&
          body.contains('DNS points to prohibited IP');
  final serverCode = edgeDnsError
      ? 'CF_1000'
      : data['code'] is String &&
              RegExp(r'^[A-Z][A-Z0-9_]{1,32}$').hasMatch(data['code'] as String)
          ? data['code'] as String
          : null;
  final rawId = headers['cf-ray'] ?? headers['x-request-id'] ?? data['ray_id'];
  final candidateId = rawId is String ? rawId : null;
  final requestId = candidateId != null &&
          RegExp(r'^[A-Za-z0-9_-]{6,80}$').hasMatch(candidateId)
      ? candidateId
      : null;
  String? failureCode;
  if (redirected) {
    failureCode = 'redirect_rejected';
  } else if (edgeDnsError) {
    failureCode = 'edge_dns_error';
  } else if (data['cloudflare_error'] == true) {
    failureCode = 'edge_rejected_unknown';
  } else if (challenged) {
    failureCode = 'proxy_challenge';
  } else if (response.statusCode == 400 && path == '/api/v1/auth/jellyfin') {
    failureCode = 'authentication_failed';
  } else if (response.statusCode == 401) {
    failureCode = path == '/api/v1/auth/jellyfin'
        ? 'authentication_failed'
        : hasCookie
            ? 'session_expired'
            : 'session_missing';
  } else if (response.statusCode >= 500) {
    failureCode = 'service_unavailable';
  } else if (!jsonResponse && response.statusCode != 204) {
    failureCode = isJsonType ? 'invalid_response' : 'unexpected_html';
  } else if (response.statusCode == 403) {
    if (path == '/api/v1/auth/me') {
      failureCode = hasCookie ? 'session_expired' : 'session_missing';
    } else if (path == '/api/v1/auth/jellyfin') {
      failureCode = 'authentication_failed';
    } else if (identityVerified) {
      failureCode = 'permission_denied';
    } else {
      failureCode = 'unknown';
    }
  } else if (response.statusCode >= 400) {
    failureCode = 'unknown';
  } else if (response.statusCode >= 200 &&
      response.statusCode < 300 &&
      path == '/api/v1/status' &&
      (data['version'] is! String || (data['version'] as String).isEmpty)) {
    failureCode = 'invalid_response';
  }
  return SeerrAssessment(
      SeerrDiagnostic(
          stage: seerrStage(path),
          method: method,
          path: seerrPathTemplate(path),
          status: response.statusCode,
          contentType:
              RegExp(r'^[a-z0-9.+-]+/[a-z0-9.+-]+$').hasMatch(contentType)
                  ? contentType
                  : 'unknown',
          redirected: redirected,
          jsonResponse: jsonResponse,
          hasCookie: hasCookie,
          reason: failureCode ?? 'response_ok',
          seerrAuthAttempted: path == '/api/v1/auth/jellyfin',
          seerrAuthHttp:
              path == '/api/v1/auth/jellyfin' ? response.statusCode : null,
          sessionCookieAttached: hasCookie,
          identityCheckHttp:
              path == '/api/v1/auth/me' ? response.statusCode : null,
          requestId: requestId,
          serverCode: serverCode),
      failureCode);
}
