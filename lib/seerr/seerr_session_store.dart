import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fladder/models/account_model.dart';
import 'package:fladder/seerr/seerr_cookie_jar.dart';
import 'package:intl/intl.dart';

final seerrSessionStoreProvider = Provider((ref) => SeerrSessionStore());

class SeerrSessionStore {
  static const channel = MethodChannel('com.jim608.jms/seerr-session');
  final Map<String, SeerrCookieJar> _staged = {};

  static String key(AccountModel account, {Uri? origin}) => sha256
      .convert(utf8.encode(jsonEncode([
        account.credentials.serverId,
        account.id,
        _sourceIdentity(account, origin),
      ])))
      .toString();

  static String _sourceIdentity(AccountModel account, Uri? origin) {
    final source = Uri.tryParse(account.seerrCredentials?.serverUrl ?? '');
    if (source?.hasAuthority == true) {
      return '${source!.origin}${source.path.replaceFirst(RegExp(r'/+$'), '')}';
    }
    return origin?.origin ?? '';
  }

  static String _legacyKey(AccountModel account) => sha256
      .convert(utf8.encode(jsonEncode([
        account.credentials.serverId,
        account.id,
        account.seerrCredentials?.serverUrl,
      ])))
      .toString();

  bool _matchesAccount(AccountModel account, Uri uri) {
    final source = Uri.tryParse(account.seerrCredentials?.serverUrl ?? '');
    if (source?.hasAuthority != true) return true;
    final basePath = source!.path.replaceFirst(RegExp(r'/+$'), '');
    return source.origin == uri.origin &&
        (basePath.isEmpty || uri.path.startsWith('$basePath/'));
  }

  Future<String?> read(AccountModel account) async {
    final source = Uri.tryParse(account.seerrCredentials?.serverUrl ?? '');
    if (source?.hasAuthority != true) return null;
    final basePath = source!.path.replaceFirst(RegExp(r'/+$'), '');
    return readForRequest(
        account, source.replace(path: '$basePath/api/v1/auth/me'));
  }

  Future<String?> readForRequest(AccountModel account, Uri requestUri) async {
    if (!_supported || !_matchesAccount(account, requestUri)) return null;
    final scope = key(account, origin: requestUri);
    final staged = _staged[scope];
    if (staged != null) {
      return _isIdentityCheck(requestUri) ? staged.headerFor(requestUri) : null;
    }
    return (await _readJar(account, requestUri))?.headerFor(requestUri);
  }

  String? readStagedForRequest(AccountModel account, Uri requestUri) {
    if (!_supported || !_matchesAccount(account, requestUri)) return null;
    return _isIdentityCheck(requestUri)
        ? _staged[key(account, origin: requestUri)]?.headerFor(requestUri)
        : null;
  }

  bool _isIdentityCheck(Uri uri) => uri.path.endsWith('/api/v1/auth/me');

  Future<bool> stageFromResponse(
      AccountModel account, Uri responseUri, List<String> setCookieHeaders,
      {bool replaceExisting = false}) async {
    if (!_supported ||
        !_matchesAccount(account, responseUri) ||
        setCookieHeaders.isEmpty) {
      return false;
    }
    final scope = key(account, origin: responseUri);
    final jar = replaceExisting
        ? SeerrCookieJar(responseUri)
        : _staged[scope] ??
            await _readJar(account, responseUri) ??
            SeerrCookieJar(responseUri);
    final received = jar.ingest(responseUri, setCookieHeaders);
    _staged[scope] = jar;
    return received;
  }

  Future<bool> commitStaged(AccountModel account, Uri uri) async {
    if (!_supported || !_matchesAccount(account, uri)) return false;
    final scope = key(account, origin: uri);
    final jar = _staged[scope];
    if (jar == null) return false;
    await _writeRecord(scope, jar.isEmpty ? null : jsonEncode(jar.toJson()));
    _staged.remove(scope);
    return !jar.isEmpty;
  }

  void discardStaged(AccountModel account, Uri uri) {
    _staged.remove(key(account, origin: uri));
  }

  Future<bool> writeFromResponse(AccountModel account, Uri responseUri,
      List<String> setCookieHeaders) async {
    if (!_supported ||
        !_matchesAccount(account, responseUri) ||
        setCookieHeaders.isEmpty) {
      return false;
    }
    final jar =
        await _readJar(account, responseUri) ?? SeerrCookieJar(responseUri);
    final received = jar.ingest(responseUri, setCookieHeaders);
    await _writeRecord(key(account, origin: responseUri),
        jar.isEmpty ? null : jsonEncode(jar.toJson()));
    return received;
  }

  Future<void> write(AccountModel account, String? cookie) async {
    if (!_supported) return;
    _staged.remove(key(account));
    if (cookie == null || cookie.isEmpty) {
      await _writeRecord(key(account), null);
      final oldKey = _legacyKey(account);
      if (oldKey != key(account)) await _writeRecord(oldKey, null);
      return;
    }
    final source = Uri.tryParse(account.seerrCredentials?.serverUrl ?? '');
    if (source?.hasAuthority != true) return;
    final jar = SeerrCookieJar(source!);
    jar.ingest(source, [
      for (final pair in cookie.split(';'))
        '${pair.trim()}; Path=/${source.scheme == 'https' ? '; Secure' : ''}'
    ]);
    await _writeRecord(
        key(account), jar.isEmpty ? null : jsonEncode(jar.toJson()));
  }

  Future<SeerrCookieJar?> _readJar(AccountModel account, Uri uri) async {
    final scope = key(account, origin: uri);
    var record = await channel.invokeMethod<String>('read', {'key': scope});
    if (record == null &&
        account.seerrCredentials?.serverUrl.isNotEmpty == true) {
      record = await channel
          .invokeMethod<String>('read', {'key': _legacyKey(account)});
    }
    if (record == null) return null;
    try {
      final decoded = jsonDecode(record);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid Seerr session record');
      }
      if (decoded['version'] == 2) return SeerrCookieJar.fromJson(uri, decoded);
      final expires = decoded['expires'];
      final cookie = decoded['cookie'];
      if (expires is! int ||
          cookie is! String ||
          expires <= DateTime.now().millisecondsSinceEpoch) {
        await write(account, null);
        return null;
      }
      final jar = SeerrCookieJar(uri);
      final expiry = DateFormat('EEE, dd MMM yyyy HH:mm:ss', 'en_US')
          .format(DateTime.fromMillisecondsSinceEpoch(expires, isUtc: true));
      jar.ingest(uri, ['${cookie.trim()}; Path=/; Expires=$expiry GMT']);
      await _writeRecord(scope, jsonEncode(jar.toJson()));
      if (_legacyKey(account) != scope) {
        await _writeRecord(_legacyKey(account), null);
      }
      return jar;
    } on FormatException {
      await write(account, null);
      return null;
    }
  }

  Future<void> _writeRecord(String scope, String? value) =>
      channel.invokeMethod<void>('write', {'key': scope, 'value': value});

  bool get _supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.windows);
}
