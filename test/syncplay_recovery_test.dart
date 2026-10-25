import 'dart:async';

import 'package:fladder/services/syncplay/syncplay_models.dart';
import 'package:fladder/services/syncplay/syncplay_recovery.dart';
import 'package:flutter_test/flutter_test.dart';

import 'syncplay_controller_test.dart' as protocol;

final _group = SyncPlayGroup(
    groupId: protocol.id(410),
    groupName: 'Synthetic recovery room',
    lastUpdatedAt: DateTime.utc(2026));

SyncPlayControllerState _state(SyncPlayStatus status,
        {bool connected = true, SyncPlayFailureCode? failure}) =>
    SyncPlayControllerState(
        status: status,
        connected: connected,
        group: _group,
        failure: failure == null ? null : SyncPlayFailure(failure));

/// Every boundary is a synthetic future. No socket, API, player or real clock.
class _Fixture {
  _Fixture({bool learnMembership = true, double jitter = 0.5}) {
    policy = SyncPlayRecovery(
        readState: () => state,
        isCurrent: () => current,
        reconnectTransport: _connect,
        rejoinKnownGroup: _join,
        revalidate: _validate,
        onChanged: () => changes++,
        scheduler: world,
        jitter: () => jitter);
    if (learnMembership) policy.observe(state);
    addTearDown(policy.dispose);
  }

  final world = protocol.World();
  late final SyncPlayRecovery policy;
  var state = _state(SyncPlayStatus.joined);
  bool current = true;
  int connects = 0, joins = 0, validations = 0, changes = 0;
  final connectTimes = <DateTime>[];
  final joinTimes = <DateTime>[];
  Future<void> Function()? onConnect;
  Future<void> Function(bool Function() isCurrent)? onJoin;
  Future<void> Function()? onValidate;

  void publish(SyncPlayControllerState next) {
    state = next;
    policy.observe(next);
  }

  Future<void> _connect() async {
    connects++;
    connectTimes.add(world.now);
    await onConnect?.call();
    if (current) publish(_state(SyncPlayStatus.disconnected));
  }

  Future<void> _join(bool Function() isCurrent) async {
    joins++;
    joinTimes.add(world.now);
    if (onJoin != null) {
      await onJoin!(isCurrent);
    } else if (isCurrent()) {
      publish(_state(SyncPlayStatus.joined));
    }
  }

  Future<void> _validate() async {
    validations++;
    await onValidate?.call();
  }

  void disconnect() => publish(_state(SyncPlayStatus.disconnected,
      connected: false, failure: SyncPlayFailureCode.disconnected));
}

