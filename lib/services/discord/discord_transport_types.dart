import 'dart:async';
import 'dart:typed_data';

abstract interface class DiscordIpcTransport {
  Stream<Uint8List> get incoming;
  Future<void> write(Uint8List bytes);
  Future<void> close();
}

typedef DiscordTransportFactory = Future<DiscordIpcTransport> Function(
    Duration timeout);
