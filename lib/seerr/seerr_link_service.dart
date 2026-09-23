part of '../providers/seerr_service_provider.dart';

extension SeerrLinkService on SeerrService {
  Future<Map<String, dynamic>> linkCapabilities() async {
    final version = _body(await _api.getStatus()).version;
    if (version == null || version.isEmpty) {
      throw const SeerrFailure('invalid_response');
    }
    final response = await _api.publicSettings();
    final settings = _body(response);
    if (settings['initialized'] != true || settings['mediaServerType'] != 2) {
      throw const SeerrFailure('link_unsupported');
    }
    if (settings['mediaServerLogin'] != true) {
      throw const SeerrFailure('authentication_failed');
    }
    return {
      ...settings,
      'version': version,
      'quickConnect': version == '3.4.1'
    };
  }

  void verifyLinkedUser(SeerrUserModel user, String jellyfinUserId) {
    String normalized(String value) => value.replaceAll('-', '').toLowerCase();
    if (user.id == null ||
        user.jellyfinUserId?.isNotEmpty != true ||
        jellyfinUserId.isEmpty ||
        normalized(user.jellyfinUserId!) != normalized(jellyfinUserId)) {
      throw const SeerrFailure('identity_mismatch');
    }
  }

  Future<String> checkLinkedCookie(String cookie, String userId) async {
    final response = cookie == kBrowserManagedCookie
        ? await _api.getMe()
        : await _api.verifyLinkedCookie(cookie);
    final user = _body(response);
    verifyLinkedUser(user, userId);
    final account = ref.read(userProvider);
    if (account == null || kIsWeb) return cookie;
    final requestUri = seerrRequestUri(
        account.seerrCredentials!.serverUrl, Uri.parse('/api/v1/auth/me'));
    return await ref
            .read(seerrSessionStoreProvider)
            .readForRequest(account, requestUri) ??
        cookie;
  }

  Future<String> linkPassword(String username, String password, String userId,
      {void Function(int, bool?, bool?)? onAuthResponse}) async {
    final response = await _api.authenticateJellyfin(
        SeerrAuthJellyfinBody(username: username, password: password));
    final cookie = await _newSessionCookie(
        response, onAuthResponse, '/api/v1/auth/jellyfin');
    return checkLinkedCookie(cookie, userId);
  }

  Future<Map<String, dynamic>> startQuickLink() async {
    final response = _body(await _api.initiateLink());
    if (response['code'] is! String ||
        !RegExp(r'^\d{6}$').hasMatch(response['code'] as String) ||
        response['secret'] is! String ||
        !RegExp(r'^[a-zA-Z0-9-]{16,256}$')
            .hasMatch(response['secret'] as String)) {
      throw const SeerrFailure('invalid_response');
    }
    return response;
  }

  Future<bool> checkQuickLink(String secret) async =>
      _body(await _api.checkLink(secret))['authenticated'] == true;

  Future<String> finishQuickLink(String secret, String userId,
      {void Function(int, bool?, bool?)? onAuthResponse}) async {
    final response = await _api.finishLink({'secret': secret});
    final cookie = await _newSessionCookie(response, onAuthResponse,
        '/api/v1/auth/jellyfin/quickconnect/authenticate');
    return checkLinkedCookie(cookie, userId);
  }

  Future<String> _newSessionCookie(Response<dynamic> response,
      void Function(int, bool?, bool?)? onAuthResponse, String path) async {
    seerrCheckStatus(response.statusCode);
    if (kIsWeb) {
      onAuthResponse?.call(response.statusCode, null, null);
      return kBrowserManagedCookie;
    }
    final account = ref.read(userProvider);
    if (account == null ||
        account.seerrCredentials?.serverUrl.isNotEmpty != true) {
      throw const SeerrFailure('account_changed');
    }
    final responseUri =
        seerrRequestUri(account.seerrCredentials!.serverUrl, Uri.parse(path));
    final headers = seerrSetCookieHeaders(response.base.headers);
    final store = ref.read(seerrSessionStoreProvider);
    final stored = await store.writeFromResponse(account, responseUri, headers);
    onAuthResponse?.call(response.statusCode, headers.isNotEmpty, stored);
    final requestUri = seerrRequestUri(
        account.seerrCredentials!.serverUrl, Uri.parse('/api/v1/auth/me'));
    final cookie =
        stored ? await store.readForRequest(account, requestUri) : null;
    if (cookie == null || cookie.isEmpty) {
      throw const SeerrFailure('authentication_failed');
    }
    return cookie;
  }
}
