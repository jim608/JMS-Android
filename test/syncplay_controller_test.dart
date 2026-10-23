import 'dart:async';

import 'package:fladder/services/syncplay/syncplay_clock.dart';
import 'package:fladder/services/syncplay/syncplay_controller.dart';
import 'package:fladder/services/syncplay/syncplay_models.dart';
import 'package:flutter_test/flutter_test.dart';

String id(int value) => value.toRadixString(16).padLeft(32, '0');
const identity = SyncPlayIdentity(
    sourceId: 'synthetic-server', userId: 'alice', sessionId: 'session-a');

Future<void> settle() async {
  for (var i = 0; i < 40; i++) {
    await Future<void>.value();
  }
}

void main() {
  late World world;
  late Server server;
  late Api alice;
  late Player player;
  late SyncPlayController controller;

  setUp(() {
    world = World();
    server = Server(world);
    alice = server.client('alice');
    player = Player(world);
    controller = makeController(world, alice, player);
  });

  tearDown(() async {
    await controller.dispose();
    for (final client in server.clients) {
      await client.events.close();
    }
  });

  Future<void> readyRoom() async {
    await controller.createRoom('001234');
    await settle();
    await controller.setQueue([id(71)], position: const Duration(seconds: 12));
    await settle();
    expect(controller.state.canControl, isTrue);
  }

  test(
      'two signed-in clients share pause, seek and server deadlines despite clock skew',
      () async {
    await controller.dispose();
    controller =
        makeController(world, alice, player, skew: const Duration(seconds: 7));
    final bob = server.client('bob');
    final otherPlayer = Player(world);
    final other = makeController(world, bob, otherPlayer,
        skew: const Duration(seconds: -13));
    addTearDown(other.dispose);
    await readyRoom();
    await other.joinRoom('001234');
    await settle();
    expect(other.state.isJoined, isTrue);
    expect(player.mediaId, otherPlayer.mediaId);
    expect(player.playlistItemId, isNot(player.mediaId));
    expect(player.playlistItemId, otherPlayer.playlistItemId);
    player.onApply =
        (_) => controller.requestPause(); // A remote event must not echo.
    await controller.requestUnpause();
    await world.advance(const Duration(milliseconds: 499));
    expect(player.isPlaying, isFalse);
    expect(otherPlayer.isPlaying, isFalse);
    await world.advance(const Duration(milliseconds: 1));
    expect(player.isPlaying, isTrue);
    expect(otherPlayer.isPlaying, isTrue);
    expect(server.requests.where((r) => r.type == SyncPlayRequestType.pause),
        isEmpty);
    await controller.requestSeek(const Duration(milliseconds: 37250));
    await world.advance(const Duration(milliseconds: 500));
    expect(player.position, const Duration(milliseconds: 37250));
    expect(otherPlayer.position, player.position);
    expect(player.isPlaying, isFalse);
    expect(otherPlayer.isPlaying, isFalse);
    final reports =
        server.requests.where((r) => r.type == SyncPlayRequestType.ready);
    expect(reports.length, greaterThanOrEqualTo(4));
    expect(
        reports.every((r) => r.body['PlaylistItemId'] == player.playlistItemId),
        isTrue);
    player.onApply = null;
    await controller.requestPause();
    await world.advance(const Duration(milliseconds: 500));
    expect(
        server.requests
            .where((r) => r.type == SyncPlayRequestType.pause)
            .length,
        1);
  });

  test(
      '204 join acknowledgement does not claim joined; timeout keeps unknown without New retry',
      () async {
    server.addGroup('JMS-123456');
    alice.confirmJoins = false;
    final join = controller.joinRoom('123456');
    await settle();
    expect(controller.state.status, SyncPlayStatus.joining);
    await world.advance(const Duration(seconds: 11));
    await join;
    expect(controller.state.status, SyncPlayStatus.unknown);
    expect(controller.state.failure?.code, SyncPlayFailureCode.timeoutUnknown);
    await controller.createRoom('222222');
    expect(server.newCalls, 0);
    server.confirm(alice);
    await settle();
    expect(controller.state.isJoined,
        isTrue); // A real late confirmation is usable.
  });

  for (final manualType in [
    SyncPlayRequestType.pause,
    SyncPlayRequestType.unpause,
    SyncPlayRequestType.seek
  ]) {
    test(
        'explicit ${manualType.name} survives pending remote work while implicit echoes stay suppressed',
        () async {
      await readyRoom();
      final remoteStarted = Completer<void>();
      final remoteFinished = Completer<void>();
      addTearDown(() {
        if (!remoteFinished.isCompleted) remoteFinished.complete();
      });
      player.onApply = (action) async {
        if (action.type == SyncPlayPlayerActionType.unpause &&
            !remoteStarted.isCompleted) {
          remoteStarted.complete();
          await remoteFinished.future;
          await controller
              .requestPause(); // An actual late backend echo remains blocked.
        }
      };
      server.command(server.groupFor(alice)!, 'Unpause');
      await world.advance(const Duration(milliseconds: 500));
      await remoteStarted.future;
      expect(controller.isApplyingRemote, isTrue);
      final before = server.requests.length;
      await controller.requestPause();
      await controller.requestUnpause();
      await controller.requestSeek(const Duration(seconds: 99));
      expect(server.requests.length, before);
      switch (manualType) {
        case SyncPlayRequestType.pause:
          await controller.requestPause(userInitiated: true);
        case SyncPlayRequestType.unpause:
          await controller.requestUnpause(userInitiated: true);
        case SyncPlayRequestType.seek:
          await controller.requestSeek(const Duration(milliseconds: 37250),
              userInitiated: true);
        default:
          fail('unsupported manual fixture request');
      }
      expect(server.requests.skip(before).where((r) => r.type == manualType),
          hasLength(1));
      await world.advance(const Duration(milliseconds: 500));
      final expectedPlaying = manualType == SyncPlayRequestType.unpause;
      expect(player.isPlaying, expectedPlaying);
      if (manualType == SyncPlayRequestType.seek) {
        expect(player.position, const Duration(milliseconds: 37250));
      }
      final actionsAfterLatest = player.actions.length;
      remoteFinished.complete();
      await settle();
      expect(controller.isApplyingRemote, isFalse);
      expect(server.requests.skip(before).where((r) => r.type == manualType),
          hasLength(1));
      expect(
          server.requests
              .skip(before)
              .where((r) => r.type == SyncPlayRequestType.pause),
          hasLength(manualType == SyncPlayRequestType.pause ? 1 : 0));
      // Completing an older Unpause must not replace the newer Pause/Seek drift anchor.
      await world.advance(const Duration(seconds: 3));
      expect(player.isPlaying, expectedPlaying);
      expect(player.actions.length, actionsAfterLatest);
    });
  }

  test(
      'zero or multiple exact code matches refuse joining and lookalikes do not match',
      () async {
    await controller.joinRoom('654321');
    expect(controller.state.failure?.code, SyncPlayFailureCode.noGroup);
    expect(server.joinCalls, 0);
    server.addGroup('JMS-654321');
    server.addGroup('JMS-654321');
    await controller.joinRoom('654321');
    expect(controller.state.failure?.code, SyncPlayFailureCode.ambiguousCode);
    expect(server.joinCalls, 0);
    server.groups.clear();
    server.addGroup('jms-654321');
    server.addGroup('JMS-654321-more');
    await controller.joinRoom('654321');
    expect(controller.state.failure?.code, SyncPlayFailureCode.noGroup);
    final exact = server.addGroup('JMS-654321');
    await controller.joinRoom('654321');
    expect(controller.state.group?.groupId, exact.groupId);
  });

  test(
      'New timeout is not retried; late REST and old socket cannot cross identity epochs',
      () async {
    final delayed = Completer<SyncPlayGroup>();
    alice.newResult = delayed;
    alice.confirmJoins = false;
    final create = controller.createRoom('100001');
    await settle();
    expect(controller.state.status, SyncPlayStatus.creating);
    await world.advance(const Duration(seconds: 11));
    await create;
    expect(controller.state.status, SyncPlayStatus.unknown);
    await controller.createRoom('100002');
    expect(server.newCalls, 1);
    final replacement = server.client('different-user');
    await controller.switchIdentity(
        identity: const SyncPlayIdentity(
            sourceId: 'different-server',
            userId: 'different-user',
            sessionId: 'different-session'),
        api: replacement,
        events: replacement.events.stream);
    delayed.complete(server.groupFor(alice)!);
    server.confirm(alice);
    await settle();
    expect(controller.state.status, SyncPlayStatus.idle);
    expect(controller.state.group, isNull);
    expect(replacement.sent, isEmpty);
  });

  test('source, account and session changes individually invalidate late reads',
      () async {
    for (final next in [
      const SyncPlayIdentity(
          sourceId: 'server-b', userId: 'alice', sessionId: 'session-a'),
      const SyncPlayIdentity(
          sourceId: 'server-b', userId: 'bob', sessionId: 'session-a'),
      const SyncPlayIdentity(
          sourceId: 'server-b', userId: 'bob', sessionId: 'session-b'),
    ]) {
      final delayed = Completer<List<SyncPlayGroup>>();
      final active = server.client('pending-${server.clients.length}');
      await controller.switchIdentity(
          identity: identity, api: active, events: active.events.stream);
      active.listResult = delayed;
      final attempt = controller.createRoom('100003');
      await settle();
      final replacement = server.client('replacement-${server.clients.length}');
      await controller.switchIdentity(
          identity: next, api: replacement, events: replacement.events.stream);
      delayed.complete([]);
      await attempt;
      expect(controller.identity, next);
      expect(controller.state.status, SyncPlayStatus.idle);
    }
    expect(server.newCalls, 0);
  });

  test(
      'new command cancels old timer; duplicate and older commands cannot replay',
      () async {
    await readyRoom();
    final group = server.groupFor(alice)!;
    server.command(group, 'Unpause', delay: const Duration(seconds: 5));
    await world.advance(const Duration(milliseconds: 10));
    final pause =
        server.command(group, 'Pause', delay: const Duration(seconds: 1));
    alice.events.add(pause);
    await world.advance(const Duration(seconds: 6));
    expect(
        player.actions
            .where((a) => a.type == SyncPlayPlayerActionType.pause)
            .length,
        1);
    expect(
        player.actions.where((a) => a.type == SyncPlayPlayerActionType.unpause),
        isEmpty);
    alice.events.add(pause);
    await world.advance(Duration.zero);
    expect(
        player.actions
            .where((a) => a.type == SyncPlayPlayerActionType.pause)
            .length,
        1);
  });

  test(
      'queue instance IDs differ from media IDs and malformed payloads never execute',
      () async {
    await readyRoom();
    final group = server.groupFor(alice)!;
    final valid = server.command(group, 'Unpause');
    final data = Map<String, dynamic>.from(valid['Data'] as Map);
    for (final mutation in [
      {'PlaylistItemId': player.mediaId},
      {'GroupId': id(999)},
      {'PositionTicks': '120000000'},
      {'Command': 'Play'},
      {'When': '2026-10-23T12:00:00'},
    ]) {
      alice.events.add({
        'MessageType': 'SyncPlayCommand',
        'Data': {...data, ...mutation}
      });
    }
    // A later valid Pause supersedes the one valid scheduled Unpause.
    server.command(group, 'Pause');
    await world.advance(const Duration(seconds: 1));
    expect(
        player.actions.where((a) => a.type == SyncPlayPlayerActionType.unpause),
        isEmpty);
    expect(controller.state.failure?.code, SyncPlayFailureCode.protocol);
    expect(server.requests.where((r) => r.type == SyncPlayRequestType.unpause),
        isEmpty);
  });

  test('two entries for the same movie retain distinct queue instances',
      () async {
    await readyRoom();
    await world.advance(const Duration(milliseconds: 1));
    await controller.setQueue([id(71), id(71)], startIndex: 1);
    await settle();
    expect(controller.state.queue!.items[0].mediaId,
        controller.state.queue!.items[1].mediaId);
    expect(controller.state.queue!.items[0].playlistItemId,
        isNot(player.playlistItemId));
    expect(
        controller.state.queue!.current!.playlistItemId, player.playlistItemId);
  });

  test(
      'late Unpause extrapolates server position while Seek remains exact and reports Ready',
      () async {
    await readyRoom();
    final group = server.roomFor(alice)!;
    group.position = const Duration(seconds: 20);
    server.command(group.info(), 'Unpause', delay: const Duration(seconds: -2));
    await world.advance(Duration.zero);
    expect(player.position, const Duration(seconds: 22));
    group.position = const Duration(seconds: 33);
    server.command(group.info(), 'Seek', delay: const Duration(seconds: -2));
    await world.advance(Duration.zero);
    expect(player.position, const Duration(seconds: 33));
    expect(player.isPlaying, isFalse);
    expect(server.requests.last.type, SyncPlayRequestType.ready);
  });

  test(
      'buffer reports wait for completed load and use server clock plus queue ID',
      () async {
    final loaded = Completer<void>();
    player.loadResult = loaded;
    await controller.createRoom('001234');
    await settle();
    await controller.setQueue([id(71)]);
    await settle();
    expect(server.requests.where((r) => r.type == SyncPlayRequestType.ready),
        isEmpty);
    loaded.complete();
    await settle();
    player.buffering = true;
    await controller.reportBuffering(true);
    expect(server.requests.last.type, SyncPlayRequestType.buffering);
    expect(server.requests.last.body['PlaylistItemId'], player.playlistItemId);
    expect(server.requests.last.body['When'], world.now.toIso8601String());
    expect(server.requests.last.body['IsPlaying'], false);
  });

  test(
      'completed load with raw buffering withholds Ready until actual recovery',
      () async {
    player.buffering = true;
    await readyRoom();
    await controller.reportReady();
    expect(server.requests.where((r) => r.type == SyncPlayRequestType.ready),
        isEmpty);
    expect(
        server.requests.where((r) => r.type == SyncPlayRequestType.buffering),
        isEmpty); // The raw probe does not invent a sustained Buffer edge.
    player.buffering = false;
    await controller.reportBuffering(false);
    expect(server.requests.where((r) => r.type == SyncPlayRequestType.ready),
        hasLength(1));
    await controller.reportBuffering(false);
    expect(server.requests.where((r) => r.type == SyncPlayRequestType.ready),
        hasLength(1));
  });

  test('new queue Ready follows the already in-flight old queue Buffer',
      () async {
    await readyRoom();
    final previousId = player.playlistItemId;
    final before = server.requests.length;
    final buffered = Completer<void>();
    alice.onSend = (request) async {
      if (request.type == SyncPlayRequestType.buffering) {
        await buffered.future;
      }
    };
    player.buffering = true;
    final oldBuffer = controller.reportBuffering(true);
    await settle();
    await world.advance(const Duration(milliseconds: 1));
    await controller.setQueue([id(72)]);
    await settle();
    player.buffering = false;
    final recovered = controller.reportBuffering(false);
    expect(
        server.requests
            .skip(before)
            .where((r) => r.type == SyncPlayRequestType.ready),
        isEmpty);
    buffered.complete();
    await Future.wait([oldBuffer, recovered]);
    await settle();
    final reports = server.requests
        .skip(before)
        .where((r) =>
            r.type == SyncPlayRequestType.buffering ||
            r.type == SyncPlayRequestType.ready)
        .toList();
    expect(reports.map((r) => r.type),
        [SyncPlayRequestType.buffering, SyncPlayRequestType.ready]);
    expect(reports.first.body['PlaylistItemId'], previousId);
    expect(reports.last.body['PlaylistItemId'], player.playlistItemId);
    expect(player.playlistItemId, isNot(previousId));
  });

  test('Buffer and newer Ready are serialized and duplicate edges coalesce',
      () async {
    await readyRoom();
    final before = server.requests.length;
    final buffered = Completer<void>();
    final completed = <SyncPlayRequestType>[];
    var active = 0, maximumActive = 0;
    alice.onSend = (request) async {
      active++;
      if (active > maximumActive) maximumActive = active;
      if (request.type == SyncPlayRequestType.buffering) {
        await buffered.future;
      }
      completed.add(request.type);
      active--;
    };
    player.buffering = true;
    final first = controller.reportBuffering(true);
    final duplicate = controller.reportBuffering(true);
    await settle();
    player.buffering = false;
    final ready = controller.reportBuffering(false);
    await settle();
    expect(server.requests.skip(before).map((r) => r.type),
        [SyncPlayRequestType.buffering]);
    buffered.complete();
    await Future.wait([first, duplicate, ready]);
    expect(server.requests.skip(before).map((r) => r.type),
        [SyncPlayRequestType.buffering, SyncPlayRequestType.ready]);
    expect(
        completed, [SyncPlayRequestType.buffering, SyncPlayRequestType.ready]);
    expect(maximumActive, 1);
  });

  test('remote transient waiting does not echo Buffer or unnecessary Ready',
      () async {
    await readyRoom();
    final before = server.requests.length;
    player.onApply = (action) async {
      if (action.type != SyncPlayPlayerActionType.pause) return;
      player.buffering = true;
      // The player reporter filters this short true edge; its real false edge
      // still reaches the controller while the remote operation is pending.
      player.buffering = false;
      await controller.reportBuffering(false);
    };
    server.command(server.groupFor(alice)!, 'Pause');
    await world.advance(const Duration(milliseconds: 500));
    await world.advance(const Duration(seconds: 4));
    expect(server.requests.skip(before), isEmpty);
    expect(player.isPlaying, isFalse);
  });

  test('duplicate wakeups never retry a failed or ambiguous Buffer POST',
      () async {
    await readyRoom();
    final before = server.requests.length;
    final response = Completer<void>();
    alice.onSend = (request) async {
      if (request.type == SyncPlayRequestType.buffering) {
        await response.future;
      }
    };
    player.buffering = true;
    final first = controller.reportBuffering(true);
    await settle();
    final duplicate = controller.reportBuffering(true);
    await settle();
    response.completeError(const SyncPlayFailure(SyncPlayFailureCode.denied));
    await Future.wait([first, duplicate]);
    await settle();
    expect(server.requests.skip(before).map((r) => r.type),
        [SyncPlayRequestType.buffering]);
    expect(controller.state.failure?.code, SyncPlayFailureCode.denied);
  });

  test(
      'sustained remote stall sends Buffer but Ready waits for remote completion',
      () async {
    await readyRoom();
    final before = server.requests.length;
    final remote = Completer<void>();
    addTearDown(() {
      if (!remote.isCompleted) remote.complete();
    });
    player.onApply = (action) async {
      if (action.type == SyncPlayPlayerActionType.unpause) {
        player.buffering = true;
        await remote.future;
      }
    };
    server.command(server.groupFor(alice)!, 'Unpause');
    await world.advance(const Duration(milliseconds: 500));
    await controller.reportReady();
    expect(server.requests.skip(before), isEmpty);
    await world.advance(const Duration(seconds: 3));
    await controller.reportBuffering(true); // Matured reporter edge.
    expect(controller.isApplyingRemote, isTrue);
    expect(server.requests.skip(before).map((r) => r.type),
        [SyncPlayRequestType.buffering]);
    player.buffering = false;
    await controller.reportBuffering(false);
    expect(server.requests.skip(before).map((r) => r.type),
        [SyncPlayRequestType.buffering]);
    remote.complete();
    await settle();
    expect(server.requests.skip(before).map((r) => r.type),
        [SyncPlayRequestType.buffering, SyncPlayRequestType.ready]);
  });

  test(
      'fresh duplicate Seek corrects stale position; exact packet never replays',
      () async {
    await readyRoom();
    server.roomFor(alice)!.position = const Duration(seconds: 33);
    player.onApply = (action) async {
      if (action.type == SyncPlayPlayerActionType.seek) {
        player.position = const Duration(seconds: 10);
      }
    };
    final packet =
        server.command(server.groupFor(alice)!, 'Seek', delay: Duration.zero);
    await world.advance(Duration.zero);
    final before = player.actions.length;
    expect(player.position, const Duration(seconds: 10));
    alice.events.add(packet);
    await world.advance(Duration.zero);
    expect(player.actions.length, before);
    player.onApply = null;
    await world.advance(const Duration(milliseconds: 1));
    final correction = {
      'MessageType': 'SyncPlayCommand',
      'Data': {
        ...Map<String, dynamic>.from(packet['Data'] as Map),
        'EmittedAt': world.now.toIso8601String(),
      }
    };
    alice.events.add(correction);
    await world.advance(Duration.zero);
    expect(player.actions.length, before + 1);
    expect(player.position, const Duration(seconds: 33));
    final readyBefore = server.requests
        .where((r) => r.type == SyncPlayRequestType.ready)
        .length;
    await world.advance(const Duration(milliseconds: 1));
    final alignedCorrection = {
      ...correction,
      'Data': {
        ...Map<String, dynamic>.from(correction['Data'] as Map),
        'EmittedAt': world.now.toIso8601String(),
      }
    };
    alice.events.add(alignedCorrection);
    await world.advance(Duration.zero);
    expect(player.actions.length, before + 1);
    expect(
        server.requests
            .where((r) => r.type == SyncPlayRequestType.ready)
            .length,
        readyBefore + 1);
    alice.events.add(alignedCorrection);
    await world.advance(Duration.zero);
    expect(
        server.requests
            .where((r) => r.type == SyncPlayRequestType.ready)
            .length,
        readyBefore + 1);
  });

  test('fresh duplicate Unpause recovers paused player without a playing loop',
      () async {
    await readyRoom();
    final packet = server.command(server.groupFor(alice)!, 'Unpause',
        delay: Duration.zero);
    await world.advance(Duration.zero);
    final before = player.actions.length;
    player.isPlaying = false;
    alice.events.add(packet);
    await world.advance(Duration.zero);
    expect(player.actions.length, before);
    await world.advance(const Duration(milliseconds: 1));
    Map<String, dynamic> freshPacket() => {
          'MessageType': 'SyncPlayCommand',
          'Data': {
            ...Map<String, dynamic>.from(packet['Data'] as Map),
            'EmittedAt': world.now.toIso8601String(),
          }
        };
    alice.events.add(freshPacket());
    await world.advance(Duration.zero);
    expect(player.actions.length, before + 1);
    expect(player.isPlaying, isTrue);
    final reports = server.requests.length;
    await world.advance(const Duration(milliseconds: 1));
    alice.events.add(freshPacket());
    await world.advance(Duration.zero);
    expect(player.actions.length, before + 1);
    expect(server.requests.length, reports);
  });

  test(
      'fresh aligned Seek before Ready ack queues exactly one new acknowledgement',
      () async {
    await readyRoom();
    final before = server.requests.length;
    final firstReady = Completer<void>();
    var readyCalls = 0;
    alice.onSend = (request) async {
      if (request.type == SyncPlayRequestType.ready && ++readyCalls == 1) {
        await firstReady.future;
      }
    };
    final packet =
        server.command(server.groupFor(alice)!, 'Seek', delay: Duration.zero);
    await world.advance(Duration.zero);
    expect(readyCalls, 1);
    final actions = player.actions.length;
    await world.advance(const Duration(milliseconds: 1));
    final correction = {
      'MessageType': 'SyncPlayCommand',
      'Data': {
        ...Map<String, dynamic>.from(packet['Data'] as Map),
        'EmittedAt': world.now.toIso8601String(),
      }
    };
    alice.events.add(correction);
    alice.events.add(correction); // Exact duplicate does not queue a third ack.
    await settle();
    expect(readyCalls, 1);
    firstReady.complete();
    await settle();
    expect(readyCalls, 2);
    expect(player.actions.length, actions);
    expect(server.requests.skip(before).map((r) => r.type),
        [SyncPlayRequestType.ready, SyncPlayRequestType.ready]);
  });

  test('pending Ready and buffered HTTP cannot cross a new queue or identity',
      () async {
    player.buffering = true;
    await readyRoom();
    final previousId = player.playlistItemId;
    await world.advance(const Duration(milliseconds: 1));
    await controller.setQueue([id(72)]);
    await settle();
    player.buffering = false;
    await controller.reportBuffering(false);
    final ready = server.requests
        .where((r) => r.type == SyncPlayRequestType.ready)
        .toList();
    expect(ready, hasLength(1));
    expect(ready.single.body['PlaylistItemId'], player.playlistItemId);
    expect(player.playlistItemId, isNot(previousId));
    final buffered = Completer<void>();
    alice.onSend = (request) async {
      if (request.type == SyncPlayRequestType.buffering) {
        await buffered.future;
      }
    };
    player.buffering = true;
    final sending = controller.reportBuffering(true);
    await settle();
    player.buffering = false;
    final recovering = controller.reportBuffering(false);
    final replacement = server.client('replacement');
    await controller.switchIdentity(
        identity: const SyncPlayIdentity(
            sourceId: 'new-source', userId: 'replacement', sessionId: 'new'),
        api: replacement,
        events: replacement.events.stream);
    buffered.complete();
    await Future.wait([sending, recovering]);
    expect(replacement.sent, isEmpty);
    expect(server.requests.where((r) => r.type == SyncPlayRequestType.ready),
        hasLength(1));
  });

  test('raw waiting blocks pre-debounce drift and paused anchors never drift',
      () async {
    await readyRoom();
    server.command(server.groupFor(alice)!, 'Unpause');
    await world.advance(const Duration(milliseconds: 500));
    final before = player.actions.length;
    player.position -= const Duration(seconds: 5);
    player.buffering = true;
    await world.advance(const Duration(seconds: 3));
    expect(player.actions.length, before);
    player.buffering = false;
    await world.advance(const Duration(seconds: 3));
    expect(player.actions.length, before + 1);
    expect(player.isPlaying, isTrue);
    server.command(server.groupFor(alice)!, 'Pause');
    await world.advance(const Duration(milliseconds: 500));
    final paused = player.actions.length;
    player.position += const Duration(seconds: 5);
    await world.advance(const Duration(seconds: 9));
    expect(player.actions.length, paused);
    expect(player.isPlaying, isFalse);
  });

  test('bounded player failure cancels pending backend actions once', () async {
    await readyRoom();
    final cancellationsBeforeFailure = player.cancellations;
    final never = Completer<void>();
    addTearDown(() {
      if (!never.isCompleted) never.complete();
    });
    player.onApply = (_) => never.future;
    server.command(server.groupFor(alice)!, 'Seek');
    await world.advance(const Duration(milliseconds: 500));
    await world.advance(const Duration(seconds: 11));
    expect(player.cancellations, cancellationsBeforeFailure + 1);
    expect(controller.state.failure?.code, SyncPlayFailureCode.player);
  });

  test(
      'disconnect cancels commands and rejoin preserves room without recreating',
      () async {
    await readyRoom();
    final group = server.groupFor(alice)!;
    server.command(group, 'Unpause', delay: const Duration(seconds: 2));
    controller.setConnected(false);
    final calls = server.requests.length;
    await controller.requestPause();
    await world.advance(const Duration(seconds: 3));
    expect(server.requests.length, calls);
    expect(player.isPlaying, isFalse);
    expect(controller.state.group?.groupId, group.groupId);
    controller.setConnected(true);
    expect(controller.state.isJoined, isFalse);
    await controller.reconnect();
    await settle();
    expect(controller.state.canControl, isTrue);
    expect(server.newCalls, 1);
    expect(server.joinCalls, 1);
  });

  for (final invalidSample in [false, true]) {
    test(
        'deferred command waits for clock poll after ${invalidSample ? 'invalid sample' : 'time request failure'} without a retry loop',
        () async {
      await readyRoom();
      final initialCalls = alice.timeCalls;
      final heldRetry = Completer<SyncPlayServerTime>();
      var recover = false;
      addTearDown(() {
        if (!heldRetry.isCompleted) {
          heldRetry.complete(SyncPlayServerTime(
              requestReceptionTime: world.now,
              responseTransmissionTime: world.now));
        }
      });
      alice.onGetServerTime = () async {
        if (recover) {
          return SyncPlayServerTime(
              requestReceptionTime: world.now,
              responseTransmissionTime: world.now);
        }
        // Hold an erroneous second request so the pre-fix regression fails
        // deterministically rather than starving the test's microtask queue.
        if (alice.timeCalls > initialCalls + 1) return heldRetry.future;
        if (!invalidSample) {
          throw const SyncPlayFailure(SyncPlayFailureCode.server);
        }
        return SyncPlayServerTime(
            requestReceptionTime: world.now,
            responseTransmissionTime:
                world.now.add(const Duration(seconds: 1)));
      };
      controller.clock.reset();
      final actionsBefore = player.actions.length;
      final timeRead = controller.synchronizeClock();
      server.command(server.groupFor(alice)!, 'Unpause');
      await timeRead;
      await settle();
      expect(alice.timeCalls, initialCalls + 1,
          reason: 'a failed time read must not immediately drain into itself');
      expect(controller.state.clockSynchronized, false);
      expect(player.actions.length, actionsBefore);
      // A newer WS correction must not bypass the already scheduled poll.
      await world.advance(const Duration(milliseconds: 1));
      server.command(server.groupFor(alice)!, 'Unpause');
      await settle();
      expect(alice.timeCalls, initialCalls + 1);
      await world.advance(const Duration(milliseconds: 59998));
      expect(alice.timeCalls, initialCalls + 1);
      expect(player.isPlaying, false);
      recover = true;
      await world.advance(const Duration(milliseconds: 1));
      expect(alice.timeCalls, initialCalls + 2);
      expect(controller.state.canControl, true);
      expect(player.isPlaying, true);
      expect(server.newCalls, 1);
      expect(server.joinCalls, 0);
      await world.advance(const Duration(seconds: 1));
      expect(alice.timeCalls, initialCalls + 2);
    });
  }

  test('explicit reconnect cancels the failed-clock wait and synchronizes once',
      () async {
    await readyRoom();
    final initialCalls = alice.timeCalls;
    final heldRetry = Completer<SyncPlayServerTime>();
    var recover = false;
    addTearDown(() {
      if (!heldRetry.isCompleted) {
        heldRetry.complete(SyncPlayServerTime(
            requestReceptionTime: world.now,
            responseTransmissionTime: world.now));
      }
    });
    alice.onGetServerTime = () async {
      if (recover) {
        return SyncPlayServerTime(
            requestReceptionTime: world.now,
            responseTransmissionTime: world.now);
      }
      if (alice.timeCalls > initialCalls + 1) return heldRetry.future;
      throw const SyncPlayFailure(SyncPlayFailureCode.server);
    };
    controller.clock.reset();
    final timeRead = controller.synchronizeClock();
    server.command(server.groupFor(alice)!, 'Unpause');
    await timeRead;
    await settle();
    expect(alice.timeCalls, initialCalls + 1);
    controller.setConnected(false);
    controller.setConnected(true);
    recover = true;
    await controller.reconnect();
    await settle();
    expect(controller.state.canControl, true);
    expect(alice.timeCalls, initialCalls + 2);
    expect(server.newCalls, 1);
    expect(server.joinCalls, 1);
    await world.advance(const Duration(seconds: 59));
    expect(alice.timeCalls, initialCalls + 2,
        reason: 'the previous connection clock timer must remain cancelled');
  });

  test(
      'API errors are visible without leaking details or optimistic player changes',
      () async {
    await readyRoom();
    alice.sendError = const SyncPlayFailure(SyncPlayFailureCode.denied);
    await controller.requestUnpause();
    expect(controller.state.failure?.code, SyncPlayFailureCode.denied);
    expect(player.isPlaying, isFalse);
    expect(controller.state.failure.toString(), isNot(contains('token')));
  });

  test(
      'dispose cancels every owned timer and subscription, including in-flight join',
      () async {
    await readyRoom();
    server.command(server.groupFor(alice)!, 'Unpause',
        delay: const Duration(seconds: 9));
    expect(world.activeTimers, greaterThan(0));
    await controller.dispose();
    expect(world.activeTimers, 0);
    expect(alice.events.hasListener, isFalse);
    await world.advance(const Duration(minutes: 3));
    expect(player.isPlaying, isFalse);
    expect(controller.state.status, SyncPlayStatus.disposed);
    final other = makeController(world, alice, Player());
    alice.confirmJoins = false;
    final pending = other.joinRoom('001234');
    await settle();
    await other.dispose();
    await pending;
    expect(world.activeTimers, 0);
  });
  test(
      'stop waits for pending New before Leave and cannot resurrect membership',
      () async {
    final response = Completer<SyncPlayGroup>();
    alice.newResult = response;
    alice.confirmJoins = false;
    final creating = controller.createRoom('200001');
    await settle();
    final room = server.groupFor(alice)!;
    final leaving = controller.leaveRoom();
    await settle();
    expect(controller.state.status, SyncPlayStatus.leaving);
    expect(server.leaveCalls, 0);
    server.confirm(alice);
    response.complete(room);
    await creating;
    await leaving;
    expect(server.leaveCalls, 1);
    expect(server.groupFor(alice), isNull);
    expect(controller.state.status, SyncPlayStatus.idle);
    expect(player.actions, isEmpty);
  });

  test(
      'stop waits for pending Join and unfinished load cannot report Ready afterwards',
      () async {
    server.addGroup('JMS-200002');
    final response = Completer<void>();
    alice.joinResult = response;
    alice.confirmJoins = false;
    final joining = controller.joinRoom('200002');
    await settle();
    final leaving = controller.leaveRoom();
    await settle();
    expect(server.leaveCalls, 0);
    response.complete();
    await joining;
    await leaving;
    expect(controller.state.status, SyncPlayStatus.idle);
    expect(server.groupFor(alice), isNull);
    alice.joinResult = null;
    alice.confirmJoins = true;
    final loaded = Completer<void>();
    player.loadResult = loaded;
    await readyRoom();
    final before = server.requests
        .where((r) => r.type == SyncPlayRequestType.ready)
        .length;
    await controller.leaveRoom();
    loaded.complete();
    await settle();
    expect(
        server.requests
            .where((r) => r.type == SyncPlayRequestType.ready)
            .length,
        before);
    expect(controller.state.status, SyncPlayStatus.idle);
  });

  test('unknown pending New cannot claim Leave completed or issue another New',
      () async {
    alice.newResult = Completer<SyncPlayGroup>();
    alice.confirmJoins = false;
    final creating = controller.createRoom('200003');
    await settle();
    final leaving = controller.leaveRoom();
    await world.advance(const Duration(seconds: 11));
    await creating;
    await leaving;
    expect(controller.state.status, SyncPlayStatus.unknown);
    expect(server.leaveCalls, 0);
    await controller.createRoom('200004');
    expect(server.newCalls, 1);
  });

  test('reconnect cannot use an empty list to dismiss an unresolved New',
      () async {
    final pendingNew = Completer<SyncPlayGroup>();
    alice.newResult = pendingNew;
    alice.confirmJoins = false;
    final creating = controller.createRoom('200005');
    await settle();
    final created = server.groupFor(alice)!;
    addTearDown(() {
      if (!pendingNew.isCompleted) pendingNew.complete(created);
    });
    await world.advance(const Duration(seconds: 11));
    await creating;
    expect(controller.state.status, SyncPlayStatus.unknown);
    // A list read does not establish that a still in-flight mutation failed.
    alice.listResult = Completer<List<SyncPlayGroup>>()..complete([]);
    final reconnecting = controller.reconnect();
    await settle();
    await world.advance(const Duration(seconds: 11));
    await reconnecting;
    expect(controller.state.status, SyncPlayStatus.unknown);
    await controller.createRoom('200006');
    expect(server.newCalls, 1);
    expect(server.joinCalls, 0);

    // Once that exact request actually settles, an explicit reconcile can
    // safely list and join the original group without creating another one.
    alice.listResult = null;
    alice.confirmJoins = true;
    pendingNew.complete(created);
    await settle();
    await controller.reconnect();
    await settle();
    expect(controller.state.canControl, true);
    expect(controller.state.group?.groupId, created.groupId);
    expect(server.newCalls, 1);
    expect(server.joinCalls, 1);
  });

  test(
      'ambiguous New reconciles only positive membership and never empty absence',
      () async {
    final pendingNew = Completer<SyncPlayGroup>();
    alice.newResult = pendingNew;
    alice.confirmJoins = false;
    final creating = controller.createRoom('200007');
    await settle();
    final created = server.groupFor(alice)!;
    pendingNew.completeError(
        const SyncPlayFailure(SyncPlayFailureCode.timeoutUnknown));
    await creating;
    expect(controller.state.status, SyncPlayStatus.unknown);
    alice.listResult = Completer<List<SyncPlayGroup>>()..complete([]);
    await controller.reconnect();
    expect(controller.state.status, SyncPlayStatus.unknown);
    await controller.createRoom('200008');
    expect(server.newCalls, 1);
    alice.listResult = null;
    alice.confirmJoins = true;
    await controller.reconnect();
    await settle();
    expect(controller.state.canControl, true);
    expect(controller.state.group?.groupId, created.groupId);
    expect(server.newCalls, 1);
    expect(server.joinCalls, 1);
  });

  test(
      'natural drift corrects over threshold, preserves playing and never echoes',
      () async {
    await readyRoom();
    server.command(server.groupFor(alice)!, 'Unpause');
    await world.advance(const Duration(milliseconds: 500));
    player.onApply = (_) => controller.requestSeek(const Duration(seconds: 99));
    final initial = player.actions.length;
    await world.advance(const Duration(seconds: 3));
    expect(player.actions.length, initial);
    player.position -= const Duration(seconds: 2);
    await world.advance(const Duration(seconds: 3));
    expect(player.actions.last.type, SyncPlayPlayerActionType.unpause);
    expect(player.position, const Duration(seconds: 18));
    expect(player.isPlaying, isTrue);
    expect(server.requests.where((r) => r.type == SyncPlayRequestType.seek),
        isEmpty);
  });

  test('fresh Pause supersedes drift anchor and large corrections are bounded',
      () async {
    await readyRoom();
    server.command(server.groupFor(alice)!, 'Unpause');
    await world.advance(const Duration(milliseconds: 500));
    player.position = const Duration(seconds: 200);
    await world.advance(const Duration(seconds: 3));
    expect(player.position, const Duration(seconds: 173));
    server.roomFor(alice)!.position = const Duration(seconds: 44);
    server.command(server.groupFor(alice)!, 'Pause');
    await world.advance(const Duration(milliseconds: 500));
    final unpauses = player.actions
        .where((a) => a.type == SyncPlayPlayerActionType.unpause)
        .length;
    await world.advance(const Duration(seconds: 4));
    expect(player.position, const Duration(seconds: 44));
    expect(player.isPlaying, isFalse);
    expect(
        player.actions
            .where((a) => a.type == SyncPlayPlayerActionType.unpause)
            .length,
        unpauses);
  });

  test(
      'participant events refresh authoritative membership without replacing queue',
      () async {
    await readyRoom();
    final queue = controller.state.queue;
    final bob = server.client('bob');
    final room = server.roomFor(alice)!;
    room.members.add(bob);
    server.update(alice, room, 'UserJoined', 'bob');
    await settle();
    expect(controller.state.group!.participants, ['alice', 'bob']);
    expect(controller.state.queue, same(queue));
    room.members.remove(bob);
    server.update(alice, room, 'UserLeft', 'bob');
    await settle();
    expect(controller.state.group!.participants, ['alice']);
    expect(controller.state.queue, same(queue));
  });

  test('malformed message is visible but does not fake a transport disconnect',
      () async {
    await readyRoom();
    alice.events.addError(const SyncPlayFailure(SyncPlayFailureCode.protocol));
    await settle();
    expect(controller.state.connected, isTrue);
    expect(controller.state.failure?.code, SyncPlayFailureCode.protocol);
    await controller.requestPause();
    expect(server.requests.last.type, SyncPlayRequestType.pause);
  });
}

