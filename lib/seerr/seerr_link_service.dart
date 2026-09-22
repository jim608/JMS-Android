part of '../providers/seerr_service_provider.dart';

extension SeerrLinkService on SeerrService {
  Future<Map<String, dynamic>> linkCapabilities() async {
    final version = _body(await _api.getStatus()).version;
    if (version == null || version.isEmpty) throw const SeerrFailure('invalid_response');
    final response = await _api.publicSettings();
    final settings = _body(response);
    if (settings['initialized'] != true || settings['mediaServerType'] != 2) {
      throw const SeerrFailure('link_unsupported');
    }
    if (settings['mediaServerLogin'] != true) throw const SeerrFailure('permission_denied');
    return {...settings, 'version': version, 'quickConnect': version == '3.4.1'};
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
    final response = await _api.verifyLinkedCookie(cookie);
    final user = _body(response);
    verifyLinkedUser(user, userId);
    return _extractSessionCookie(response) ?? cookie;
  }

  Future<String> linkPassword(String username, String password, String userId) async {
    final response = await _api.authenticateJellyfin(SeerrAuthJellyfinBody(username: username, password: password));
    verifyLinkedUser(_body(response), userId);
    final cookie = _requireSessionCookie(response, label: 'JMS link');
    return checkLinkedCookie(cookie, userId);
  }

  Future<Map<String, dynamic>> startQuickLink() async {
    final response = _body(await _api.initiateLink());
    if (response['code'] is! String ||
        !RegExp(r'^\d{6}$').hasMatch(response['code'] as String) ||
        response['secret'] is! String ||
        !RegExp(r'^[a-zA-Z0-9-]{16,256}$').hasMatch(response['secret'] as String)) {
      throw const SeerrFailure('invalid_response');
    }
    return response;
  }

  Future<bool> checkQuickLink(String secret) async => _body(await _api.checkLink(secret))['authenticated'] == true;

  Future<String> finishQuickLink(String secret, String userId) async {
    final response = await _api.finishLink({'secret': secret});
    verifyLinkedUser(_body(response), userId);
    final cookie = _requireSessionCookie(response, label: 'JMS Quick Connect');
    return checkLinkedCookie(cookie, userId);
  }
}
