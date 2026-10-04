import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win32/win32.dart';
import 'package:fladder/services/discord/discord_ipc_client.dart';
import 'package:fladder/services/discord/discord_transport.dart';
import 'package:fladder/services/discord/discord_transport_io.dart' as io;
import 'package:fladder/services/discord/discord_transport_windows.dart';

class SyntheticNamedPipe {
  SyntheticNamedPipe() {
    path =
        '\\\\?\\pipe\\jms-discord-fixture-$pid-${DateTime.now().microsecondsSinceEpoch}';
    final name = path.toNativeUtf16();
    try {
      handle = CreateNamedPipe(
          name,
          PIPE_ACCESS_DUPLEX,
          PIPE_TYPE_BYTE |
              PIPE_READMODE_BYTE |
              PIPE_NOWAIT |
              PIPE_REJECT_REMOTE_CLIENTS,
          1,
          4096,
          4096,
          0,
          nullptr);
      if (handle == INVALID_HANDLE_VALUE) {
        throw StateError('Synthetic named pipe creation failed');
      }
      // The initial nonblocking call puts this fresh instance into listening.
      ConnectNamedPipe(handle, nullptr);
    } finally {
      calloc.free(name);
    }
  }

  late final String path;
  late final int handle;

  void accept() {
    final available = calloc<Uint32>();
    try {
      if (PeekNamedPipe(handle, nullptr, 0, nullptr, available, nullptr) == 0) {
        throw StateError('Synthetic named pipe not connected');
      }
    } finally {
      calloc.free(available);
    }
  }

