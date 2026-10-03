import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fladder/services/discord/discord_ipc_client.dart';
import 'package:fladder/services/discord/discord_transport.dart';

const applicationId = '123456789012345678';

Uint8List frame(int opcode, Object? payload) {
  final body = payload is Uint8List
      ? payload
      : Uint8List.fromList(utf8.encode(jsonEncode(payload)));
  final bytes = Uint8List(body.length + 8)..setAll(8, body);
  final header = ByteData.sublistView(bytes);
  header.setUint32(0, opcode, Endian.little);
  header.setUint32(4, body.length, Endian.little);
  return bytes;
}

Map<String, dynamic> body(Uint8List bytes) =>
    jsonDecode(utf8.decode(bytes.sublist(8))) as Map<String, dynamic>;

class SyntheticTransport implements DiscordIpcTransport {
  final input = StreamController<Uint8List>();
  final writes = <Uint8List>[];
  FutureOr<void> Function(Uint8List bytes)? onWrite;
  bool closed = false;

  @override
  Stream<Uint8List> get incoming => input.stream;

  @override
  Future<void> write(Uint8List bytes) async {
    if (closed) throw StateError('Synthetic transport closed');
    writes.add(bytes);
    await onWrite?.call(bytes);
  }

  void ready() => input.add(frame(1, {
        'cmd': 'DISPATCH',
        'evt': 'READY',
        'data': {'v': 1}
      }));
  void ack(Uint8List request, {Object? data}) => input.add(frame(1, {
        'cmd': 'SET_ACTIVITY',
        'nonce': body(request)['nonce'],
        'evt': null,
        'data': data,
      }));

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    unawaited(input.close());
  }
}

Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 5));

