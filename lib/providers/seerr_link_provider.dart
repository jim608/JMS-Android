import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fladder/models/account_model.dart';
import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/seerr_api_provider.dart';
import 'package:fladder/providers/seerr_service_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/seerr/seerr_connection.dart';
import 'package:fladder/seerr/seerr_session_store.dart';

const jmsSeerrSource = 'https://legacy-seerr.example.invalid';

final seerrJellyfinLinkFactoryProvider = Provider<JellyfinOpenApi Function(AccountModel, {bool anonymous})>((ref) =>
    (account, {anonymous = false}) => createJellyfinApiForAccount(
        ref, account.credentials.url, anonymous ? {} : account.credentials.header(ref),
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
        user.seerrCredentials?.serverUrl == account.seerrCredentials?.serverUrl &&
        user.seerrCredentials?.linkedServerId == account.credentials.serverId;
  }

  Future<void> ensure({String? username, String? password, bool manual = false}) {
    if (_pending != null) return _pending!;
    if (!manual &&
        _checked != null &&
        DateTime.now().difference(_checked!) < const Duration(minutes: 5) &&
        (state != 'connected' || ref.read(userProvider)?.seerrCredentials?.sessionCookie.isNotEmpty == true)) {
      return Future.value();
    }
    final future = _connect(username, password);
    _pending = future;
    return future.whenComplete(() => _pending = null);
  }

  Future<void> _connect(String? username, String? password) async {
    final account = ref.read(userProvider);
    if (account == null ||
        account.seerrCredentials?.serverUrl != jmsSeerrSource ||
        account.seerrCredentials?.linkedServerId != account.credentials.serverId ||
        account.credentials.serverId.isEmpty) {
      state = 'binding_required';
      return;
    }
    state = 'connecting';
    _checked = DateTime.now();
    ref.read(seerrDiagnosticProvider.notifier).state = null;
    try {
      var service = ref.read(seerrApiProvider);
      final store = ref.read(seerrSessionStoreProvider);
      final stored = account.seerrCredentials?.sessionCookie.isNotEmpty == true
          ? account.seerrCredentials!.sessionCookie
          : await store.read(account);
      if (!current(account)) return;
      if (stored?.isNotEmpty == true) {
        try {
          final verifiedCookie = await service.checkLinkedCookie(stored!, account.id);
          if (!current(account)) return;
          await ref.read(userProvider.notifier).setSeerrSessionCookie(verifiedCookie);
          if (current(account)) {
            ref.read(seerrDiagnosticProvider.notifier).state = null;
            state = 'connected';
          }
          return;
        } on SeerrFailure catch (failure) {
          if (failure.code != 'session_expired' && failure.code != 'identity_mismatch') rethrow;
          await store.write(account, null);
          if (!current(account)) return;
          await ref.read(userProvider.notifier).setSeerrSessionCookie('');
          service = ref.read(seerrApiProvider);
        }
      }
      final capabilities = await service.linkCapabilities();
      if (!current(account)) return;
      final advertised = capabilities['jellyfinExternalHost'];
      if (advertised is String && advertised.isNotEmpty) {
        final publicUri = seerrBaseUri(advertised);
        if (publicUri.scheme != 'https') throw const SeerrFailure('binding_unverified');
        final probeAccount =
            account.copyWith(credentials: account.credentials.copyWith(url: publicUri.toString(), token: ''));
        final probe = ref.read(seerrJellyfinLinkFactoryProvider)(probeAccount, anonymous: true);
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
      if (capabilities['quickConnect'] == true) {
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
            final challenge = await service.startQuickLink();
            if (!current(account)) return;
            final authorized =
                await seerrBounded(jellyfin.quickConnectAuthorizePost(code: challenge['code'] as String));
            if (!current(account)) return;
            seerrCheckStatus(authorized.statusCode);
            if (authorized.body != true) throw const SeerrFailure('permission_denied');
            final secret = challenge['secret'] as String;
            bool ready = false;
            for (var attempt = 0; attempt < 3; attempt++) {
              if (!current(account)) return;
              ready = await service.checkQuickLink(secret);
              if (ready) break;
              if (attempt < 2) await Future<void>.delayed(const Duration(seconds: 1));
            }
            if (!ready) throw const SeerrFailure('needs_auth');
            cookie = await service.finishQuickLink(secret, account.id);
          }
        } finally {
          jellyfin.client.dispose();
        }
      }
      if (cookie == null && password != null && username != null) {
        if (!current(account)) return;
        cookie = await service.linkPassword(username, password, account.id);
      }
      if (!current(account)) return;
      if (cookie == null) {
        state = 'needs_auth';
        return;
      }
      await ref.read(userProvider.notifier).setSeerrSessionCookie(cookie);
      if (current(account)) {
        ref.read(seerrDiagnosticProvider.notifier).state = null;
        state = 'connected';
      }
    } on SeerrFailure catch (failure) {
      if (current(account)) state = failure.code;
    } catch (_) {
      if (current(account)) state = 'service_unavailable';
    }
  }
}
