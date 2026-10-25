import 'dart:async';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart' as jellyfin;
import 'package:fladder/services/syncplay/syncplay_clock.dart';
import 'package:fladder/services/syncplay/syncplay_controller.dart';
import 'package:fladder/services/syncplay/syncplay_models.dart';
import 'package:fladder/services/syncplay/syncplay_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'syncplay_controller_test.dart' as fixture;
import 'syncplay_transport_test.dart' as transport_fixture;

// Exercise the real production HTTP conversion, transport and controller.
// Official Jellyfin 10.10.7 SyncPlayController.New returns HTTP 204; 10.11+
// returns GroupInfoDto. No live Jellyfin server or native player is involved.
class _LegacyNewFixture {
  _LegacyNewFixture() {
    player = fixture.Player(world);
    final api = jellyfin.JellyfinOpenApi.create(
      baseUrl: Uri.parse('https://jellyfin.example.invalid'),
      httpClient: MockClient((request) async {
        final endpoint = request.url.path.split('/').last;
        requests.add(endpoint);
        switch (endpoint) {
          case 'List':
            return transport_fixture.jsonResponse([]);
          case 'New':
            newStarted.complete();
            await newGate?.future;
            return newStatus == 204
                ? http.Response('', 204)
                : transport_fixture.jsonResponse(newBody);
          case 'GetUtcTime':
            final now = world.now.toIso8601String();
            return transport_fixture.jsonResponse({
              'RequestReceptionTime': now,
              'ResponseTransmissionTime': now,
            });
          default:
            return http.Response('', 204);
        }
      }),
    );
    transport = SyncPlayTransport(
      api: api,
      baseUri: Uri.parse('https://jellyfin.example.invalid'),
      token: 'synthetic-legacy-only',
      deviceId: 'synthetic-control-device',
      socketFactory: (_) => socket,
    );
    controller = SyncPlayController(
      identity: fixture.identity,
      api: transport,
      player: player,
      events: transport.events,
      scheduler: world,
      clock: SyncPlayClock(now: () => world.now),
      cancelPendingPlayerActions: () => player.cancellations++,
    );
  }

  final world = fixture.World();
  final socket = transport_fixture.FakeSocket();
  final requests = <String>[];
  final newStarted = Completer<void>();
  Completer<void>? newGate;
  int newStatus = 204;
  Object? newBody;
  late final fixture.Player player;
  late final SyncPlayTransport transport;
  late final SyncPlayController controller;

  Map<String, dynamic> group({String name = 'JMS-012345'}) => {
        ...transport_fixture.group(),
        'GroupName': name,
        'LastUpdatedAt': world.now.toIso8601String(),
      };

  void joined({String name = 'JMS-012345'}) => socket.emit({
        'MessageType': 'SyncPlayGroupUpdate',
        'Data': {
          'GroupId': transport_fixture.groupId,
          'Type': 'GroupJoined',
          'Data': group(name: name),
        },
      });

  Future<void> close() async {
    if (newGate != null && !newGate!.isCompleted) newGate!.complete();
    await controller.dispose();
    await transport.close();
  }
}

void main() {
  late _LegacyNewFixture scenario;
  setUp(() async {
    scenario = _LegacyNewFixture();
    await scenario.transport.connect();
  });
  tearDown(() => scenario.close());

  test('legacy New confirms a real GroupJoined that precedes HTTP 204',
      () async {
    scenario.newGate = Completer<void>();
    final creating = scenario.controller.createRoom('012345');
    await scenario.newStarted.future;
    scenario.joined();
    expect(scenario.controller.state.isJoined, true);
    scenario.newGate!.complete();
    await creating;
    expect(scenario.controller.state.failure, isNull);
    expect(scenario.requests.where((e) => e == 'New'), hasLength(1));
  });

  test('legacy New 204 waits for matching GroupJoined after the response',
      () async {
    final creating = scenario.controller.createRoom('012345');
    await scenario.newStarted.future;
    await fixture.settle();
    expect(scenario.controller.state.status, SyncPlayStatus.creating);
    expect(scenario.controller.state.failure, isNull);
    expect(scenario.controller.state.group, isNull);
    scenario.joined(name: 'JMS-654321');
    expect(scenario.controller.state.group, isNull);
    scenario.joined();
    await creating;
    expect(scenario.controller.state.isJoined, true);
    expect(scenario.controller.state.group?.code, '012345');
    expect(scenario.requests.where((e) => e == 'New'), hasLength(1));
  });

  test('legacy New 204 without GroupJoined becomes unknown without replay',
      () async {
    final creating = scenario.controller.createRoom('012345');
    await scenario.newStarted.future;
    await fixture.settle();
    await scenario.world.advance(const Duration(seconds: 11));
    await creating;
    expect(scenario.controller.state.status, SyncPlayStatus.unknown);
    expect(scenario.controller.state.failure?.code,
        SyncPlayFailureCode.timeoutUnknown);
    expect(scenario.controller.state.group, isNull);
    await scenario.controller.createRoom('654321');
    expect(scenario.requests.where((e) => e == 'New'), hasLength(1));
  });

  test('Leave revokes delayed legacy New 204 and all late GroupJoined replies',
      () async {
    scenario.newGate = Completer<void>();
    final creating = scenario.controller.createRoom('012345');
    await scenario.newStarted.future;
    final leaving = scenario.controller.leaveRoom();
    expect(scenario.controller.leaveRequested, true);
    expect(scenario.controller.state.canControl, false);
    scenario.joined();
    expect(scenario.controller.state.group, isNull);
    scenario.newGate!.complete();
    await Future.wait([creating, leaving]);
    scenario.joined();
    expect(scenario.controller.state.status, SyncPlayStatus.idle);
    expect(scenario.controller.state.group, isNull);
    expect(scenario.player.actions, isEmpty);
    expect(scenario.requests.where((e) => e == 'New'), hasLength(1));
    expect(scenario.requests.where((e) => e == 'Leave'), hasLength(1));
    expect(scenario.requests.where((e) => e == 'Join'), isEmpty);
  });

  test(
      'malformed New HTTP 200 remains ambiguous rather than fabricating a room',
      () async {
    scenario.newStatus = 200;
    scenario.newBody = <String, dynamic>{};
    await scenario.controller.createRoom('012345');
    expect(scenario.controller.state.status, SyncPlayStatus.unknown);
    expect(scenario.controller.state.failure?.code,
        SyncPlayFailureCode.timeoutUnknown);
    expect(scenario.controller.state.group, isNull);
  });

  test('current New HTTP 200 DTO still confirms without a websocket reply',
      () async {
    scenario.newStatus = 200;
    scenario.newBody = scenario.group();
    await scenario.controller.createRoom('012345');
    expect(scenario.controller.state.isJoined, true);
    expect(scenario.controller.state.failure, isNull);
    expect(scenario.controller.state.group?.code, '012345');
    expect(scenario.requests.where((e) => e == 'New'), hasLength(1));
  });
}
