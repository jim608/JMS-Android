import 'dart:async';

import 'package:chopper/chopper.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';

/// This port owns one captured account's private client. Implementations must
/// return the original HTTP completion, never a timeout that releases ordering.
abstract interface class PlaybackReportApi {
  Future<void> start(PlaybackStartInfo info);
  Future<void> progress(PlaybackProgressInfo info);
  Future<void> stop(PlaybackStopInfo info);
  void close();
}

enum _Kind { start, progress, stop }

typedef CapturedPlaybackInfoRequest = Future<Response<PlaybackInfoResponse>>
    Function(String itemId, PlaybackInfoDto body);

class _Write {
  _Write(this.owner, this.send);
  final Object owner;
  final Future<void> Function() send;
  final done = Completer<void>();
}

/// Preserved across login generations of the same server/device/user. Closing a
/// client is not evidence that its already-sent server mutation was cancelled.
class PlaybackReportLane {
  final _queue = <_Write>[];
  bool _busy = false;
  Future<void> _send(Object owner, Future<void> Function() send) {
    final write = _Write(owner, send);
    _queue.add(write);
    if (!_busy) unawaited(_drain());
    return write.done.future;
  }

  void _cancelQueued(Object owner) {
    final cancelled =
        _queue.where((write) => identical(write.owner, owner)).toList();
    _queue.removeWhere((write) => identical(write.owner, owner));
    for (final write in cancelled) {
      write.done.complete();
    }
  }

  Future<void> _drain() async {
    _busy = true;
    try {
      while (_queue.isNotEmpty) {
        final write = _queue.removeAt(0);
        try {
          await write.send();
        } catch (_) {
        } finally {
          write.done.complete();
        }
      }
    } finally {
      _busy = false;
    }
  }
}

class _Report {
  _Report(this.scope, this.kind, this.payload, this.isCurrent);
  final PlaybackReportingScope scope;
  final _Kind kind;
  final Object payload;
  final bool Function()? isCurrent;
  final done = Completer<void>();
}

/// One login generation and one physical playback-report writer. Capturing a
/// scope does not activate it, so prefetch/negotiation leaves playback untouched.
class PlaybackReportingCapture {
  PlaybackReportingCapture({
    required this.api,
    required bool Function() isCurrent,
    required bool Function(PlaybackReportingScope scope) isPlaybackCurrent,
    bool Function()? enabled,
    void Function(PlaybackStopInfo info)? onStopped,
    PlaybackReportLane? lane,
    CapturedPlaybackInfoRequest? playbackInfoRequest,
  })  : _accountCurrent = isCurrent,
        _playbackCurrent = isPlaybackCurrent,
        _enabled = enabled ?? (() => true),
        _onStopped = onStopped,
        _lane = lane ?? PlaybackReportLane(),
        _playbackInfoRequest = playbackInfoRequest;

  final PlaybackReportApi api;
  final bool Function() _accountCurrent;
  final bool Function(PlaybackReportingScope) _playbackCurrent;
  final bool Function() _enabled;
  final void Function(PlaybackStopInfo)? _onStopped;
  final PlaybackReportLane _lane;
  final CapturedPlaybackInfoRequest? _playbackInfoRequest;
  bool _closed = false;
  bool _writing = false;
  int _negotiating = 0;
  bool _apiClosed = false;
  PlaybackReportingScope? _active;
  PlaybackReportingScope? _serverScope;
  final _pending = <_Report>[];

  bool get isCurrent {
    if (_closed) return false;
    try {
      return _accountCurrent();
    } catch (_) {
      return false;
    }
  }

  bool _matches(PlaybackReportingScope scope) {
    try {
      return _playbackCurrent(scope);
    } catch (_) {
      return false;
    }
  }

  bool get _canReport {
    if (!isCurrent) return false;
    try {
      return _enabled();
    } catch (_) {
      return false;
    }
  }

  PlaybackReportingScope bind({
    required String itemId,
    required String? mediaSourceId,
    required String? playSessionId,
    required String? playlistItemId,
  }) =>
      PlaybackReportingScope._(
          this, itemId, mediaSourceId, playSessionId, playlistItemId);

  /// Subtitle renegotiation is another account-owned POST. It must not enter
  /// the mutable JellyRequest interceptor while waiting for a connectivity probe.
  Future<Response<PlaybackInfoResponse>?> negotiatePlaybackInfo({
    required String itemId,
    required PlaybackInfoDto body,
  }) async {
    final request = _playbackInfoRequest;
    if (!isCurrent || request == null) return null;
    _negotiating++;
    try {
      final response = await request(itemId, body);
      return isCurrent ? response : null;
    } catch (_) {
      return null;
    } finally {
      _negotiating--;
      _closeApiIfIdle();
    }
  }

  bool _activate(PlaybackReportingScope scope) {
    if (!scope.isOwned || !_matches(scope)) return false;
    if (identical(_active, scope)) return true;
    _active = scope;
    // A queued stop for the physically current occurrence must precede the new
    // start. Old starts/progress have never committed and are obsolete.
    _removeWhere((job) =>
        !identical(job.scope, scope) &&
        !(job.kind == _Kind.stop && identical(job.scope, _serverScope)));
    return true;
  }

