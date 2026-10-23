import 'package:fladder/services/syncplay/syncplay_clock.dart';
import 'package:fladder/services/syncplay/syncplay_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final start = DateTime.utc(2026, 10, 23, 12);

  test('wire timestamps reject calendar rollover and ticks preserve zero', () {
    for (final value in [
      '2026-02-30T12:00:00Z',
      '2026-13-01T12:00:00Z',
      '2026-10-23T24:00:00Z',
      '2026-10-23T12:00:00',
      '2026-10-23T12:00:00+15:00'
    ]) {
      expect(() => syncPlayDate(value), throwsFormatException);
    }
    expect(syncPlayDate('2026-10-23T20:00:00+08:00'), start);
    expect(syncPlayPosition(0), Duration.zero);
    expect(() => syncPlayPosition('0'), throwsFormatException);
    expect(() => syncPlayPosition(-1), throwsFormatException);
  });

  test('four timestamps remove server processing and measure clock skew', () {
    var now = start.add(const Duration(milliseconds: 140));
    final clock = SyncPlayClock(now: () => now);
    expect(
        clock.recordSample(
          sentAt: start,
          receivedAt: now,
          serverTime: SyncPlayServerTime(
            requestReceptionTime:
                start.add(const Duration(minutes: 5, milliseconds: 60)),
            responseTransmissionTime:
                start.add(const Duration(minutes: 5, milliseconds: 80)),
          ),
        ),
        isTrue);
    expect(clock.offset, const Duration(minutes: 5));
    expect(clock.ping, const Duration(milliseconds: 60));
    expect(clock.toLocal(start.add(const Duration(minutes: 5))), start);
    expect(clock.serverNow, now.add(const Duration(minutes: 5)));
    now = now.add(const Duration(minutes: 3));
    expect(clock.isSynchronized, isFalse);
  });

  test(
      'lowest network delay wins over noisy measurements and reset isolates sources',
      () {
    var now = start.add(const Duration(milliseconds: 20));
    final clock = SyncPlayClock(now: () => now);
    bool sample(Duration trip, Duration skew) {
      final sent = now.subtract(trip);
      return clock.recordSample(
          sentAt: sent,
          receivedAt: now,
          serverTime: SyncPlayServerTime(
            requestReceptionTime: sent.add(trip ~/ 2).add(skew),
            responseTransmissionTime: sent.add(trip ~/ 2).add(skew),
          ));
    }

    expect(
        sample(const Duration(milliseconds: 20), const Duration(seconds: -7)),
        isTrue);
    now = now.add(const Duration(seconds: 1));
    expect(
        sample(const Duration(milliseconds: 900), const Duration(seconds: 4)),
        isTrue);
    expect(clock.offset, const Duration(seconds: -7));
    expect(clock.ping, const Duration(milliseconds: 10));
    clock.reset();
    expect(clock.isSynchronized, isFalse);
    expect(clock.offset, Duration.zero);
    expect(
        sample(const Duration(milliseconds: 40), const Duration(seconds: 12)),
        isTrue);
    expect(clock.offset, const Duration(seconds: 12));
  });

  test(
      'impossible timing, future observations and excessive delay are rejected',
      () {
    final now = start.add(const Duration(seconds: 20));
    final clock = SyncPlayClock(now: () => now);
    bool sample(DateTime sent, DateTime received, DateTime reception,
            DateTime transmission) =>
        clock.recordSample(
            sentAt: sent,
            receivedAt: received,
            serverTime: SyncPlayServerTime(
                requestReceptionTime: reception,
                responseTransmissionTime: transmission));
    expect(sample(now, start, start, start), isFalse);
    expect(sample(start, now, start, start), isFalse);
    expect(sample(now, now.add(const Duration(seconds: 1)), now, now), isFalse);
    expect(sample(now, now, now, now.add(const Duration(milliseconds: 1))),
        isFalse);
    expect(sample(now, now, now, start), isFalse);
    expect(clock.isSynchronized, isFalse);
  });

  test(
      'backwards wall clock invalidates old estimates rather than executing early',
      () {
    var now = start;
    final clock = SyncPlayClock(now: () => now);
    expect(
        clock.recordSample(
            sentAt: now,
            receivedAt: now,
            serverTime: SyncPlayServerTime(
                requestReceptionTime: now, responseTransmissionTime: now)),
        isTrue);
    now = now.subtract(const Duration(hours: 1));
    expect(clock.isSynchronized, isFalse);
  });
}
