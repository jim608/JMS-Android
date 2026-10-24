import 'dart:async';
import 'dart:convert';

import 'package:chopper/chopper.dart' show Response;
import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart' as jellyfin;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'syncplay_clock.dart';
import 'syncplay_models.dart';

/// Injectable socket boundary; neither socket URLs nor errors may be logged.
abstract interface class SyncPlaySocket {
  Future<void> get ready;
  Stream<Object?> get messages;
  void send(String message);
  Future<void> close();
}

typedef SyncPlaySocketFactory = SyncPlaySocket Function(Uri uri);

class _ChannelSocket implements SyncPlaySocket {
  _ChannelSocket(Uri uri) : _channel = WebSocketChannel.connect(uri);
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

/// A single captured Jellyfin account's SyncPlay connection.
///
/// Construct [api] with createJellyfinApiForAccount(..., privateLink: true),
/// using the same captured base URL, token and device ID as this socket. The
/// regular account-following JellyRequest interceptor must not be used here.
/// [isCurrent] must compare the owner's account/credential generation. Close
/// this instance when that generation changes; it never reconnects or retries
/// an ambiguous mutation, and never moves its credentials to another source.
class SyncPlayTransport implements SyncPlayApiPort {
  SyncPlayTransport({
    required jellyfin.JellyfinOpenApi api,
    required Uri baseUri,
    required String token,
    required String deviceId,
    bool Function()? isCurrent,
    bool ownsApi = true,
    SyncPlaySocketFactory? socketFactory,
    SyncPlayScheduler scheduler = const SyncPlayTimerScheduler(),
    this.requestTimeout = const Duration(seconds: 15),
    this.connectTimeout = const Duration(seconds: 10),
  })  : _api = api,
        _socketUri = _makeSocketUri(baseUri, token, deviceId),
        _isCurrent = isCurrent ?? _alwaysCurrent,
        _ownsApi = ownsApi,
        _scheduler = scheduler,
        _socketFactory = socketFactory ?? _ChannelSocket.new;

  final jellyfin.JellyfinOpenApi _api;
  // This URL contains the token. Keep it private and out of all errors/logs.
  final Uri _socketUri;
  final bool Function() _isCurrent;
  final bool _ownsApi;
  final SyncPlayScheduler _scheduler;
  final SyncPlaySocketFactory _socketFactory;
  final Duration requestTimeout;
  final Duration connectTimeout;
  final _events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final _connections = StreamController<bool>.broadcast(sync: true);
  SyncPlaySocket? _socket;
  // Cancelled exactly once in _doReleaseSocket, shared by close/error paths.
  // ignore: cancel_subscriptions
  StreamSubscription<Object?>? _subscription;
  SyncPlayCancellation? _keepAlive;
  int _keepAliveGeneration = 0;
  Future<void>? _connecting;
  Future<void>? _reconnecting;
  Future<void>? _closing;
  Future<void>? _releasingSocket;
  bool _connected = false;
  bool _disposed = false;
  bool _socketEnded = false;

  Stream<Map<String, dynamic>> get events => _events.stream;
  Stream<bool> get connections => _connections.stream;
  bool get connected => _connected && !_disposed && _current;

  static bool _alwaysCurrent() => true;

  bool get _current {
    try {
      return _isCurrent();
    } catch (_) {
      return false;
    }
  }

  static Uri _makeSocketUri(Uri baseUri, String token, String deviceId) {
    if (!const {'http', 'https'}.contains(baseUri.scheme) ||
        !baseUri.hasAuthority ||
        baseUri.host.isEmpty ||
        baseUri.userInfo.isNotEmpty ||
        baseUri.hasQuery ||
        baseUri.hasFragment ||
        token.isEmpty ||
        deviceId.isEmpty) {
      throw const SyncPlayFailure(SyncPlayFailureCode.protocol);
    }
    final segments = baseUri.pathSegments.toList();
    while (segments.isNotEmpty && segments.last.isEmpty) {
      segments.removeLast();
    }
    return baseUri.replace(
      scheme: baseUri.scheme == 'https' ? 'wss' : 'ws',
      pathSegments: [...segments, 'socket'],
      // ApiKey works without Jellyfin's optional legacy-authorization setting.
      queryParameters: {'ApiKey': token, 'deviceId': deviceId},
    );
  }

  void _checkCurrent() {
    if (_disposed || !_current) {
      if (!_disposed) unawaited(close());
      throw const SyncPlayFailure(SyncPlayFailureCode.disconnected);
    }
  }

  /// Attach event listeners before awaiting this method and issuing New/Join.
  Future<void> connect() {
    _checkCurrent();
    if (_connected) return Future.value();
    if (_socketEnded) {
      throw const SyncPlayFailure(SyncPlayFailureCode.disconnected);
    }
    return _connecting ??= _connect();
  }