SyncPlayController makeController(World world, Api api, Player player,
        {Duration skew = Duration.zero}) =>
    SyncPlayController(
        identity: identity,
        api: api,
        player: player,
        events: api.events.stream,
        isPlayerBuffering: () => player.buffering,
        cancelPendingPlayerActions: () => player.cancellations++,
        clock: SyncPlayClock(now: () => world.now.add(skew)),
        scheduler: world);

class Job implements SyncPlayCancellation {
  Job(this.when, this.callback);
  final DateTime when;
  final void Function() callback;
  bool cancelled = false;
  @override
  void cancel() => cancelled = true;
}

class World implements SyncPlayScheduler {
  DateTime now = DateTime.utc(2026, 10, 23, 12);
  final jobs = <Job>[];
  int get activeTimers => jobs.where((job) => !job.cancelled).length;
  @override
  Job schedule(Duration delay, void Function() callback) {
    final job = Job(now.add(delay), callback);
    jobs.add(job);
    return job;
  }

  Future<void> advance(Duration duration) async {
    final until = now.add(duration);
    await settle();
    while (jobs.any((job) => !job.cancelled && !job.when.isAfter(until))) {
      final next = jobs
          .where((job) => !job.cancelled && !job.when.isAfter(until))
          .reduce((a, b) => a.when.isBefore(b.when) ? a : b);
      now = next.when;
      next.cancelled = true;
      next.callback();
      await settle();
    }
    now = until;
    await settle();
  }
}

