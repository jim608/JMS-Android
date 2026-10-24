import 'dart:async';

import 'package:fladder/services/syncplay/syncplay_clock.dart';
import 'package:fladder/services/syncplay/syncplay_controller.dart';
import 'package:fladder/services/syncplay/syncplay_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/syncplay_wait_server.dart';

class AdaptiveRoom {
  AdaptiveRoom() {
    server = WaitServer(time);
    a = WaitApi(server, 'synthetic-a');
    b = WaitApi(server, 'synthetic-b');
    p = WaitPlayer(time);
    q = WaitPlayer(time);
    first = controller(a, p, () => ready);
    second = controller(b, q, () => true);
  }
  final time = WaitClock();
  late final WaitServer server;
  late final WaitApi a, b;
  late final WaitPlayer p, q;
  late final SyncPlayController first, second;
  bool ready = true;
  Duration ahead = const Duration(seconds: 8);
  SyncPlayController controller(
          WaitApi api, WaitPlayer player, bool Function() ready) =>
      SyncPlayController(
          identity: SyncPlayIdentity(
              sourceId: 'synthetic', userId: api.name, sessionId: api.name),
          api: api,
          player: player,
          events: api.events.stream,
          clock: SyncPlayClock(now: () => time.now),
          scheduler: time,
          isPlayerBuffering: () => player.buffering,
          cancelPendingPlayerActions: player.cancelPending,
          mediaReadiness: ready,
          bufferedAhead: () => ahead,
          targetBufferedAhead: () => const Duration(seconds: 8),
          slowWaitBudget: const Duration(seconds: 2),
          operationTimeout: const Duration(seconds: 5));
  Future<void> open({bool seed = true}) async {
    await first.createRoom('001234');
    await second.joinRoom('001234');
    await flushTasks();
    if (seed) {
      server.seedQueue();
      await time.advance(const Duration(milliseconds: 50));
    }
  }

  Future<void> starve() async {
    ready = false;
    ahead = const Duration(milliseconds: 100);
    p.buffering = true;
    p.isPlaying = false;
    await first.reportBuffering(true);
    await time.advance(const Duration(milliseconds: 50));
  }

  Iterable<SyncPlayRequest> get requests => server.requests.map((x) => x.$2);
  Future<void> close() async {
    await first.dispose();
    await second.dispose();
    await a.events.close();
    await b.events.close();
  }
}

