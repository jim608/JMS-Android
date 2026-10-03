import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'discord_presence_client.dart';
import 'discord_transport.dart';

export 'discord_presence_client.dart';

DiscordPresenceClient createDiscordPresenceClient() => DiscordIpcClient();

/// Discord's local IPC v1 framing, without OAuth, user subscriptions or logging.
class DiscordIpcClient implements DiscordPresenceClient {
  DiscordIpcClient({
    DiscordTransportFactory? transportFactory,
    bool? supported,
    int? processId,
    this.timeout = const Duration(seconds: 2),
    this.maxFrameBytes = 64 * 1024,
  })  : _factory = transportFactory ?? openDiscordIpcTransport,
        _supported = supported ?? discordDesktopSupported,
        _processId = processId ?? discordProcessId {
    if (timeout <= Duration.zero ||
        maxFrameBytes < 128 ||
        maxFrameBytes > 64 * 1024) {
      throw ArgumentError('Invalid Discord IPC limits');
    }
  }

  final DiscordTransportFactory _factory;
  final bool _supported;
  final int _processId;
  final Duration timeout;
  final int maxFrameBytes;
  final _states = StreamController<DiscordConnectionState>.broadcast();
  final _requests = <String, Completer<void>>{};
  DiscordIpcTransport? _transport;
  // Released in _release for errors, cancellation and every replacement session.
  // ignore: cancel_subscriptions
  StreamSubscription<Uint8List>? _subscription;
  Completer<void>? _ready;
  Uint8List _buffer = Uint8List(0);
  Future<void> _writes = Future<void>.value();
  Timer? _frameDeadline;
  var _queuedWrites = 0;
  var _generation = 0;
  var _nonce = 0;
  var _handshaken = false;
  var _state = DiscordConnectionState.disconnected;

  @override
  bool get supported => _supported;
  @override
  Stream<DiscordConnectionState> get states => _states.stream;

  void _stateChanged(DiscordConnectionState state) {
    if (_state == state) return;
    _state = state;
    _states.add(state);
  }

  @override
  Future<void> connect(String applicationId) async {
    if (!supported) {
      throw const DiscordIpcException(DiscordIpcFailure.unsupported);
    }
    if (!RegExp(r'^[1-9][0-9]{14,21}$').hasMatch(applicationId)) {
      throw const DiscordIpcException(DiscordIpcFailure.protocol);
    }
    final generation = ++_generation;
    await _release();
    if (_generation != generation) {
      throw const DiscordIpcException(DiscordIpcFailure.closed);
    }
    _stateChanged(DiscordConnectionState.connecting);
    final ready = _ready = Completer<void>();
    // Attach an error handler before writes: the peer can close immediately.
    final readyResult = ready.future.timeout(timeout);
    unawaited(readyResult.then<void>((_) {}, onError: (Object _) {}));
    try {
      final attempt = _factory(timeout);
      unawaited(attempt.then((transport) {
        if (_generation != generation) unawaited(_closeTransport(transport));
      }, onError: (Object _) {}));
      final transport = await attempt.timeout(timeout);
      if (_generation != generation) {
        await _closeTransport(transport);
        throw const DiscordIpcException(DiscordIpcFailure.closed);
      }
      _transport = transport;
      _subscription = transport.incoming.listen((bytes) {
        if (_generation == generation) _receive(bytes, generation);
      }, onError: (Object _) {
        if (_generation == generation) _fail(DiscordIpcFailure.unavailable);
      }, onDone: () {
        if (_generation == generation) _fail(DiscordIpcFailure.closed);
      });
      await _writeFrame(
          0,
          Uint8List.fromList(
              utf8.encode(jsonEncode({'v': 1, 'client_id': applicationId}))),
          generation);
      await readyResult;
      if (_generation != generation || !_handshaken || _transport == null) {
        throw const DiscordIpcException(DiscordIpcFailure.closed);
      }
    } catch (error) {
      if (_generation == generation) {
        _fail(error is TimeoutException
            ? DiscordIpcFailure.timeout
            : DiscordIpcFailure.protocol);
      }
      if (error is DiscordIpcException) rethrow;
      throw DiscordIpcException(error is TimeoutException
          ? DiscordIpcFailure.timeout
          : DiscordIpcFailure.unavailable);
    }
  }

  @override
  Future<void> setActivity(Map<String, Object?>? activity) async {
    if (!_handshaken || _transport == null) {
      throw const DiscordIpcException(DiscordIpcFailure.closed);
    }
    if (_requests.length >= 4) {
      throw const DiscordIpcException(DiscordIpcFailure.busy);
    }
    final generation = _generation;
    final nonce = '$_processId-$generation-${++_nonce}';
    late final Uint8List payload;
    try {
      payload = Uint8List.fromList(utf8.encode(jsonEncode({
        'cmd': 'SET_ACTIVITY',
        'args': {'pid': _processId, 'activity': activity},
        'nonce': nonce,
      })));
    } catch (_) {
      throw const DiscordIpcException(DiscordIpcFailure.protocol);
    }
    if (payload.length > maxFrameBytes) {
      throw const DiscordIpcException(DiscordIpcFailure.protocol);
    }
    final request = Completer<void>();
    _requests[nonce] = request;
    final response = request.future.timeout(timeout);
    unawaited(response.then<void>((_) {}, onError: (Object _) {}));
    try {
      await _writeFrame(1, payload, generation);
      await response;
      if (_generation != generation) {
        throw const DiscordIpcException(DiscordIpcFailure.closed);
      }
      _stateChanged(DiscordConnectionState.connected);
    } catch (error) {
      if (_generation == generation) {
        _fail(error is TimeoutException
            ? DiscordIpcFailure.timeout
            : DiscordIpcFailure.unavailable);
      }
      if (error is DiscordIpcException) rethrow;
      throw DiscordIpcException(error is TimeoutException
          ? DiscordIpcFailure.timeout
          : DiscordIpcFailure.unavailable);
    } finally {
      _requests.remove(nonce);
    }
  }