class Room {
  Room(this.groupId, this.groupName, this.updated);
  final String groupId, groupName;
  DateTime updated;
  final members = <Api>[];
  List<Map<String, dynamic>> playlist = [];
  int index = 0;
  Duration position = Duration.zero;
  SyncPlayGroup info() => SyncPlayGroup(
      groupId: groupId,
      groupName: groupName,
      lastUpdatedAt: updated,
      participants: members.map((api) => api.name).toList());
}

class Server {
  Server(this.world);
  final World world;
  final clients = <Api>[];
  final groups = <Room>[];
  final requests = <SyncPlayRequest>[];
  int newCalls = 0, joinCalls = 0, leaveCalls = 0, nextId = 100;
  Api client(String name) {
    final api = Api(this, name);
    clients.add(api);
    return api;
  }

  Room addGroup(String name) {
    final group = Room(id(nextId++), name, world.now);
    groups.add(group);
    return group;
  }

  Room? roomFor(Api api) {
    for (final group in groups) {
      if (group.members.contains(api)) return group;
    }
    return null;
  }

  SyncPlayGroup? groupFor(Api api) => roomFor(api)?.info();
  void update(Api api, Room group, String type, Object? data) =>
      api.events.add({
        'MessageType': 'SyncPlayGroupUpdate',
        'Data': {'GroupId': group.groupId, 'Type': type, 'Data': data}
      });
  void confirm(Api api) {
    final group = roomFor(api)!;
    group.updated = world.now;
    update(api, group, 'GroupJoined', {
      'GroupId': group.groupId,
      'GroupName': group.groupName,
      'State': 'Paused',
      'Participants': group.members.map((api) => api.name).toList(),
      'LastUpdatedAt': group.updated.toIso8601String()
    });
    if (group.playlist.isNotEmpty) queue(api, group);
  }

