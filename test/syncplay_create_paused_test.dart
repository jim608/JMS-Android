import 'dart:async';

import 'package:fladder/services/syncplay/syncplay_controller.dart';
import 'package:fladder/services/syncplay/syncplay_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'syncplay_controller_test.dart' as fixture;

void main() {
  late fixture.World world;
  late fixture.Server server;
  late fixture.Api api;
  late fixture.Player player;
  late SyncPlayController controller;
  setUp(() {
    world = fixture.World();
    server = fixture.Server(world);
    api = server.client('synthetic-paused-owner');
    player = fixture.Player(world)
      ..mediaId = fixture.id(71)
      ..position = const Duration(seconds: 12)
      ..isPlaying = false;
    controller = fixture.makeController(world, api, player);
  });
  tearDown(() async {
    await controller.dispose();
    for (final client in server.clients) {
      await client.events.close();
    }
  });

  int getLoads() => player.actions
      .where((action) => action.type == SyncPlayPlayerActionType.load)
      .length;

  test(
      'Pause during initial room load is deferred and does not fail or restart load',
      () async {
    player.loadResult = Completer<void>();
    await controller.createRoom('001234');
    await controller.setQueue([fixture.id(71)], position: player.position);
    await fixture.settle();
    expect(controller.isLoading, true);
    expect(getLoads(), 1);
    final cancellations = player.cancellations;
    await controller.requestPause(userInitiated: true);
    await world.advance(const Duration(milliseconds: 500));
    expect(controller.state.failure, isNull);
    expect(controller.isLoading, true);
    expect(getLoads(), 1);
    expect(player.cancellations, cancellations);
    expect(
        player.actions.where((a) => a.type == SyncPlayPlayerActionType.unpause),
        isEmpty);
    player.loadResult!.complete();
    await fixture.settle();
    await world.advance(Duration.zero);
    expect(controller.isLoading, false);
    expect(controller.state.failure, isNull);
    expect(player.isPlaying, false);
    expect(
        player.actions.where((a) => a.type == SyncPlayPlayerActionType.pause),
        hasLength(1));
    expect(getLoads(), 1);
  });

  test(
      'fresh duplicate queue metadata never reloads its unchanged playlist item',
      () async {
    player.loadResult = Completer<void>();
    await controller.createRoom('001234');
    await controller.setQueue([fixture.id(71)], position: player.position);
    await fixture.settle();
    final room = server.roomFor(api)!;
    await world.advance(const Duration(milliseconds: 1));
    room.updated = world.now;
    server.queue(api, room);
    await fixture.settle();
    expect(getLoads(), 1);
    player.loadResult!.complete();
    await fixture.settle();
    await world.advance(const Duration(milliseconds: 1));
    room.updated = world.now;
    server.queue(api, room);
    await fixture.settle();
    expect(getLoads(), 1);
    expect(controller.state.failure, isNull);
  });

  test(
      'actual load rejection after Pause becomes player failure without membership loss',
      () async {
    player.loadResult = Completer<void>();
    await controller.createRoom('001234');
    await controller.setQueue([fixture.id(71)], position: player.position);
    await fixture.settle();
    await controller.requestPause(userInitiated: true);
    player.loadResult!.completeError(StateError('synthetic load rejection'));
    await fixture.settle();
    expect(controller.state.failure?.code, SyncPlayFailureCode.player);
    expect(controller.isLoading, false);
    expect(controller.state.isJoined, true);
    expect(getLoads(), 1);
    expect(server.leaveCalls, 0);
  });
}
