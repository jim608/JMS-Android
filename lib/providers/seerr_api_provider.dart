import 'dart:convert';

import 'package:chopper/chopper.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show StateProvider;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:fladder/models/account_model.dart';
import 'package:fladder/providers/seerr_service_provider.dart';
import 'package:fladder/providers/seerr_link_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/seerr/seerr_chopper_service.dart';
import 'package:fladder/seerr/seerr_json_converter.dart';
import 'package:fladder/seerr/seerr_connection.dart';
import 'package:fladder/seerr/seerr_source.dart';
import 'package:fladder/seerr/seerr_diagnostic.dart';
import 'package:fladder/seerr/seerr_cookie_jar.dart';
import 'package:fladder/seerr/seerr_session_store.dart';
import 'package:fladder/util/fladder_config.dart';
import 'package:fladder/util/seerr_http_client.dart'
    if (dart.library.html) 'package:fladder/util/seerr_http_client_web.dart';

part 'seerr_api_provider.g.dart';

final seerrDiagnosticProvider = StateProvider<SeerrDiagnostic?>((ref) {
  ref.watch(userProvider.select((account) => (
        account?.credentials.serverId,
        account?.id,
        account?.seerrCredentials?.serverUrl,
      )));
  return null;
});

@riverpod
class SeerrApi extends _$SeerrApi {
  @override
  SeerrService build() {
    final scope = ref.watch(userProvider.select((account) => (
          account?.id,
          account?.credentials.serverId,
          account?.seerrCredentials
        )));
    final credentials = effectiveJmsSeerrCredentials(scope.$3,
        configuredSource: FladderConfig.seerrBaseUrl);
    final server = credentials.serverUrl;
    final account = ref.read(userProvider);
    bool active = true;

    final requestInterceptor = SeerrRequest(
        server,
        _authHeaders(
            apiKey:
                credentials.linkedServerId.isNotEmpty ? '' : credentials.apiKey,
            cookie: credentials.sessionCookie),
        credentials.linkedServerId.isNotEmpty ? {} : credentials.customHeaders,
        () => active,
        account: account,
        sessionStore: ref.read(seerrSessionStoreProvider),
        expectedJellyfinUserId: scope.$1, onDiagnostic: (diagnostic) {
      if (active) {
        ref.read(seerrDiagnosticProvider.notifier).state = diagnostic;
      }
    }, onUnauthorized: () {
      Future.microtask(() async {
        if (active && credentials.isConfigured) {
          try {
            await ref.read(userProvider.notifier).logoutSeerr();
          } catch (_) {
            ref.invalidate(seerrApiProvider);
          }
          if (active) ref.invalidate(seerrLinkProvider);
        }
      });
    });
    final chopperClient = ChopperClient(
      client: createSeerrHttpClient(),
      converter: const SeerrJsonConverter(),
      interceptors: [requestInterceptor],
    );
    ref.onDispose(() {
      active = false;
      requestInterceptor.clearVerifiedIdentity();
      chopperClient.dispose();
    });

    return SeerrService(
      ref,
      SeerrChopperService.create(chopperClient),
    );
  }
}

class SeerrRequest implements Interceptor {
  SeerrRequest(this.server, this.auth, this.custom, this.active,
      {this.onUnauthorized,
      this.onDiagnostic,
      this.expectedJellyfinUserId,
      this.account,
      this.sessionStore});
  final String? server;
  final Map<String, String> auth;
  final Map<String, String> custom;
  final bool Function() active;
  final void Function()? onUnauthorized;
  final void Function(SeerrDiagnostic)? onDiagnostic;
  final String? expectedJellyfinUserId;
  final AccountModel? account;
  final SeerrSessionStore? sessionStore;
  final _verification = _SeerrVerification();

  void clearVerifiedIdentity() => _verification.verified = false;