  void _removeWhere(bool Function(_Report) test) {
    final removed = _pending.where(test).toList();
    _pending.removeWhere(test);
    for (final job in removed) {
      job.done.complete();
    }
  }

  bool _guard(bool Function()? guard) {
    try {
      return guard?.call() ?? true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _enqueue(PlaybackReportingScope scope, _Kind kind, Object info,
      {bool Function()? guard}) {
    if (!isCurrent || !_guard(guard)) return Future<void>.value();
    if (kind == _Kind.stop) {
      if (scope._stopped || !identical(_active, scope)) {
        return Future<void>.value();
      }
      scope._stopped = true;
      _removeWhere(
          (job) => identical(job.scope, scope) && job.kind != _Kind.stop);
      // An occurrence never sent to the server needs no server stop.
      if (!identical(_serverScope, scope)) return Future<void>.value();
    } else {
      if (!scope.isCurrent) return Future<void>.value();
      if (kind == _Kind.start) {
        // A later play/start is newer intent than a queued paused/progress
        // observation. It must not be followed by that obsolete observation.
        _removeWhere(
            (job) => identical(job.scope, scope) && job.kind == _Kind.progress);
      }
      // One latest progress and one latest start per current occurrence.
      _removeWhere((job) =>
          identical(job.scope, scope) &&
          job.kind == kind &&
          (kind != _Kind.progress ||
              (job.isCurrent == null) == (guard == null)));
    }
    if (!_canReport) return Future<void>.value();
    final job = _Report(scope, kind, info, guard);
    _pending.add(job);
    if (!_writing) unawaited(_drain());
    return job.done.future;
  }

  Future<void> _drain() async {
    _writing = true;
    try {
      while (_pending.isNotEmpty) {
        final job = _pending.removeAt(0);
        try {
          await _lane._send(this, () async {
            if (!_canReport) return;
            if (job.kind == _Kind.stop) {
              if (!identical(_serverScope, job.scope)) return;
              // Local sync progress is also an account-owned side effect.
              try {
                _onStopped?.call(job.payload as PlaybackStopInfo);
              } catch (_) {}
              if (!_canReport) return;
              await api.stop(job.payload as PlaybackStopInfo);
              if (identical(_serverScope, job.scope)) _serverScope = null;
            } else {
              if (!job.scope.isCurrent || !_guard(job.isCurrent)) return;
              _serverScope = job.scope;
              switch (job.kind) {
                case _Kind.start:
                  await api.start(job.payload as PlaybackStartInfo);
                case _Kind.progress:
                  await api.progress(job.payload as PlaybackProgressInfo);
                case _Kind.stop:
                  break;
              }
            }
          });
        } catch (_) {
          // No retry and no raw error/URL logging. A completed failure releases
          // the actual HTTP slot; a still-pending HTTP request never does.
        } finally {
          job.done.complete();
        }
      }
    } finally {
      _writing = false;
      _closeApiIfIdle();
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _active = null;
    _removeWhere((_) => true);
    _lane._cancelQueued(this);
    _closeApiIfIdle();
  }

  void _closeApiIfIdle() {
    if (_closed && !_writing && _negotiating == 0 && !_apiClosed) {
      _apiClosed = true;
      api.close();
    }
  }
}

class PlaybackReportingScope {
  PlaybackReportingScope._(this.capture, this.itemId, this.mediaSourceId,
      this.playSessionId, this.playlistItemId);
  final PlaybackReportingCapture capture;
  final String itemId;
  final String? mediaSourceId;
  final String? playSessionId;
  final String? playlistItemId;
  bool _stopped = false;

  bool get isOwned => capture.isCurrent && !_stopped;
  bool get isCurrent =>
      isOwned && identical(capture._active, this) && capture._matches(this);
  bool activate() => capture._activate(this);

  PlaybackReportingScope rebind(
      {required String itemId,
      required String? mediaSourceId,
      required String? playSessionId,
      required String? playlistItemId}) {
    if (this.itemId == itemId &&
        this.mediaSourceId == mediaSourceId &&
        this.playSessionId == playSessionId &&
        this.playlistItemId == playlistItemId) {
      return this;
    }
    return capture.bind(
        itemId: itemId,
        mediaSourceId: mediaSourceId,
        playSessionId: playSessionId,
        playlistItemId: playlistItemId);
  }

  bool _payload(
          String? item, String? source, String? session, String? playlist) =>
      item == itemId &&
      source == mediaSourceId &&
      session == playSessionId &&
      playlist == playlistItemId;

  Future<void> start(PlaybackStartInfo info) {
    if (!_payload(info.itemId, info.mediaSourceId, info.playSessionId,
            info.playlistItemId) ||
        !activate()) {
      return Future<void>.value();
    }
    return capture._enqueue(this, _Kind.start, info);
  }

  Future<void> progress(PlaybackProgressInfo info,
      {bool Function()? isCurrent}) {
    if (!_payload(info.itemId, info.mediaSourceId, info.playSessionId,
        info.playlistItemId)) {
      return Future<void>.value();
    }
    return capture._enqueue(this, _Kind.progress, info, guard: isCurrent);
  }

  Future<void> stop(PlaybackStopInfo info) {
    if (!_payload(info.itemId, info.mediaSourceId, info.playSessionId,
        info.playlistItemId)) {
      return Future<void>.value();
    }
    return capture._enqueue(this, _Kind.stop, info);
  }
}
