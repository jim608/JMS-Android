import 'dart:async';

enum DiscordConnectionState { disconnected, connecting, connected, error }

enum DiscordIpcFailure {
  unsupported,
  unavailable,
  timeout,
  closed,
  protocol,
  rejected,
  busy
}

/// A safe classification only: never contains an IPC payload or local path.
class DiscordIpcException implements Exception {
  const DiscordIpcException(this.failure);

  final DiscordIpcFailure failure;

  @override
  String toString() => 'Discord IPC: ${failure.name}';
}

abstract interface class DiscordPresenceClient {
  bool get supported;
  Stream<DiscordConnectionState> get states;

  /// Completes after READY. Connected is reported only after an activity ACK.
  Future<void> connect(String applicationId);
  Future<void> setActivity(Map<String, Object?>? activity);

  /// Releases the current session. The client may subsequently reconnect.
  Future<void> close();
}
