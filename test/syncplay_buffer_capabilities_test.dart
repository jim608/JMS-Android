import 'dart:async';

import 'package:fladder/util/mpv_syncplay_buffer.dart';
import 'package:fladder/util/web_syncplay_buffer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('forward byte metadata never treats unknown malformed or negative as zero', () {
    for (final value in [null, '', 'unknown', '-1', 'NaN', '1.2']) {
      expect(mpvSyncPlayForwardBytes(value), isNull);
    }
    expect(mpvSyncPlayForwardBytes('0'), 0);
    expect(mpvSyncPlayForwardBytes('157286400'), maximumMpvSyncPlayForwardBytes);
  });
  test('native ahead subtracts position and clamps backwards cache endpoints', () {
    expect(
      mpvSyncPlayBufferAhead(position: const Duration(seconds: 100), bufferEnd: const Duration(seconds: 105)),
      const Duration(seconds: 5),
    );
    expect(
      mpvSyncPlayBufferAhead(position: const Duration(seconds: 100), bufferEnd: const Duration(seconds: 20)),
      Duration.zero,
    );
  });
  test('web only measures a contiguous range containing the playhead', () {
    Duration? end(List<SyncPlayBufferedRange>? ranges) =>
        webSyncPlayContiguousBufferEnd(position: const Duration(seconds: 10), ranges: ranges);
    expect(end(null), isNull);
    expect(end([]), const Duration(seconds: 10));
    expect(end([const SyncPlayBufferedRange(0, 5), const SyncPlayBufferedRange(20, 100)]), const Duration(seconds: 10));
    expect(
      end([const SyncPlayBufferedRange(9, 12), const SyncPlayBufferedRange(20, 100)]),
      const Duration(seconds: 12),
    );
    expect(
      end([
        const SyncPlayBufferedRange(12, 14),
        const SyncPlayBufferedRange(9, 12),
        const SyncPlayBufferedRange(13, 16),
      ]),
      const Duration(seconds: 16),
    );
    expect(end([const SyncPlayBufferedRange(9, double.nan)]), isNull);
    expect(
      end([const SyncPlayBufferedRange(9, 12), const SyncPlayBufferedRange(12.001, 20)]),
      const Duration(seconds: 12),
    );
  });
  test('native write completion alone never claims the cache setting took effect', () async {
    final calls = <String>[];
    final result = await capMpvSyncPlayForwardBuffer(
      read: (_) async => '1',
      write: (key, value) async {
        calls.add('$key=$value');
      },
    );
    expect(result.status, MpvSyncPlayBufferSettingStatus.verified); // Existing smaller cap is retained.
    expect(calls, ['demuxer-max-bytes=1']);
    var reads = 0;
    final ignored = await capMpvSyncPlayForwardBuffer(
      read: (_) async => ++reads == 1 ? null : '999999999',
      write: (_, __) async {},
    );
    expect(ignored.status, MpvSyncPlayBufferSettingStatus.unverified);
    expect(ignored.requestedBytes, maximumMpvSyncPlayForwardBytes);
  });
  test('readback verifies at most150MiB; empty unsupported mismatched or thrown remain explicit', () async {
    String? option;
    final verified = await capMpvSyncPlayForwardBuffer(
      requestedBytes: 999999999,
      read: (_) async => option,
      write: (_, value) async {
        option = value;
      },
    );
    expect(verified.status, MpvSyncPlayBufferSettingStatus.verified);
    expect(verified.actualBytes, maximumMpvSyncPlayForwardBytes);
    final unknown = await capMpvSyncPlayForwardBuffer(read: (_) async => null, write: (_, __) async {});
    expect(unknown.status, MpvSyncPlayBufferSettingStatus.unverified);
    final failed = await capMpvSyncPlayForwardBuffer(
      read: (_) async => throw StateError('synthetic unsupported'),
      write: (_, __) async {},
    );
    expect(failed.status, MpvSyncPlayBufferSettingStatus.failed);
    final timed = await capMpvSyncPlayForwardBuffer(
      read: (_) => Completer<String?>().future,
      write: (_, __) async {},
      timeout: const Duration(milliseconds: 1),
    );
    expect(timed.status, MpvSyncPlayBufferSettingStatus.failed);
  });
}