  @override
  FutureOr<Response<BodyType>> intercept<BodyType>(
      Chain<BodyType> chain) async {
    if (!active()) throw const SeerrFailure('account_changed');
    if (server == null || server!.isEmpty) {
      throw const SeerrFailure('not_configured');
    }
    final uri = seerrRequestUri(server!, chain.request.url);
    String? storedCookie;
    if (!kIsWeb && account != null && sessionStore != null) {
      try {
        storedCookie = await sessionStore!.readForRequest(account!, uri);
      } catch (_) {
        throw const SeerrFailure('authentication_failed');
      }
    }
    if (!active()) throw const SeerrFailure('account_changed');
    if (chain.request.url.path == '/api/v1/auth/jellyfin' ||
        chain.request.url.path ==
            '/api/v1/auth/jellyfin/quickconnect/authenticate' ||
        (!kIsWeb && account != null && storedCookie == null)) {
      clearVerifiedIdentity();
    }
    final usingNativeSession =
        !kIsWeb && account != null && sessionStore != null;
    final requestHeaders = usingNativeSession
        ? {
            for (final entry in chain.request.headers.entries)
              if (entry.key.toLowerCase() != 'cookie' &&
                  entry.key.toLowerCase() != 'authorization' &&
                  entry.key.toLowerCase() != 'x-api-key')
                entry.key: entry.value,
          }
        : chain.request.headers;
    final headers = <String, String>{
      'Accept': 'application/json',
      for (final entry in custom.entries)
        if (!{'authorization', 'cookie', 'x-api-key', 'host', 'origin'}
            .contains(entry.key.toLowerCase()))
          entry.key: entry.value,
      if (!{'/api/v1/status', '/api/v1/settings/public'}
              .contains(chain.request.url.path) &&
          !(chain.request.url.path.startsWith('/api/v1/auth/') &&
              !{'/api/v1/auth/me', '/api/v1/auth/logout'}
                  .contains(chain.request.url.path)) &&
          !requestHeaders.keys.any((key) => key.toLowerCase() == 'cookie'))
        ...(usingNativeSession
            ? (storedCookie == null
                ? const <String, String>{}
                : {'Cookie': storedCookie})
            : auth),
    };
    final request = applyHeaders(
        chain.request
            .copyWith(baseUri: Uri(), uri: uri, headers: requestHeaders),
        headers);
    final bool hasCookie = request.headers.entries.any((entry) =>
        entry.key.toLowerCase() == 'cookie' && entry.value.isNotEmpty);
    Response<BodyType> response;
    try {
      response = await seerrBounded(Future<Response<BodyType>>.sync(() {
        if (!active()) throw const SeerrFailure('account_changed');
        return chain.proceed(request);
      }),
          mutation: chain.request.method.toUpperCase() == 'POST' &&
              (chain.request.url.path.startsWith('/api/v1/request') ||
                  chain.request.url.path.startsWith('/api/v1/issue')));
    } on SeerrFailure catch (failure) {
      if (active()) {
        onDiagnostic?.call(SeerrDiagnostic(
            stage: seerrStage(chain.request.url.path),
            method: chain.request.method,
            path: seerrPathTemplate(chain.request.url.path),
            status: null,
            contentType: 'unknown',
            redirected: false,
            jsonResponse: false,
            hasCookie: hasCookie,
            reason: failure.code));
      }
      rethrow;
    }
    if (!active()) throw const SeerrFailure('account_changed');
    final setCookieHeaders = seerrSetCookieHeaders(response.base.headers);
    bool? cookieStored;
    if (usingNativeSession &&
        response.statusCode >= 200 &&
        response.statusCode < 300 &&
        setCookieHeaders.isNotEmpty) {
      try {
        cookieStored = await sessionStore!
            .writeFromResponse(account!, uri, setCookieHeaders);
      } catch (_) {
        throw const SeerrFailure('authentication_failed');
      }
    }
    final assessment = seerrAssessResponse(
        response: response,
        method: chain.request.method,
        path: chain.request.url.path,
        hasCookie: hasCookie,
        identityVerified: _verification.verified);
    var failureCode = assessment.failureCode;
    if (response.statusCode == 401 ||
        {'session_missing', 'session_expired'}.contains(failureCode) ||
        chain.request.url.path == '/api/v1/auth/logout') {
      clearVerifiedIdentity();
    }
    if (chain.request.url.path == '/api/v1/auth/me') {
      clearVerifiedIdentity();
      if (failureCode == null && expectedJellyfinUserId?.isNotEmpty == true) {
        try {
          final user = jsonDecode(response.bodyString);
          final actualId =
              user is Map<String, dynamic> ? user['jellyfinUserId'] : null;
          if (actualId is String &&
              actualId.replaceAll('-', '').toLowerCase() ==
                  expectedJellyfinUserId!.replaceAll('-', '').toLowerCase()) {
            _verification.verified = true;
          }
        } catch (_) {}
        if (!_verification.verified) failureCode = 'identity_mismatch';
      }
    }
    if (failureCode == 'identity_mismatch') clearVerifiedIdentity();
    if (failureCode != null ||
        {'/api/v1/auth/me', '/api/v1/auth/jellyfin'}
            .contains(chain.request.url.path)) {
      onDiagnostic?.call(assessment.diagnostic.copyWith(
        reason: failureCode,
        seerrAuthAttempted:
            chain.request.url.path == '/api/v1/auth/jellyfin' ? true : null,
        seerrAuthHttp: chain.request.url.path == '/api/v1/auth/jellyfin'
            ? response.statusCode
            : null,
        sessionCookieReceived: setCookieHeaders.isNotEmpty,
        sessionCookieStored: cookieStored,
        sessionCookieRestored: storedCookie != null,
        sessionCookieAttached: hasCookie,
        identityCheckHttp: chain.request.url.path == '/api/v1/auth/me'
            ? response.statusCode
            : null,
        identityMatched: chain.request.url.path == '/api/v1/auth/me'
            ? _verification.verified
            : null,
      ));
    }
    if ({'session_missing', 'session_expired'}.contains(failureCode) &&
        chain.request.url.path != '/api/v1/auth/me') {
      onUnauthorized?.call();
    }
    if (failureCode != null) {
      throw SeerrFailure(failureCode);
    }
    return response;
  }
}

class _SeerrVerification {
  bool verified = false;
}

Map<String, String> _authHeaders(
    {required String apiKey, required String cookie}) {
  if (cookie.isNotEmpty && cookie != kBrowserManagedCookie) {
    return {'Cookie': cookie};
  }
  if (cookie == kBrowserManagedCookie) return const {};
  if (apiKey.isNotEmpty) return {'X-Api-Key': apiKey};
  return const {};
}
