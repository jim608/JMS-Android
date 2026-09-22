import 'dart:convert';

import 'package:chopper/chopper.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show StateProvider;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:fladder/providers/seerr_service_provider.dart';
import 'package:fladder/providers/seerr_link_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/seerr/seerr_chopper_service.dart';
import 'package:fladder/seerr/seerr_json_converter.dart';
import 'package:fladder/seerr/seerr_connection.dart';
import 'package:fladder/seerr/seerr_diagnostic.dart';
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
    final credentials = scope.$3;
    final server = credentials?.serverUrl.isNotEmpty == true
        ? credentials!.serverUrl
        : FladderConfig.seerrBaseUrl;
    bool active = true;

    final chopperClient = ChopperClient(
      client: createSeerrHttpClient(),
      converter: const SeerrJsonConverter(),
      interceptors: [
        SeerrRequest(
            server,
            _authHeaders(
            apiKey: credentials?.linkedServerId.isNotEmpty == true ? '' : credentials?.apiKey ?? '',
                cookie: credentials?.sessionCookie ?? ''),
            credentials?.linkedServerId.isNotEmpty == true ? {} : credentials?.customHeaders ?? {},
            () => active, expectedJellyfinUserId: scope.$1, onDiagnostic: (diagnostic) {
          if (active) ref.read(seerrDiagnosticProvider.notifier).state = diagnostic;
        }, onUnauthorized: () {
          Future.microtask(() async {
            if (active && credentials?.isConfigured == true) {
              try {
                await ref.read(userProvider.notifier).logoutSeerr();
              } catch (_) {
                ref.invalidate(seerrApiProvider);
              }
              if (active) ref.invalidate(seerrLinkProvider);
            }
          });
        }),
      ],
    );
    ref.onDispose(() {
      active = false;
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
      {this.onUnauthorized, this.onDiagnostic, this.expectedJellyfinUserId});
  final String? server;
  final Map<String, String> auth;
  final Map<String, String> custom;
  final bool Function() active;
  final void Function()? onUnauthorized;
  final void Function(SeerrDiagnostic)? onDiagnostic;
  final String? expectedJellyfinUserId;
  final _verification = _SeerrVerification();

  @override
  FutureOr<Response<BodyType>> intercept<BodyType>(
      Chain<BodyType> chain) async {
    if (!active()) throw const SeerrFailure('account_changed');
    if (server == null || server!.isEmpty) {
      throw const SeerrFailure('not_configured');
    }
    final uri = seerrRequestUri(server!, chain.request.url);
    final headers = <String, String>{
      'Accept': 'application/json',
      for (final entry in custom.entries)
        if (!{'authorization', 'cookie', 'x-api-key', 'host', 'origin'}
            .contains(entry.key.toLowerCase()))
          entry.key: entry.value,
      if (!{'/api/v1/status', '/api/v1/settings/public'}.contains(chain.request.url.path) &&
          !(chain.request.url.path.startsWith('/api/v1/auth/') &&
          !{'/api/v1/auth/me', '/api/v1/auth/logout'}.contains(chain.request.url.path)) &&
          !chain.request.headers.keys.any((key) => key.toLowerCase() == 'cookie'))
        ...auth,
    };
    final request =
        applyHeaders(chain.request.copyWith(baseUri: Uri(), uri: uri), headers);
    final bool hasCookie = request.headers.entries.any(
        (entry) => entry.key.toLowerCase() == 'cookie' && entry.value.isNotEmpty);
    Response<BodyType> response;
    try {
      response = await seerrBounded(
          Future<Response<BodyType>>.sync(() => chain.proceed(request)),
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
    final assessment = seerrAssessResponse(
        response: response,
        method: chain.request.method,
        path: chain.request.url.path,
        hasCookie: hasCookie,
        identityVerified: _verification.verifiedAt != null &&
            DateTime.now().difference(_verification.verifiedAt!) < const Duration(seconds: 15));
    if (chain.request.url.path == '/api/v1/auth/me') {
      _verification.verifiedAt = null;
      if (assessment.failureCode == null && expectedJellyfinUserId?.isNotEmpty == true) {
        try {
          final user = jsonDecode(response.bodyString);
          final actualId = user is Map<String, dynamic> ? user['jellyfinUserId'] : null;
          if (actualId is String &&
              actualId.replaceAll('-', '').toLowerCase() ==
                  expectedJellyfinUserId!.replaceAll('-', '').toLowerCase()) {
            _verification.verifiedAt = DateTime.now();
          }
        } catch (_) {}
      }
    }
    if (assessment.failureCode != null) {
      onDiagnostic?.call(assessment.diagnostic);
    }
    final explicitCookie = chain.request.headers.keys.any((key) => key.toLowerCase() == 'cookie');
    if (assessment.failureCode == 'session_expired' &&
        !(chain.request.url.path == '/api/v1/auth/me' && explicitCookie)) {
      onUnauthorized?.call();
    }
    if (assessment.failureCode != null) throw SeerrFailure(assessment.failureCode!);
    return response;
  }
}

class _SeerrVerification {
  DateTime? verifiedAt;
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
