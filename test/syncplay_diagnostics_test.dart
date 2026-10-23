import 'dart:convert';
import 'dart:async';

import 'package:fladder/services/syncplay/syncplay_clock.dart';
import 'package:fladder/services/syncplay/syncplay_controller.dart';
import 'package:fladder/services/syncplay/syncplay_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'syncplay_controller_test.dart' as fixture;

void main() {
  Future<
      (
        fixture.World,
        fixture.Server,
        fixture.Api,
        fixture.Player,
        SyncPlayController
      )> playingRoom() async {
    final world = fixture.World();
    final server = fixture.Server(world);
    final api = server.client('synthetic-local');
    final player = fixture.Player(world);
    final controller = fixture.makeController(world, api, player);
    addTearDown(() async {
      await controller.dispose();
      await api.events.close();
    });
    await controller.createRoom('001234');
    await controller
        .setQueue([fixture.id(71)], position: const Duration(seconds: 120));
    await fixture.settle();
    await controller.requestUnpause();
    await world.advance(const Duration(milliseconds: 500));
    return (world, server, api, player, controller);
  }

  test(
      'clock sample expiry falls back to a newer sample and accepts a valid zero',
      () {
    final start = DateTime.utc(2026, 10, 24);
    var now = start;
    final clock = SyncPlayClock(now: () => now);
    expect(
        clock.recordSample(
            sentAt: now,
            receivedAt: now,
            serverTime: SyncPlayServerTime(
                requestReceptionTime: now, responseTransmissionTime: now)),
        isTrue);
    expect(clock.estimate!.networkRoundTrip, Duration.zero);
    expect(clock.estimate!.offset, Duration.zero);
    now = start.add(const Duration(seconds: 60));
    final sent = now.subtract(const Duration(milliseconds: 100));
    expect(
        clock.recordSample(
            sentAt: sent,
            receivedAt: now,
            serverTime: SyncPlayServerTime(
                requestReceptionTime: sent, responseTransmissionTime: sent)),
        isTrue);
    now = start.add(const Duration(minutes: 2));
    expect(clock.estimate!.networkRoundTrip, Duration.zero,
        reason: 'exact maximum age remains valid');
    now = now.add(const Duration(microseconds: 1));
    expect(clock.estimate!.networkRoundTrip, const Duration(milliseconds: 100));
    expect(clock.estimate!.age, const Duration(seconds: 60, microseconds: 1));
    now = start.add(const Duration(minutes: 3, microseconds: 1));
    expect(clock.estimate, isNull);
  });

  test(
      'threshold, bounded corrections and emitted pause snapshots remain honest',
      () async {
    final (world, _, _, player, controller) = await playingRoom();
    final snapshots = <SyncPlayControllerState>[];
    final subscription = controller.states.listen(snapshots.add);
    addTearDown(subscription.cancel);
    player.position -= const Duration(milliseconds: 500);
    await world.advance(const Duration(seconds: 3));
    expect(snapshots.last.diagnostics.playbackDrift,
        const Duration(milliseconds: 500));
    expect(snapshots.last.diagnostics.correctionCount, 0);
    player.position -= const Duration(seconds: 60);
    await world.advance(const Duration(seconds: 3));
    expect(snapshots.last.diagnostics.playbackDrift,
        const Duration(milliseconds: 60500));
    expect(
        snapshots.last.diagnostics.lastCorrection, const Duration(seconds: 30));
    expect(snapshots.last.diagnostics.correctionCount, 1);
    await controller.requestPause();
    await fixture.settle();
    expect(snapshots.last.diagnostics.playbackDrift, isNull,
        reason: 'the published UI snapshot must clear before Pause is applied');
    await world.advance(const Duration(milliseconds: 500));
    expect(snapshots.last.diagnostics.playbackDrift, isNull);
  });

  for (final disconnect in [false, true]) {
    test(
        'a ${disconnect ? 'disconnected' : 'failed'} in-flight correction never increments diagnostics',
        () async {
      final (world, _, _, player, controller) = await playingRoom();
      final held = Completer<void>();
      addTearDown(() {
        if (!held.isCompleted) held.complete();
      });
      player.onApply = (_) => held.future;
      player.position -= const Duration(seconds: 1);
      await world.advance(const Duration(seconds: 3));
      expect(controller.state.diagnostics.playbackDrift,
          const Duration(seconds: 1));
      expect(controller.state.diagnostics.correctionCount, 0);
      expect(controller.state.diagnostics.lastCorrection, isNull);
      if (disconnect) {
        controller.setConnected(false);
        held.complete();
      } else {
        held.completeError(StateError('synthetic backend failure'));
      }
      await fixture.settle();
      expect(controller.state.diagnostics.correctionCount, 0);
      expect(controller.state.diagnostics.lastCorrection, isNull);
      expect(controller.state.diagnostics.playbackDrift, isNull);
    });
  }

  test(
      'buffering and queue or identity changes do not retain an old drift sample',
      () async {
    final (world, server, api, player, controller) = await playingRoom();
    player.position -= const Duration(milliseconds: 700);
    await world.advance(const Duration(seconds: 3));
    expect(controller.state.diagnostics.playbackDrift,
        const Duration(milliseconds: 700));
    player.buffering = true;
    await world.advance(const Duration(seconds: 3));
    expect(controller.state.diagnostics.playbackDrift, isNull);
    player.buffering = false;
    expect(controller.state.diagnostics.playbackDrift, isNull,
        reason: 'ready alone must not revive a pre-buffer sample');
    await controller
        .setQueue([fixture.id(72)], position: const Duration(seconds: 30));
    await fixture.settle();
    expect(controller.state.diagnostics.correctionCount, 0);
    expect(controller.state.diagnostics.lastCorrection, isNull);
    final other = server.client('synthetic-other');
    addTearDown(other.events.close);
    await controller.switchIdentity(
      identity: const SyncPlayIdentity(
          sourceId: 'another-synthetic-server',
          userId: 'other',
          sessionId: 'another'),
      api: other,
      events: other.events.stream,
    );
    expect(controller.state.diagnostics.toJson(),
        const SyncPlayDiagnostics().toJson());
    expect(api.timeCalls, greaterThan(0));
  });

  test('clock diagnostics use the same best sample and exact adjusted RTT', () {
    final start = DateTime.utc(2026, 10, 24);
    var now = start.add(const Duration(milliseconds: 100));
    final clock = SyncPlayClock(now: () => now);
    expect(clock.estimate, isNull);
    expect(
        clock.recordSample(
          sentAt: start,
          receivedAt: now,
          serverTime: SyncPlayServerTime(
            requestReceptionTime: start.add(const Duration(milliseconds: 250)),
            responseTransmissionTime:
                start.add(const Duration(milliseconds: 270)),
          ),
        ),
        isTrue);
    final first = clock.estimate!;
    expect(first.networkRoundTrip, const Duration(milliseconds: 80));
    expect(first.offset, const Duration(milliseconds: 210));
    expect(first.age, Duration.zero);
    now = start.add(const Duration(milliseconds: 1200));
    expect(
        clock.recordSample(
          sentAt: start.add(const Duration(milliseconds: 200)),
          receivedAt: now,
          serverTime: SyncPlayServerTime(
            requestReceptionTime: start.add(const Duration(milliseconds: 900)),
            responseTransmissionTime:
                start.add(const Duration(milliseconds: 920)),
          ),
        ),
        isTrue);
    final best = clock.estimate!;
    expect(best.networkRoundTrip, first.networkRoundTrip);
    expect(best.offset, first.offset);
    expect(best.age, const Duration(milliseconds: 1100),
        reason:
            'sample age describes the selected best sample, not the latest');
    now = start.add(const Duration(minutes: 3));
    expect(clock.estimate, isNull);
    expect(clock.isSynchronized, isFalse);
  });

  test(
      'clock rollback and reset hide obsolete estimates instead of showing zero',
      () {
    var now = DateTime.utc(2026, 10, 24);
    final clock = SyncPlayClock(now: () => now);
    void sample() => expect(
        clock.recordSample(
          sentAt: now,
          receivedAt: now,
          serverTime: SyncPlayServerTime(
              requestReceptionTime: now, responseTransmissionTime: now),
        ),
        isTrue);
    sample();
    expect(clock.estimate, isNotNull);
    now = now.subtract(const Duration(milliseconds: 1));
    expect(clock.estimate, isNull);
    sample();
    clock.reset();
    expect(clock.estimate, isNull);
  });

  test(
      'diagnostics serialization contains only numeric allowlisted measurements',
      () {
    const d = SyncPlayDiagnostics(
      networkRoundTrip: Duration(microseconds: 81500),
      clockOffset: Duration(milliseconds: -23),
      clockSampleAge: Duration(seconds: 2),
      playbackDrift: Duration(milliseconds: 750),
      driftSampleAge: Duration(milliseconds: 30),
      lastCorrection: Duration(milliseconds: -600),
      correctionCount: 2,
    );
    expect(jsonDecode(jsonEncode(d.toJson())), {
      'networkRoundTripMs': 81.5,
      'clockOffsetMs': -23.0,
      'clockSampleAgeMs': 2000,
      'playbackDriftMs': 750.0,
      'driftSampleAgeMs': 30,
      'lastCorrectionMs': -600.0,
      'correctionCount': 2,
    });
    expect(d.toJson().values.every((v) => v == null || v is num), isTrue);
    final empty = const SyncPlayDiagnostics().toJson();
    expect(empty['playbackDriftMs'], isNull);
    expect(empty['networkRoundTripMs'], isNull);
    expect(empty['correctionCount'], 0);
  });

  test(
      'signed drift reports ahead and behind, counts only completed current corrections',
      () async {
    final world = fixture.World();
    final server = fixture.Server(world);
    final api = server.client('synthetic-local');
    final player = fixture.Player(world);
    final controller = fixture.makeController(world, api, player);
    addTearDown(() async {
      await controller.dispose();
      await api.events.close();
    });
    await controller.createRoom('001234');
    await controller
        .setQueue([fixture.id(71)], position: const Duration(seconds: 12));
    await fixture.settle();
    expect(controller.state.diagnostics.playbackDrift, isNull);
    await controller.requestUnpause();
    await world.advance(const Duration(milliseconds: 500));
    player.position -= const Duration(milliseconds: 750);
    await world.advance(const Duration(seconds: 3));
    var d = controller.state.diagnostics;
    expect(d.playbackDrift, const Duration(milliseconds: 750));
    expect(d.correctionCount, 1);
    expect(d.lastCorrection, const Duration(milliseconds: 750));
    player.position += const Duration(milliseconds: 800);
    await world.advance(const Duration(seconds: 3));
    d = controller.state.diagnostics;
    expect(d.playbackDrift, const Duration(milliseconds: -800));
    expect(d.correctionCount, 2);
    expect(d.lastCorrection, const Duration(milliseconds: -800));
    await controller.requestPause();
    await world.advance(const Duration(milliseconds: 500));
    expect(controller.state.diagnostics.playbackDrift, isNull);
    controller.setConnected(false);
    final disconnected = controller.state.diagnostics;
    expect(disconnected.networkRoundTrip, isNull);
    expect(disconnected.playbackDrift, isNull);
    expect(disconnected.lastCorrection, isNull);
    expect(disconnected.correctionCount, 0);
  });
}
