import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'syncplay/syncplay_socket_connector_stub.dart'
    if (dart.library.io) 'syncplay/syncplay_socket_connector_io.dart';

/// Injectable socket boundary. URLs and underlying errors can contain secrets.
abstract interface class JellyfinSessionSocket {
  Future<void> get ready;
  Stream<Object?> get messages;
  void send(String message);
  Future<void> close();
}

typedef JellyfinSessionSocketFactory = JellyfinSessionSocket Function(Uri uri);
typedef JellyfinSessionSocketConnector = JellyfinSessionSocket Function(
    Uri uri, Map<String, String> headers);

/// Keeps the existing native headers and browser WebSocket behavior.
JellyfinSessionSocketFactory capturedJellyfinSessionSocketFactory(
  Map<String, String>? headers,
) {
  final captured = Map<String, String>.unmodifiable(headers ?? const {});
  return (uri) => _ChannelSocket(uri, captured);
}

class _ChannelSocket implements JellyfinSessionSocket {
  _ChannelSocket(Uri uri, Map<String, String> headers)
      : _channel = connectSyncPlaySocket(uri, headers);
  final WebSocketChannel _channel;
  @override
  Future<void> get ready => _channel.ready;
  @override
  Stream<Object?> get messages => _channel.stream;
  @override
  void send(String message) => _channel.sink.add(message);
  @override
  Future<void> close() async => _channel.sink.close(1000);
}

/// Safe failure shared by socket consumers; never wraps a credential URL.
class JellyfinSessionSocketClosed implements Exception {
  const JellyfinSessionSocketClosed();
  @override
  String toString() => 'Jellyfin session socket disconnected';
}

/// One account/credential generation's explicitly opened session sockets.
///
/// Identical URI and captured headers share one physical channel. Each lease
/// receives every message once and owns its own subscription lifetime. This
/// hub has no protocol knowledge, automatic connections, retries, or replay.
/// Dispose it immediately when its account/credential generation changes.
class JellyfinSessionSocketHub {
  JellyfinSessionSocketHub({JellyfinSessionSocketConnector? connector})
      : _connector = connector ?? _connect;

  final JellyfinSessionSocketConnector _connector;
  final _entries = <_SocketKey, _SharedSocket>{};
  bool _disposed = false;
  Future<void>? _disposing;

  static JellyfinSessionSocket _connect(Uri uri, Map<String, String> headers) =>
      _ChannelSocket(uri, headers);

  /// Captures headers now; creating a factory does not connect a socket.
  JellyfinSessionSocketFactory factory({
    required bool Function() isCurrent,
    Map<String, String>? headers,
  }) {
    final captured = Map<String, String>.unmodifiable(headers ?? const {});
    return (uri) {
      if (_disposed || !_current(isCurrent)) {
        throw const JellyfinSessionSocketClosed();
      }
      final key = _SocketKey(uri, captured);
      var entry = _entries[key];
      var created = false;
      if (entry == null) {
        final JellyfinSessionSocket socket;
        try {
          socket = _connector(uri, captured);
        } catch (_) {
          throw const JellyfinSessionSocketClosed();
        }
        if (_disposed || !_current(isCurrent)) {
          unawaited(_SharedSocket(socket, () {}).end());
          throw const JellyfinSessionSocketClosed();
        }
        entry = _SharedSocket(socket, () {
          if (identical(_entries[key], entry)) _entries.remove(key);
        });
        _entries[key] = entry;
        created = true;
      }
      final lease = entry.acquire(isCurrent);
      if (created) entry.start();
      return lease;
    };
  }

  /// Invalidates all leases synchronously before awaiting physical cleanup.
  Future<void> dispose() => _disposing ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    final entries = _entries.values.toList();
    _entries.clear();
    await Future.wait(entries.map((entry) => entry.end()));
  }
}

bool _current(bool Function() check) {
  try {
    return check();
  } catch (_) {
    return false;
  }
}

class _SocketKey {
  _SocketKey(this.uri, this.headers);
  final Uri uri;
  final Map<String, String> headers;

  @override
  bool operator ==(Object other) =>
      other is _SocketKey &&
      uri == other.uri &&
      headers.length == other.headers.length &&
      headers.entries.every((entry) => other.headers[entry.key] == entry.value);

  @override
  int get hashCode => Object.hash(
        uri,
        Object.hashAllUnordered(
          headers.entries.map((entry) => Object.hash(entry.key, entry.value)),
        ),
      );
}

class _SharedSocket {
  _SharedSocket(this.socket, this.onEnded);
  final JellyfinSessionSocket socket;
  final void Function() onEnded;
  final _leases = <_SocketLease>{};
  // Cancelled once by end(), independently of the physical channel's close.
  // ignore: cancel_subscriptions
  StreamSubscription<Object?>? _subscription;
  bool _ended = false;
  bool _ready = false;
  bool _observingReady = false;
  Future<void>? _closing;

