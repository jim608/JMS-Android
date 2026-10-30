import 'package:fladder/services/syncplay/syncplay_prebuffer.dart';
import 'package:fladder/util/mpv_syncplay_buffer.dart';

Duration? syncPlayMeasuredMediaTime(String? raw) {
  final seconds = double.tryParse(raw?.trim() ?? '');
  if (seconds == null ||
      !seconds.isFinite ||
      seconds < 0 ||
      seconds > 9000000000) {
    return null;
  }
  return Duration(microseconds: (seconds * 1000000).round());
}

SyncPlayBufferSample unknownSyncPlayBufferSample(
        {DateTime Function()? now, bool preparing = false}) =>
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
  int _sampleSerial = 0;
  SyncPlayBufferSample? _idleRecovery;
  Object? _idleRecoveryGeneration;

  /// Native waiting/seek notifications revoke an in-flight observation even
  /// when media-kit's conflated buffering boolean stays true -> true.
  void invalidateIdleRecovery() {
    _sampleSerial++;
    _idleRecovery = null;
    _idleRecoveryGeneration = null;
  }

  /// Consume exactly the fresh, current observation that distinguished a
  /// subtitle/renderer idle from a real cache wait. This never plays or seeks.
  bool consumeIdleRecovery(SyncPlayBufferSample sample) {
    if (!_current ||
        !identical(sample, _idleRecovery) ||
        generation() != _idleRecoveryGeneration ||
        preparing() ||
        !buffering()) {
      return false;
    }
    final age = now().difference(sample.observedAt);
    if (age.isNegative || age > timeout) return false;
    _idleRecovery = null;
    _idleRecoveryGeneration = null;
    return true;
  }

  bool get _current => !_disposed && isCurrent();
  void dispose() {
    _disposed = true;
    invalidateIdleRecovery();
  }

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
    return _current && result.status == MpvSyncPlayBufferSettingStatus.verified
        ? result.actualBytes
        : null;
  }

  Future<SyncPlayBufferSample> sample() async {
    if (!_current) return unknownSyncPlayBufferSample(now: now);
    invalidateIdleRecovery();
    final serial = _sampleSerial;
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
        'core-idle',
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
      if (!_current || generation() != epoch || serial != _sampleSerial) {
        return unknownSyncPlayBufferSample(now: now);
      }
      final position = syncPlayMeasuredMediaTime(values[0]);
      if (position == null) {
        return unknownSyncPlayBufferSample(
            now: now, preparing: wasPreparing || preparing());
      }
      final bufferEnd = syncPlayMeasuredMediaTime(values[1]);
      final cacheWaiting = _nativeFlag(values[3]);
      final seeking = _nativeFlag(values[5]);
      final coreIdle = _nativeFlag(values[6]);
      final isPreparing = wasPreparing || preparing() || seeking == true;
      // media-kit emits buffering=true for core-idle as well as for actual
      // paused-for-cache. Changing sid/sub-add can idle the renderer without
      // starving the demuxer. Requiring that flag to clear before Play creates
      // a circular wait in SyncPlay. Only explicit native false flags plus a
      // real forward media range can distinguish this benign idle; unknown,
      // malformed, seeking, HDR preparation and real cache waits fail closed.
      final idleRecovery = (wasBuffering || buffering()) &&
          coreIdle == true &&
          cacheWaiting == false &&
          seeking == false &&
          !isPreparing &&
          bufferEnd != null &&
          bufferEnd > position;
      final result = SyncPlayBufferSample(
        position: position,
        bufferEnd: bufferEnd,
        duration: syncPlayMeasuredMediaTime(values[2]),
        forwardBytes: mpvSyncPlayForwardBytes(values[4]),
        buffering: !idleRecovery &&
            (wasBuffering || buffering() || cacheWaiting == true),
        preparing: isPreparing,
        observedAt: started,
      );
      if (idleRecovery) {
        _idleRecovery = result;
        _idleRecoveryGeneration = epoch;
      }
      return result;
    } catch (_) {
      return unknownSyncPlayBufferSample(
          now: now, preparing: _current && preparing());
    }
  }

  static bool? _nativeFlag(String? value) => switch (value?.trim()) {
        'yes' || 'true' || '1' => true,
        'no' || 'false' || '0' => false,
        _ => null,
      };
}