  void queue(Api api, Room group) => update(api, group, 'PlayQueue', {
        'Reason': 'NewPlaylist',
        'LastUpdate': group.updated.toIso8601String(),
        'Playlist': group.playlist,
        'PlayingItemIndex': group.index,
        'StartPositionTicks': syncPlayTicks(group.position),
        'IsPlaying': false,
      });
  Map<String, dynamic> command(SyncPlayGroup info, String type,
      {Duration delay = const Duration(milliseconds: 500)}) {
    final group = groups.singleWhere((r) => r.groupId == info.groupId);
    final event = <String, dynamic>{
      'MessageType': 'SyncPlayCommand',
      'Data': {
        'GroupId': group.groupId,
        'PlaylistItemId': group.playlist.isEmpty
            ? id(0)
            : group.playlist[group.index]['PlaylistItemId'],
        'Command': type,
        'When': world.now.add(delay).toIso8601String(),
        'EmittedAt': world.now.toIso8601String(),
        'PositionTicks': syncPlayTicks(group.position),
      }
    };
    for (final api in group.members) {
      api.events.add(event);
    }
    return event;
  }
}

class Api implements SyncPlayApiPort {
  Api(this.server, this.name);
  final Server server;
  final String name;
  final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final sent = <SyncPlayRequest>[];
  bool confirmJoins = true;
  Completer<SyncPlayGroup>? newResult;
  Completer<void>? joinResult;
  Completer<List<SyncPlayGroup>>? listResult;
  Object? sendError;
  Future<void> Function(SyncPlayRequest)? onSend;
  int timeCalls = 0;
  Future<SyncPlayServerTime> Function()? onGetServerTime;
  @override
  Future<List<SyncPlayGroup>> listGroups() async {
    if (listResult != null) return listResult!.future;
    return server.groups.map((r) => r.info()).toList();
  }

