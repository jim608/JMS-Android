import 'dart:async';

import 'package:fladder/util/syncplay_buffer_probe.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Map<String, String?> properties;
  late List<String> reads;
  late List<String> writes;
  late bool current, buffering, preparing;
  late int generation;
  late MpvSyncPlayBufferProbe probe;
  final now = DateTime.utc(2026, 10, 24);
  setUp(() {
    current = true;
    buffering = false;
    preparing = false;
    generation = 1;
    properties = {
      'time-pos': '100.25',
      'demuxer-cache-time': '130.5',
      'duration': '300',
      'paused-for-cache': 'no',
      'demuxer-cache-state/fw-bytes': '10000',
      'seeking': 'no',
      'demuxer-max-bytes': '157286400',
    };
    reads = [];
    writes = [];
    probe = MpvSyncPlayBufferProbe(
      read: (name) async {
        reads.add(name);
        return properties[name];
      },
      write: (name, value) async {
        writes.add('$name=$value');
        properties[name] = value;
      },
      isCurrent: () => current,
      generation: () => generation,
      buffering: () => buffering,
      preparing: () => preparing,
      now: () => now,
    );
  });

  test('native measured time parsing rejects unknown nonfinite negative and overflow', () {
    for (final value in [null, '', 'unknown', 'NaN', 'Infinity', '-1', '1e100', '5MiB']) {
      expect(syncPlayMeasuredMediaTime(value), isNull);
    }
    expect(syncPlayMeasuredMediaTime('0'), Duration.zero);
    expect(syncPlayMeasuredMediaTime('100.25'), const Duration(milliseconds: 100250));
  });
  test('fresh property allowlist copies absolute cache end and only scalar data', () async {
    final sample = await probe.sample();
    expect(sample.position, const Duration(milliseconds: 100250));
    expect(sample.bufferEnd, const Duration(milliseconds: 130500));
    expect(sample.duration, const Duration(seconds: 300));
    expect(sample.forwardBytes, 10000);
    expect(sample.observedAt, now);
    expect(sample.buffering, isFalse);
    expect(sample.preparing, isFalse);
    expect(reads.toSet(), {
      'time-pos',
      'demuxer-cache-time',
      'duration',
      'paused-for-cache',
      'demuxer-cache-state/fw-bytes',
      'seeking',
    });
    properties['demuxer-cache-time'] = '200';
    expect(sample.bufferEnd, const Duration(milliseconds: 130500));
    expect((await probe.sample()).bufferEnd, const Duration(seconds: 200));
    expect(writes, isEmpty);
  });
  test('unknown native metrics remain null, never PlayerState initial zeros', () async {
    properties['demuxer-cache-time'] = '';
    properties['demuxer-cache-state/fw-bytes'] = 'invalid';
    properties['duration'] = 'NaN';
    final sample = await probe.sample();
    expect(sample.bufferEnd, isNull);
    expect(sample.forwardBytes, isNull);
    expect(sample.duration, isNull);
    properties['time-pos'] = null;
    final unknown = await probe.sample();
    expect(unknown.position, lessThan(Duration.zero));
    expect(unknown.buffering, isTrue);
  });
  test('native HDR, seeking and raw waiting are distinct from buffer capacity', () async {
    preparing = true;
    expect((await probe.sample()).preparing, isTrue);
    preparing = false;
    properties['seeking'] = 'yes';
    expect((await probe.sample()).preparing, isTrue);
    properties['seeking'] = 'no';
    properties['paused-for-cache'] = 'yes';
    expect((await probe.sample()).buffering, isTrue);
    properties['paused-for-cache'] = 'no';
    buffering = true;
    expect((await probe.sample()).buffering, isTrue);
  });
  test('one budget write is shared across repeated and concurrent initialization', () async {
    final result = await Future.wait([probe.configureBudget(), probe.configureBudget(), probe.configureBudget()]);
    expect(result, everyElement(157286400));
    expect(writes, ['demuxer-max-bytes=157286400']);
    await probe.sample();
    await probe.sample();
    expect(writes.length, 1);
  });
  test('a smaller native budget is preserved and unavailable readback is not verified', () async {
    properties['demuxer-max-bytes'] = '1024';
    expect(await probe.configureBudget(), 1024);
    expect(writes, ['demuxer-max-bytes=1024']);
    final ignored = MpvSyncPlayBufferProbe(
      read: (_) async => null,
      write: (_, __) async {},
      isCurrent: () => true,
      generation: () => 1,
      buffering: () => false,
      preparing: () => false,
    );
    expect(await ignored.configureBudget(), isNull);
  });
  for (final change in ['media epoch', 'player', 'dispose']) {
    test('late native property replies are rejected after $change changes', () async {
      final gate = Completer<String?>();
      final delayed = MpvSyncPlayBufferProbe(
        read: (name) => name == 'time-pos' ? gate.future : Future.value(properties[name]),
        write: (_, __) async {},
        isCurrent: () => current,
        generation: () => generation,
        buffering: () => false,
        preparing: () => false,
        now: () => now,
      );
      final pending = delayed.sample();
      if (change == 'media epoch') generation++;
      if (change == 'player') current = false;
      if (change == 'dispose') delayed.dispose();
      gate.complete('100');
      final result = await pending;
      expect(result.position, lessThan(Duration.zero));
      expect(result.bufferEnd, isNull);
    });
  }
  test('disposing a pending budget cannot report verified support for a replacement', () async {
    final gate = Completer<String?>();
    final delayed = MpvSyncPlayBufferProbe(
      read: (_) => gate.future,
      write: (_, __) async {},
      isCurrent: () => current,
      generation: () => generation,
      buffering: () => false,
      preparing: () => false,
    );
    final pending = delayed.configureBudget();
    delayed.dispose();
    gate.complete('157286400');
    expect(await pending, isNull);
  });
  test(
    'optional unsupported properties do not discard measured position; required time timeout stays unknown',
    () async {
      final optional = MpvSyncPlayBufferProbe(
        read: (name) async {
          if (name == 'time-pos') return '10';
          throw StateError('synthetic unsupported property');
        },
        write: (_, __) async {},
        isCurrent: () => true,
        generation: () => 1,
        buffering: () => false,
        preparing: () => false,
      );
      final sample = await optional.sample();
      expect(sample.position, const Duration(seconds: 10));
      expect(sample.bufferEnd, isNull);
      final stalled = MpvSyncPlayBufferProbe(
        read: (_) => Completer<String?>().future,
        write: (_, __) async {},
        isCurrent: () => true,
        generation: () => 1,
        buffering: () => false,
        preparing: () => false,
        timeout: const Duration(milliseconds: 1),
      );
      expect((await stalled.sample()).position, lessThan(Duration.zero));
    },
  );
}
