import 'package:fladder/services/syncplay/syncplay_prebuffer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late DateTime clock;
  late SyncPlayPrebufferPolicy policy;
  setUp(() {
    clock = DateTime.utc(2026, 10, 24);
    policy = SyncPlayPrebufferPolicy(now: () => clock);
  });
  SyncPlayPrebufferDecision sample({
    int position = 100,
    int? end = 104,
    bool buffering = false,
    int? duration,
    int? bytes,
    bool preparing = false,
    DateTime? at,
    Object generation = 1,
  }) =>
      policy.evaluate(
        SyncPlayBufferSample(
          position: Duration(seconds: position),
          bufferEnd: end == null ? null : Duration(seconds: end),
          duration: duration == null ? null : Duration(seconds: duration),
          buffering: buffering,
          observedAt: at ?? clock,
          forwardBytes: bytes,
          preparing: preparing,
        ),
        generation: generation,
      );

  test('copied absolute native endpoint yields ahead, not total buffered position', () {
    final decision = sample(end: 102);
    expect(decision.ahead, const Duration(seconds: 2));
    expect(decision.needsBuffer, isTrue);
    expect(decision.ready, isFalse);
    expect(sample(end: 99).ahead, Duration.zero);
  });
  test('ready hysteresis avoids oscillating at the target but restarts below low water', () {
    expect(sample().ready, isTrue);
    final held = sample(end: 103);
    expect(held.ready, isTrue);
    expect(held.needsBuffer, isFalse);
    expect(sample(end: 101).ready, isFalse);
    expect(sample(end: 103).ready, isFalse);
    expect(sample().ready, isTrue);
  });
  test('bounded waiting does not renew on repeated samples; later recovery is ready', () {
    expect(sample(end: 100, buffering: true).timedOut, isFalse);
    clock = clock.add(const Duration(seconds: 11));
    expect(sample(end: 101, buffering: true).timedOut, isFalse);
    clock = clock.add(const Duration(seconds: 1));
    final decision = sample(end: 101, buffering: true);
    expect(decision.timedOut, isTrue);
    expect(decision.status, SyncPlayPrebufferStatus.timedOut);
    expect(sample(end: 120).ready, isTrue);
  });
  test('queue seek reload epoch and explicit reset discard wait and rate history', () {
    sample(end: 100, buffering: true);
    clock = clock.add(const Duration(seconds: 20));
    expect(sample(end: 100, buffering: true).timedOut, isTrue);
    final changed = sample(end: 100, buffering: true, generation: 2);
    expect(changed.timedOut, isFalse);
    expect(changed.waited, Duration.zero);
    expect(changed.deliveryRate, isNull);
    expect(changed.target, const Duration(seconds: 4));
    policy.reset();
    expect(sample(end: 100, buffering: true, generation: 2).waited, Duration.zero);
  });
  test('unknown metrics use bounded fresh player fallback and remain stable after it', () {
    expect(sample(end: null).ready, isFalse);
    clock = clock.add(const Duration(seconds: 2));
    final ready = sample(end: null);
    expect(ready.ready, isTrue);
    expect(ready.status, SyncPlayPrebufferStatus.fallbackReady);
    expect(sample(end: null).ready, isTrue);
    expect(sample(end: null, buffering: true).ready, isFalse);
    clock = clock.add(const Duration(seconds: 12));
    expect(sample(end: null, buffering: true).timedOut, isTrue);
  });
  test('stale future invalid and out of order samples never prove ready', () {
    final old = clock.subtract(const Duration(seconds: 4));
    expect(sample(at: old).status, SyncPlayPrebufferStatus.stale);
    expect(sample(at: clock.add(const Duration(seconds: 1))).ready, isFalse);
    expect(sample(position: -1).status, SyncPlayPrebufferStatus.unknown);
    expect(sample().ready, isTrue);
    expect(sample(at: clock.subtract(const Duration(seconds: 1))).ready, isFalse);
  });
  test('near EOF clamps target to the remaining playable interval', () {
    final decision = sample(position: 100, end: 101, duration: 101);
    expect(decision.target, const Duration(seconds: 1));
    expect(decision.ready, isTrue);
    expect(sample(position: 101, end: 200, duration: 101).ahead, Duration.zero);
  });
  test('150MiB cache ceiling can bound readiness without requesting whole media', () {
    final decision = sample(end: 102, bytes: 150 * 1024 * 1024);
    expect(decision.byteBudgetLimited, isTrue);
    expect(decision.target, const Duration(seconds: 2));
    expect(decision.ready, isTrue);
    // Falling slightly below a full byte cache must not immediately rebuffer.
    expect(sample(end: 101, bytes: 150 * 1024 * 1024 - 1).ready, isTrue);
    expect(sample(end: 100, bytes: 150 * 1024 * 1024 - 1).ready, isFalse);
    policy.reset();
    expect(sample(end: 102, bytes: 150 * 1024 * 1024 - 1).ready, isFalse);
    expect(
      () => SyncPlayPrebufferPolicy(config: const SyncPlayPrebufferConfig(maximumForwardBytes: 151 * 1024 * 1024)),
      throwsArgumentError,
    );
  });
  test('observed media progress supplies rate, with bounded growth and cooldown', () {
    sample(end: 102);
    clock = clock.add(const Duration(seconds: 1));
    final stalled = sample(end: 102, buffering: true);
    expect(stalled.deliveryRate, 0);
    expect(stalled.target, const Duration(seconds: 6));
    clock = clock.add(const Duration(seconds: 1));
    expect(sample(end: 102, buffering: true).target, const Duration(seconds: 6));
    for (var i = 0; i < 20; i++) {
      clock = clock.add(const Duration(seconds: 5));
      sample(end: 102, buffering: true);
    }
    expect(sample(end: 102, buffering: true).target, const Duration(seconds: 30));
    sample(end: null);
    clock = clock.add(const Duration(seconds: 2));
    final unknown = sample(end: null);
    expect(unknown.ready, isTrue);
    expect(unknown.status, SyncPlayPrebufferStatus.fallbackReady);
    expect(unknown.ahead, isNull);
    expect(unknown.measuredTargetReached, isFalse);
    expect(unknown.deliveryRate, isNull);
  });
  test('stable plentiful media shrinks slowly, never below the minimum', () {
    sample(end: 120);
    clock = clock.add(const Duration(seconds: 30));
    expect(sample(end: 120).target, const Duration(seconds: 3));
    clock = clock.add(const Duration(seconds: 30));
    expect(sample(end: 120).target, const Duration(seconds: 2));
    clock = clock.add(const Duration(seconds: 30));
    expect(sample(end: 120).target, const Duration(seconds: 2));
  });

  test('frequent observations accumulate enough time to measure real media progress', () {
    SyncPlayPrebufferDecision? result;
    for (var i = 0; i <= 20; i++) {
      result = policy.evaluate(
          SyncPlayBufferSample(
              position: const Duration(seconds: 100),
              buffering: false,
              observedAt: clock,
              bufferEnd: Duration(milliseconds: 100000 + i * 200)),
          generation: 1);
      clock = clock.add(const Duration(milliseconds: 100));
    }
    expect(result!.deliveryRate, closeTo(2, 0.001));
    expect(result.target, const Duration(seconds: 4));
  });
  test('HDR decoder preparation is not network underflow or a throughput observation', () {
    sample(end: 102);
    clock = clock.add(const Duration(seconds: 1));
    final preparing = sample(end: 102, buffering: true, preparing: true);
    expect(preparing.status, SyncPlayPrebufferStatus.preparing);
    expect(preparing.needsBuffer, isFalse);
    expect(preparing.deliveryRate, isNull);
    expect(preparing.target, const Duration(seconds: 4));
    clock = clock.add(const Duration(seconds: 1));
    final decoder = sample(end: 110, buffering: true);
    expect(decoder.status, SyncPlayPrebufferStatus.playerWaiting);
    expect(decoder.needsBuffer, isFalse);
    expect(decoder.deliveryRate, isNull);
  });
  test('clock rollback and copied identical samples do not produce negative rates or waits', () {
    sample(end: 102);
    expect(sample(end: 102).deliveryRate, isNull);
    clock = clock.subtract(const Duration(seconds: 1));
    final result = sample(end: 102);
    expect(result.waited, Duration.zero);
    expect(result.deliveryRate, isNull);
  });
}
