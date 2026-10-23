@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chopper/chopper.dart';
import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart' as jellyfin;
import 'package:fladder/services/syncplay/syncplay_controller.dart';
import 'package:fladder/services/syncplay/syncplay_models.dart';
import 'package:fladder/services/syncplay/syncplay_transport.dart';
import 'package:flutter_test/flutter_test.dart';

const _groupId = '11111111111111111111111111111111';
const _mediaId = '22222222222222222222222222222222';

/// Protocol integration fixture, not a Jellyfin server or playback acceptance.
/// It exercises real HTTP/WS framing and the production generated REST client;
/// its deliberately small room logic is not a replacement for Jellyfin testing.
class _LoopbackJellyfin {
  late final HttpServer _server;
  StreamSubscription<HttpRequest>? _requests;
  final sockets = <String, WebSocket>{};
  final _allSockets = <WebSocket>[];
  final members = <String>{};
  final wire = <_WireRequest>[];
  String? groupName;
  List<Map<String, dynamic>> playlist = [];
  int playingIndex = 0;
  int positionTicks = 0;
  bool playing = false;
  int socketConnections = 0;
  int socketDisconnections = 0;
  int _queueSerial = 0;
  DateTime _lastUpdate = DateTime.now().toUtc();

  Uri get baseUri => Uri.parse('http://127.0.0.1:${_server.port}/demo');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _requests = _server.listen((request) => unawaited(_handle(request)));
  }

  Map<String, dynamic> _group() => {
        'GroupId': _groupId,
        'GroupName': groupName,
        'State': playing ? 'Playing' : 'Paused',
        'Participants': members.toList(),
        'LastUpdatedAt': _lastUpdate.toIso8601String(),
      };

  Map<String, dynamic> _queue() => {
        'Reason': 'NewPlaylist',
        'LastUpdate': _lastUpdate.toIso8601String(),
        'Playlist': playlist,
        'PlayingItemIndex': playingIndex,
        'StartPositionTicks': positionTicks,
        'IsPlaying': playing,
        'ShuffleMode': 'Sorted',
        'RepeatMode': 'RepeatNone',
      };

  void _sendGroup(String token, String type, Object? data) {
    sockets[token]?.add(jsonEncode({
      'MessageType': 'SyncPlayGroupUpdate',
      'Data': {'GroupId': _groupId, 'Type': type, 'Data': data},
    }));
  }

  void _broadcastQueue() {
    for (final token in members) {
      _sendGroup(token, 'PlayQueue', _queue());
    }
  }

  void _broadcastCommand(String command) {
    final emitted = DateTime.now().toUtc();
    final when = emitted.add(const Duration(milliseconds: 300));
    for (final token in members) {
      sockets[token]?.add(jsonEncode({
        'MessageType': 'SyncPlayCommand',
        'Data': {
          'GroupId': _groupId,
          'PlaylistItemId': playlist[playingIndex]['PlaylistItemId'],
          'Command': command,
          'When': when.toIso8601String(),
          'EmittedAt': emitted.toIso8601String(),
          'PositionTicks': positionTicks,
        },
      }));
    }
  }

  Future<void> _json(HttpRequest request, Object? value,
      [int status = 200]) async {
    request.response.statusCode = status;
    if (status != 204) {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(value));
    }
    await request.response.close();
  }

  Future<void> _handle(HttpRequest request) async {
    final reception = DateTime.now().toUtc();
    if (request.uri.path == '/demo/socket') {
      final token = request.uri.queryParameters['api_key'];
      final device = request.uri.queryParameters['deviceId'];
      if (!const {'friend-a', 'friend-b', 'denied'}.contains(token) ||
          device != 'device-$token' ||
          !WebSocketTransformer.isUpgradeRequest(request)) {
        await _json(request, {'error': 'unauthorized'}, 401);
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      sockets[token!] = socket;
      _allSockets.add(socket);
      socketConnections++;
      socket.listen((_) {}, onDone: () {
        if (identical(sockets[token], socket)) sockets.remove(token);
        socketDisconnections++;
      });
      return;
    }
    final auth = request.headers.value('authorization') ?? '';
    final token = RegExp(r'Token="([^"]+)"').firstMatch(auth)?.group(1);
    final device = RegExp(r'DeviceId="([^"]+)"').firstMatch(auth)?.group(1);
    if (!const {'friend-a', 'friend-b', 'denied'}.contains(token) ||
        device != 'device-$token') {
      await _json(request, {'error': 'unauthorized'}, 401);
      return;
    }
    final text = await utf8.decoder.bind(request).join();
    final body =
        text.isEmpty ? <String, dynamic>{} : syncPlayMap(jsonDecode(text));
    final endpoint = request.uri.path.split('/').last;
    wire.add(_WireRequest(token!, request.method, endpoint, body));
    if (token == 'denied') {
      await _json(request, {'error': 'SyncPlay denied'}, 403);
      return;
    }
    switch (endpoint) {
      case 'GetUtcTime':
        await _json(request, {
          'RequestReceptionTime': reception.toIso8601String(),
          'ResponseTransmissionTime': DateTime.now().toUtc().toIso8601String(),
        });
      case 'List':
        await _json(request, groupName == null ? [] : [_group()]);
      case 'New':
        groupName = body['GroupName'] as String;
        members.add(token);
        _lastUpdate = DateTime.now().toUtc();
        _sendGroup(token, 'GroupJoined', _group());
        await _json(request, _group());
      case 'Join':
        if (body['GroupId'] != _groupId || groupName == null) {
          await _json(request, {'error': 'unknown group'}, 404);
          return;
        }
        members.add(token);
        _sendGroup(token, 'GroupJoined', _group());
        if (playlist.isNotEmpty) _sendGroup(token, 'PlayQueue', _queue());
        await _json(request, null, 204);
      case 'Leave':
        members.remove(token);
        _sendGroup(token, 'GroupLeft', _groupId);
        await _json(request, null, 204);
      case 'SetNewQueue':
        playlist = (body['PlayingQueue'] as List)
            .map((item) => {
                  'ItemId': item,
                  'PlaylistItemId':
                      (++_queueSerial).toRadixString(16).padLeft(32, '0'),
                })
            .toList();
        playingIndex = body['PlayingItemPosition'] as int;
        positionTicks = body['StartPositionTicks'] as int;
        _lastUpdate = DateTime.now().toUtc();
        _broadcastQueue();
        await _json(request, null, 204);
      case 'Unpause':
      case 'Pause':
      case 'Seek':
        if (endpoint == 'Seek') positionTicks = body['PositionTicks'] as int;
        playing = endpoint == 'Unpause';
        _broadcastCommand(endpoint);
        await _json(request, null, 204);
      case 'Buffering':
      case 'Ready':
      case 'Ping':
        await _json(request, null, 204);
      default:
        await _json(request, {'error': 'unsupported fixture endpoint'}, 404);
    }
  }

  int count(String endpoint, {String? token}) => wire
      .where((item) =>
          item.endpoint == endpoint && (token == null || item.token == token))
      .length;

  Future<void> disconnect(String token) async => sockets[token]?.close(1001);

  Future<void> close() async {
    for (final socket in _allSockets) {
      await socket.close(1000);
    }
    await _requests?.cancel();
    await _server.close(force: true);
  }
}

