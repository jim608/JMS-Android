import 'dart:async';
import 'dart:convert';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/services/jellyfin_session_socket.dart';
import 'package:fladder/services/remote_control/remote_control_models.dart';
import 'package:fladder/services/remote_control/remote_control_protocol.dart';

class RemotePlaybackSnapshot {
  const RemotePlaybackSnapshot({
    required this.binding,
    required this.positionTicks,
    required this.durationTicks,
    required this.paused,
    required this.canSeek,
    this.subtitleIndex,
    this.playSessionId,
    this.audioStreamIndex,
  });

  final RemotePlaybackBinding binding;
  final int positionTicks;
  final int? durationTicks;
  final bool paused;
  final bool canSeek;
  // Null means the player's applied selection has not been confirmed.
  final int? subtitleIndex;
  final String? playSessionId;
  final int? audioStreamIndex;

  PlaybackProgressInfo toProgress() => PlaybackProgressInfo(
        itemId: binding.itemId,
        mediaSourceId: binding.mediaSourceId,
        playlistItemId: binding.playbackId,
        nowPlayingQueue: [
          QueueItem(id: binding.itemId, playlistItemId: binding.playbackId),
        ],
        playSessionId: playSessionId,
        positionTicks: positionTicks,
        isPaused: paused,
        canSeek: canSeek,
        subtitleStreamIndex: subtitleIndex,
        audioStreamIndex: audioStreamIndex,
      );
}

abstract interface class RemotePlaybackPort {
  RemotePlaybackSnapshot? get snapshot;
  bool get blockedBySyncPlay;
  Future<void> play(RemotePlaybackBinding binding);
  Future<void> pause(RemotePlaybackBinding binding);
  Future<void> seek(Duration position, RemotePlaybackBinding binding);
  Future<void> setSubtitle(int index, RemotePlaybackBinding binding);
}

abstract interface class RemoteReceiverApi {
  Future<String?> ownSessionId();
  Future<void> capabilities(bool enabled);
  Future<void> report(PlaybackProgressInfo progress);
}

enum RemoteReceiverState {
  disabled,
  connecting,
  enabled,
  blocked,
  disconnected,
  error,
}

/// One explicit opt-in lease on the account's shared Jellyfin socket.
/// No reconnect can replay a previously accepted player mutation.
class RemoteReceiverController {
  RemoteReceiverController({
    required this.api,
    required this.socketFactory,
    required this.socketUri,
    required this.currentUserId,
    required this.player,
    required this.isCurrent,
    DateTime Function()? now,
    this.progressInterval = const Duration(seconds: 2),
    this.keepAliveInterval = const Duration(seconds: 30),
    this.cleanupTimeout = const Duration(seconds: 2),
  }) : now = now ?? DateTime.now;

  final RemoteReceiverApi api;
  final JellyfinSessionSocketFactory socketFactory;
  final Uri socketUri;
  final String currentUserId;
  final RemotePlaybackPort player;
  final bool Function() isCurrent;
  final DateTime Function() now;
  final Duration progressInterval;
  final Duration keepAliveInterval;
  final Duration cleanupTimeout;

  final _states = StreamController<RemoteReceiverState>.broadcast(sync: true);
  final _guard = RemoteCommandGuard();
  final _pending = <RemoteControlCommand>[];
  RemoteReceiverState _state = RemoteReceiverState.disabled;
  RemoteReceiverState get state => _state;
  Stream<RemoteReceiverState> get states => _states.stream;
  bool get enabled => _enabled;
  bool _enabled = false;
  bool _closed = false;
  bool _closing = false;
  Future<void>? _closeFuture;
  bool _ready = false;
  bool _draining = false;
  bool _reporting = false;
  bool? _advertised;
  String? _advertisedSessionId;
  int _generation = 0;
  String? _sessionId;
  JellyfinSessionSocket? _socket;
  // Cancelled by _release after moving the lease out of the active generation.
  // ignore: cancel_subscriptions
  StreamSubscription<Object?>? _subscription;
  Timer? _progressTimer;
  Timer? _keepAliveTimer;
  RemotePlaybackSnapshot? _latestReport;
  bool? _desiredCapabilities;
  int _capabilityGeneration = 0;
  String? _capabilitySessionId;
  Completer<void>? _capabilityIdle;

  bool _valid(int generation) =>
      !_closed &&
      !_closing &&
      _enabled &&
      generation == _generation &&
      isCurrent();
  bool get _available =>
      _ready &&
      !player.blockedBySyncPlay &&
      player.snapshot?.binding.isComplete == true;

  void _setState(RemoteReceiverState value) {
    if (_closed || _state == value) return;
    _state = value;
    _states.add(value);
  }