void main() {
  late AdaptiveRoom f;
  setUp(() => f = AdaptiveRoom());
  tearDown(() async => f.close());

  for (final rawStarvation in [false, true]) {
    test(
        'scheduled Unpause rechecks ${rawStarvation ? 'raw buffering' : 'media policy'} at execution',
        () async {
      await f.open();
      f.server.pause();
      await f.time.advance(Duration.zero);
      final before = f.p.actions
          .where((a) => a.type == SyncPlayPlayerActionType.unpause)
          .length;
      f.server.state = 'Playing';
      f.server.anchorPosition = const Duration(seconds: 20);
      f.server.anchorWhen = f.time.now.add(const Duration(seconds: 1));
      f.server.command('Unpause', only: f.a);
      await flushTasks();
      if (rawStarvation) {
        f.p.buffering = true;
      } else {
        f.ready = false;
        f.ahead = Duration.zero;
      }
      await f.time.advance(const Duration(seconds: 1));
      expect(f.p.isPlaying, isFalse);
      expect(
          f.p.actions.where((a) => a.type == SyncPlayPlayerActionType.unpause),
          hasLength(before));
      f.ready = true;
      f.ahead = const Duration(seconds: 8);
      f.p.buffering = false;
      await f.first.notifyMediaReadinessChanged();
      await f.time.advance(Duration.zero);
      expect(f.p.isPlaying, isTrue);
      expect(f.p.position, const Duration(seconds: 20));
      expect(f.requests.where((r) => r.type == SyncPlayRequestType.unpause),
          isEmpty);
    });
  }

  test(
      'new Pause supersedes a scheduled Unpause deferred at its start deadline',
      () async {
    await f.open();
    f.server.pause();
    await f.time.advance(Duration.zero);
    final before = f.p.actions
        .where((a) => a.type == SyncPlayPlayerActionType.unpause)
        .length;
    f.server.state = 'Playing';
    f.server.anchorPosition = const Duration(seconds: 20);
    f.server.anchorWhen = f.time.now.add(const Duration(seconds: 1));
    f.server.command('Unpause', only: f.a);
    await flushTasks();
    f.ready = false;
    await f.time.advance(const Duration(seconds: 1));
    f.server.pause();
    await f.time.advance(Duration.zero);
    f.ready = true;
    await f.first.notifyMediaReadinessChanged();
    await f.time.advance(const Duration(milliseconds: 100));
    expect(f.p.isPlaying, isFalse);
    expect(f.p.actions.where((a) => a.type == SyncPlayPlayerActionType.unpause),
        hasLength(before));
    expect(f.requests.where((r) => r.type == SyncPlayRequestType.unpause),
        isEmpty);
  });

  test('successful replacement load clears only the previous player failure',
      () async {
    await f.open(seed: false);
    f.p.beforeApply = (action) async {
      if (action.type == SyncPlayPlayerActionType.load) {
        throw StateError('synthetic unavailable first media');
      }
    };
    f.server.seedQueue(71);
    await flushTasks();
    expect(f.first.state.failure?.code, SyncPlayFailureCode.player);
    f.p.beforeApply = null;
    f.server.seedQueue(99);
    await f.time.advance(const Duration(milliseconds: 50));
    expect(f.first.state.failure, isNull);
    expect(f.p.mediaId, wireId(99));
    expect(f.p.isPlaying, isTrue);
  });

  test('load completion rotates sample epoch without resetting total wait',
      () async {
    await f.open(seed: false);
    final gate = Completer<void>();
    f.p.beforeApply = (action) async {
      if (action.type == SyncPlayPlayerActionType.load) await gate.future;
    };
    f.server.seedQueue();
    await flushTasks();
    expect(f.first.isLoading, isTrue);
    final loadingEpoch = f.first.mediaBufferEpoch;
    gate.complete();
    await flushTasks();
    expect(f.first.isLoading, isFalse);
    expect(f.first.mediaBufferEpoch, greaterThan(loadingEpoch));
  });

  test(
      'two clients: bounded raw starvation releases peers and recovers only locally',
      () async {
    await f.open();
    expect(f.p.isPlaying, isTrue);
    expect(f.q.isPlaying, isTrue);
    await f.starve();
    expect(f.server.state, 'Waiting');
    expect(f.q.isPlaying, isFalse);
    await f.time.advance(const Duration(seconds: 2));
    await f.time.advance(const Duration(milliseconds: 50));
    expect(f.server.members[f.a]!.ignored, isTrue);
    expect(f.q.isPlaying, isTrue);
    expect(f.p.isPlaying, isFalse);
    final buffers =
        f.requests.where((r) => r.type == SyncPlayRequestType.buffering).length;
    await f.first.reportBuffering(true);
    await f.time.advance(const Duration(seconds: 10));
    expect(f.requests.where((r) => r.type == SyncPlayRequestType.buffering),
        hasLength(buffers));
    f.ready = true;
    f.ahead = const Duration(seconds: 8);
    f.p.buffering = false;
    await f.first.reportBuffering(false);
    await f.first.notifyMediaReadinessChanged();
    await f.time.advance(const Duration(milliseconds: 50));
    expect(f.p.isPlaying, isTrue);
    expect((f.p.position - f.q.position).abs(),
        lessThanOrEqualTo(const Duration(milliseconds: 500)));
    expect(f.first.state.waitParticipation,
        SyncPlayWaitParticipation.ignoredRecovered);
    final recoveredRequests = f.server.requests.length;
    for (var i = 0; i < 3; i++) {
      await f.first.notifyMediaReadinessChanged();
      await f.time.advance(const Duration(milliseconds: 500));
      expect(f.first.state.waitParticipation,
          SyncPlayWaitParticipation.ignoredRecovered,
          reason: 'Stable buffer polls must not restart catch-up');
    }
    expect(f.server.requests.length, recoveredRequests);
    expect(f.server.members[f.a]!.ignored, isTrue,
        reason:
            'Playing Ready does not prove the old server buffer flag cleared');
    expect(
        f.requests.where((r) => [
              SyncPlayRequestType.pause,
              SyncPlayRequestType.unpause,
              SyncPlayRequestType.seek
            ].contains(r.type)),
        isEmpty);
    expect(
        f.requests.where((r) =>
            r.type == SyncPlayRequestType.setIgnoreWait &&
            r.body['IgnoreWait'] == false),
        isEmpty);
  });

  test(
      'short native false with inadequate ahead does not fabricate Ready or Buffer',
      () async {
    await f.open();
    await f.starve();
    final readyBefore =
        f.requests.where((r) => r.type == SyncPlayRequestType.ready).length;
    final buffers =
        f.requests.where((r) => r.type == SyncPlayRequestType.buffering).length;
    f.p.buffering = false;
    await f.first.reportBuffering(false);
    await f.first.notifyMediaReadinessChanged();
    await f.time.advance(const Duration(milliseconds: 100));
    expect(f.requests.where((r) => r.type == SyncPlayRequestType.ready),
        hasLength(readyBefore));
    expect(f.requests.where((r) => r.type == SyncPlayRequestType.buffering),
        hasLength(buffers));
    expect(f.server.state, 'Waiting');
    expect(f.first.state.mediaReady, isFalse);
    expect(f.first.state.bufferedAhead, const Duration(milliseconds: 100));
  });

  test('initial prebuffer gates Ready without manufacturing Buffer', () async {
    f.ready = false;
    await f.open();
    expect(f.server.state, 'Waiting');
    expect(
        f.server.requests.where(
            (x) => x.$1 == f.a && x.$2.type == SyncPlayRequestType.ready),
        isEmpty);
    expect(f.requests.where((r) => r.type == SyncPlayRequestType.buffering),
        isEmpty);
    f.ready = true;
    await f.first.notifyMediaReadinessChanged();
    await f.time.advance(const Duration(milliseconds: 50));
    expect(f.p.isPlaying, isTrue);
    expect(f.q.isPlaying, isTrue);
  });

  test(
      'loading has its own bounded budget and can bypass before load completes',
      () async {
    final gate = Completer<void>();
    f.p.beforeApply = (a) async {
      if (a.type == SyncPlayPlayerActionType.load) await gate.future;
    };
    await f.open();
    await f.time.advance(const Duration(seconds: 2));
    await f.time.advance(const Duration(milliseconds: 50));
    expect(f.server.members[f.a]!.ignored, isTrue);
    expect(f.q.isPlaying, isTrue);
    expect(f.first.state.failure, isNull);
    gate.complete();
    await flushTasks();
    await f.first.notifyMediaReadinessChanged();
    await f.time.advance(const Duration(milliseconds: 50));
    expect(f.p.isPlaying, isTrue);
  });

  test('new authoritative Pause cancels deferred catchup', () async {
    await f.open();
    await f.starve();
    await f.time.advance(const Duration(seconds: 2));
    await f.time.advance(const Duration(milliseconds: 50));
    f.server.pause();
    await flushTasks();
    final before = f.p.actions
        .where((a) => a.type == SyncPlayPlayerActionType.unpause)
        .length;
    f.ready = true;
    f.p.buffering = false;
    await f.first.reportBuffering(false);
    await f.first.notifyMediaReadinessChanged();
    await f.time.advance(const Duration(seconds: 1));
    expect(f.p.isPlaying, isFalse);
    expect(f.q.isPlaying, isFalse);
    expect(f.p.actions.where((a) => a.type == SyncPlayPlayerActionType.unpause),
        hasLength(before));
    expect(f.requests.where((r) => r.type == SyncPlayRequestType.unpause),
        isEmpty);
  });

  test('late Buffer acknowledgement is settled before IgnoreWait mutation',
      () async {
    await f.open();
    final gate = Completer<void>();
    f.a.beforeRequest = (r) async {
      if (r.type == SyncPlayRequestType.buffering) await gate.future;
    };
    f.ready = false;
    f.p.buffering = true;
    final report = f.first.reportBuffering(true);
    await flushTasks();
    await f.time.advance(const Duration(seconds: 2));
    expect(f.first.state.waitParticipation, SyncPlayWaitParticipation.ignoring);
    expect(f.server.members[f.a]!.ignored, isFalse);
    gate.complete();
    await report;
    await flushTasks();
    await f.time.advance(const Duration(milliseconds: 50));
    expect(f.server.members[f.a]!.ignored, isTrue);
    final relevant = f.server.applied
        .where((r) =>
            r == SyncPlayRequestType.buffering ||
            r == SyncPlayRequestType.setIgnoreWait)
        .toList();
    expect(relevant,
        [SyncPlayRequestType.buffering, SyncPlayRequestType.setIgnoreWait]);
    expect(f.q.isPlaying, isTrue);
  });

  test('ambiguous IgnoreWait suppresses Buffer and blocks membership mutations',
      () async {
    await f.open();
    final gate = Completer<void>();
    f.a.afterRequest = (r) async {
      if (r.type == SyncPlayRequestType.setIgnoreWait) await gate.future;
    };
    await f.starve();
    await f.time.advance(const Duration(seconds: 8));
    expect(
        f.first.state.waitParticipation, SyncPlayWaitParticipation.uncertain);
    final before =
        f.requests.where((r) => r.type == SyncPlayRequestType.buffering).length;
    await f.first.reportBuffering(true);
    expect(f.requests.where((r) => r.type == SyncPlayRequestType.buffering),
        hasLength(before));
    final leaving = f.first.leaveRoom();
    await flushTasks();
    await f.time.advance(const Duration(seconds: 6));
    await leaving;
    expect(f.server.leaves, 0);
    expect(f.first.state.status, SyncPlayStatus.unknown);
    gate.complete();
    await flushTasks();
    final joins = f.server.joins;
    await f.first.reconnect();
    expect(f.server.joins, joins + 1,
        reason:
            'only the exact settled acknowledgement releases the membership barrier');
    expect(f.server.members[f.a]!.ignored, isTrue,
        reason:
            'restoring the same session must preserve its server ignore flag');
  });

  test('unsupported API is explicit and never repeatedly retried', () async {
    await f.open();
    f.a.beforeRequest = (r) async {
      if (r.type == SyncPlayRequestType.setIgnoreWait) {
        throw const SyncPlayFailure(SyncPlayFailureCode.unsupported);
      }
    };
    await f.starve();
    await f.time.advance(const Duration(seconds: 8));
    expect(
        f.first.state.waitParticipation, SyncPlayWaitParticipation.unsupported);
    expect(f.first.state.failure?.code, SyncPlayFailureCode.unsupported);
    expect(f.requests.where((r) => r.type == SyncPlayRequestType.setIgnoreWait),
        hasLength(1));
    expect(f.server.members[f.a]!.ignored, isFalse);
  });

  test('disconnect and late ignore ACK cannot resume local playback', () async {
    await f.open();
    final gate = Completer<void>();
    f.a.afterRequest = (r) async {
      if (r.type == SyncPlayRequestType.setIgnoreWait) await gate.future;
    };
    await f.starve();
    await f.time.advance(const Duration(seconds: 2));
    f.first.setConnected(false);
    final count = f.p.actions.length;
    f.ready = true;
    f.p.buffering = false;
    gate.complete();
    await flushTasks();
    await f.first.notifyMediaReadinessChanged();
    await f.time.advance(const Duration(seconds: 1));
    expect(f.first.state.connected, isFalse);
    expect(f.p.actions, hasLength(count));
  });

  test('late previous identity ACK cannot mutate the replacement state',
      () async {
    await f.open();
    final gate = Completer<void>();
    f.a.afterRequest = (r) async {
      if (r.type == SyncPlayRequestType.setIgnoreWait) await gate.future;
    };
    await f.starve();
    await f.time.advance(const Duration(seconds: 2));
    final replacement = WaitApi(f.server, 'replacement');
    await f.first.switchIdentity(
        identity: const SyncPlayIdentity(
            sourceId: 'other-synthetic', userId: 'other', sessionId: 'other'),
        api: replacement,
        events: replacement.events.stream);
    gate.complete();
    await flushTasks();
    expect(f.first.state.status, SyncPlayStatus.idle);
    expect(
        f.first.state.waitParticipation, SyncPlayWaitParticipation.following);
    expect(f.server.requests.where((r) => r.$1 == replacement), isEmpty);
    await replacement.events.close();
  });

  test('buffer revision changes on queue and seek, not ticks or pause/unpause',
      () async {
    await f.open();
    final epoch = f.first.mediaBufferEpoch;
    await f.first.notifyMediaReadinessChanged();
    await f.time.advance(const Duration(milliseconds: 100));
    f.server.pause();
    await flushTasks();
    expect(f.first.mediaBufferEpoch, epoch);
    f.server.command('Unpause', only: f.a);
    await flushTasks();
    expect(f.first.mediaBufferEpoch, epoch);
    f.server.anchorPosition = const Duration(seconds: 40);
    f.server.anchorWhen = f.time.now;
    f.server.command('Seek', only: f.a);
    await flushTasks();
    expect(f.first.mediaBufferEpoch, greaterThan(epoch));
    final seekEpoch = f.first.mediaBufferEpoch;
    f.server.seedQueue(99);
    await flushTasks();
    expect(f.first.mediaBufferEpoch, greaterThan(seekEpoch));
  });

  test(
      'unreachable local catchup is bounded and sends no room playback command',
      () async {
    await f.open();
    await f.starve();
    await f.time.advance(const Duration(seconds: 2));
    f.p.refuseUnpause = true;
    f.ready = true;
    f.p.buffering = false;
    final before = f.p.actions
        .where((a) => a.type == SyncPlayPlayerActionType.unpause)
        .length;
    await f.first.reportBuffering(false);
    await f.first.notifyMediaReadinessChanged();
    await f.time.advance(const Duration(seconds: 1));
    final after = f.p.actions
        .where((a) => a.type == SyncPlayPlayerActionType.unpause)
        .length;
    expect(after - before, lessThanOrEqualTo(2));
    expect(f.p.isPlaying, isFalse);
    expect(f.first.state.waitParticipation,
        isNot(SyncPlayWaitParticipation.ignoredRecovered));
    expect(
        f.requests.where((r) =>
            r.type == SyncPlayRequestType.unpause ||
            r.type == SyncPlayRequestType.seek),
        isEmpty);
  });

  test(
      'empty credential-scoped group list marks last-known membership uncertain',
      () async {
    await f.open();
    final previous = f.first.state.group;
    f.a.listOverride = [];
    await f.first.refreshMembership();
    expect(f.first.state.group, same(previous));
    expect(f.first.state.status, SyncPlayStatus.unknown);
    expect(f.first.state.canControl, isFalse);
    expect(f.first.state.membershipFreshness,
        SyncPlayMembershipFreshness.uncertain);
    expect(f.first.state.membershipCheckAge, Duration.zero);
    expect(f.server.leaves, 0);
    expect(
        f.requests.where((r) =>
            r.type == SyncPlayRequestType.pause ||
            r.type == SyncPlayRequestType.unpause),
        isEmpty);
  });

  test('old queue load completion cannot release Ready into its replacement',
      () async {
    await f.open(seed: false);
    final gate = Completer<void>();
    f.p.beforeApply = (a) async {
      if (a.type == SyncPlayPlayerActionType.load &&
          a.queueItem?.mediaId == wireId(71)) {
        await gate.future;
      }
    };
    f.server.seedQueue(71);
    await flushTasks();
    await f.time.advance(const Duration(seconds: 2));
    f.ready = false;
    f.server.seedQueue(99);
    await flushTasks();
    f.ready = true;
    await f.first.notifyMediaReadinessChanged();
    await f.time.advance(const Duration(milliseconds: 50));
    final before = f.server.requests.length;
    final epoch = f.first.mediaBufferEpoch;
    gate.complete();
    await flushTasks();
    expect(f.first.mediaBufferEpoch, epoch);
    expect(f.p.mediaId, wireId(99));
    expect(
        f.server.requests.skip(before).where((x) =>
            x.$1 == f.a &&
            x.$2.type == SyncPlayRequestType.ready &&
            x.$2.body['PlaylistItemId'] == wireId(1071)),
        isEmpty);
  });

  test('repeated corrective Seek cannot reset the ignored catchup budget',
      () async {
    await f.open();
    await f.starve();
    await f.time.advance(const Duration(seconds: 2));
    f.ready = true;
    f.p.buffering = false;
    f.p.refuseSeek = true;
    f.p.refuseUnpause = true;
    final start = f.p.actions.length;
    f.server.anchorPosition = const Duration(seconds: 200);
    f.server.anchorWhen = f.time.now;
    for (var i = 0; i < 5; i++) {
      f.server.command('Seek', only: f.a);
      await flushTasks();
      await f.time.advance(const Duration(milliseconds: 1));
    }
    expect(
        f.p.actions
            .skip(start)
            .where((a) =>
                a.type == SyncPlayPlayerActionType.seek ||
                a.type == SyncPlayPlayerActionType.unpause)
            .length,
        lessThanOrEqualTo(2));
    expect(f.first.state.waitParticipation,
        isNot(SyncPlayWaitParticipation.ignoredRecovered));
  });

  test(
      'Leave waits for actual ignore ACK rather than its cancelled local waiter',
      () async {
    await f.open();
    final gate = Completer<void>();
    f.a.afterRequest = (r) async {
      if (r.type == SyncPlayRequestType.setIgnoreWait) await gate.future;
    };
    await f.starve();
    await f.time.advance(const Duration(seconds: 2));
    final leaving = f.first.leaveRoom();
    await flushTasks();
    expect(f.server.leaves, 0);
    gate.complete();
    await leaving;
    await flushTasks();
    expect(f.server.leaves, 1);
    expect(f.first.state.status, SyncPlayStatus.idle);
    expect(
        f.first.state.waitParticipation, SyncPlayWaitParticipation.following);
    expect(
        f.requests.where((r) =>
            r.type == SyncPlayRequestType.setIgnoreWait &&
            r.body['IgnoreWait'] == false),
        isEmpty);
  });
}
