import 'dart:async';

import 'package:fladder/services/syncplay/syncplay_controller.dart';
import 'package:fladder/services/syncplay/syncplay_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'syncplay_controller_test.dart' as fixture;

class _Api extends fixture.Api {
  _Api(super.server, super.name);
  int listCalls = 0;
  @override
  Future<List<SyncPlayGroup>> listGroups() {
    listCalls++;
    return super.listGroups();
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
    for (final api in server.clients) {
      await api.events.close();
    }
  });
  Future<void> joined() async {
    await controller.createRoom('001234');
    await fixture.settle();
    await controller
        .setQueue([fixture.id(71)], position: const Duration(seconds: 12));
    await fixture.settle();
  }

  test('exact reconnect keeps the same queue and does not reload media',
      () async {
    await joined();
    final queue = controller.state.queue;
    final loads = player.actions
        .where((a) => a.type == SyncPlayPlayerActionType.load)
        .length;
    controller.setConnected(false);
    controller.setConnected(true);
    await controller.reconnect(automatic: true);
    await fixture.settle();
    expect(controller.state.isJoined, isTrue);
    expect(controller.state.queue?.current?.playlistItemId,
        queue?.current?.playlistItemId);
    expect(
        player.actions
            .where((a) => a.type == SyncPlayPlayerActionType.load)
            .length,
        loads);
    expect(server.newCalls, 1);
    expect(server.joinCalls, 1);
    expect(server.leaveCalls, 0);
  });

  test('unprepared backend reloads its retained queue on exact reconnect', () async {
    await joined();
    final loads = player.actions.where((a) => a.type == SyncPlayPlayerActionType.load).length;
    player.mediaId = null;
    player.playlistItemId = null;
    controller.setConnected(false);
    controller.setConnected(true);
    await controller.reconnect(automatic: true);
    await fixture.settle();
    expect(controller.state.isJoined, isTrue);
    expect(player.actions.where((a) => a.type == SyncPlayPlayerActionType.load).length, loads + 1);
  });

  test(
      'known room confirmation timeout can recover once without creating another room',
      () async {
    await joined();
    api.confirmJoins = false;
    controller.setConnected(false);
    controller.setConnected(true);
    final manual = controller.reconnect();
    await world.advance(const Duration(seconds: 11));
    await manual;
    expect(controller.state.status, SyncPlayStatus.unknown);
    expect(controller.state.failure?.code, SyncPlayFailureCode.timeoutUnknown);
    api.confirmJoins = true;
    await controller.reconnect(automatic: true);
    expect(controller.state.isJoined, isTrue);
    expect(server.newCalls, 1);
    expect(server.joinCalls, 2);
    expect(server.leaveCalls, 0);
  });

  test('unconfirmed initial join is never automatically repeated', () async {
    server.addGroup('JMS-001234');
    api.confirmJoins = false;
    final initial = controller.joinRoom('001234');
    await world.advance(const Duration(seconds: 11));
    await initial;
    final before = server.joinCalls;
    await controller.reconnect(automatic: true);
    expect(controller.state.status, SyncPlayStatus.unknown);
    expect(server.joinCalls, before);
    expect(server.newCalls, 0);
  });

  test('unsettled old join prevents an automatic duplicate mutation', () async {
    await joined();
    api.confirmJoins = false;
    api.joinResult = Completer<void>();
    controller.setConnected(false);
    controller.setConnected(true);
    final oldJoin = controller.reconnect();
    await world.advance(const Duration(seconds: 11));
    await oldJoin;
    final before = server.joinCalls;
    final recovery = controller.reconnect(automatic: true);
    await world.advance(const Duration(seconds: 11));
    await recovery;
    expect(server.joinCalls, before);
    expect(controller.state.status, SyncPlayStatus.unknown);
    api.joinResult!.complete();
    await fixture.settle();
    expect(controller.state.status, SyncPlayStatus.unknown);
  });

  test('expired recovery cannot send Join after its visibility request returns',
      () async {
    await joined();
    final group = controller.state.group!;
    api.listResult = Completer<List<SyncPlayGroup>>();
    controller.setConnected(false);
    controller.setConnected(true);
    var current = true;
    final recovery =
        controller.reconnect(automatic: true, isRecoveryCurrent: () => current);
    await fixture.settle();
    current = false;
    api.listResult!.complete([group]);
    await recovery;
    expect(server.joinCalls, 0);
    expect(controller.state.status, SyncPlayStatus.unknown);
  });

  test(
      'empty visible list is not a leave and does not invalidate current playback',
      () async {
    await joined();
    final before = player.cancellations;
    final queue = controller.state.queue;
    api.listResult = Completer<List<SyncPlayGroup>>()..complete([]);
    await controller.refreshMembership();
    expect(controller.state.isJoined, isTrue);
    expect(controller.state.membershipFreshness,
        SyncPlayMembershipFreshness.uncertain);
    expect(controller.state.queue, same(queue));
    expect(player.cancellations, before);
    expect(server.joinCalls, 0);
    expect(server.leaveCalls, 0);
  });

  test('visible list cannot renew authoritative membership confirmation',
      () async {
    await joined();
    await world.advance(const Duration(minutes: 3));
    expect(controller.state.membershipFreshness,
        SyncPlayMembershipFreshness.stale);
    await controller.refreshMembership();
    expect(controller.state.membershipFreshness,
        SyncPlayMembershipFreshness.stale);
  });

  test('overlapping refreshes share one actual list request even after timeout',
      () async {
    await joined();
    api.listResult = Completer<List<SyncPlayGroup>>();
    final before = api.listCalls;
    final first = controller.refreshMembership();
    final second = controller.refreshMembership();
    expect(first, same(second));
    await world.advance(const Duration(seconds: 11));
    await first;
    final third = controller.refreshMembership();
    expect(api.listCalls, before + 1);
    api.listResult!.complete([controller.state.group!]);
    await third;
    expect(api.listCalls, before + 1);
  });

  test('new identity never reuses the previous identity list future', () async {
    await joined();
    final oldGroup = controller.state.group!;
    api.listResult = Completer<List<SyncPlayGroup>>();
    final oldRefresh = controller.refreshMembership();
    await fixture.settle();
    final next = _Api(server, 'synthetic-bob');
    server.clients.add(next);
    await controller.switchIdentity(
        identity: const SyncPlayIdentity(
            sourceId: 'synthetic-other', userId: 'bob', sessionId: 'session-b'),
        api: next,
        events: next.events.stream);
    await controller.createRoom('002345');
    await controller.refreshMembership();
    expect(next.listCalls, 2);
    final newId = controller.state.group!.groupId;
    expect(newId, isNot(oldGroup.groupId));
    api.listResult!.complete([oldGroup]);
    await oldRefresh;
    expect(controller.state.group!.groupId, newId);
    expect(controller.state.isJoined, isTrue);
  });

  test(
      'leave during automatic Join waits for acknowledgement and prevents late recovery',
      () async {
    await joined();
    controller.setConnected(false);
    controller.setConnected(true);
    api.confirmJoins = false;
    api.joinResult = Completer<void>();
    final recovery = controller.reconnect(automatic: true);
    await fixture.settle();
    expect(server.joinCalls, 1);
    final leaving = controller.leaveRoom();
    await fixture.settle();
    expect(server.leaveCalls, 0);
    api.joinResult!.complete();
    await recovery;
    await leaving;
    expect(server.leaveCalls, 1);
    expect(controller.state.status, SyncPlayStatus.idle);
    expect(server.groupFor(api), isNull);
    expect(server.newCalls, 1);
  });
}
