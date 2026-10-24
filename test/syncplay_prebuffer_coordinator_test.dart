import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fladder/services/syncplay/syncplay_clock.dart';
import 'package:fladder/services/syncplay/syncplay_prebuffer.dart';
import 'package:fladder/services/syncplay/syncplay_prebuffer_coordinator.dart';

class _Job implements SyncPlayCancellation {
  _Job(this.at, this.callback);
  final DateTime at;
  final void Function() callback;
  bool cancelled = false;
  @override
  void cancel() => cancelled = true;
}

class _World implements SyncPlayScheduler {
  DateTime now = DateTime.utc(2026, 1, 1);
  final jobs = <_Job>[];
  final decisions = <SyncPlayPrebufferDecision>[];
  bool active = true,
      current = true,
      allowReads = true,
      rawBuffering = false,
      failSample = false;
  Object generation = Object();
  Duration? end = const Duration(seconds: 1);
  int? bytes, budget;
  int reads = 0;
  Completer<SyncPlayBufferSample>? blocked;
  Completer<int?>? blockedBudget;
  late final coordinator = SyncPlayPrebufferCoordinator(
    isCurrent: () {
      expect(allowReads, isTrue);
      return current;
    },
    isActive: () {
      expect(allowReads, isTrue);
      return active;
    },
    generation: () {
      expect(allowReads, isTrue);
      return generation;
    },
    verifiedForwardBudget: () async {
      final pending = blockedBudget;
      if (pending != null) return pending.future;
      return budget;
    },
    readSample: () async {
      expect(allowReads, isTrue);
      reads++;
      if (failSample) throw StateError('synthetic sampler unavailable');
      if (blocked != null) return blocked!.future;
      return sample();
    },
    onDecision: decisions.add,
    scheduler: this,
    now: () => now,
  );

  SyncPlayBufferSample sample() => SyncPlayBufferSample(
        position: Duration.zero,
        bufferEnd: end,
        buffering: rawBuffering,
        forwardBytes: bytes,
        observedAt: now,
      );

  @override
  SyncPlayCancellation schedule(Duration delay, void Function() callback) {
    final job = _Job(now.add(delay), callback);
    jobs.add(job);
    return job;
  }

