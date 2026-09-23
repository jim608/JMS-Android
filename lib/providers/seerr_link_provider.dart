import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fladder/models/account_model.dart';
import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/seerr_api_provider.dart';
import 'package:fladder/providers/seerr_service_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/seerr/seerr_connection.dart';
import 'package:fladder/seerr/seerr_diagnostic.dart';
import 'package:fladder/seerr/seerr_session_store.dart';
import 'package:fladder/seerr/seerr_source.dart';

final seerrJellyfinLinkFactoryProvider =
    Provider<JellyfinOpenApi Function(AccountModel, {bool anonymous})>((ref) =>
        (account, {anonymous = false}) => createJellyfinApiForAccount(
            ref,
            account.credentials.url,
            anonymous ? {} : account.credentials.header(ref),
            privateLink: true));

final seerrLinkProvider = StateNotifierProvider<SeerrLink, String>((ref) {
  ref.watch(userProvider.select((account) => (
        account?.credentials.serverId,
        account?.id,
        account?.seerrCredentials?.serverUrl,
        account?.seerrCredentials?.linkedServerId
      )));
  return SeerrLink(ref);
});

class SeerrLink extends StateNotifier<String> {
  SeerrLink(this.ref) : super('needs_auth');
  final Ref ref;
  Future<void>? _pending;
  bool _pendingHasPassword = false;
  DateTime? _checked;
  bool _active = true;

  @override
  void dispose() {
    _active = false;
    super.dispose();
  }

  bool current(AccountModel account) {
    if (!_active) return false;
    final user = ref.read(userProvider);
    return user != null &&
        user.sameIdentity(account) &&
        user.seerrCredentials?.serverUrl ==
            account.seerrCredentials?.serverUrl &&
        user.seerrCredentials?.linkedServerId == account.credentials.serverId;
  }

  Future<void> ensure(
      {String? username,
      String? password,
      bool manual = false,
      bool requireServerProof = false,
      bool? jellyfinAuthSuccess}) {
    if (_pending != null) {
      if (password != null && !_pendingHasPassword) {
        return _pending!.then((_) => ensure(
            username: username,
            password: password,
            manual: manual,
            requireServerProof: requireServerProof,
            jellyfinAuthSuccess: jellyfinAuthSuccess));
      }
      return _pending!;
    }
    if (!manual &&
        _checked != null &&
        DateTime.now().difference(_checked!) < const Duration(minutes: 5) &&
        (password == null ||
            !{'needs_auth', 'session_missing', 'session_expired'}
                .contains(state))) {
      return Future.value();
    }
    _pendingHasPassword = password != null;
    _pending =
        _connect(username, password, requireServerProof, jellyfinAuthSuccess)
            .whenComplete(() {
      _pending = null;
      _pendingHasPassword = false;
    });
    return _pending!;
  }