class _WireRequest {
  _WireRequest(this.token, this.method, this.endpoint, this.body);
  final String token;
  final String method;
  final String endpoint;
  final Map<String, dynamic> body;
}

class _Player implements SyncPlayPlayerPort {
  @override
  String? mediaId;
  @override
  String? playlistItemId;
  @override
  Duration position = Duration.zero;
  @override
  bool isPlaying = false;
  final actions = <SyncPlayPlayerAction>[];

  @override
  Future<void> applyRemote(SyncPlayPlayerAction action) async {
    actions.add(action);
    position = action.position;
    if (action.type == SyncPlayPlayerActionType.load) {
      mediaId = action.queueItem!.mediaId;
      playlistItemId = action.queueItem!.playlistItemId;
    }
    isPlaying = action.type == SyncPlayPlayerActionType.unpause;
  }

  int count(SyncPlayPlayerActionType type) =>
      actions.where((item) => item.type == type).length;
}

class _Client {
  _Client(_LoopbackJellyfin server, String token) {
    final api = jellyfin.JellyfinOpenApi.create(
      baseUrl: server.baseUri,
      interceptors: [
        HeadersInterceptor({
          'authorization':
              'MediaBrowser Token="$token", DeviceId="device-$token"'
        })
      ],
    );
    transport = SyncPlayTransport(
        api: api,
        baseUri: server.baseUri,
        token: token,
        deviceId: 'device-$token');
    controller = SyncPlayController(
      identity: SyncPlayIdentity(
          sourceId: server.baseUri.toString(),
          userId: token,
          sessionId: 'device-$token:1'),
      api: transport,
      player: player,
      events: transport.events,
      operationTimeout: const Duration(seconds: 2),
    );
    controller.setConnected(false);
    _connections = transport.connections.listen(controller.setConnected);
  }
  final player = _Player();
  late final SyncPlayTransport transport;
  late final SyncPlayController controller;
  StreamSubscription<bool>? _connections;

  Future<void> close() async {
    await controller.dispose();
    await _connections?.cancel();
    await transport.close();
  }
}