  Future<Uint8List> read(int length) async {
    final result = BytesBuilder(copy: false);
    final buffer = calloc<Uint8>(4096);
    final available = calloc<Uint32>();
    final count = calloc<Uint32>();
    final clock = Stopwatch()..start();
    try {
      while (result.length < length &&
          clock.elapsed < const Duration(seconds: 1)) {
        if (PeekNamedPipe(handle, nullptr, 0, nullptr, available, nullptr) ==
            0) {
          throw StateError(
              'Synthetic named pipe peek failed (${GetLastError()})');
        }
        if (available.value != 0) {
          final wanted = (length - result.length).clamp(0, 4096);
          if (ReadFile(handle, buffer, wanted, count, nullptr) == 0) {
            throw StateError(
                'Synthetic named pipe read failed (${GetLastError()})');
          }
          result.add(Uint8List.fromList(buffer.asTypedList(count.value)));
        }
        if (result.length < length) {
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
      }
      if (result.length != length) {
        throw StateError('Synthetic named pipe read deadline');
      }
      return result.takeBytes();
    } finally {
      calloc.free(buffer);
      calloc.free(available);
      calloc.free(count);
    }
  }

  void write(Uint8List bytes) {
    final buffer = calloc<Uint8>(bytes.length);
    final count = calloc<Uint32>();
    try {
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      if (WriteFile(handle, buffer, bytes.length, count, nullptr) == 0 ||
          count.value != bytes.length) {
        throw StateError('Synthetic named pipe write failed');
      }
    } finally {
      calloc.free(buffer);
      calloc.free(count);
    }
  }

  void close() {
    DisconnectNamedPipe(handle);
    CloseHandle(handle);
  }
}

Uint8List packet(int opcode, Object payload) {
  final body = payload is Uint8List
      ? payload
      : Uint8List.fromList(utf8.encode(jsonEncode(payload)));
  final bytes = Uint8List(body.length + 8)..setAll(8, body);
  final header = ByteData.sublistView(bytes);
  header.setUint32(0, opcode, Endian.little);
  header.setUint32(4, body.length, Endian.little);
  return bytes;
}

void main() {
  test(
      'Unix candidates follow official environment order without directory traversal',
      () {
    expect(
        io.discordUnixPrefixes({
          'XDG_RUNTIME_DIR': '/synthetic-run/',
          'TMPDIR': '/synthetic-tmp',
          'TMP': '/synthetic-tmp',
          'TEMP': 'not-an-absolute-path'
        }),
        [
          '/synthetic-run',
          '/synthetic-tmp',
          '/tmp',
          '/synthetic-run/app/com.discordapp.Discord',
        ]);
  });

  test('Discord Flatpak runtime candidates reject invalid environment paths',
      () {
    for (final runtime in ['relative', '/runtime\u0000bad']) {
      expect(io.discordUnixPrefixes({'XDG_RUNTIME_DIR': runtime}), ['/tmp']);
    }
  });

  test('Windows transport refuses remote named pipes before opening a handle',
      () {
    expect(
        () => openWindowsDiscordPipe('\\\\synthetic-host\\pipe\\synthetic',
            timeout: const Duration(seconds: 1)),
        throwsA(isA<DiscordIpcException>()));
  });

  group('isolated real Windows named pipe', () {
    late SyntheticNamedPipe server;
    late DiscordIpcTransport transport;

    setUp(() {
      server = SyntheticNamedPipe();
      transport = openWindowsDiscordPipe(server.path,
          timeout: const Duration(milliseconds: 800));
      server.accept();
    });

    tearDown(() async {
      await transport.close();
      server.close();
    });

    test('fragmented reads preserve bytes and close releases an idle handle',
        () async {
      final bytes = BytesBuilder(copy: false);
      final received = Completer<void>();
      final subscription = transport.incoming.listen((chunk) {
        bytes.add(chunk);
        if (bytes.length == 6) received.complete();
      });
      server.write(Uint8List.fromList([0, 1]));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      server.write(Uint8List.fromList([2, 3, 4, 255]));
      await received.future.timeout(const Duration(seconds: 1));
      expect(bytes.takeBytes(), [0, 1, 2, 3, 4, 255]);
      await transport.close().timeout(const Duration(milliseconds: 100));
      await subscription.cancel();
    });

    test('backpressure and partial writes retain complete ordered bytes',
        () async {
      final expected =
          Uint8List.fromList(List.generate(128 * 1024, (index) => index % 251));
      final sending = transport.write(expected);
      final received = await server.read(expected.length);
      await sending;
      expect(received, expected);
    });

    test(
        'production client handshake, PONG, PID and activity ACK cross a real local pipe',
        () async {
      final client = DiscordIpcClient(
          transportFactory: (_) async => transport,
          supported: true,
          timeout: const Duration(seconds: 1));
      addTearDown(client.close);
      Future<(int, Uint8List)> next() async {
        final header = ByteData.sublistView(await server.read(8));
        return (
          header.getUint32(0, Endian.little),
          await server.read(header.getUint32(4, Endian.little))
        );
      }

      final connecting = client.connect('123456789012345678');
      final handshake = await next();
      expect(handshake.$1, 0);
      expect(jsonDecode(utf8.decode(handshake.$2)),
          {'v': 1, 'client_id': '123456789012345678'});
      final ready = packet(1, {
        'cmd': 'DISPATCH',
        'evt': 'READY',
        'data': {'v': 1}
      });
      server.write(Uint8List.fromList(ready.sublist(0, 3)));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      server.write(Uint8List.fromList(ready.sublist(3)));
      await connecting;
      server.write(packet(3, Uint8List.fromList([0, 255, 3])));
      final pong = await next();
      expect(pong.$1, 4);
      expect(pong.$2, [0, 255, 3]);
      final activity = client
          .setActivity({'type': 3, 'details': '合成測試影片', 'state': 'Playing'});
      final requestFrame = await next();
      final request =
          jsonDecode(utf8.decode(requestFrame.$2)) as Map<String, dynamic>;
      expect(requestFrame.$1, 1);
      expect(request['args']['pid'], pid);
      expect(request['args']['activity']['details'], '合成測試影片');
      server.write(packet(1, {
        'cmd': 'SET_ACTIVITY',
        'evt': null,
        'data': null,
        'nonce': request['nonce']
      }));
      await activity;
      await client.close();
    });

    test('a stalled peer cannot hold a write or close indefinitely', () async {
      await transport.close();
      server.close();
      server = SyntheticNamedPipe();
      transport = openWindowsDiscordPipe(server.path,
          timeout: const Duration(milliseconds: 50));
      server.accept();
      final clock = Stopwatch()..start();
      await expectLater(
          transport.write(Uint8List(256 * 1024)),
          throwsA(predicate<Object>((error) =>
              error is DiscordIpcException &&
              error.failure == DiscordIpcFailure.timeout)));
      expect(clock.elapsed, lessThan(const Duration(seconds: 1)));
      await transport.close().timeout(const Duration(milliseconds: 100));
    });

    test('close does not wait for a paused incoming subscription', () async {
      final subscription = transport.incoming.listen((_) {});
      subscription.pause();
      await transport.close().timeout(const Duration(milliseconds: 100));
      subscription.resume();
      await subscription.cancel();
    });
  }, skip: !Platform.isWindows);

  test('isolated real Linux Unix socket reads and writes without TCP',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('jms-discord-fixture-');
    final path = '${directory.path}/ipc';
    final server = await ServerSocket.bind(
        InternetAddress(path, type: InternetAddressType.unix), 0);
    final accepted = server.first;
    final transport = await io.openDiscordUnixSocket(path,
        timeout: const Duration(seconds: 1));
    final peer = await accepted;
    final incoming = transport.incoming.first;
    peer.add([9, 8, 7]);
    await peer.flush();
    expect(await incoming.timeout(const Duration(seconds: 1)), [9, 8, 7]);
    final peerRead = peer.first;
    await transport.write(Uint8List.fromList([6, 5, 4]));
    expect(await peerRead.timeout(const Duration(seconds: 1)), [6, 5, 4]);
    await transport.close();
    peer.destroy();
    await server.close();
    await directory.delete(recursive: true);
  }, skip: !Platform.isLinux);
}
