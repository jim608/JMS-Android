import 'dart:convert';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart' as jellyfin;
import 'package:fladder/services/syncplay/syncplay_test_trace.dart';
import 'package:fladder/services/syncplay/syncplay_transport.dart';
import 'package:fladder/util/jms_test_profile_policy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'syncplay_transport_test.dart' as fixture;

void main() {
  test('TEST trace records real New 204 metadata and only hashed identities',
      () async {
    final lines = <String>[];
    final trace = SyncPlayTestTrace.enabledForTesting((line) async {
      lines.add(line);
    });
    const device = 'canary-private-control-device';
    const token = 'canary-private-token';
    const user = 'canary-private-user';
    final headers = {
      'authorization': 'MediaBrowser Token="$token", DeviceId="$device"',
      'canary-extra-header': user,
    };
    final api = jellyfin.JellyfinOpenApi.create(
      baseUrl: Uri.parse('https://fixture.example.invalid/canary-private-path'),
      httpClient: MockClient((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 2));
        return http.Response('', 204);
      }),
    );
    final socket = fixture.FakeSocket();
    final transport = SyncPlayTransport(
      api: api,
      baseUri: Uri.parse('https://fixture.example.invalid/canary-private-path'),
      token: token,
      deviceId: device,
      socketFactory: (_) => socket,
      socketHeaders: headers,
      traceRestHeaders: headers,
      testTrace: trace,
    );
    try {
      await transport.connect();
      expect(await transport.newGroup('JMS-012345'), isNull);
      socket.emit({
        'MessageType': 'SyncPlayGroupUpdate',
        'Data': {
          'Type': 'GroupJoined',
          'Data': {'UserId': user, 'RoomId': 'canary-private-room'},
        },
      });
      await trace.flush();
      final events = lines
          .map((line) => jsonDecode(line) as Map<String, dynamic>)
          .toList();
      final identity =
          events.singleWhere((event) => event['event'] == 'controlIdentity');
      expect(identity['identitiesMatch'], true);
      expect(identity['restDeviceHash'], matches(r'^[a-f0-9]{64}$'));
      expect(identity['restDeviceHash'], identity['socketHeaderDeviceHash']);
      expect(identity['restDeviceHash'], identity['socketQueryDeviceHash']);
      final response =
          events.singleWhere((event) => event['event'] == 'newHttp');
      expect(response['status'], 204);
      expect(response['elapsedMs'], greaterThanOrEqualTo(1));
      expect(response['bodyPresent'], false);
      expect(response['bodyShape'], 'empty');
      expect(events.where((event) => event['event'] == 'groupJoined'),
          hasLength(1));
      final encoded = lines.join();
      for (final raw in [
        device,
        token,
        user,
        'canary-private-path',
        'canary-private-room',
        'JMS-012345',
        'authorization'
      ]) {
        expect(encoded, isNot(contains(raw)));
      }
      for (var count = 0; count < 100; count++) {
        trace.groupJoined();
      }
      await trace.flush();
      expect(lines, hasLength(64));
    } finally {
      await transport.close();
    }
  });

  test('normal production build never writes TEST traces', () async {
    expect(JmsTestProfilePolicy.enabled, false);
    final lines = <String>[];
    final trace = SyncPlayTestTrace.localWindowsTest(writeLine: (line) async {
      lines.add(line);
    });
    trace.controlIdentity(
        restHeaders: const {},
        socketHeaders: const {},
        socketQueryDeviceId: 'canary-private-device');
    trace.newHttp(
        status: 204,
        elapsedMs: 9,
        bodyPresent: false,
        bodyShape: SyncPlayTraceBodyShape.empty);
    await trace.flush();
    expect(trace.enabled, false);
    expect(lines, isEmpty);
  });

  test('trace storage failures cannot fail a real New operation', () async {
    final trace = SyncPlayTestTrace.enabledForTesting((_) async {
      throw StateError('canary-private-storage-error');
    });
    final api = jellyfin.JellyfinOpenApi.create(
      httpClient: MockClient((_) async => http.Response('', 204)),
    );
    final socket = fixture.FakeSocket();
    final transport = SyncPlayTransport(
      api: api,
      baseUri: Uri.parse('https://fixture.example.invalid'),
      token: 'synthetic-only',
      deviceId: 'synthetic-control',
      socketFactory: (_) => socket,
      testTrace: trace,
    );
    try {
      await transport.connect();
      expect(await transport.newGroup('JMS-012345'), isNull);
      await trace.flush();
    } finally {
      await transport.close();
    }
  });
}