Future<void> _until(bool Function() condition, String description) async {
  final stopwatch = Stopwatch()..start();
  while (!condition()) {
    if (stopwatch.elapsed > const Duration(seconds: 3)) {
      fail('Timed out waiting for $description');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test(
      'two real loopback transports coordinate queue, scheduled controls, readiness and explicit rejoin',
      () async {
    final server = _LoopbackJellyfin();
    await server.start();
    final a = _Client(server, 'friend-a');
    final b = _Client(server, 'friend-b');
    addTearDown(() async {
      await a.close();
      await b.close();
      await server.close();
    });
    await Future.wait([a.transport.connect(), b.transport.connect()]);
    await a.controller.createRoom('012345');
    await b.controller.joinRoom('012345');
    await _until(
        () => a.controller.state.canControl && b.controller.state.canControl,
        'both joined and clock synchronized');
    expect(server.count('New'), 1);
    expect(server.count('Join'), 1);
    await a.controller.setQueue([_mediaId, _mediaId],
        startIndex: 1, position: const Duration(seconds: 4));
    await _until(
        () =>
            a.player.playlistItemId != null && b.player.playlistItemId != null,
        'both queue loads');
    await _until(() => server.count('Ready') >= 2 && server.count('Ping') >= 2,
        'own-account Ready and half-RTT Ping');
    expect(server.playlist.map((item) => item['PlaylistItemId']).toSet(),
        hasLength(2));
    expect(a.player.mediaId, _mediaId);
    expect(b.player.mediaId, _mediaId);
    expect(a.player.playlistItemId, server.playlist[1]['PlaylistItemId']);
    expect(b.player.playlistItemId, a.player.playlistItemId);
    expect(a.player.playlistItemId, isNot(_mediaId));

    await a.controller.requestUnpause();
    expect(a.player.count(SyncPlayPlayerActionType.unpause), 0);
    await _until(() => a.player.isPlaying && b.player.isPlaying,
        'scheduled server Unpause on both clients');
    expect(server.count('Unpause'), 1,
        reason: 'remote applications must not echo requests');
    await b.controller.requestPause();
    await _until(
        () =>
            a.player.count(SyncPlayPlayerActionType.pause) == 1 &&
            b.player.count(SyncPlayPlayerActionType.pause) == 1,
        'scheduled Pause on both clients');
    expect(server.count('Pause'), 1);

    final readyBeforeSeek = server.count('Ready');
    await a.controller.requestSeek(const Duration(seconds: 12));
    await _until(
        () =>
            a.player.position == const Duration(seconds: 12) &&
            b.player.position == const Duration(seconds: 12),
        'scheduled Seek on both clients');
    await _until(() => server.count('Ready') >= readyBeforeSeek + 2,
        'Ready after each completed seek');
    expect(server.count('Seek'), 1);
    await b.controller.reportBuffering(true);
    await b.controller.reportReady();
    final buffering =
        server.wire.singleWhere((item) => item.endpoint == 'Buffering');
    expect(buffering.token, 'friend-b');
    expect(buffering.body['PlaylistItemId'], b.player.playlistItemId);
    expect(buffering.body['PositionTicks'], 120000000);
    expect(buffering.body['IsPlaying'], false);
    expect(DateTime.parse(buffering.body['When'] as String).isUtc, true);

    await server.disconnect('friend-b');
    await _until(() => b.controller.state.status == SyncPlayStatus.disconnected,
        'disconnection propagation');
    await b.transport.reconnect();
    await b.controller.reconnect();
    await _until(
        () => b.controller.state.canControl, 'explicit rejoin and fresh clock');
    expect(server.socketConnections, 3);
    expect(server.count('New'), 1,
        reason: 'reconnect must not create another room');
    expect(server.count('Join', token: 'friend-b'), 2);
    await b.controller.leaveRoom();
    expect(b.controller.state.status, SyncPlayStatus.idle);
    expect(a.controller.state.isJoined, true);
    await a.controller.leaveRoom();
    expect(server.members, isEmpty);
    await a.close();
    await b.close();
    await _until(() => server.socketDisconnections == 3,
        'all owned loopback sockets close');
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('server permissions are preserved through the production transport',
      () async {
    final server = _LoopbackJellyfin();
    await server.start();
    final client = _Client(server, 'denied');
    addTearDown(() async {
      await client.close();
      await server.close();
    });
    await client.transport.connect();
    await client.controller.createRoom('123456');
    expect(client.controller.state.failure?.code, SyncPlayFailureCode.denied);
    expect(client.controller.state.isJoined, false);
    expect(server.count('New'), 0);
    expect(client.player.actions, isEmpty);
  }, timeout: const Timeout(Duration(seconds: 10)));
}
