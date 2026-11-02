import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/models/account_model.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/services/jellyfin_session_socket.dart';

/// A hub is retired on every login or credential change, including A -> B -> A.
/// Creating/reading this provider never opens a socket.
final jellyfinSessionSocketHubProvider = Provider<JellyfinSessionSocketHub>((
  ref,
) {
  final hub = JellyfinSessionSocketHub();
  ref.listen(userProvider, (previous, next) {
    if (!_sameLogin(previous, next)) {
      unawaited(hub.dispose());
      ref.invalidateSelf();
    }
  });
  ref.onDispose(() => unawaited(hub.dispose()));
  return hub;
});

/// Both consumers pass the same captured account and URI. The protocol owner
/// remains responsible for its own connection/reconnection and event handling.
JellyfinSessionSocketFactory jellyfinSessionSocketFactoryForAccount(
  Ref ref,
  AccountModel account, {
  required bool Function() isCurrent,
  Map<String, String>? headers,
}) {
  final hub = ref.read(jellyfinSessionSocketHubProvider);
  return jellyfinSessionSocketFactoryForPlatform(
    hub,
    account: account,
    isWeb: kIsWeb,
    headers: kIsWeb ? null : headers ?? account.credentials.header(ref),
    isCurrent: () {
      try {
        return isCurrent() && _sameLogin(account, ref.read(userProvider));
      } catch (_) {
        return false;
      }
    },
  );
}

/// Browser channels cannot send custom headers. Their physical session identity
/// is the captured URI, even if a device label changed between consumers.
/// No caller can move this account's captured headers to a different URI.
JellyfinSessionSocketFactory jellyfinSessionSocketFactoryForPlatform(
  JellyfinSessionSocketHub hub, {
  required AccountModel account,
  required bool isWeb,
  required bool Function() isCurrent,
  Map<String, String>? headers,
}) {
  final expectedUri = _socketUriForAccount(account);
  final factory = hub.factory(
    isCurrent: isCurrent,
    headers: isWeb ? const <String, String>{} : headers,
  );
  return (uri) {
    if (uri != expectedUri) throw const JellyfinSessionSocketClosed();
    return factory(uri);
  };
}

Uri _socketUriForAccount(AccountModel account) {
  try {
    final credentials = account.credentials;
    final base = Uri.parse(credentials.url);
    if (!const {'http', 'https'}.contains(base.scheme) ||
        !base.hasAuthority ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment ||
        credentials.token.isEmpty ||
        credentials.deviceId.isEmpty) {
      throw const JellyfinSessionSocketClosed();
    }
    final segments = base.pathSegments.toList();
    while (segments.isNotEmpty && segments.last.isEmpty) {
      segments.removeLast();
    }
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      pathSegments: [...segments, 'socket'],
      queryParameters: {
        'ApiKey': credentials.token,
        'deviceId': credentials.deviceId,
      },
    );
  } catch (_) {
    throw const JellyfinSessionSocketClosed();
  }
}

bool _sameLogin(AccountModel? a, AccountModel? b) =>
    a?.id == b?.id && a?.credentials == b?.credentials;
