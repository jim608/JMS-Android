import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'package:fladder/util/jms_test_profile_policy.dart';

import 'syncplay_test_trace_sink_stub.dart'
    if (dart.library.io) 'syncplay_test_trace_sink_io.dart' as sink;

enum SyncPlayTraceBodyShape { empty, groupDto, other }

/// Local TEST-only evidence with a fixed schema. Never accepts log messages,
/// URLs, response contents or exception strings.
class SyncPlayTestTrace {
  SyncPlayTestTrace._(this.enabled, this._writeLine);

  factory SyncPlayTestTrace.localWindowsTest({
    Future<void> Function(String)? writeLine,
  }) =>
      SyncPlayTestTrace._(
        JmsTestProfilePolicy.enabled && sink.isNativeWindows,
        writeLine ?? sink.writeSyncPlayTestTraceLine,
      );

  @visibleForTesting
  factory SyncPlayTestTrace.enabledForTesting(
          Future<void> Function(String) writeLine) =>
      SyncPlayTestTrace._(true, writeLine);

  final bool enabled;
  final Future<void> Function(String) _writeLine;
  Future<void> _writes = Future.value();
  String? _controlHash;
  int _events = 0;
  int _joined = 0;
  int _left = 0;
  static const _maximumEvents = 64;

  String? _deviceId(Map<String, String>? headers) {
    if (headers == null) return null;
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == 'authorization') {
        return RegExp(r'(?:^|,\s*)DeviceId="([^"]*)"')
            .firstMatch(entry.value)
            ?.group(1);
      }
    }
    return null;
  }

  String? _hash(String? value) =>
      value == null ? null : sha256.convert(utf8.encode(value)).toString();

  void controlIdentity({
    required Map<String, String>? restHeaders,
    required Map<String, String>? socketHeaders,
    required String? socketQueryDeviceId,
  }) {
    if (!enabled) return;
    final rest = _hash(_deviceId(restHeaders));
    final socket = _hash(_deviceId(socketHeaders));
    final query = _hash(socketQueryDeviceId);
    _controlHash = query;
    _record('controlIdentity', {
      'restDeviceHash': rest,
      'socketHeaderDeviceHash': socket,
      'socketQueryDeviceHash': query,
      'identitiesMatch': rest != null && rest == socket && rest == query,
    });
  }

  void socketOpened() => _record('socketOpened', const {});

  void newHttp({
    required int status,
    required int elapsedMs,
    required bool bodyPresent,
    required SyncPlayTraceBodyShape bodyShape,
  }) =>
      _record('newHttp', {
        'status': status >= 100 && status <= 599 ? status : 0,
        'elapsedMs': elapsedMs.clamp(0, 3600000),
        'bodyPresent': bodyPresent,
        'bodyShape': bodyShape.name,
      });

  void newFailed({required int elapsedMs}) => _record('newFailed', {
        'elapsedMs': elapsedMs.clamp(0, 3600000),
        'stage': 'httpOrConversion',
      });

  void groupJoined() => _record('groupJoined', {'count': ++_joined});
  void groupLeft() => _record('groupLeft', {'count': ++_left});

  void _record(String event, Map<String, Object?> fields) {
    if (!enabled || _events >= _maximumEvents) return;
    _events++;
    try {
      final line = '${jsonEncode({
            'schema': 1,
            'timeUtc': DateTime.now().toUtc().toIso8601String(),
            'event': event,
            'controlHash': _controlHash,
            ...fields,
          })}\n';
      _writes = _writes.then((_) => _writeLine(line)).catchError((Object _) {});
    } catch (_) {
      // Diagnostics must never change a room operation's result.
    }
  }

  @visibleForTesting
  Future<void> flush() => _writes;
}