  Future<void> _connect() async {
    try {
      final socket = _socketFactory(_socketUri);
      _socket = socket;
      _subscription = socket.messages.listen(
        _onMessage,
        onError: (Object _, StackTrace __) => _lostConnection(),
        onDone: _lostConnection,
      );
      await socket.ready.timeout(connectTimeout);
      _checkCurrent();
      if (_socketEnded) {
        throw const SyncPlayFailure(SyncPlayFailureCode.disconnected);
      }
      _setConnected(true);
    } catch (_) {
      _lostConnection();
      throw const SyncPlayFailure(SyncPlayFailureCode.disconnected);
    }
  }

  /// One explicitly requested reconnection; group rejoin belongs to the owner.
  /// Never retries New/Join or reuses the retired socket's subscription/timer.
  Future<void> reconnect() {
    _checkCurrent();
    if (connected) return Future.value();
    return _reconnecting ??= _reconnect();
  }

  Future<void> _reconnect() async {
    try {
      if (!_socketEnded && _connecting != null) {
        await _connecting;
        return;
      }
      await _releaseSocket();
      _checkCurrent();
      _releasingSocket = null;
      _socketEnded = false;
      _connecting = null;
      await connect();
    } finally {
      _reconnecting = null;
    }
  }

  void _setConnected(bool value) {
    if (_connected == value) return;
    _connected = value;
    if (!_connections.isClosed) _connections.add(value);
  }

  void _lostConnection() {
    if (_disposed || _socketEnded) return;
    _socketEnded = true;
    _keepAlive?.cancel();
    _keepAlive = null;
    _keepAliveGeneration++;
    _setConnected(false);
    _events.addError(const SyncPlayFailure(SyncPlayFailureCode.disconnected));
    unawaited(_releaseSocket());
  }

  void _onMessage(Object? message) {
    if (_disposed || _socketEnded) return;
    if (!_current) {
      unawaited(close());
      return;
    }
    try {
      final String text;
      if (message is String && message.length <= 1024 * 1024) {
        text = message;
      } else if (message is List<int> && message.length <= 1024 * 1024) {
        text = utf8.decode(message);
      } else {
        throw const FormatException();
      }
      final envelope = syncPlayMap(jsonDecode(text));
      final type = envelope['MessageType'];
      if (type == 'ForceKeepAlive') {
        _startKeepAlive(envelope['Data']);
        return;
      }
      if (type != 'SyncPlayGroupUpdate' && type != 'SyncPlayCommand') return;
      final data = syncPlayMap(envelope['Data']);
      // Preserve polymorphic Type/Data, bypassing the generated empty base DTO.
      _events.add(Map.unmodifiable({'MessageType': type, 'Data': data}));
    } catch (_) {
      _events.addError(const SyncPlayFailure(SyncPlayFailureCode.protocol));
    }
  }

  // Jellyfin SDK 2a7a70d682fa044ed0899266375c0dea02e854d3,
  // src/websocket/websocket-service.ts:119-122: reply now and every half timeout.
  void _startKeepAlive(Object? seconds) {
    if (seconds is! num ||
        !seconds.isFinite ||
        seconds < 1 ||
        seconds > 86400) {
      throw const FormatException();
    }
    _keepAlive?.cancel();
    final generation = ++_keepAliveGeneration;
    _sendKeepAlive();
    if (_disposed || _socketEnded) return;
    _scheduleKeepAlive(
        Duration(milliseconds: (seconds * 500).round()), generation);
  }

  void _scheduleKeepAlive(Duration interval, int generation) {
    _keepAlive = _scheduler.schedule(interval, () {
      if (generation != _keepAliveGeneration) return;
      _sendKeepAlive();
      if (!_disposed && !_socketEnded && generation == _keepAliveGeneration) {
        _scheduleKeepAlive(interval, generation);
      }
    });
  }

  void _sendKeepAlive() {
    if (_disposed || _socketEnded || !_current) {
      if (!_disposed && !_current) unawaited(close());
      return;
    }
    try {
      _socket?.send('{"MessageType":"KeepAlive"}');
    } catch (_) {
      _lostConnection();
    }
  }

  Future<Response<T>> _request<T>(
    Future<Response<T>> Function() request, {
    bool ambiguousMutation = false,
    bool requiresSocket = false,
    bool unsupportedIsDefinitive = false,
  }) async {
    _checkCurrent();
    if (requiresSocket && !connected) {
      throw const SyncPlayFailure(SyncPlayFailureCode.disconnected);
    }
    try {
      final response = await request().timeout(requestTimeout);
      _checkCurrent();
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const SyncPlayFailure(SyncPlayFailureCode.denied);
      }
      if (unsupportedIsDefinitive &&
          const {404, 405, 501}.contains(response.statusCode)) {
        throw const SyncPlayFailure(SyncPlayFailureCode.unsupported);
      }
      if (!response.isSuccessful) {
        throw SyncPlayFailure(ambiguousMutation && response.statusCode >= 500
            ? SyncPlayFailureCode.timeoutUnknown
            : SyncPlayFailureCode.server);
      }
      return response;
    } on SyncPlayFailure {
      rethrow;
    } on FormatException {
      throw SyncPlayFailure(ambiguousMutation
          ? SyncPlayFailureCode.timeoutUnknown
          : SyncPlayFailureCode.protocol);
    } catch (_) {
      _checkCurrent();
      throw SyncPlayFailure(ambiguousMutation
          ? SyncPlayFailureCode.timeoutUnknown
          : SyncPlayFailureCode.server);
    }
  }

