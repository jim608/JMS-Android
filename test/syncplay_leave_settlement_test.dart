import 'dart:async';

import 'package:fladder/services/syncplay/syncplay_controller.dart';
import 'package:fladder/services/syncplay/syncplay_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'syncplay_controller_test.dart' as fixture;

class _Api extends fixture.Api {
  _Api(super.server, super.name);
  Completer<void>? leaveGate;
  Object? leaveError;
  bool leaveEvent = true;
  int leaveRequests = 0;

  @override
  Future<void> leaveGroup() async {
    leaveRequests++;
    await leaveGate?.future;
    if (leaveError != null) throw leaveError!;
    if (leaveEvent) await super.leaveGroup();
  }
}

void main() {
  late fixture.World world;
  late fixture.Server server;
  late _Api api;
  late fixture.Player player;
  late SyncPlayController controller;
  setUp(() {
    world = fixture.World();
    server = fixture.Server(world);
    api = _Api(server, 'synthetic-alice');
    server.clients.add(api);
    player = fixture.Player(world);
    controller = fixture.makeController(world, api, player);
  });
  tearDown(() async {
    await controller.dispose();
    for (final client in server.clients) {
      await client.events.close();
    }
  });

  Future<void> joined() async {
    await controller.createRoom('001234');
    await fixture.settle();
    await controller.setQueue([fixture.id(71)]);
    await fixture.settle();
  }

  for (final playing in [false, true]) {
    test('leave immediately revokes sync while preserving playing=$playing',
        () async {
      await joined();
      final group = controller.state.group!;
      player.position = const Duration(seconds: 37);
      player.isPlaying = playing;
      final before = player.actions.length;
      final cancellations = player.cancellations;
      // Both a scheduled command and later websocket updates must lose control
      // as soon as Leave is pressed, before the HTTP request can settle.
      server.command(group, 'Unpause');
      api.leaveGate = Completer<void>();
      final leaving = controller.leaveRoom();
      expect(controller.leaveRequested, isTrue);
      expect(controller.state.canControl, isFalse);
      expect(controller.state.status, SyncPlayStatus.leaving);
      expect(player.cancellations, greaterThan(cancellations));
      expect(player.position, const Duration(seconds: 37));
      expect(player.isPlaying, playing);
      server.confirm(api);
      server.command(group, 'Pause', delay: Duration.zero);
      await world.advance(const Duration(seconds: 11));
      await leaving;
      expect(player.actions.length, before);
      expect(player.isPlaying, playing);
      expect(controller.state.status, SyncPlayStatus.unknown);
      expect(controller.state.canControl, isFalse);
      api.leaveGate!.complete();
      await fixture.settle();
      expect(controller.state.status, SyncPlayStatus.idle);
      expect(player.actions.length, before);
      expect(player.isPlaying, playing);
    });
  }

  test('leave has one total budget across pending New and Leave', () async {
    api.confirmJoins = false;
    api.newResult = Completer<SyncPlayGroup>();
    final creating = controller.createRoom('001234');
    await fixture.settle();
    api.leaveGate = Completer<void>();
    final leaving = controller.leaveRoom();
    await world.advance(const Duration(seconds: 9));
    expect(api.leaveRequests, 0);
    api.newResult!.complete(server.groupFor(api)!);
    await fixture.settle();
    expect(api.leaveRequests, 1);
    await world.advance(const Duration(seconds: 2));
    await Future.wait([creating, leaving]);
    expect(controller.state.status, SyncPlayStatus.unknown);
    expect(controller.leaveRequested, isTrue);
    expect(controller.state.canControl, isFalse);
    server.confirm(api);
    await fixture.settle();
    expect(controller.state.status, SyncPlayStatus.unknown);
    expect(server.newCalls, 1);
    expect(server.joinCalls, 0);
    api.leaveGate!.complete();
    await fixture.settle();
    expect(controller.state.status, SyncPlayStatus.idle);
  });

  test('manual retries of a still-live Leave stay bounded and single flight',
      () async {
    await joined();
    api.leaveGate = Completer<void>();
    final first = controller.leaveRoom();
    await world.advance(const Duration(seconds: 11));
    await first;
    for (var retry = 0; retry < 2; retry++) {
      final attempt = controller.leaveRoom();
      expect(identical(attempt, controller.leaveRoom()), isTrue);
      expect(controller.state.status, SyncPlayStatus.leaving);
      await world.advance(const Duration(seconds: 11));
      await attempt;
      expect(controller.state.status, SyncPlayStatus.unknown);
      expect(
          controller.state.failure?.code, SyncPlayFailureCode.timeoutUnknown);
      expect(controller.leaveRequested, isTrue);
      expect(api.leaveRequests, 1);
      expect(server.joinCalls, 0);
    }
    api.leaveGate!.complete();
    await fixture.settle();
    expect(controller.state.status, SyncPlayStatus.idle);
    expect(controller.leaveRequested, isFalse);
  });

  test('leave timeout then reconnect settles one Leave without any Join',
      () async {
    await joined();
    api.leaveGate = Completer<void>();
    final leaving = controller.leaveRoom();
    await world.advance(const Duration(seconds: 11));
    await leaving;
    expect(controller.state.status, SyncPlayStatus.unknown);
    expect(controller.leaveRequested, isTrue);
    expect(api.leaveRequests, 1);
    final reconnecting = controller.reconnect();
    await fixture.settle();
    expect(api.leaveRequests, 1);
    expect(server.joinCalls, 0);
    api.leaveGate!.complete();
    await reconnecting;
    expect(controller.state.status, SyncPlayStatus.idle);
    expect(controller.leaveRequested, isFalse);
    expect(server.joinCalls, 0);
  });

  test(
      'leave late HTTP acknowledgement clears pending without another user action',
      () async {
    await joined();
    api.leaveEvent = false;
    api.leaveGate = Completer<void>();
    final leaving = controller.leaveRoom();
    await world.advance(const Duration(seconds: 11));
    await leaving;
    expect(controller.state.status, SyncPlayStatus.unknown);
    api.leaveGate!.complete();
    await fixture.settle();
    expect(controller.state.status, SyncPlayStatus.idle);
    expect(controller.leaveRequested, isFalse);
    expect(server.joinCalls, 0);
  });

  test('leave concurrent calls share one mutation and future', () async {
    await joined();
    api.leaveGate = Completer<void>();
    final first = controller.leaveRoom();
    final second = controller.leaveRoom();
    expect(identical(first, second), isTrue);
    await fixture.settle();
    expect(api.leaveRequests, 1);
    api.leaveGate!.complete();
    await Future.wait([first, second]);
    expect(controller.state.status, SyncPlayStatus.idle);
  });

  test('leave uses HTTP while the room socket is disconnected', () async {
    await joined();
    controller.setConnected(false);
    await controller.leaveRoom();
    expect(api.leaveRequests, 1);
    expect(controller.state.status, SyncPlayStatus.idle);
    expect(controller.state.connected, isFalse);
    expect(controller.leaveRequested, isFalse);
    expect(server.joinCalls, 0);
  });

  test('failed offline Leave retries without reconnecting or automatic rejoin',
      () async {
    await joined();
    controller.setConnected(false);
    api.leaveError = const SyncPlayFailure(SyncPlayFailureCode.server);
    await controller.leaveRoom();
    expect(controller.leaveRequested, isTrue);
    expect(controller.state.status, SyncPlayStatus.unknown);
    await controller.reconnect(automatic: true);
    expect(server.joinCalls, 0);
    expect(api.leaveRequests, 1);
    api.leaveError = null;
    await controller.reconnect();
    expect(api.leaveRequests, 2);
    expect(controller.state.status, SyncPlayStatus.idle);
    expect(controller.state.connected, isFalse);
    controller.setConnected(true);
    await controller.reconnect(automatic: true);
    expect(server.joinCalls, 0);
  });

  test('leave completed HTTP error allows explicit Leave retry but never Join',
      () async {
    await joined();
    api.leaveError = const SyncPlayFailure(SyncPlayFailureCode.server);
    await controller.leaveRoom();
    expect(controller.state.status, SyncPlayStatus.unknown);
    expect(controller.leaveRequested, isTrue);
    await controller.reconnect(automatic: true);
    expect(api.leaveRequests, 1);
    api.leaveError = null;
    await controller.reconnect();
    expect(api.leaveRequests, 2);
    expect(server.joinCalls, 0);
    expect(controller.state.status, SyncPlayStatus.idle);
  });

  test('leave intent rejects late GroupJoined after confirmation timeout',
      () async {
    await joined();
    api.leaveGate = Completer<void>();
    final leaving = controller.leaveRoom();
    await world.advance(const Duration(seconds: 11));
    await leaving;
    server.confirm(api);
    await fixture.settle();
    expect(controller.state.status, SyncPlayStatus.unknown);
    expect(controller.leaveRequested, isTrue);
    api.leaveGate!.complete();
    await fixture.settle();
    expect(controller.state.status, SyncPlayStatus.idle);
  });

  test('leave late result cannot clear a replacement identity room', () async {
    await joined();
    api.leaveEvent = false;
    api.leaveGate = Completer<void>();
    final leaving = controller.leaveRoom();
    await world.advance(const Duration(seconds: 11));
    await leaving;
    final other = _Api(server, 'synthetic-bob');
    server.clients.add(other);
    await controller.switchIdentity(
      identity: const SyncPlayIdentity(
          sourceId: 'synthetic-other', userId: 'bob', sessionId: 'synthetic-b'),
      api: other,
      events: other.events.stream,
    );
    await controller.createRoom('005678');
    final group = controller.state.group;
    api.leaveGate!.complete();
    await fixture.settle();
    expect(controller.state.isJoined, isTrue);
    expect(controller.state.group?.groupId, group?.groupId);
    expect(controller.leaveRequested, isFalse);
  });
}
