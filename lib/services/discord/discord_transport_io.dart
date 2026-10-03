import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'discord_presence_client.dart';
import 'discord_transport_types.dart';
import 'discord_transport_windows.dart';

bool get discordDesktopSupported => Platform.isWindows || Platform.isLinux;
int get discordProcessId => pid;

/// The official IPC endpoints only; no TCP, web API or user-data discovery.
Future<DiscordIpcTransport> openDiscordIpcTransport(Duration timeout) async {
  if (Platform.isWindows) {
    for (var index = 0; index < 10; index++) {
      try {
        return openWindowsDiscordPipe('\\\\?\\pipe\\discord-ipc-$index',
            timeout: timeout);
      } on DiscordIpcException {
        // Check each numbered endpoint once. The provider owns reconnect backoff.
      }
    }
  } else if (Platform.isLinux) {
    final clock = Stopwatch()..start();
    for (final prefix in discordUnixPrefixes(Platform.environment)) {
      for (var index = 0; index < 10; index++) {
        final remaining = timeout - clock.elapsed;
        if (remaining <= Duration.zero) {
          throw const DiscordIpcException(DiscordIpcFailure.timeout);
        }
        try {
          return await openDiscordUnixSocket('$prefix/discord-ipc-$index',
              timeout: remaining < const Duration(milliseconds: 150)
                  ? remaining
                  : const Duration(milliseconds: 150));
        } on DiscordIpcException {
          // Bounded exact socket endpoints, without traversing their directories.
        }
      }
    }
  } else {
    throw const DiscordIpcException(DiscordIpcFailure.unsupported);
  }
  throw const DiscordIpcException(DiscordIpcFailure.unavailable);
}

List<String> discordUnixPrefixes(Map<String, String> environment) {
  return <String>{
    for (final name in const ['XDG_RUNTIME_DIR', 'TMPDIR', 'TMP', 'TEMP'])
      if (environment[name] case final String path
          when path.startsWith('/') && !path.contains('\u0000'))
        path.replaceFirst(RegExp(r'/+$'), ''),
    '/tmp',
  }.toList(growable: false);
}

/// Public for isolated local socket fixtures; an IP address cannot be used here.
Future<DiscordIpcTransport> openDiscordUnixSocket(String path,
    {required Duration timeout}) async {
  if (!Platform.isLinux ||
      !path.startsWith('/') ||
      path.contains('\u0000') ||
      utf8.encode(path).length > 107) {
    throw const DiscordIpcException(DiscordIpcFailure.unavailable);
  }
  var expired = false;
  final attempt =
      Socket.connect(InternetAddress(path, type: InternetAddressType.unix), 0);
  unawaited(attempt.then((socket) {
    if (expired) socket.destroy();
  }, onError: (Object _) {}));
  try {
    return _UnixDiscordTransport(await attempt.timeout(timeout));
  } catch (_) {
    expired = true;
    throw const DiscordIpcException(DiscordIpcFailure.unavailable);
  }
}

class _UnixDiscordTransport implements DiscordIpcTransport {
  _UnixDiscordTransport(this._socket);

  final Socket _socket;
  bool _closed = false;

  @override
  Stream<Uint8List> get incoming => _socket;

  @override
  Future<void> write(Uint8List bytes) async {
    if (_closed) throw const DiscordIpcException(DiscordIpcFailure.closed);
    try {
      _socket.add(bytes);
      await _socket.flush().timeout(const Duration(seconds: 1));
    } catch (_) {
      await close();
      throw const DiscordIpcException(DiscordIpcFailure.unavailable);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _socket.destroy();
  }
}