  _SocketLease acquire(bool Function() isCurrent) {
    final lease = _SocketLease(this, isCurrent);
    _leases.add(lease);
    if (_ready) lease.opened();
    return lease;
  }

  void start() {
    _observeReady();
    if (_ended) return;
    try {
      final subscription = socket.messages.listen(
        (message) {
          for (final lease in _leases.toList()) {
            lease.receive(message);
          }
        },
        onError: (Object _, StackTrace __) => unawaited(end(error: true)),
        onDone: () => unawaited(end(error: true)),
      );
      if (_ended) {
        unawaited(subscription.cancel().catchError((Object _) {}));
        return;
      }
      _subscription = subscription;
    } catch (_) {
      unawaited(end(error: true));
    }
  }

  void _observeReady() {
    if (_observingReady) return;
    _observingReady = true;
    unawaited(_waitReady());
  }

  Future<void> _waitReady() async {
    try {
      await socket.ready;
      if (_ended) return;
      _ready = true;
      for (final lease in _leases.toList()) {
        lease.opened();
      }
    } catch (_) {
      await end(error: true);
    }
  }

  void send(String message) {
    if (_ended) throw const JellyfinSessionSocketClosed();
    try {
      socket.send(message);
    } catch (_) {
      unawaited(end(error: true));
      throw const JellyfinSessionSocketClosed();
    }
  }

  Future<void> release(_SocketLease lease) {
    _leases.remove(lease);
    return _leases.isEmpty ? end() : Future.value();
  }

  Future<void> end({bool error = false}) {
    if (_ended) return _closing ?? Future.value();
    _ended = true;
    // Even a socket retired before start() can reject its handshake later.
    _observeReady();
    onEnded();
    for (final lease in _leases.toList()) {
      lease.ended(error: error);
    }
    _leases.clear();
    return _closing = _cleanup();
  }

  Future<void> _cleanup() async {
    Future<void> settle(Future<void> Function() action) async {
      try {
        await action().timeout(const Duration(seconds: 2));
      } catch (_) {
        // Neither cleanup failures nor timeouts may expose socket URLs.
      }
    }

    final subscription = _subscription;
    _subscription = null;
    await Future.wait([
      settle(() async => subscription?.cancel()),
      settle(socket.close),
    ]);
  }
}

class _SocketLease implements JellyfinSessionSocket {
  _SocketLease(this._owner, this._isCurrent) {
    // A lease can end before a consumer observes ready. Keep that safe while
    // retaining the same failure for a later await of the original future.
    unawaited(
      _ready.future.then<void>((_) {}, onError: (Object _, StackTrace __) {}),
    );
  }
  final _SharedSocket _owner;
  final bool Function() _isCurrent;
  final _ready = Completer<void>();
  final _messages = StreamController<Object?>.broadcast(sync: true);
  bool _closed = false;
  bool _dispatching = false;
  bool _messagesFinished = false;
  bool _terminalError = false;
  Future<void>? _closing;

  bool get _valid => !_closed && _current(_isCurrent);

  @override
  Future<void> get ready {
    if (!_valid) unawaited(close());
    if (_closed) return Future.error(const JellyfinSessionSocketClosed());
    return _ready.future;
  }

  @override
  Stream<Object?> get messages {
    if (!_valid) unawaited(close());
    return _messages.stream;
  }

  void opened() {
    if (!_valid) {
      unawaited(close());
    } else if (!_ready.isCompleted) {
      _ready.complete();
    }
  }

  void receive(Object? message) {
    if (!_valid) {
      unawaited(close());
    } else {
      _dispatching = true;
      try {
        _messages.add(message);
      } finally {
        _dispatching = false;
        if (_closed) _finishMessages();
      }
    }
  }

  @override
  void send(String message) {
    if (!_valid) {
      unawaited(close());
      throw const JellyfinSessionSocketClosed();
    }
    _owner.send(message);
  }

  void ended({required bool error}) {
    if (_closed) return;
    _closed = true;
    if (!_ready.isCompleted) {
      _ready.completeError(const JellyfinSessionSocketClosed());
    }
    _terminalError = error;
    _finishMessages();
  }

  void _finishMessages() {
    if (_dispatching || _messagesFinished) return;
    _messagesFinished = true;
    if (_terminalError) _messages.addError(const JellyfinSessionSocketClosed());
    unawaited(_messages.close());
  }

  @override
  Future<void> close() {
    if (_closed) return _closing ?? _owner._closing ?? Future.value();
    ended(error: false);
    return _closing = _owner.release(this);
  }
}