  Future<void> _connect(String? username, String? password,
      bool requireServerProof, bool? jellyfinAuthSuccess) async {
    final account = ref.read(userProvider);
    if (account == null ||
        account.seerrCredentials?.serverUrl != jmsSeerrSource ||
        account.seerrCredentials?.linkedServerId !=
            account.credentials.serverId ||
        account.credentials.serverId.isEmpty) {
      state = 'binding_required';
      return;
    }
    state = 'connecting';
    _checked = DateTime.now();
    ref.read(seerrDiagnosticProvider.notifier).state = null;
    bool seerrAuthAttempted = false;
    int? seerrAuthHttp;
    bool? cookieReceived;
    bool? cookieStored;
    bool cookieRestored = false;
    bool cookieAttached = false;
    bool recoveryAttempted = false;
    int? identityCheckHttp;
    bool? identityMatched;

    void authResponse(int status, bool? received, bool? stored) {
      seerrAuthHttp = status;
      cookieReceived = received;
      cookieStored = stored;
    }

    void report(String reason) {
      final previous = ref.read(seerrDiagnosticProvider);
      final identityFailure = previous?.stage == 'identity_check';
      final diagnostic = previous ??
          SeerrDiagnostic(
              stage: seerrAuthAttempted ? 'login' : 'identity_check',
              method: seerrAuthAttempted ? 'POST' : 'GET',
              path: seerrAuthAttempted
                  ? '/api/v1/auth/jellyfin'
                  : '/api/v1/auth/me',
              status: seerrAuthHttp,
              contentType:
                  seerrAuthHttp == null ? 'unknown' : 'application/json',
              redirected: false,
              jsonResponse: seerrAuthHttp != null,
              hasCookie: cookieAttached,
              reason: reason);
      ref.read(seerrDiagnosticProvider.notifier).state = diagnostic.copyWith(
          reason: reason,
          jellyfinAuthSuccess: jellyfinAuthSuccess,
          seerrAuthAttempted: seerrAuthAttempted,
          seerrAuthHttp: seerrAuthHttp ??
              (previous?.stage == 'login' ? previous?.status : null),
          sessionCookieReceived: cookieReceived,
          sessionCookieStored: cookieStored,
          sessionCookieRestored: cookieRestored,
          sessionCookieAttached:
              identityFailure ? previous?.hasCookie : cookieAttached,
          identityCheckHttp:
              identityCheckHttp ?? (identityFailure ? previous?.status : null),
          identityMatched:
              identityMatched ?? (reason == 'identity_mismatch' ? false : null),
          recoveryAttempted: recoveryAttempted);
    }

    void connected() {
      ref.read(seerrDiagnosticProvider.notifier).state = SeerrDiagnostic(
          stage: 'identity_check',
          method: 'GET',
          path: '/api/v1/auth/me',
          status: 200,
          contentType: 'application/json',
          redirected: false,
          jsonResponse: true,
          hasCookie: true,
          reason: 'authenticated',
          jellyfinAuthSuccess: jellyfinAuthSuccess,
          seerrAuthAttempted: seerrAuthAttempted,
          seerrAuthHttp: seerrAuthHttp,
          sessionCookieReceived: cookieReceived,
          sessionCookieStored: cookieStored,
          sessionCookieRestored: cookieRestored,
          sessionCookieAttached: true,
          identityCheckHttp: 200,
          identityMatched: true,
          recoveryAttempted: recoveryAttempted);
      state = 'connected';
    }

    try {
      var service = ref.read(seerrApiProvider);
      final store = ref.read(seerrSessionStoreProvider);
      final meUri =
          seerrRequestUri(jmsSeerrSource, Uri.parse('/api/v1/auth/me'));
      final stored = kIsWeb
          ? kBrowserManagedCookie
          : await store.readForRequest(account, meUri);
      if (!current(account)) return;
      if (stored?.isNotEmpty == true) {
        cookieRestored = true;
        cookieAttached = true;
        try {
          final verifiedCookie =
              await service.checkLinkedCookie(stored!, account.id);
          if (!current(account)) return;
          await ref
              .read(userProvider.notifier)
              .setSeerrSessionCookie(verifiedCookie, persist: false);
          if (current(account)) {
            identityCheckHttp = 200;
            identityMatched = true;
            connected();
          }
          return;
        } on SeerrFailure catch (failure) {
          if (!{'session_missing', 'session_expired', 'identity_mismatch'}
              .contains(failure.code)) {
            rethrow;
          }
          recoveryAttempted = true;
          await store.write(account, null);
          if (!current(account)) return;
          await ref
              .read(userProvider.notifier)
              .setSeerrSessionCookie('', persist: false);
          service = ref.read(seerrApiProvider);
        }
      }
      final capabilities = await service.linkCapabilities();
      if (!current(account)) return;
      final advertised = capabilities['jellyfinExternalHost'];
      if (requireServerProof && (advertised is! String || advertised.isEmpty)) {
        throw const SeerrFailure('binding_unverified');
      }
      if (advertised is String && advertised.isNotEmpty) {
        final publicUri = seerrBaseUri(advertised);
        if (publicUri.scheme != 'https') {
          throw const SeerrFailure('binding_unverified');
        }
        final probeAccount = account.copyWith(
            credentials: account.credentials
                .copyWith(url: publicUri.toString(), token: ''));
        final probe = ref.read(seerrJellyfinLinkFactoryProvider)(probeAccount,
            anonymous: true);
        try {
          final identity = await seerrBounded(probe.systemInfoPublicGet());
          if (!current(account)) return;
          seerrCheckStatus(identity.statusCode);
          if (identity.body?.id?.replaceAll('-', '').toLowerCase() !=
              account.credentials.serverId.replaceAll('-', '').toLowerCase()) {
            throw const SeerrFailure('identity_mismatch');
          }
        } finally {
          probe.client.dispose();
        }
      }
      String? cookie;
      if (password != null && username != null) {
        if (!current(account)) return;
        seerrAuthAttempted = true;
        cookie = await service.linkPassword(username, password, account.id,
            onAuthResponse: authResponse);
      } else if (capabilities['quickConnect'] == true) {
        final jellyfin = ref.read(seerrJellyfinLinkFactoryProvider)(account);
        try {
          final server = await seerrBounded(jellyfin.systemInfoPublicGet());
          if (!current(account)) return;
          if (server.body?.id?.replaceAll('-', '').toLowerCase() !=
              account.credentials.serverId.replaceAll('-', '').toLowerCase()) {
            throw const SeerrFailure('identity_mismatch');
          }
          final enabled = await seerrBounded(jellyfin.quickConnectEnabledGet());
          if (!current(account)) return;
          if (enabled.isSuccessful && enabled.body == true) {
            seerrAuthAttempted = true;
            final Map<String, dynamic> challenge;
            try {
              challenge = await service.startQuickLink();
            } on SeerrFailure catch (failure) {
              if (failure.code != 'unsupported_or_missing') {
                rethrow;
              }
              report('session_missing');
              state = 'needs_auth';
              return;
            }
            if (!current(account)) return;
            final authorized = await seerrBounded(jellyfin
                .quickConnectAuthorizePost(code: challenge['code'] as String));
            if (!current(account)) return;
            seerrCheckStatus(authorized.statusCode);
            if (authorized.body != true) {
              throw const SeerrFailure('authentication_failed');
            }
            final secret = challenge['secret'] as String;
            bool ready = false;
            for (var attempt = 0; attempt < 3; attempt++) {
              if (!current(account)) return;
              ready = await service.checkQuickLink(secret);
              if (ready) break;
              if (attempt < 2) {
                await Future<void>.delayed(const Duration(seconds: 1));
              }
            }
            if (!ready) throw const SeerrFailure('needs_auth');
            cookie = await service.finishQuickLink(secret, account.id,
                onAuthResponse: authResponse);
          }
        } finally {
          jellyfin.client.dispose();
        }
      }
      if (!current(account)) return;
      if (cookie == null) {
        report('session_missing');
        state = 'needs_auth';
        return;
      }
      cookieAttached = true;
      await ref
          .read(userProvider.notifier)
          .setSeerrSessionCookie(cookie, persist: false);
      if (current(account)) {
        identityCheckHttp = 200;
        identityMatched = true;
        connected();
      }
    } on SeerrFailure catch (failure) {
      if (current(account)) {
        if (failure.code == 'identity_mismatch') {
          await ref.read(seerrSessionStoreProvider).write(account, null);
          await ref
              .read(userProvider.notifier)
              .setSeerrSessionCookie('', persist: false);
        }
        report(failure.code);
        state = failure.code;
      }
    } catch (_) {
      if (current(account)) {
        report('service_unavailable');
        state = 'service_unavailable';
      }
    }
  }
}