  T _parse<T>(T Function() parse) {
    try {
      return parse();
    } catch (_) {
      throw const SyncPlayFailure(SyncPlayFailureCode.protocol);
    }
  }

  @override
  Future<List<SyncPlayGroup>> listGroups() async {
    final response = await _request(_api.syncPlayListGet);
    return _parse(() {
      final body = response.body;
      if (body == null || body.length > 10000) throw const FormatException();
      return body
          .map((group) => SyncPlayGroup.fromJson(group.toJson()))
          .toList();
    });
  }

  @override
  Future<SyncPlayGroup> newGroup(String groupName) async {
    if (!RegExp(r'^JMS-[0-9]{6}$').hasMatch(groupName)) {
      throw const SyncPlayFailure(SyncPlayFailureCode.invalidCode);
    }
    final response = await _request(
      () => _api.syncPlayNewPost(
          body: jellyfin.NewGroupRequestDto(groupName: groupName)),
      ambiguousMutation: true,
      requiresSocket: true,
    );
    try {
      return SyncPlayGroup.fromJson(response.body!.toJson());
    } catch (_) {
      // The server may have created the room even if its response was malformed.
      throw const SyncPlayFailure(SyncPlayFailureCode.timeoutUnknown);
    }
  }

  @override
  Future<void> joinGroup(String groupId) async {
    final id = _parse(() => syncPlayId(groupId));
    await _request(
      () => _api.syncPlayJoinPost(
          body: jellyfin.JoinGroupRequestDto(groupId: id)),
      ambiguousMutation: true,
      requiresSocket: true,
    );
  }

  @override
  Future<void> leaveGroup() async {
    await _request(_api.syncPlayLeavePost);
  }

  @override
  Future<void> sendRequest(SyncPlayRequest request) async {
    _checkCurrent();
    if (!connected) {
      throw const SyncPlayFailure(SyncPlayFailureCode.disconnected);
    }
    // DTO construction and all HTTP failures stay inside the sanitizing boundary.
    await _request(
        () => switch (request.type) {
              SyncPlayRequestType.pause => _api.syncPlayPausePost(),
              SyncPlayRequestType.unpause => _api.syncPlayUnpausePost(),
              SyncPlayRequestType.seek => _api.syncPlaySeekPost(
                  body: jellyfin.SeekRequestDto.fromJson(request.body)),
              SyncPlayRequestType.setNewQueue => _api.syncPlaySetNewQueuePost(
                  body: jellyfin.PlayRequestDto.fromJson(request.body)),
              SyncPlayRequestType.buffering => _api.syncPlayBufferingPost(
                  body: jellyfin.BufferRequestDto.fromJson(request.body)),
              SyncPlayRequestType.ready => _api.syncPlayReadyPost(
                  body: jellyfin.ReadyRequestDto.fromJson(request.body)),
              SyncPlayRequestType.setIgnoreWait =>
                _api.syncPlaySetIgnoreWaitPost(
                    body: jellyfin.IgnoreWaitRequestDto(
                        ignoreWait: request.body['IgnoreWait'] as bool)),
              SyncPlayRequestType.ping => _api.syncPlayPingPost(
                  body: jellyfin.PingRequestDto.fromJson(request.body)),
            },
        requiresSocket: true,
        ambiguousMutation: request.type == SyncPlayRequestType.setIgnoreWait,
        unsupportedIsDefinitive:
            request.type == SyncPlayRequestType.setIgnoreWait);
  }

  @override
  Future<SyncPlayServerTime> getServerTime() async {
    final response = await _request(_api.getUtcTimeGet);
    return _parse(() => SyncPlayServerTime.fromJson(response.body!.toJson()));
  }

  Future<void> _releaseSocket() => _releasingSocket ??= _doReleaseSocket();

  Future<void> _doReleaseSocket() async {
    final subscription = _subscription;
    final socket = _socket;
    _subscription = null;
    _socket = null;
    try {
      await subscription?.cancel();
    } catch (_) {
      // Cleanup cannot expose a network error containing a credential URL.
    }
    try {
      await socket?.close().timeout(const Duration(seconds: 2));
    } catch (_) {
      // The client has already detached; do not retry closing another session.
    }
  }

  /// Idempotent; invalidates pending HTTP/handshake results before any await.
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _disposed = true;
    _keepAlive?.cancel();
    _keepAlive = null;
    _keepAliveGeneration++;
    _setConnected(false);
    if (_ownsApi) {
      try {
        // Chopper does not close an externally supplied HTTP client itself.
        _api.client.httpClient.close();
      } catch (_) {
        // Continue detaching Chopper even when a client fails during close.
      }
      try {
        _api.client.dispose();
      } catch (_) {
        // A disposed HTTP client cannot be reused; never expose its URL/error.
      }
    }
    await _releaseSocket();
    unawaited(_events.close());
    unawaited(_connections.close());
  }
}
