import 'dart:async';

import 'syncplay_models.dart';

abstract interface class SyncPlayCancellation {
  void cancel();
}

abstract interface class SyncPlayScheduler {
  SyncPlayCancellation schedule(Duration delay, void Function() callback);
}

class SyncPlayTimerScheduler implements SyncPlayScheduler {
  const SyncPlayTimerScheduler();
  @override
  SyncPlayCancellation schedule(Duration delay, void Function() callback) =>
      _TimerCancellation(
          Timer(delay.isNegative ? Duration.zero : delay, callback));
}

class _TimerCancellation implements SyncPlayCancellation {
  _TimerCancellation(this.timer);
  final Timer timer;
  @override
  void cancel() => timer.cancel();
}

/// NTP-style estimate used by Jellyfin Web TimeSync.js at commit
/// 5ab0379f5106439aa6266ca3b8824a642059f1a2. Ping is half network RTT.
class SyncPlayClock {
  SyncPlayClock({
    DateTime Function()? now,
    this.maximumSampleAge = const Duration(minutes: 2),
    this.maximumRoundTrip = const Duration(seconds: 10),
  }) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final Duration maximumSampleAge;
  final Duration maximumRoundTrip;
  final List<_Measurement> _measurements = [];

  DateTime get now => _now().toUtc();
  _Measurement? get _best {
    final current = now;
    _measurements.removeWhere((sample) =>
        current.isBefore(sample.receivedAt) ||
        current.difference(sample.receivedAt) > maximumSampleAge);
    if (_measurements.isEmpty) return null;
    return _measurements.reduce((a, b) => a.delay <= b.delay ? a : b);
  }

  bool get isSynchronized => _best != null;
  Duration get offset => _best?.offset ?? Duration.zero;
  Duration get ping =>
      Duration(microseconds: (_best?.delay.inMicroseconds ?? 0) ~/ 2);
  DateTime get serverNow => toServer(now);
  DateTime toServer(DateTime local) => local.toUtc().add(offset);
  DateTime toLocal(DateTime server) => server.toUtc().subtract(offset);

  bool recordSample({
    required DateTime sentAt,
    required DateTime receivedAt,
    required SyncPlayServerTime serverTime,
  }) {
    final roundTrip = receivedAt.difference(sentAt);
    final processing = serverTime.responseTransmissionTime
        .difference(serverTime.requestReceptionTime);
    final delay = roundTrip - processing;
    if (roundTrip.isNegative ||
        processing.isNegative ||
        delay.isNegative ||
        roundTrip > maximumRoundTrip ||
        receivedAt.isAfter(now) ||
        now.difference(receivedAt) > maximumSampleAge) {
      return false;
    }
    final offsetMicros =
        (serverTime.requestReceptionTime.difference(sentAt).inMicroseconds +
                serverTime.responseTransmissionTime
                    .difference(receivedAt)
                    .inMicroseconds) ~/
            2;
    _measurements.add(_Measurement(
        receivedAt.toUtc(), delay, Duration(microseconds: offsetMicros)));
    if (_measurements.length > 8) _measurements.removeAt(0);
    return true;
  }

  void reset() => _measurements.clear();
}

class _Measurement {
  const _Measurement(this.receivedAt, this.delay, this.offset);
  final DateTime receivedAt;
  final Duration delay;
  final Duration offset;
}
