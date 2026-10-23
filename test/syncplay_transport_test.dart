import 'dart:async';
import 'dart:convert';

import 'package:chopper/chopper.dart';
import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart' as jellyfin;
import 'package:fladder/services/syncplay/syncplay_clock.dart';
import 'package:fladder/services/syncplay/syncplay_models.dart';
import 'package:fladder/services/syncplay/syncplay_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const groupId = '11111111111111111111111111111111';
const mediaId = '22222222222222222222222222222222';
const playlistId = '33333333333333333333333333333333';
const capturedToken = 'synthetic-token-do-not-log';
const now = '2026-10-23T12:00:00.000Z';

Map<String, dynamic> group() => {
      'GroupId': groupId,
      'GroupName': 'JMS-012345',
      'State': 'Idle',
      'Participants': ['Demo friend'],
      'LastUpdatedAt': now,
    };

http.Response jsonResponse(Object? body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

Matcher failure(SyncPlayFailureCode code) =>
    isA<SyncPlayFailure>().having((e) => e.code, 'safe failure code', code);

class FakeSocket implements SyncPlaySocket {
  FakeSocket({bool pending = false}) {
    if (!pending) handshake.complete();
  }
  final handshake = Completer<void>();
  final incoming = StreamController<Object?>(sync: true);
  final sent = <String>[];
  int closes = 0;

  @override
  Future<void> get ready => handshake.future;
  @override
  Stream<Object?> get messages => incoming.stream;
  @override
  void send(String message) => sent.add(message);
  @override
  Future<void> close() async {
    closes++;
    if (!incoming.isClosed) unawaited(incoming.close());
  }

  void emit(Map<String, dynamic> envelope) =>
      incoming.add(jsonEncode(envelope));
}

class ManualScheduler implements SyncPlayScheduler {
  final pending = <Scheduled>[];
  @override
  SyncPlayCancellation schedule(Duration delay, void Function() callback) {
    final task = Scheduled(delay, callback);
    pending.add(task);
    return task;
  }

  void fireNext() {
    final task = pending.removeAt(0);
    if (!task.cancelled) task.callback();
  }
}

class Scheduled implements SyncPlayCancellation {
  Scheduled(this.delay, this.callback);
  final Duration delay;
  final void Function() callback;
  bool cancelled = false;
  @override
  void cancel() => cancelled = true;
}

class CloseRecordingClient extends MockClient {
  CloseRecordingClient() : super((_) async => http.Response('', 204));
  int closes = 0;
  @override
  void close() {
    closes++;
    super.close();
  }
}

class Fixture {
  Fixture({
    this.baseUrl = 'https://jellyfin.example.invalid/jellyfin',
    this.socket,
    this.current,
    this.handler,
    this.scheduler,
    this.socketFactory,
    this.timeout = const Duration(seconds: 1),
  }) {
    final api = jellyfin.JellyfinOpenApi.create(
      baseUrl: Uri.parse(baseUrl),
      interceptors: [
        const HeadersInterceptor({
          'authorization':
              'MediaBrowser Token="$capturedToken", DeviceId="demo-device"',
        }),
      ],
      httpClient: MockClient((request) async {
        requests.add(request);
        return await handler?.call(request) ?? http.Response('', 204);
      }),
    );
    transport = SyncPlayTransport(
      api: api,
      baseUri: Uri.parse(baseUrl),
      token: capturedToken,
      deviceId: 'demo-device',
      isCurrent: current,
      scheduler: scheduler ?? const SyncPlayTimerScheduler(),
      requestTimeout: timeout,
      socketFactory: (uri) {
        socketUris.add(uri);
        return socketFactory?.call(uri) ?? socket ?? defaultSocket;
      },
    );
  }
  final String baseUrl;
  final FakeSocket? socket;
  final bool Function()? current;
  final Future<http.Response> Function(http.Request)? handler;
  final SyncPlayScheduler? scheduler;
  final SyncPlaySocketFactory? socketFactory;
  final Duration timeout;
  final defaultSocket = FakeSocket();
  final requests = <http.Request>[];
  final socketUris = <Uri>[];
  late final SyncPlayTransport transport;
}

void main() {
  test('socket preserves a source base path and captures credentials',
      () async {
    final fixture =
        Fixture(baseUrl: 'https://demo.example.invalid:8920/jellyfin%20demo/');
    final statuses = <bool>[];
    final subscription = fixture.transport.connections.listen(statuses.add);
    await fixture.transport.connect();
    expect(fixture.socketUris, hasLength(1));
    final uri = fixture.socketUris.single;
    expect(uri.scheme, 'wss');
    expect(uri.host, 'demo.example.invalid');
    expect(uri.port, 8920);
    expect(uri.pathSegments, ['jellyfin demo', 'socket']);
    expect(uri.queryParameters,
        {'api_key': capturedToken, 'deviceId': 'demo-device'});
    expect(fixture.transport.connected, isTrue);
    await fixture.transport.close();
    await fixture.transport.close();
    expect(statuses, [true, false]);
    expect(fixture.defaultSocket.closes, 1);
    await subscription.cancel();
  });

  test('captured external HTTP client is closed once only when owned',
      () async {
    for (final ownsApi in [true, false]) {
      final client = CloseRecordingClient();
      final api = jellyfin.JellyfinOpenApi.create(
          baseUrl: Uri.parse('https://demo.example.invalid'),
          httpClient: client);
      final transport = SyncPlayTransport(
          api: api,
          baseUri: Uri.parse('https://demo.example.invalid'),
          token: capturedToken,
          deviceId: 'demo-device',
          ownsApi: ownsApi);
      await transport.close();
      await transport.close();
      expect(client.closes, ownsApi ? 1 : 0);
      if (!ownsApi) {
        client.close();
        api.client.dispose();
      }
    }
  });

  test('HTTP sources use ws and unsafe source forms fail without leaking input',
      () async {
    final fixture = Fixture(baseUrl: 'http://localhost:8096/base');
    await fixture.transport.connect();
    expect(fixture.socketUris.single.scheme, 'ws');
    await fixture.transport.close();
    for (final url in [
      'ftp://demo.example.invalid',
      'https://fixture-user@demo.example.invalid',
      'https://demo.example.invalid?api_key=secret',
      'https://demo.example.invalid/#secret',
      '/relative',
    ]) {
      final api = jellyfin.JellyfinOpenApi.create(
          baseUrl: Uri.parse('https://demo.example.invalid'),
          httpClient: MockClient((_) async => http.Response('', 204)));
      expect(
          () => SyncPlayTransport(
              api: api,
              baseUri: Uri.parse(url),
              token: capturedToken,
              deviceId: 'demo-device'),
          throwsA(failure(SyncPlayFailureCode.protocol)));
      api.client.dispose();
    }
  });

  test(
      'listener is attached during handshake and concurrent connects share one socket',
      () async {
    final socket = FakeSocket(pending: true);
    final fixture = Fixture(socket: socket);
    final received = <Map<String, dynamic>>[];
    final subscription = fixture.transport.events.listen(received.add);
    final first = fixture.transport.connect();
    final second = fixture.transport.connect();
    socket.emit({
      'MessageType': 'SyncPlayGroupUpdate',
      'Data': {'Type': 'GroupJoined', 'Data': group()}
    });
    expect(received.single['Data']['Type'], 'GroupJoined');
    await expectLater(fixture.transport.newGroup('JMS-012345'),
        throwsA(failure(SyncPlayFailureCode.disconnected)));
    expect(fixture.requests, isEmpty);
    socket.handshake.complete();
    await Future.wait([first, second]);
    expect(fixture.socketUris, hasLength(1));
    await fixture.transport.close();
    await subscription.cancel();
  });

  test(
      'only raw SyncPlay envelopes are forwarded, including nested polymorphic data',
      () async {
    final fixture = Fixture();
    final received = <Map<String, dynamic>>[];
    final errors = <Object>[];
    final subscription =
        fixture.transport.events.listen(received.add, onError: errors.add);
    await fixture.transport.connect();
    fixture.defaultSocket.emit({
      'MessageType': 'Sessions',
      'Data': {'private': capturedToken}
    });
    final queue = {
      'Type': 'PlayQueue',
      'Data': {
        'Playlist': [
          {'ItemId': mediaId, 'PlaylistItemId': playlistId}
        ]
      }
    };
    fixture.defaultSocket
        .emit({'MessageType': 'SyncPlayGroupUpdate', 'Data': queue});
    fixture.defaultSocket.emit({
      'MessageType': 'SyncPlayCommand',
      'Data': {'Command': 'Pause', 'PositionTicks': 0}
    });
    expect(received, hasLength(2));
    expect(received.first['Data'], queue);
    fixture.defaultSocket
        .emit({'MessageType': 'SyncPlayCommand', 'Data': capturedToken});
    expect(errors.single, failure(SyncPlayFailureCode.protocol));
    expect(errors.single.toString(), isNot(contains(capturedToken)));
    await fixture.transport.close();
    await subscription.cancel();
  });

  test(
      'REST uses captured API and maps group and four-timestamp clock responses',
      () async {
    final fixture = Fixture(handler: (request) async {
      if (request.url.path.endsWith('/List')) return jsonResponse([group()]);
      if (request.url.path.endsWith('/New')) return jsonResponse(group());
      if (request.url.path.endsWith('/GetUtcTime')) {
        return jsonResponse(
            {'RequestReceptionTime': now, 'ResponseTransmissionTime': now});
      }
      return http.Response('', 204);
    });
    await fixture.transport.connect();
    expect((await fixture.transport.listGroups()).single.code, '012345');
    expect((await fixture.transport.newGroup('JMS-012345')).groupId, groupId);
    await fixture.transport.joinGroup(groupId);
    final clock = await fixture.transport.getServerTime();
    expect(clock.requestReceptionTime, DateTime.parse(now));
    expect(clock.responseTransmissionTime, DateTime.parse(now));
    await fixture.transport.leaveGroup();
    expect(fixture.requests, hasLength(5));
    for (final request in fixture.requests) {
      expect(request.url.host, 'jellyfin.example.invalid');
      expect(request.url.path, startsWith('/jellyfin/'));
      expect(request.headers['authorization'], contains(capturedToken));
    }
    expect(jsonDecode(fixture.requests[1].body), {'GroupName': 'JMS-012345'});
    expect(jsonDecode(fixture.requests[2].body), {'GroupId': groupId});
    await fixture.transport.close();
  });

  test(
      'all supported control requests keep queue-entry IDs distinct from media IDs',
      () async {
    final fixture = Fixture();
    await fixture.transport.connect();
    final report = {
      'When': now,
      'PositionTicks': 1230000,
      'IsPlaying': false,
      'PlaylistItemId': playlistId
    };
    final requests = [
      SyncPlayRequest(SyncPlayRequestType.pause),
      SyncPlayRequest(SyncPlayRequestType.unpause),
      SyncPlayRequest(SyncPlayRequestType.seek, {'PositionTicks': 1230000}),
      SyncPlayRequest(SyncPlayRequestType.setNewQueue, {
        'PlayingQueue': [mediaId, mediaId],
        'PlayingItemPosition': 1,
        'StartPositionTicks': 1230000
      }),
      SyncPlayRequest(SyncPlayRequestType.buffering, report),
      SyncPlayRequest(SyncPlayRequestType.ready, report),
      SyncPlayRequest(SyncPlayRequestType.ping, {'Ping': 25}),
    ];
    for (final request in requests) {
      await fixture.transport.sendRequest(request);
    }
    expect(
        fixture.requests.map((request) => request.url.path.split('/').last), [
      'Pause',
      'Unpause',
      'Seek',
      'SetNewQueue',
      'Buffering',
      'Ready',
      'Ping'
    ]);
    final queue = jsonDecode(fixture.requests[3].body) as Map;
    expect(queue['PlayingQueue'], [mediaId, mediaId]);
    final buffering = jsonDecode(fixture.requests[4].body) as Map;
    expect(buffering['PlaylistItemId'], playlistId);
    expect(buffering['IsPlaying'], false);
    expect(jsonDecode(fixture.requests.last.body), {'Ping': 25});
    await fixture.transport.close();
  });

  test('HTTP errors expose only safe failure codes', () async {
    for (final status in [401, 403, 503]) {
      final fixture = Fixture(
          handler: (_) async =>
              http.Response('private $capturedToken', status));
      try {
        await fixture.transport.listGroups();
        fail('An unsuccessful HTTP response must fail');
      } on SyncPlayFailure catch (error) {
        expect(
            error.code,
            status == 503
                ? SyncPlayFailureCode.server
                : SyncPlayFailureCode.denied);
        expect(error.toString(), isNot(contains(capturedToken)));
      } finally {
        await fixture.transport.close();
      }
    }
  });

  test('ambiguous New and Join network failures are not retried', () async {
    for (final create in [true, false]) {
      final fixture = Fixture(
          handler: (_) async =>
              throw http.ClientException('private $capturedToken'));
      await fixture.transport.connect();
      await expectLater(
          create
              ? fixture.transport.newGroup('JMS-012345')
              : fixture.transport.joinGroup(groupId),
          throwsA(failure(SyncPlayFailureCode.timeoutUnknown)));
      expect(fixture.requests, hasLength(1));
      await fixture.transport.close();
    }
  });

  test(
      'a timed-out New remains ambiguous and late HTTP completion does not retry',
      () async {
    final pending = Completer<http.Response>();
    final fixture = Fixture(
        timeout: const Duration(milliseconds: 10),
        handler: (_) => pending.future);
    await fixture.transport.connect();
    await expectLater(fixture.transport.newGroup('JMS-012345'),
        throwsA(failure(SyncPlayFailureCode.timeoutUnknown)));
    pending.complete(jsonResponse(group()));
    await Future<void>.delayed(Duration.zero);
    expect(fixture.requests, hasLength(1));
    await fixture.transport.close();
  });

  test('invalid locator and group identifier never reach HTTP', () async {
    final fixture = Fixture();
    await fixture.transport.connect();
    await expectLater(fixture.transport.newGroup('JMS-１２３４５６'),
        throwsA(failure(SyncPlayFailureCode.invalidCode)));
    await expectLater(fixture.transport.joinGroup('not-an-id'),
        throwsA(failure(SyncPlayFailureCode.protocol)));
    expect(fixture.requests, isEmpty);
    await fixture.transport.close();
  });

  test('malformed New response and server 5xx cannot authorize a blind retry',
      () async {
    for (final response in [
      jsonResponse({'GroupId': groupId}),
      http.Response('', 503)
    ]) {
      final fixture = Fixture(handler: (_) async => response);
      await fixture.transport.connect();
      await expectLater(fixture.transport.newGroup('JMS-012345'),
          throwsA(failure(SyncPlayFailureCode.timeoutUnknown)));
      expect(fixture.requests, hasLength(1));
      await fixture.transport.close();
    }
  });

  test('account change during HTTP rejects late response and detaches old WS',
      () async {
    var current = true;
    final pending = Completer<http.Response>();
    final started = Completer<void>();
    final fixture = Fixture(
        current: () => current,
        handler: (_) {
          started.complete();
          return pending.future;
        });
    final received = <Map<String, dynamic>>[];
    final subscription = fixture.transport.events.listen(received.add);
    await fixture.transport.connect();
    final request = fixture.transport.newGroup('JMS-012345');
    final rejected = expectLater(
        request, throwsA(failure(SyncPlayFailureCode.disconnected)));
    await started.future;
    current = false;
    fixture.defaultSocket.emit({
      'MessageType': 'SyncPlayGroupUpdate',
      'Data': {'Type': 'GroupJoined', 'Data': group()}
    });
    pending.complete(jsonResponse(group()));
    await rejected;
    await fixture.transport.close();
    expect(received, isEmpty);
    expect(fixture.requests, hasLength(1));
    expect(fixture.defaultSocket.closes, 1);
    expect(fixture.transport.connected, false);
    await subscription.cancel();
  });

  test(
      'account change before a request closes the old connection without sending',
      () async {
    var current = true;
    final fixture = Fixture(current: () => current);
    await fixture.transport.connect();
    current = false;
    await expectLater(
        fixture.transport
            .sendRequest(SyncPlayRequest(SyncPlayRequestType.pause)),
        throwsA(failure(SyncPlayFailureCode.disconnected)));
    await fixture.transport.close();
    expect(fixture.requests, isEmpty);
    expect(fixture.defaultSocket.closes, 1);
  });

  test('close invalidates a pending handshake even if it later succeeds',
      () async {
    final socket = FakeSocket(pending: true);
    final fixture = Fixture(socket: socket);
    final connection = fixture.transport.connect();
    final rejected = expectLater(
        connection, throwsA(failure(SyncPlayFailureCode.disconnected)));
    await fixture.transport.close();
    socket.handshake.complete();
    await rejected;
    expect(fixture.transport.connected, false);
    expect(socket.closes, 1);
  });

  test('unexpected WS failure is sanitized and never automatically reconnects',
      () async {
    final fixture = Fixture();
    final errors = <Object>[];
    final subscription =
        fixture.transport.events.listen((_) {}, onError: errors.add);
    await fixture.transport.connect();
    fixture.defaultSocket.incoming
        .addError(StateError('private URL $capturedToken'));
    await Future<void>.delayed(Duration.zero);
    expect(fixture.transport.connected, false);
    expect(errors.single, failure(SyncPlayFailureCode.disconnected));
    expect(errors.single.toString(), isNot(contains(capturedToken)));
    expect(() => fixture.transport.connect(),
        throwsA(failure(SyncPlayFailureCode.disconnected)));
    expect(fixture.socketUris, hasLength(1));
    await fixture.transport.close();
    expect(fixture.defaultSocket.closes, 1);
    await subscription.cancel();
  });

  test(
      'explicit reconnect retires old socket and heartbeat without replaying mutations',
      () async {
    final oldSocket = FakeSocket();
    final newSocket = FakeSocket();
    final scheduler = ManualScheduler();
    var count = 0;
    final fixture = Fixture(
      scheduler: scheduler,
      socketFactory: (_) => count++ == 0 ? oldSocket : newSocket,
    );
    final errors = <Object>[];
    final received = <Map<String, dynamic>>[];
    final subscription =
        fixture.transport.events.listen(received.add, onError: errors.add);
    await fixture.transport.connect();
    oldSocket.emit({'MessageType': 'ForceKeepAlive', 'Data': 1});
    oldSocket.incoming.addError(StateError('synthetic disconnect'));
    final first = fixture.transport.reconnect();
    final second = fixture.transport.reconnect();
    await Future.wait([first, second]);
    expect(oldSocket.closes, 1);
    expect(oldSocket.incoming.hasListener, false);
    expect(fixture.socketUris, hasLength(2));
    expect(fixture.socketUris.first, fixture.socketUris.last);
    scheduler.fireNext();
    expect(oldSocket.sent, hasLength(1));
    expect(newSocket.sent, isEmpty);
    newSocket.emit({
      'MessageType': 'SyncPlayGroupUpdate',
      'Data': {'Type': 'UserJoined', 'Data': 'Demo'}
    });
    expect(received, hasLength(1));
    expect(errors.single, failure(SyncPlayFailureCode.disconnected));
    expect(fixture.requests, isEmpty);
    await fixture.transport.close();
    expect(newSocket.closes, 1);
    await subscription.cancel();
  });

  test(
      'ForceKeepAlive sends at half timeout and stops on identity invalidation',
      () async {
    var current = true;
    final scheduler = ManualScheduler();
    final fixture = Fixture(current: () => current, scheduler: scheduler);
    await fixture.transport.connect();
    fixture.defaultSocket.emit({'MessageType': 'ForceKeepAlive', 'Data': 1});
    expect(fixture.defaultSocket.sent, ['{"MessageType":"KeepAlive"}']);
    expect(scheduler.pending.single.delay, const Duration(milliseconds: 500));
    scheduler.fireNext();
    expect(fixture.defaultSocket.sent, hasLength(2));
    current = false;
    scheduler.fireNext();
    await fixture.transport.close();
    expect(scheduler.pending, isEmpty);
    expect(fixture.defaultSocket.sent, hasLength(2));
    expect(fixture.defaultSocket.closes, 1);
  });
}
