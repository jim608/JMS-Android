import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fladder/models/account_model.dart';

final seerrSessionStoreProvider = Provider((ref) => SeerrSessionStore());

class SeerrSessionStore {
  static const channel = MethodChannel('com.jim608.jms/seerr-session');
  static String key(AccountModel account) => sha256
      .convert(utf8.encode(jsonEncode([
        account.credentials.serverId,
        account.id,
        account.seerrCredentials?.serverUrl,
      ])))
      .toString();

  Future<String?> read(AccountModel account) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    final value = await channel.invokeMethod<String>('read', {'key': key(account)});
    if (value == null) return null;
    final record = jsonDecode(value) as Map<String, dynamic>;
    if ((record['expires'] as int) <= DateTime.now().millisecondsSinceEpoch) {
      await write(account, null);
      return null;
    }
    return record['cookie'] as String;
  }

  Future<void> write(AccountModel account, String? cookie) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    final value = cookie?.isNotEmpty == true
        ? jsonEncode({'cookie': cookie, 'expires': DateTime.now().add(const Duration(days: 7)).millisecondsSinceEpoch})
        : null;
    await channel.invokeMethod<void>('write', {'key': key(account), 'value': value});
  }
}
