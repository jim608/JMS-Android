import 'dart:async';

import 'package:fladder/services/syncplay/syncplay_controller.dart';
import 'package:fladder/services/syncplay/syncplay_clock.dart';
import 'package:fladder/services/syncplay/syncplay_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'syncplay_controller_test.dart' as fixture;

class _PauseFailureApi extends fixture.Api {
  _PauseFailureApi(super.server, super.name);
  Completer<void>? pauseGate;
  Completer<void>? queueGate;
  Object? pauseError;
  int pauseRequests = 0;
  int queueRequests = 0;
  @override
  Future<void> sendRequest(SyncPlayRequest request) async {
    if (request.type == SyncPlayRequestType.setNewQueue) {
      queueRequests++;
      await queueGate?.future;
    }
    if (request.type == SyncPlayRequestType.pause) {
      pauseRequests++;
      await pauseGate?.future;
      if (pauseError != null) throw pauseError!;
    }
    await super.sendRequest(request);
  }
}

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

  for (final timeout in [false, true]) {
    test(
        'paused creator failed initial Pause keeps Ready and IgnoreWait held timeout=$timeout',
        () async {
      await controller.dispose();
      final failureApi = _PauseFailureApi(server, 'synthetic-pause-failure');
      server.clients.add(failureApi);
      api = failureApi;
      if (timeout) {
        failureApi.pauseGate = Completer<void>();
        addTearDown(() => failureApi.pauseGate!.complete());
      } else {
        failureApi.pauseError =
            const SyncPlayFailure(SyncPlayFailureCode.server);
      }
      var mediaReady = false;
      player.loadResult = Completer<void>();
      controller = SyncPlayController(
        identity: fixture.identity,
        api: api,
        player: player,
        events: api.events.stream,
        scheduler: world,
        clock: SyncPlayClock(now: () => world.now),
        isPlayerBuffering: () => player.buffering,
        mediaReadiness: () => mediaReady,
        bufferedAhead: () => const Duration(seconds: 10),
        targetBufferedAhead: () => const Duration(seconds: 3),
      );
      await controller.createRoom('001234', startPaused: true);
      final setting =
          controller.setQueue([fixture.id(71)], position: player.position);
      await fixture.settle();
      if (timeout) await world.advance(const Duration(seconds: 11));
      await setting; // The action ends even though readiness remains held.
      expect(controller.state.failure?.code,
          SyncPlayFailureCode.creationUnconfirmed);
      await world.advance(Duration(seconds: timeout ? 20 : 31));
      expect(failureApi.pauseRequests, 1);
      expect(
          server.requests.where((request) => const {
                SyncPlayRequestType.ready,
                SyncPlayRequestType.setIgnoreWait,
                SyncPlayRequestType.unpause,
              }.contains(request.type)),
          isEmpty);
      mediaReady = true;
      player.loadResult!.complete();
      await fixture.settle();
      server.command(server.groupFor(api)!, 'Unpause', delay: Duration.zero);
      await world.advance(const Duration(seconds: 1));
      expect(player.isPlaying, false);
      expect(
          server.requests
              .where((request) => request.type == SyncPlayRequestType.ready),
          isEmpty);
      expect(
          player.actions.where(
              (action) => action.type == SyncPlayPlayerActionType.unpause),
          isEmpty);
    });
  }

  test(
      'initial Pause timeout rejects contradictory intents through late ACK until Leave',
      () async {
    await controller.dispose();
    final delayedApi = _PauseFailureApi(server, 'synthetic-late-pause')
      ..pauseGate = Completer<void>();
    server.clients.add(delayedApi);
    api = delayedApi;
    controller = fixture.makeController(world, api, player);
    await controller.createRoom('001234', startPaused: true);
    final setting =
        controller.setQueue([fixture.id(71)], position: player.position);
    await fixture.settle();
    await world.advance(const Duration(seconds: 11));
    await setting;
    expect(controller.state.failure?.code,
        SyncPlayFailureCode.creationUnconfirmed);
    await controller.requestUnpause(userInitiated: true);
    await controller.requestPause(userInitiated: true);
    await controller.requestSeek(const Duration(seconds: 99),
        userInitiated: true);
    await controller.setQueue([fixture.id(72)], startPaused: true);
    expect(delayedApi.queueRequests, 1);
    expect(delayedApi.pauseRequests, 1);
    expect(
        server.requests
            .where((request) => request.type == SyncPlayRequestType.seek),
        isEmpty);
    expect(
        server.requests
            .where((request) => request.type == SyncPlayRequestType.unpause),
        isEmpty);
    expect(
        server.requests
            .where((request) => request.type == SyncPlayRequestType.ready),
        isEmpty);
    delayedApi.pauseGate!.complete();
    await fixture.settle();
    await world.advance(const Duration(seconds: 1));
    expect(player.isPlaying, false);
    expect(
        server.requests
            .where((request) => request.type == SyncPlayRequestType.ready),
        isEmpty);
    await controller.requestUnpause(userInitiated: true);
    expect(
        server.requests
            .where((request) => request.type == SyncPlayRequestType.unpause),
        isEmpty);
    controller.setConnected(false);
    controller.setConnected(true);
    await controller.reconnect(automatic: true);
    await controller.reconnect();
    expect(server.joinCalls, 0);
    expect(
        server.requests
            .where((request) => request.type == SyncPlayRequestType.ready),
        isEmpty);
    await controller.leaveRoom();
    expect(controller.state.status, SyncPlayStatus.idle);
    expect(controller.leaveRequested, false);
    expect(player.isPlaying, false);
  });

  test(
      'initial Queue timeout keeps late Queue and explicit Play behind the uncertain hold',
      () async {
    await controller.dispose();
    final delayedApi = _PauseFailureApi(server, 'synthetic-late-queue')
      ..queueGate = Completer<void>();
    server.clients.add(delayedApi);
    api = delayedApi;
    controller = fixture.makeController(world, api, player);
    await controller.createRoom('001234', startPaused: true);
    final setting =
        controller.setQueue([fixture.id(71)], position: player.position);
    await fixture.settle();
    await world.advance(const Duration(seconds: 11));
    await setting;
    expect(controller.state.failure?.code,
        SyncPlayFailureCode.creationUnconfirmed);
    await controller.requestUnpause(userInitiated: true);
    await controller.requestPause(userInitiated: true);
    delayedApi.queueGate!.complete();
    await fixture.settle();
    expect(delayedApi.queueRequests, 1);
    expect(delayedApi.pauseRequests, 0);
    expect(
        server.requests.where((request) => const {
              SyncPlayRequestType.ready,
              SyncPlayRequestType.unpause,
            }.contains(request.type)),
        isEmpty);
    expect(player.isPlaying, false);
    await controller.leaveRoom();
    expect(controller.state.status, SyncPlayStatus.idle);
    expect(player.isPlaying, false);
  });

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