  Future<void> tick([Duration elapsed = Duration.zero]) async {
    now = now.add(elapsed);
    for (final job in jobs
        .where((job) => !job.cancelled && !job.at.isAfter(now))
        .toList()) {
      job.cancelled = true;
      job.callback();
    }
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('no active room samples no player and starts no timer', () async {
    final world = _World()..active = false;
    world.coordinator.refresh();
    await world.tick(const Duration(minutes: 1));
    expect(world.reads, 0);
    expect(world.jobs, isEmpty);
    expect(world.decisions, isEmpty);
  });

  test('fresh media ahead gates readiness independently of the raw false edge',
      () async {
    final world = _World();
    world.coordinator.refresh();
    await world.tick();
    expect(world.coordinator.ready, isFalse);
    expect(world.decisions.single.ahead, const Duration(seconds: 1));
    world.end = const Duration(seconds: 5);
    await world.tick(const Duration(milliseconds: 500));
    expect(world.coordinator.ready, isTrue);
    expect(world.decisions.last.status, SyncPlayPrebufferStatus.ready);
    world.coordinator.dispose();
  });

  test(
      'unknown metric fallback stays explicit and waits for a stable fresh player',
      () async {
    final world = _World()..end = null;
    world.coordinator.refresh();
    await world.tick();
    expect(world.coordinator.ready, isFalse);
    await world.tick(const Duration(seconds: 2));
    expect(world.decisions.last.status, SyncPlayPrebufferStatus.fallbackReady);
    expect(world.decisions.last.ahead, isNull);
    expect(world.decisions.last.measuredTargetReached, isFalse);
    world.coordinator.dispose();
  });

  test('a queue or seek generation change discards a late ready sample',
      () async {
    final world = _World()..blocked = Completer<SyncPlayBufferSample>();
    world.coordinator.refresh();
    await world.tick();
    final old = world.blocked!;
    world.generation = Object();
    world.coordinator.refresh();
    world.blocked = null;
    old.complete(SyncPlayBufferSample(
      position: Duration.zero,
      bufferEnd: const Duration(seconds: 30),
      buffering: false,
      observedAt: world.now,
    ));
    await Future<void>.delayed(Duration.zero);
    expect(world.decisions, isEmpty);
    await world.tick();
    expect(world.decisions, hasLength(1));
    expect(world.coordinator.ready, isFalse);
    world.coordinator.dispose();
  });

  test('dispose rejects pending and forcibly invoked cancelled callbacks',
      () async {
    final world = _World()..blocked = Completer<SyncPlayBufferSample>();
    world.coordinator.refresh();
    final oldJob = world.jobs.single;
    await world.tick();
    world.coordinator.dispose();
    world.allowReads = false;
    oldJob.callback();
    world.blocked!.complete(world.sample());
    await Future<void>.delayed(Duration.zero);
    expect(world.decisions, isEmpty);
    expect(world.coordinator.ready, isFalse);
  });

  test(
      'a verified smaller byte ceiling takes priority over the duration target',
      () async {
    final world = _World()
      ..budget = 2 * 1024 * 1024
      ..bytes = 2 * 1024 * 1024;
    world.coordinator.refresh();
    await world.tick();
    expect(world.coordinator.confirmedForwardBudget, 2 * 1024 * 1024);
    expect(world.decisions.single.byteBudgetLimited, isTrue);
    expect(world.decisions.single.target, const Duration(seconds: 1));
    expect(world.coordinator.ready, isTrue);
    world.coordinator.dispose();
  });

  test('an unverifiable oversized budget is not reported as enforced',
      () async {
    final world = _World()..budget = 1024 * 1024 * 1024;
    world.coordinator.refresh();
    await world.tick();
    expect(world.coordinator.confirmedForwardBudget, isNull);
    expect(world.coordinator.ready, isFalse);
    world.coordinator.dispose();
  });

  test('a sampler failure never invents ready and has a bounded wait status',
      () async {
    final world = _World()..failSample = true;
    world.coordinator.refresh();
    await world.tick();
    expect(world.coordinator.ready, isFalse);
    await world.tick(const Duration(seconds: 12));
    expect(world.decisions.last.timedOut, isTrue);
    expect(world.coordinator.ready, isFalse);
    world.coordinator.dispose();
  });

  test(
      'ready getters reject changed generation immediately and expire stale samples',
      () async {
    final world = _World()..end = const Duration(seconds: 5);
    world.coordinator.refresh();
    await world.tick();
    expect(world.coordinator.ready, isTrue);
    world.generation = Object();
    // No refresh/poll yet: an old ready decision must not grant initial Ready.
    expect(world.coordinator.ready, isFalse);
    expect(world.coordinator.decision, isNull);
    expect(world.coordinator.ahead, isNull);
    world.coordinator.refresh();
    await world.tick();
    expect(world.coordinator.ready, isTrue);
    world.blocked = Completer<SyncPlayBufferSample>();
    await world.tick(const Duration(milliseconds: 500));
    world.now = world.now.add(const Duration(seconds: 4));
    expect(world.coordinator.ready, isFalse);
    world.coordinator.dispose();
    world.blocked!.complete(world.sample());
    await Future<void>.delayed(Duration.zero);
  });

  test('a retired budget await never reads a replaced or disposed backend',
      () async {
    for (final dispose in [true, false]) {
      final world = _World()..blockedBudget = Completer<int?>();
      world.coordinator.refresh();
      await world.tick();
      expect(world.reads, 0);
      if (dispose) {
        world.coordinator.dispose();
        world.allowReads = false;
      } else {
        world.generation = Object();
        world.coordinator.refresh();
      }
      world.blockedBudget!.complete(2 * 1024 * 1024);
      await Future<void>.delayed(Duration.zero);
      expect(world.reads, 0);
      expect(world.decisions, isEmpty);
      expect(world.coordinator.confirmedForwardBudget, isNull);
      if (!dispose) world.coordinator.dispose();
    }
  });

  test(
      'new generation cannot inherit a previous players smaller verified ceiling',
      () async {
    final world = _World()
      ..budget = 2 * 1024 * 1024
      ..bytes = 2 * 1024 * 1024;
    world.coordinator.refresh();
    await world.tick();
    expect(world.coordinator.ready, isTrue);
    expect(world.coordinator.confirmedForwardBudget, 2 * 1024 * 1024);
    world.generation = Object();
    world.budget = null;
    world.coordinator.refresh();
    expect(world.coordinator.confirmedForwardBudget, isNull);
    await world.tick();
    expect(world.coordinator.ready, isFalse);
    expect(world.decisions.last.byteBudgetLimited, isFalse);
    expect(world.decisions.last.target, const Duration(seconds: 4));
    world.coordinator.dispose();
  });
}