  Future<void> _writeFrame(int opcode, Uint8List payload, int generation) {
    if (_queuedWrites >= 8) {
      return Future<void>.error(
          const DiscordIpcException(DiscordIpcFailure.protocol));
    }
    ++_queuedWrites;
    final frame = Uint8List(payload.length + 8);
    final header = ByteData.sublistView(frame);
    header.setUint32(0, opcode, Endian.little);
    header.setUint32(4, payload.length, Endian.little);
    frame.setAll(8, payload);
    final write = _writes.then((_) async {
      try {
        if (_generation != generation || _transport == null) {
          throw const DiscordIpcException(DiscordIpcFailure.closed);
        }
        await _transport!.write(frame).timeout(timeout);
      } finally {
        if (_generation == generation) --_queuedWrites;
      }
    });
    _writes = write.then<void>((_) {}, onError: (Object _) {});
    return write;
  }

  void _receive(Uint8List bytes, int generation) {
    try {
      if (_buffer.isEmpty && bytes.isNotEmpty) {
        _frameDeadline = Timer(timeout, () {
          if (_generation == generation) _fail(DiscordIpcFailure.timeout);
        });
      }
      // At most one bounded frame plus one OS read is retained at any time.
      if (bytes.length > maxFrameBytes + 8 ||
          _buffer.length + bytes.length > maxFrameBytes * 2 + 16) {
        throw const DiscordIpcException(DiscordIpcFailure.protocol);
      }
      _buffer = Uint8List.fromList([..._buffer, ...bytes]);
      while (_buffer.length >= 8 && _generation == generation) {
        final header = ByteData.sublistView(_buffer, 0, 8);
        final opcode = header.getUint32(0, Endian.little);
        final length = header.getUint32(4, Endian.little);
        if (length > maxFrameBytes || opcode > 4 || opcode == 0) {
          throw const DiscordIpcException(DiscordIpcFailure.protocol);
        }
        if (_buffer.length < length + 8) return;
        final payload = Uint8List.fromList(_buffer.sublist(8, length + 8));
        _buffer = Uint8List.fromList(_buffer.sublist(length + 8));
        if (_buffer.isEmpty) {
          _frameDeadline?.cancel();
          _frameDeadline = null;
        }
        if (opcode == 3) {
          unawaited(_writeFrame(4, payload, generation).catchError((Object _) {
            if (_generation == generation) _fail(DiscordIpcFailure.unavailable);
          }));
        } else if (opcode == 2) {
          _fail(DiscordIpcFailure.closed);
        } else if (opcode == 1) {
          _receiveJson(payload);
        }
      }
    } catch (_) {
      if (_generation == generation) _fail(DiscordIpcFailure.protocol);
    }
  }

  void _receiveJson(Uint8List payload) {
    final data = jsonDecode(utf8.decode(payload));
    if (data is! Map<String, dynamic>) {
      throw const DiscordIpcException(DiscordIpcFailure.protocol);
    }
    if (data['evt'] == 'ERROR') {
      _fail(DiscordIpcFailure.rejected);
      return;
    }
    if (data['cmd'] == 'DISPATCH' && data['evt'] == 'READY') {
      if (_handshaken ||
          data['data'] is! Map ||
          (data['data'] as Map)['v'] != 1) {
        throw const DiscordIpcException(DiscordIpcFailure.protocol);
      }
      _handshaken = true;
      _ready?.complete();
      return;
    }
    final request = _requests[data['nonce']];
    if (request == null) {
      return; // Events and unmatched replies never count as an ACK.
    }
    if (!_handshaken ||
        data['cmd'] != 'SET_ACTIVITY' ||
        data['evt'] != null ||
        (data['data'] != null && data['data'] is! Map)) {
      throw const DiscordIpcException(DiscordIpcFailure.protocol);
    }
    if (!request.isCompleted) request.complete();
  }

  void _fail(DiscordIpcFailure reason) {
    ++_generation;
    _stateChanged(DiscordConnectionState.error);
    unawaited(_release(reason));
  }

  Future<void> _release(
      [DiscordIpcFailure reason = DiscordIpcFailure.closed]) async {
    final subscription = _subscription;
    final transport = _transport;
    _subscription = null;
    _transport = null;
    _handshaken = false;
    _buffer = Uint8List(0);
    _writes = Future<void>.value();
    _queuedWrites = 0;
    _frameDeadline?.cancel();
    _frameDeadline = null;
    final ready = _ready;
    _ready = null;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(DiscordIpcException(reason));
    }
    for (final request in _requests.values) {
      if (!request.isCompleted) {
        request.completeError(DiscordIpcException(reason));
      }
    }
    _requests.clear();
    // Closing the OS handle first interrupts pending writes and socket reads.
    if (transport != null) await _closeTransport(transport);
    if (subscription != null) {
      try {
        await subscription.cancel().timeout(timeout);
      } catch (_) {
        // Fixed deadline, without exposing a transport exception or local path.
      }
    }
  }

  Future<void> _closeTransport(DiscordIpcTransport transport) async {
    try {
      await transport.close().timeout(timeout);
    } catch (_) {
      // Release is best effort and bounded even if the peer vanished.
    }
  }

  @override
  Future<void> close() async {
    ++_generation;
    _stateChanged(DiscordConnectionState.disconnected);
    await _release();
  }
}