  Future<void> enable() async {
    if (_closed || _closing || _enabled || !isCurrent()) return;
    _enabled = true;
    final generation = ++_generation;
    _setState(RemoteReceiverState.connecting);
    try {
      final socket = socketFactory(socketUri);
      _socket = socket;
      // Subscribe before awaiting readiness: a broadcast socket may already emit.
      _subscription = socket.messages.listen(
        (message) => _receive(message, generation),
        onError: (Object _) => unawaited(_disconnect(generation)),
        onDone: () => unawaited(_disconnect(generation)),
      );
      await socket.ready;
      if (!_valid(generation)) {
        await _disconnect(generation);
        return;
      }
      final sessionId = await api.ownSessionId();
      if (!_valid(generation)) {
        await _disconnect(generation);
        return;
      }
      if (sessionId == null || sessionId.isEmpty) {
        await _disconnect(generation, failed: true);
        return;
      }
      _sessionId = sessionId;
      _ready = true;
      _progressTimer = Timer.periodic(
        progressInterval,
        (_) => _tick(generation),
      );
      _keepAliveTimer = Timer.periodic(keepAliveInterval, (_) {
        if (!_valid(generation)) {
          unawaited(_disconnect(generation));
          return;
        }
        try {
          socket.send('{"MessageType":"KeepAlive"}');
        } catch (_) {
          unawaited(_disconnect(generation));
        }
      });
      _refresh(generation);
      if (_valid(generation) && _available) _queueReport(generation);
    } catch (_) {
      await _disconnect(generation, failed: true);
    }
  }

  void _refresh(int generation) {
    if (!_valid(generation) || !_ready) return;
    _setState(
      player.blockedBySyncPlay
          ? RemoteReceiverState.blocked
          : RemoteReceiverState.enabled,
    );
    _capabilities(_available, generation);
  }

  // One physical request and one latest desired value, even on a stalled API.
  // A timed-out cleanup never claims to cancel that request. An open receiver
  // retains its latest desired value; full close stops further requests.
  Future<void> _capabilities(bool value, int generation) {
    // A late cleanup from an older lease must not replace the new lease's
    // pending advertisement, particularly when Jellyfin assigned a new session.
    if (_closed) return Future<void>.value();
    if (!isCurrent() ||
        (value && (!_valid(generation) || !_available)) ||
        (!value && _enabled && _ready && _available)) {
      return _capabilityIdle?.future ?? Future<void>.value();
    }
    _desiredCapabilities = value;
    _capabilityGeneration = generation;
    _capabilitySessionId = _sessionId;
    if (_capabilityIdle == null) {
      final idle = _capabilityIdle = Completer<void>();
      unawaited(_drainCapabilities(idle));
      return idle.future;
    }
    return _capabilityIdle!.future;
  }

  Future<void> _drainCapabilities(Completer<void> idle) async {
    try {
      while (!_closed && _desiredCapabilities != null) {
        final value = _desiredCapabilities!;
        final generation = _capabilityGeneration;
        final sessionId = _capabilitySessionId;
        _desiredCapabilities = null;
        if (!isCurrent() ||
            (value &&
                (!_valid(generation) ||
                    !_available ||
                    sessionId != _sessionId))) {
          continue;
        }
        if (!value && _enabled && _ready && _available) continue;
        if (_advertised == value &&
            (!value || _advertisedSessionId == sessionId)) {
          continue;
        }
        try {
          await api.capabilities(value);
          if (!_closed) {
            _advertised = value;
            _advertisedSessionId = value ? sessionId : null;
          }
        } catch (_) {
          // A timeout may leave the physical request in flight. Its eventual
          // result can differ from this cache, so a later desired true must be
          // sent even when the last confirmed value had also been true.
          _clearCapabilityCache();
          // Keep an already queued latest value. With none queued, the next
          // tick refreshes the current opt-in without an immediate retry loop.
        }
      }
    } finally {
      _capabilityIdle = null;
      idle.complete();
    }
  }

  void _clearCapabilityCache() {
    _advertised = null;
    _advertisedSessionId = null;
  }

  void _tick(int generation) {
    if (!_valid(generation)) {
      unawaited(_disconnect(generation));
      return;
    }
    _refresh(generation);
    if (_valid(generation) && _available) _queueReport(generation);
  }

