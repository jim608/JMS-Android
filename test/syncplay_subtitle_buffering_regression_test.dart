import 'dart:async';

import 'package:fladder/util/syncplay_buffer_probe.dart';
import 'package:flutter_test/flutter_test.dart';

/// Native events only: these fixtures do not claim an actual subtitle decoder,
/// physical device or server acceptance test.
void main() {
  late Map<String, String?> properties;
  late bool rawWaiting, preparing, current;
  late int generation;
  late MpvSyncPlayBufferProbe probe;

  setUp(() {
    rawWaiting = false;
    preparing = false;
    current = true;
    generation = 1;
    properties = {
      'time-pos': '12',
      'demuxer-cache-time': '42',
      'duration': '300',
      'paused-for-cache': 'no',
      'seeking': 'no',
      'core-idle': 'no',
      'demuxer-cache-state/fw-bytes': '2048000',
    };
    probe = MpvSyncPlayBufferProbe(
      read: (name) async => properties[name],
      write: (_, __) async => fail('Readiness must not write native options'),
      isCurrent: () => current,
      generation: () => generation,
      buffering: () => rawWaiting,
      preparing: () => preparing,
    );
    addTearDown(probe.dispose);
  });

  test('ordinary playing and genuine seeking retain their readiness semantics',
      () async {
    expect((await probe.sample()).buffering, isFalse);
    properties['seeking'] = 'yes';
    expect((await probe.sample()).preparing, isTrue);
    properties['seeking'] = 'no';
    expect((await probe.sample()).preparing, isFalse);
  });

  test('measured healthy idle after a subtitle pulse is not cache starvation',
      () async {
    rawWaiting = true;
    properties['core-idle'] = 'yes';
    final sample = await probe.sample();
    expect(sample.position, const Duration(seconds: 12));
    expect(sample.bufferEnd, const Duration(seconds: 42));
    expect(sample.preparing, isFalse);
    expect(sample.buffering, isFalse,
        reason: 'core-idle plus a full cache must not deadlock group Unpause');
  });

  test('repeated idle events recover real cache waiting without raw false edge',
      () async {
    rawWaiting = true;
    properties['core-idle'] = 'yes';
    properties['paused-for-cache'] = 'yes';
    expect((await probe.sample()).buffering, isTrue);
    properties['paused-for-cache'] = 'no';
    for (var i = 0; i < 3; i++) {
      expect((await probe.sample()).buffering, isFalse,
          reason: 'Recovery is native evidence, not a timeout or play command');
    }
    properties['paused-for-cache'] = 'yes';
    expect((await probe.sample()).buffering, isTrue,
        reason: 'A later genuine cache stall must block again');
  });

  test('real starvation and preparation cannot be hidden by ample cache data',
      () async {
    rawWaiting = true;
    properties['core-idle'] = 'yes';
    properties['paused-for-cache'] = 'yes';
    expect((await probe.sample()).buffering, isTrue);
    properties['paused-for-cache'] = 'no';
    properties['seeking'] = 'yes';
    expect((await probe.sample()).preparing, isTrue);
    properties['seeking'] = 'no';
    preparing = true;
    expect((await probe.sample()).preparing, isTrue);
  });

  test('unknown and malformed direct observations retain conservative waiting',
      () async {
    rawWaiting = true;
    properties['core-idle'] = 'yes';
    for (final entry in <(String, String?)>[
      ('paused-for-cache', null),
      ('paused-for-cache', 'malformed'),
      ('seeking', null),
      ('core-idle', null),
      ('demuxer-cache-time', null),
      ('demuxer-cache-time', 'NaN'),
      ('demuxer-cache-time', '8'),
    ]) {
      final old = properties[entry.$1];
      properties[entry.$1] = entry.$2;
      expect((await probe.sample()).buffering, isTrue, reason: entry.$1);
      properties[entry.$1] = old;
    }
    properties['core-idle'] = 'no';
    expect((await probe.sample()).buffering, isTrue,
        reason: 'An unexplained raw waiting signal must not be cleared');
  });

  for (final replace in ['generation', 'backend']) {
    test('a late healthy reply cannot clear waiting after $replace replacement',
        () async {
      final gate = Completer<String?>();
      rawWaiting = true;
      properties['core-idle'] = 'yes';
      final delayed = MpvSyncPlayBufferProbe(
        read: (name) =>
            name == 'time-pos' ? gate.future : Future.value(properties[name]),
        write: (_, __) async => fail('No native writes'),
        isCurrent: () => current,
        generation: () => generation,
        buffering: () => rawWaiting,
        preparing: () => preparing,
      );
      addTearDown(delayed.dispose);
      final pending = delayed.sample();
      if (replace == 'generation') generation++;
      if (replace == 'backend') current = false;
      gate.complete('12');
      final stale = await pending;
      expect(stale.buffering, isTrue);
      expect(stale.position, lessThan(Duration.zero));
      expect(stale.bufferEnd, isNull);
    });
  }
}