void main() {
  test('retained disconnected membership restores socket then one exact join',
      () async {
    final f = _Fixture();
    f.disconnect();
    expect(f.policy.active, isTrue);
    await f.world.advance(const Duration(milliseconds: 1124));
    expect(f.connects, 0);
    await f.world.advance(const Duration(milliseconds: 1));
    expect(f.connects, 1);
    expect(f.joins, 1);
    expect(f.state.isJoined, isTrue);
    expect(f.policy.active, isFalse);
    expect(f.policy.exhausted, isFalse);
    expect(f.joinTimes.single, f.connectTimes.single);
  });

  test('transport failures use three jittered backoff attempts then stop',
      () async {
    final f = _Fixture();
    final start = f.world.now;
    f.onConnect = () async {
      throw const SyncPlayFailure(SyncPlayFailureCode.disconnected);
    };
    f.disconnect();
    await f.world.advance(const Duration(seconds: 10));
    expect(f.connectTimes.map((time) => time.difference(start)), [
      const Duration(milliseconds: 1125),
      const Duration(milliseconds: 3250),
      const Duration(milliseconds: 7375),
    ]);
    expect(f.joins, 0);
    expect(f.policy.active, isFalse);
    expect(f.policy.exhausted, isTrue);
    for (var i = 0; i < 20; i++) {
      f.policy.wake();
      f.policy.observe(f.state);
    }
    await f.world.advance(const Duration(hours: 1));
    expect(f.connects, 3);
  });

  test('repeated resume and network triggers share a pending connect',
      () async {
    final f = _Fixture();
    final gate = Completer<void>();
    f.onConnect = () => gate.future;
    f.disconnect();
    await f.world.advance(const Duration(seconds: 2));
    for (var i = 0; i < 20; i++) {
      f.policy.wake();
      f.policy.observe(f.state);
    }
    await f.world.advance(const Duration(seconds: 5));
    expect(f.connects, 1);
    expect(f.joins, 0);
    gate.complete();
    await protocol.settle();
    expect(f.joins, 1);
    expect(f.state.isJoined, isTrue);
  });

  test('unknown exact prior membership gets one bounded revalidation join',
      () async {
    final f = _Fixture();
    f.publish(_state(SyncPlayStatus.unknown,
        failure: SyncPlayFailureCode.timeoutUnknown));
    await f.world.advance(const Duration(seconds: 2));
    expect(f.connects, 0);
    expect(f.joins, 1);
    expect(f.state.isJoined, isTrue);
  });

  test('a visible group without prior confirmation never authorizes auto join',
      () async {
    final f = _Fixture(learnMembership: false);
    f.publish(_state(SyncPlayStatus.unknown,
        failure: SyncPlayFailureCode.timeoutUnknown));
    f.policy.wake();
    await f.world.advance(const Duration(minutes: 1));
    expect(f.connects, 0);
    expect(f.joins, 0);
    expect(f.policy.active, isFalse);
  });

  test('ambiguous join result is not automatically retried', () async {
    final f = _Fixture();
    f.onJoin = (_) async {
      f.publish(_state(SyncPlayStatus.unknown,
          failure: SyncPlayFailureCode.timeoutUnknown));
    };
    f.disconnect();
    await f.world.advance(const Duration(seconds: 2));
    expect(f.joins, 1);
    expect(f.policy.exhausted, isTrue);
    for (var i = 0; i < 20; i++) {
      f.policy.wake();
    }
    await f.world.advance(const Duration(minutes: 2));
    expect(f.joins, 1);
    expect(f.connects, 1);
  });

  test(
      'never-settling transport has a total deadline; late success cannot join',
      () async {
    final f = _Fixture();
    final gate = Completer<void>();
    f.onConnect = () => gate.future;
    f.disconnect();
    await f.world.advance(const Duration(seconds: 44));
    f.policy.wake();
    expect(f.policy.active, isTrue);
    await f.world.advance(const Duration(seconds: 1));
    expect(f.policy.active, isFalse);
    expect(f.policy.exhausted, isTrue);
    expect(f.connects, 1);
    gate.complete();
    await protocol.settle();
    expect(f.joins, 0);
    f.policy.wake();
    await f.world.advance(const Duration(minutes: 1));
    expect(f.connects, 1);
    expect(f.joins, 0);
  });

  test('deadline revokes the guard passed to a still-pending join', () async {
    final f = _Fixture();
    final gate = Completer<void>();
    late bool Function() joinCurrent;
    f.onJoin = (isCurrent) async {
      joinCurrent = isCurrent;
      await gate.future;
      if (isCurrent()) f.publish(_state(SyncPlayStatus.joined));
    };
    f.publish(_state(SyncPlayStatus.disconnected));
    await f.world.advance(const Duration(seconds: 2));
    expect(joinCurrent(), isTrue);
    await f.world.advance(const Duration(seconds: 43));
    expect(joinCurrent(), isFalse);
    expect(f.policy.exhausted, isTrue);
    gate.complete();
    await protocol.settle();
    expect(f.state.isJoined, isFalse);
    expect(f.joins, 1);
  });

  for (final ending in ['cancel', 'leave', 'dispose', 'identity']) {
    test('$ending during a connect prevents its late membership mutation',
        () async {
      final f = _Fixture();
      final gate = Completer<void>();
      f.onConnect = () => gate.future;
      f.disconnect();
      await f.world.advance(const Duration(seconds: 2));
      switch (ending) {
        case 'cancel':
          f.policy.cancel();
        case 'leave':
          f.publish(_state(SyncPlayStatus.leaving));
        case 'dispose':
          f.policy.dispose();
        case 'identity':
          f.current = false;
          f.policy.dispose();
      }
      gate.complete();
      await protocol.settle();
      await f.world.advance(const Duration(minutes: 1));
      expect(f.joins, 0);
      expect(f.connects, 1);
      expect(f.policy.active, isFalse);
    });
  }

  for (final failure in [
    SyncPlayFailureCode.denied,
    SyncPlayFailureCode.noGroup,
    SyncPlayFailureCode.protocol,
    SyncPlayFailureCode.unsupported,
  ]) {
    test('$failure does not auto reconnect or join', () async {
      final f = _Fixture();
      f.publish(_state(SyncPlayStatus.unknown, failure: failure));
      f.policy.wake();
      await f.world.advance(const Duration(minutes: 1));
      expect(f.connects, 0);
      expect(f.joins, 0);
    });
  }

  for (final failure in [
    SyncPlayFailureCode.denied,
    SyncPlayFailureCode.noGroup,
    SyncPlayFailureCode.protocol,
  ]) {
    test('$failure during transport revokes late success even if error clears',
        () async {
      final f = _Fixture();
      final gate = Completer<void>();
      f.onConnect = () => gate.future;
      f.disconnect();
      await f.world.advance(const Duration(seconds: 2));
      f.publish(_state(SyncPlayStatus.unknown, failure: failure));
      expect(f.policy.exhausted, isTrue);
      gate.complete();
      await protocol.settle();
      expect(f.joins, 0);
      expect(f.policy.exhausted, isTrue);
    });
  }

  test('healthy wake only coalesces read validation, never reconnects or joins',
      () async {
    final f = _Fixture();
    final gate = Completer<void>();
    f.onValidate = () => gate.future;
    for (var i = 0; i < 20; i++) {
      f.policy.wake();
    }
    await protocol.settle();
    expect(f.validations, 1);
    expect(f.connects, 0);
    expect(f.joins, 0);
    expect(f.policy.active, isFalse);
    gate.complete();
    await protocol.settle();
    for (var i = 0; i < 20; i++) {
      f.policy.wake();
    }
    await protocol.settle();
    expect(f.validations, 1);
    await f.world.advance(const Duration(seconds: 15));
    f.policy.wake();
    await protocol.settle();
    expect(f.validations, 2);
    expect(f.connects, 0);
    expect(f.joins, 0);
  });

  test('explicit manual retry revokes a pending auto join callback', () async {
    final f = _Fixture();
    final gate = Completer<void>();
    late bool Function() joinCurrent;
    f.onJoin = (isCurrent) async {
      joinCurrent = isCurrent;
      await gate.future;
      if (isCurrent()) f.publish(_state(SyncPlayStatus.joined));
    };
    f.publish(_state(SyncPlayStatus.disconnected));
    await f.world.advance(const Duration(seconds: 2));
    f.policy.manualRetry();
    expect(joinCurrent(), isFalse);
    gate.complete();
    await protocol.settle();
    f.policy.wake();
    await f.world.advance(const Duration(minutes: 1));
    expect(f.joins, 1);
    expect(f.state.isJoined, isFalse);
  });
}