  @override
  Future<SyncPlayGroup> newGroup(String name) async {
    server.newCalls++;
    final group = server.addGroup(name)..members.add(this);
    if (confirmJoins) server.confirm(this);
    if (newResult != null) return newResult!.future;
    return group.info();
  }

  @override
  Future<void> joinGroup(String groupId) async {
    server.joinCalls++;
    final group =
        server.groups.singleWhere((group) => group.groupId == groupId);
    if (!group.members.contains(this)) group.members.add(this);
    if (confirmJoins) server.confirm(this);
    await joinResult?.future;
  }

  @override
  Future<void> leaveGroup() async {
    server.leaveCalls++;
    final group = server.roomFor(this);
    if (group != null) {
      group.members.remove(this);
      server.update(this, group, 'GroupLeft', group.groupId);
    }
  }

  @override
  Future<SyncPlayServerTime> getServerTime() async {
    timeCalls++;
    if (onGetServerTime != null) return onGetServerTime!();
    return SyncPlayServerTime(
        requestReceptionTime: server.world.now,
        responseTransmissionTime: server.world.now);
  }

  @override
  Future<void> sendRequest(SyncPlayRequest request) async {
    if (sendError != null) throw sendError!;
    sent.add(request);
    server.requests.add(request);
    await onSend?.call(request);
    final group = server.roomFor(this)!;
    switch (request.type) {
      case SyncPlayRequestType.setNewQueue:
        group.playlist = (request.body['PlayingQueue'] as List)
            .map((media) => <String, dynamic>{
                  'ItemId': media,
                  'PlaylistItemId': id(server.nextId++)
                })
            .toList();
        group.index = request.body['PlayingItemPosition'] as int;
        group.position = syncPlayPosition(request.body['StartPositionTicks']);
        group.updated = server.world.now;
        for (final api in group.members) {
          server.queue(api, group);
        }
      case SyncPlayRequestType.pause:
        server.command(group.info(), 'Pause');
      case SyncPlayRequestType.unpause:
        server.command(group.info(), 'Unpause');
      case SyncPlayRequestType.seek:
        group.position = syncPlayPosition(request.body['PositionTicks']);
        server.command(group.info(), 'Seek');
      case SyncPlayRequestType.buffering:
      case SyncPlayRequestType.ready:
      case SyncPlayRequestType.ping:
        break;
    }
  }
}