void main() {
  late SyntheticTransport transport;
  late DiscordIpcClient client;
  late List<DiscordConnectionState> states;
  late StreamSubscription<DiscordConnectionState> subscription;

  setUp(() {
    transport = SyntheticTransport();
    transport.onWrite = (bytes) {
      if (ByteData.sublistView(bytes).getUint32(0, Endian.little) == 0) {
        transport.ready();
      }
    };
    client = DiscordIpcClient(
        transportFactory: (_) async => transport,
        supported: true,
        timeout: const Duration(milliseconds: 80));
    states = [];
    subscription = client.states.listen(states.add);
  });

  tearDown(() async {
    await client.close();
    await subscription.cancel();
  });

  test('READY handshake is v1 and does not count as an activity success',
      () async {
    await client.connect(applicationId);
    await tick();
    expect(body(transport.writes.single), {'v': 1, 'client_id': applicationId});
    expect(states, [DiscordConnectionState.connecting]);
    final updating = client.setActivity(
        {'type': 3, 'state': 'Playing', 'details': 'Synthetic film'});
    await tick();
    expect(states, isNot(contains(DiscordConnectionState.connected)));
    final request = transport.writes.last;
    expect(body(request)['args']['pid'], pid);
    transport.ack(request, data: {'state': 'Playing'});
    await updating;
    await tick();
    expect(states.last, DiscordConnectionState.connected);
  });

  test('null activity uses the same ACK contract and the real current PID',
      () async {
    await client.connect(applicationId);
    final clearing = client.setActivity(null);
    await tick();
    final request = transport.writes.last;
    expect(body(request)['args'], {'pid': pid, 'activity': null});
    transport.ack(request);
    await clearing;
  });

  test(
      'fragmented header and coalesced READY/PING respond with exact opaque PONG',
      () async {
    final ping = Uint8List.fromList([0, 255, 2, 3]);
    transport.onWrite = (bytes) {
      if (ByteData.sublistView(bytes).getUint32(0, Endian.little) != 0) return;
      final all = Uint8List.fromList([
        ...frame(1, {
          'cmd': 'DISPATCH',
          'evt': 'READY',
          'data': {'v': 1}
        }),
        ...frame(3, ping),
      ]);
      transport.input.add(Uint8List.fromList(all.sublist(0, 3)));
      transport.input.add(Uint8List.fromList(all.sublist(3, 7)));
      transport.input.add(Uint8List.fromList(all.sublist(7)));
    };
    await client.connect(applicationId);
    await tick();
    expect(transport.writes.last, frame(4, ping));
  });

  test('unknown nonce cannot acknowledge an update', () async {
    await client.connect(applicationId);
    final updating = client.setActivity({'state': 'Paused'});
    await tick();
    transport.input.add(
        frame(1, {'cmd': 'SET_ACTIVITY', 'nonce': 'unrelated', 'data': null}));
    await tick();
    expect(states, isNot(contains(DiscordConnectionState.connected)));
    transport.ack(transport.writes.last);
    await updating;
  });

  test('matching nonce with wrong command is rejected and closes transport',
      () async {
    await client.connect(applicationId);
    final updating = client.setActivity({'state': 'Playing'});
    final result = expectLater(updating, throwsA(isA<DiscordIpcException>()));
    await tick();
    transport.input.add(frame(1, {
      'cmd': 'OTHER',
      'nonce': body(transport.writes.last)['nonce'],
      'data': null
    }));
    await result;
    await tick();
    expect(transport.closed, true);
    expect(states.last, DiscordConnectionState.error);
  });

  test('RPC ERROR never exposes peer messages or reports successful presence',
      () async {
    await client.connect(applicationId);
    final updating = client.setActivity({'details': 'Synthetic film'});
    final result = expectLater(
        updating,
        throwsA(predicate<Object>((error) =>
            error is DiscordIpcException &&
            error.failure == DiscordIpcFailure.rejected &&
            !error.toString().contains('synthetic peer text'))));
    await tick();
    transport.input.add(frame(1, {
      'evt': 'ERROR',
      'data': {'code': 4000, 'message': 'synthetic peer text'}
    }));
    await result;
    expect(states, isNot(contains(DiscordConnectionState.connected)));
  });

  test('missing READY is bounded and releases the transport', () async {
    transport.onWrite = null;
    await expectLater(
        client.connect(applicationId), throwsA(isA<DiscordIpcException>()));
    await tick();
    expect(transport.closed, true);
    expect(states.last, DiscordConnectionState.error);
  });

  test('missing activity ACK is bounded and cannot count as connected',
      () async {
    await client.connect(applicationId);
    await expectLater(client.setActivity({'state': 'Playing'}),
        throwsA(isA<DiscordIpcException>()));
    await tick();
    expect(transport.closed, true);
    expect(states, isNot(contains(DiscordConnectionState.connected)));
  });

  test('peer CLOSE cancels pending commands', () async {
    await client.connect(applicationId);
    final updating = client.setActivity(null);
    final result = expectLater(updating, throwsA(isA<DiscordIpcException>()));
    await tick();
    transport.input.add(frame(2, Uint8List(0)));
    await result;
    expect(transport.closed, true);
  });

  for (final invalid in [
    'oversized frame',
    'invalid UTF8',
    'invalid JSON',
    'unknown opcode'
  ]) {
    test('$invalid fails closed', () async {
      transport.onWrite = (bytes) {
        if (invalid == 'oversized frame') {
          final header = Uint8List(8);
          ByteData.sublistView(header).setUint32(4, 0xffffffff, Endian.little);
          transport.input.add(header);
        } else if (invalid == 'invalid UTF8') {
          transport.input.add(frame(1, Uint8List.fromList([255])));
        } else if (invalid == 'invalid JSON') {
          transport.input.add(frame(1, Uint8List.fromList([123])));
        } else {
          transport.input.add(frame(255, Uint8List(0)));
        }
      };
      await expectLater(
          client.connect(applicationId), throwsA(isA<DiscordIpcException>()));
      await tick();
      expect(transport.closed, true);
    });
  }

  test(
      'close during endpoint lookup releases a late transport without handshake',
      () async {
    final lookup = Completer<DiscordIpcTransport>();
    final lateClient = DiscordIpcClient(
        transportFactory: (_) => lookup.future,
        supported: true,
        timeout: const Duration(milliseconds: 80));
    final connecting = lateClient.connect(applicationId);
    final result = expectLater(connecting, throwsA(isA<DiscordIpcException>()));
    await tick();
    await lateClient.close();
    lookup.complete(transport);
    await result;
    expect(transport.closed, true);
    expect(transport.writes, isEmpty);
  });

  test('unsupported platforms do not attempt IPC', () async {
    var attempted = false;
    final unsupported = DiscordIpcClient(
        supported: false,
        transportFactory: (_) async {
          attempted = true;
          return transport;
        });
    await expectLater(unsupported.connect(applicationId),
        throwsA(isA<DiscordIpcException>()));
    expect(attempted, false);
    await unsupported.close();
  });

  test(
      'an incomplete frame has its own deadline even without an activity request',
      () async {
    await client.connect(applicationId);
    transport.input.add(Uint8List.fromList([1, 0, 0, 0]));
    await Future<void>.delayed(const Duration(milliseconds: 110));
    expect(transport.closed, true);
    expect(states.last, DiscordConnectionState.error);
  });

  test('PING flood cannot create an unbounded pending write queue', () async {
    await client.connect(applicationId);
    final stall = Completer<void>();
    transport.onWrite = (_) => stall.future;
    transport.input.add(Uint8List.fromList([
      for (var index = 0; index < 20; index++)
        ...frame(3, Uint8List.fromList([index])),
    ]));
    await tick();
    expect(transport.closed, true);
    expect(states.last, DiscordConnectionState.error);
    stall.complete();
  });

  test(
      'activity followed by clear writes null last while the old ACK is still pending',
      () async {
    await client.connect(applicationId);
    final oldActivity =
        client.setActivity({'details': 'Synthetic film', 'state': 'Playing'});
    final clear = client.setActivity(null);
    await tick();
    expect(transport.writes.length, 3);
    expect(body(transport.writes[1])['args']['activity']['state'], 'Playing');
    expect(body(transport.writes[2])['args']['activity'], null);
    expect(body(transport.writes[1])['nonce'],
        isNot(body(transport.writes[2])['nonce']));
    transport.ack(transport.writes[1]);
    transport.ack(transport.writes[2]);
    await Future.wait([oldActivity, clear]);
  });

  test('a failed write is classified and never echoes its exception', () async {
    await client.connect(applicationId);
    transport.onWrite = (_) => throw StateError('synthetic transport detail');
    await expectLater(
        client.setActivity(null),
        throwsA(predicate<Object>((error) =>
            error is DiscordIpcException &&
            !error.toString().contains('synthetic transport detail'))));
    expect(transport.closed, true);
  });

  test(
      'a new session cancels old activity without marking the new session connected',
      () async {
    await client.connect(applicationId);
    final previous = transport;
    final updating = client.setActivity({'state': 'Playing'});
    final cancelled =
        expectLater(updating, throwsA(isA<DiscordIpcException>()));
    await tick();
    transport = SyntheticTransport();
    transport.onWrite = (bytes) {
      if (ByteData.sublistView(bytes).getUint32(0, Endian.little) == 0) {
        transport.ready();
      }
    };
    await client.connect(applicationId);
    await cancelled;
    expect(previous.closed, true);
    expect(states, isNot(contains(DiscordConnectionState.connected)));
    final clearing = client.setActivity(null);
    await tick();
    transport.ack(transport.writes.last);
    await clearing;
  });

  test(
      'READY followed by CLOSE in the same read cannot complete connect successfully',
      () async {
    transport.onWrite = (_) {
      transport.input.add(Uint8List.fromList([
        ...frame(1, {
          'cmd': 'DISPATCH',
          'evt': 'READY',
          'data': {'v': 1}
        }),
        ...frame(2, Uint8List(0)),
      ]));
    };
    await expectLater(
        client.connect(applicationId), throwsA(isA<DiscordIpcException>()));
    expect(transport.closed, true);
    expect(states, isNot(contains(DiscordConnectionState.connected)));
  });
}