  void _receive(Object? message, int generation) {
    if (!_valid(generation)) {
      unawaited(_disconnect(generation));
      return;
    }
    if (!_ready) return;
    if (!_available) {
      _refresh(generation);
      return;
    }
    if (message is String) {
      if (message.length > 32768) return;
      try {
        message = jsonDecode(message);
      } on FormatException {
        return;
      }
    }
    final command = RemoteControlProtocol.parse(
      message,
      userId: currentUserId,
      sessionId: _sessionId!,
      binding: player.snapshot!.binding,
      now: now(),
    );
    if (command == null || !_guard.accept(command)) return;
    final category = _category(command.action.type);
    _pending.removeWhere((entry) => _category(entry.action.type) == category);
    _pending.add(command); // At most one transport, seek, and subtitle command.
    if (!_draining) unawaited(_drain(generation));
  }

  int _category(RemoteActionType type) => switch (type) {
        RemoteActionType.play || RemoteActionType.pause => 0,
        RemoteActionType.seek => 1,
        RemoteActionType.subtitle => 2,
      };

  Future<void> _drain(int generation) async {
    _draining = true;
    try {
      while (_valid(generation) && _pending.isNotEmpty) {
        final command = _pending.removeAt(0);
        final snapshot = player.snapshot;
        if (!_available ||
            snapshot?.binding != command.binding ||
            !command.expiresAt.isAfter(now())) {
          continue;
        }
        try {
          switch (command.action.type) {
            case RemoteActionType.play:
              await player.play(command.binding);
            case RemoteActionType.pause:
              await player.pause(command.binding);
            case RemoteActionType.seek:
              final position = command.action.position!;
              final ticks = position.inMicroseconds * 10;
              if (!snapshot!.canSeek ||
                  ticks < 0 ||
                  (snapshot.durationTicks != null &&
                      ticks > snapshot.durationTicks!)) {
                continue;
              }
              await player.seek(position, command.binding);
            case RemoteActionType.subtitle:
              await player.setSubtitle(
                command.action.subtitleIndex!,
                command.binding,
              );
          }
          if (_valid(generation) &&
              _available &&
              player.snapshot?.binding == command.binding) {
            _queueReport(generation);
          }
        } catch (_) {
          // A failed selection is not a confirmed selection of Off.
        }
      }
    } finally {
      _draining = false;
      // A new opt-in can arrive while an old player's callback finishes.
      if (_valid(_generation) && _pending.isNotEmpty) {
        unawaited(_drain(_generation));
      }
    }
  }

  void _queueReport(int generation) {
    if (!_valid(generation) || !_available) return;
    _latestReport = player.snapshot;
    if (!_reporting) unawaited(_drainReports(generation));
  }

  Future<void> _drainReports(int generation) async {
    _reporting = true;
    try {
      while (_valid(generation) && _latestReport != null) {
        final snapshot = _latestReport!;
        _latestReport = null;
        if (!_available || player.snapshot?.binding != snapshot.binding) {
          continue;
        }
        try {
          await api.report(snapshot.toProgress());
        } catch (_) {
          // Do not retry an old progress payload after a connection failure.
        }
      }
    } finally {
      _reporting = false;
      if (_valid(_generation) && _latestReport != null) {
        unawaited(_drainReports(_generation));
      }
    }
  }

  Future<void> _disconnect(int generation, {bool failed = false}) async {
    if (generation != _generation || _closed) return;
    ++_generation;
    _enabled = false;
    await _release(generation);
    if (_generation == generation + 1) {
      _setState(
        failed ? RemoteReceiverState.error : RemoteReceiverState.disconnected,
      );
    }
  }

  Future<void> _release(int generation) async {
    _ready = false;
    _sessionId = null;
    _pending.clear();
    _latestReport = null;
    // Opt-out/reconnect revokes pending work, but must not make an already
    // executed envelope replayable while its wire TTL is still valid.
    _progressTimer?.cancel();
    _keepAliveTimer?.cancel();
    _progressTimer = null;
    _keepAliveTimer = null;
    final subscription = _subscription;
    final socket = _socket;
    _subscription = null;
    _socket = null;
    try {
      await subscription?.cancel().timeout(cleanupTimeout);
    } catch (_) {}
    try {
      await socket?.close().timeout(cleanupTimeout);
    } catch (_) {}
    try {
      await _capabilities(false, generation).timeout(cleanupTimeout);
    } catch (_) {
      _clearCapabilityCache();
    }
  }

  Future<void> disable() async {
    if (_closed) return;
    _enabled = false;
    final generation = ++_generation;
    await _release(generation);
    if (_generation == generation) _setState(RemoteReceiverState.disabled);
  }

  Future<void> close() {
    if (_closeFuture != null) return _closeFuture!;
    _closing = true;
    return _closeFuture = _finishClose();
  }

  Future<void> _finishClose() async {
    await disable();
    _closed = true;
    _guard.clear();
    _desiredCapabilities = null;
    _clearCapabilityCache();
    await _states.close();
  }
}
