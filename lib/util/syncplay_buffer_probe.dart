import 'package:fladder/services/syncplay/syncplay_prebuffer.dart';
import 'package:fladder/util/mpv_syncplay_buffer.dart';

Duration? syncPlayMeasuredMediaTime(String? raw) {
  final seconds = double.tryParse(raw?.trim() ?? '');
  if (seconds == null || !seconds.isFinite || seconds < 0 || seconds > 9000000000) return null;
  return Duration(microseconds: (seconds * 1000000).round());
}

SyncPlayBufferSample unknownSyncPlayBufferSample({DateTime Function()? now, bool preparing = false}) =>
    SyncPlayBufferSample(
      position: const Duration(microseconds: -1),
      buffering: true,
      observedAt: (now ?? DateTime.now)(),
      preparing: preparing,
    );

/// One native backend lifetime. No URL, account, title or track metadata is read.
class MpvSyncPlayBufferProbe {
  MpvSyncPlayBufferProbe({
    required this.read,
    required this.write,
    required this.isCurrent,
    required this.generation,
    required this.buffering,
    required this.preparing,
    DateTime Function()? now,
    this.timeout = const Duration(milliseconds: 750),
  }) : now = now ?? DateTime.now;

  final Future<String?> Function(String property) read;
  final Future<void> Function(String property, String value) write;
  final bool Function() isCurrent, buffering, preparing;
  final Object Function() generation;
  final DateTime Function() now;
  final Duration timeout;
  bool _disposed = false;
  Future<int?>? _budget;

  bool get _current => !_disposed && isCurrent();
  void dispose() => _disposed = true;

  Future<int?> configureBudget() {
    if (!_current) return Future.value();
    return _budget ??= _configureBudget();
  }

  Future<int?> _configureBudget() async {
    final result = await capMpvSyncPlayForwardBuffer(
      read: (name) async => _current ? read(name) : null,
      write: (name, value) async {
        if (!_current) throw StateError('Native buffer backend was replaced');
        await write(name, value);
      },
      timeout: timeout,
    );
    return _current && result.status == MpvSyncPlayBufferSettingStatus.verified ? result.actualBytes : null;
  }

  Future<SyncPlayBufferSample> sample() async {
    if (!_current) return unknownSyncPlayBufferSample(now: now);
    final epoch = generation();
    final started = now();
    final wasBuffering = buffering();
    final wasPreparing = preparing();
    try {
      const properties = [
        'time-pos',
        'demuxer-cache-time',
        'duration',
        'paused-for-cache',
        'demuxer-cache-state/fw-bytes',
        'seeking',
      ];
      final values = await Future.wait(
        properties.map((name) async {
          try {
            return await read(name).timeout(timeout);
          } catch (_) {
            return null;
          }
        }),
      );
      if (!_current || generation() != epoch) return unknownSyncPlayBufferSample(now: now);
      final position = syncPlayMeasuredMediaTime(values[0]);
      if (position == null) return unknownSyncPlayBufferSample(now: now, preparing: wasPreparing || preparing());
      return SyncPlayBufferSample(
        position: position,
        bufferEnd: syncPlayMeasuredMediaTime(values[1]),
        duration: syncPlayMeasuredMediaTime(values[2]),
        forwardBytes: mpvSyncPlayForwardBytes(values[4]),
        buffering: wasBuffering || buffering() || values[3] == 'yes' || values[3] == 'true' || values[3] == '1',
        preparing: wasPreparing || preparing() || values[5] == 'yes' || values[5] == 'true' || values[5] == '1',
        observedAt: started,
      );
    } catch (_) {
      return unknownSyncPlayBufferSample(now: now, preparing: _current && preparing());
    }
  }
}