class Player implements SyncPlayPlayerPort {
  Player([this.world]);
  final World? world;
  @override
  String? mediaId;
  @override
  String? playlistItemId;
  Duration _position = Duration.zero;
  DateTime? _positionAt;
  @override
  Duration get position =>
      _position +
      (isPlaying && world != null && _positionAt != null
          ? world!.now.difference(_positionAt!)
          : Duration.zero);
  set position(Duration value) {
    _position = value;
    _positionAt = world?.now;
  }

  @override
  bool isPlaying = false;
  bool buffering = false;
  int cancellations = 0;
  final actions = <SyncPlayPlayerAction>[];
  Future<void> Function(SyncPlayPlayerAction)? onApply;
  Completer<void>? loadResult;
  @override
  Future<void> applyRemote(SyncPlayPlayerAction action) async {
    actions.add(action);
    position = action.position;
    switch (action.type) {
      case SyncPlayPlayerActionType.load:
        mediaId = action.queueItem!.mediaId;
        playlistItemId = action.queueItem!.playlistItemId;
        isPlaying = false;
        await loadResult?.future;
      case SyncPlayPlayerActionType.unpause:
        isPlaying = true;
      case SyncPlayPlayerActionType.pause:
      case SyncPlayPlayerActionType.seek:
      case SyncPlayPlayerActionType.stop:
        isPlaying = false;
    }
    await onApply?.call(action);
  }
}
