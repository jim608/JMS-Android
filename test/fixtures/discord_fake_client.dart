import 'dart:async';

import 'package:fladder/services/discord/discord_presence_client.dart';

class FakeDiscordPresenceClient implements DiscordPresenceClient {
  FakeDiscordPresenceClient({this.supported = true});

  @override
  final bool supported;
  final events = StreamController<DiscordConnectionState>.broadcast(sync: true);
  final activities = <Map<String, Object?>?>[];
  int connections = 0;
  int closes = 0;
  bool failConnect = false;
  Completer<void>? connectGate;
  Completer<void>? activityGate;

  @override
  Stream<DiscordConnectionState> get states => events.stream;

  @override
  Future<void> connect(String applicationId) async {
    connections++;
    events.add(DiscordConnectionState.connecting);
    if (failConnect) {
      events.add(DiscordConnectionState.error);
      throw StateError('Synthetic IPC unavailable');
    }
    await connectGate?.future;
  }

  @override
  Future<void> setActivity(Map<String, Object?>? activity) async {
    activities.add(activity);
    if (activity != null) await activityGate?.future;
    events.add(DiscordConnectionState.connected);
  }

  @override
  Future<void> close() async {
    closes++;
    events.add(DiscordConnectionState.disconnected);
  }
}
