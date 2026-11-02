import 'dart:async';
import 'dart:math';

import 'package:chopper/chopper.dart' show Response;
import 'package:fladder/jellyfin/jellyfin_open_api.enums.swagger.dart' as enums;
import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart' as jellyfin;

import 'remote_control_models.dart';
import 'remote_control_protocol.dart';

/// Uses an account-captured API with no retrying/account-following interceptor.
class RemoteControlTransport
    implements
        RemoteControlApi,
        RemoteControlCancellation,
        RemoteControlSendObservation {
  RemoteControlTransport({
    required jellyfin.JellyfinOpenApi api,
    required this.userId,
    required this.deviceId,
    required this.serverId,
    required this.client,
    bool Function()? isCurrent,
    DateTime Function()? now,
    this.requestTimeout = const Duration(seconds: 10),
    this.ownsApi = true,
  })  : _api = api,
        _isCurrent = isCurrent ?? _alwaysCurrent,
        _now = now ?? DateTime.now,
        _controllerId = _nonce();

  final jellyfin.JellyfinOpenApi _api;
  final String userId;
  final String deviceId;
  final String serverId;
  final String client;
  final bool Function() _isCurrent;
  final DateTime Function() _now;
  final Duration requestTimeout;
  final bool ownsApi;
  final String _controllerId;
  int _sequence = 0;
  bool _closed = false;
  bool _sending = false;
  bool _commandOutstanding = false;
  int _sendGeneration = 0;
  @override
  RemoteTarget? get lastAcceptedBaseline => _lastAcceptedBaseline;
  RemoteTarget? _lastAcceptedBaseline;
  late final _LatestMutationLane<bool> _capabilityLane = _LatestMutationLane(
    timeout: requestTimeout,
    checkCurrent: _checkCurrent,
    request: _writeCapabilities,
  );
  late final _LatestMutationLane<_ReportIntent> _reportLane =
      _LatestMutationLane(
    timeout: requestTimeout,
    checkCurrent: _checkCurrent,
    request: _writeReport,
  );

  static bool _alwaysCurrent() => true;
  static String _nonce() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  void _checkCurrent() {
    bool current;
    try {
      current = _isCurrent();
    } catch (_) {
      current = false;
    }
    if (_closed || !current) {
      throw RemoteControlFailure(
        _closed ? RemoteFailureCode.closed : RemoteFailureCode.stale,
      );
    }
    if (userId.isEmpty ||
        deviceId.isEmpty ||
        serverId.isEmpty ||
        client.isEmpty) {
      throw const RemoteControlFailure(RemoteFailureCode.invalidTarget);
    }
  }

  Future<Response<T>> _request<T>(
    Future<Response<T>> Function() request, {
    bool mutation = false,
    bool bounded = true,
  }) async {
    _checkCurrent();
    try {
      final actual = request();
      final response =
          bounded ? await actual.timeout(requestTimeout) : await actual;
      _checkCurrent();
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const RemoteControlFailure(RemoteFailureCode.denied);
      }
      if (const {404, 405, 501}.contains(response.statusCode)) {
        throw const RemoteControlFailure(RemoteFailureCode.unsupported);
      }
      if (!response.isSuccessful) {
        throw RemoteControlFailure(
          mutation && response.statusCode >= 500
              ? RemoteFailureCode.timeoutUnknown
              : RemoteFailureCode.server,
        );
      }
      return response;
    } on RemoteControlFailure {
      rethrow;
    } catch (_) {
      _checkCurrent();
      throw RemoteControlFailure(
        mutation ? RemoteFailureCode.timeoutUnknown : RemoteFailureCode.server,
      );
    }
  }

  bool _freshOwned(jellyfin.SessionInfoDto session) {
    final seen = session.lastActivityDate;
    final current = _now().toUtc();
    return session.id?.isNotEmpty == true &&
        session.userId == userId &&
        (session.serverId == null ||
            session.serverId!.isEmpty ||
            session.serverId == serverId) &&
        session.isActive == true &&
        seen != null &&
        !seen.toUtc().isBefore(current.subtract(const Duration(seconds: 30))) &&
        !seen.toUtc().isAfter(current.add(const Duration(seconds: 5)));
  }

  /// The receiving session, not a controllable target on another device.
  Future<String?> ownSessionId() async {
    final response = await _request(
      () => _api.sessionsGet(deviceId: deviceId, activeWithinSeconds: 30),
    );
    final sessions = response.body;
    if (sessions == null || sessions.length > 10000) {
      throw const RemoteControlFailure(RemoteFailureCode.protocol);
    }
    final matches = sessions
        .where(
          (session) =>
              _freshOwned(session) &&
              session.deviceId == deviceId &&
              session.$Client == client,
        )
        .toList();
    return matches.length == 1 ? matches.single.id : null;
  }

  @override
  Future<List<RemoteTarget>> discover() async {
    final response = await _request(
      () => _api.sessionsGet(
        controllableByUserId: userId,
        activeWithinSeconds: 30,
      ),
    );
    final sessions = response.body;
    if (sessions == null || sessions.length > 10000) {
      throw const RemoteControlFailure(RemoteFailureCode.protocol);
    }
    final result = <RemoteTarget>[];
    final ids = <String>{};
    for (final session in sessions) {
      final commands = session.supportedCommands ??
          session.capabilities?.supportedCommands ??
          const [];
      if (!_freshOwned(session) ||
          session.deviceId?.isNotEmpty != true ||
          session.deviceId == deviceId ||
          session.$Client != client ||
          session.supportsMediaControl != true ||
          session.supportsRemoteControl != true ||
          !commands.contains(enums.GeneralCommandType.playstate) ||
          !commands.contains(enums.GeneralCommandType.setsubtitlestreamindex)) {
        continue;
      }
      // Duplicate IDs are an ambiguous target, never choose one arbitrarily.
      if (!ids.add(session.id!)) {
        throw const RemoteControlFailure(RemoteFailureCode.protocol);
      }
      final item = session.nowPlayingItem;
      final play = session.playState;
      final binding = RemotePlaybackBinding(
        itemId: item?.id ?? '',
        mediaSourceId: play?.mediaSourceId ?? '',
        playbackId: session.playlistItemId ?? '',
      );
      result.add(
        RemoteTarget(
          id: session.id!,
          deviceId: session.deviceId!,
          name: session.deviceName?.isNotEmpty == true
              ? session.deviceName!
              : client,
          userId: userId,
          serverId:
              session.serverId?.isNotEmpty == true ? session.serverId : null,
          binding: binding.isComplete ? binding : null,
          positionTicks: play?.positionTicks,
          durationTicks: item?.runTimeTicks,
          paused: play?.isPaused,
          canSeek: play?.canSeek == true,
          subtitleIndex: play?.subtitleStreamIndex,
          lastPlaybackCheckIn: session.lastPlaybackCheckIn,
        ),
      );
    }
    return List.unmodifiable(result);
  }

  void _validateTarget(RemoteTarget target) {
    _checkCurrent();
    if (target.id.isEmpty ||
        target.deviceId.isEmpty ||
        target.deviceId == deviceId ||
        target.userId != userId ||
        (target.serverId != null && target.serverId != serverId) ||
        target.binding?.isComplete != true) {
      throw const RemoteControlFailure(RemoteFailureCode.invalidTarget);
    }
  }

  Future<RemoteTarget> _revalidate(RemoteTarget target) async {
    _validateTarget(target);
    final candidates = await discover();
    final match = candidates
        .where((candidate) => candidate.samePlayback(target))
        .toList();
    if (match.length != 1) {
      throw const RemoteControlFailure(RemoteFailureCode.stale);
    }
    return match.single;
  }

  @override
  Future<List<RemoteSubtitle>> subtitles(RemoteTarget target) async {
    _validateTarget(target);
    final binding = target.binding!;
    final response = await _request(
      () => _api.usersUserIdItemsGet(
        userId: userId,
        ids: [binding.itemId],
        fields: [enums.ItemFields.mediasources, enums.ItemFields.mediastreams],
        enableUserData: false,
      ),
    );
    final items = response.body?.items;
    if (items == null ||
        items.length != 1 ||
        items.single.id != binding.itemId) {
      throw const RemoteControlFailure(RemoteFailureCode.protocol);
    }
    final sources = items.single.mediaSources
            ?.where((source) => source.id == binding.mediaSourceId)
            .toList() ??
        const <jellyfin.MediaSourceInfo>[];
    if (sources.length != 1) {
      throw const RemoteControlFailure(RemoteFailureCode.stale);
    }
    final streams =
        sources.single.mediaStreams ?? const <jellyfin.MediaStream>[];
    final result = <RemoteSubtitle>[];
    final indices = <int>{};
    for (final stream in streams) {
      if (stream.type != enums.MediaStreamType.subtitle) continue;
      final index = stream.index;
      if (index == null || index < 0 || !indices.add(index)) {
        throw const RemoteControlFailure(RemoteFailureCode.protocol);
      }
      result.add(
        RemoteSubtitle(
          sourceId: binding.mediaSourceId,
          index: index,
          label: stream.displayTitle?.isNotEmpty == true
              ? stream.displayTitle!
              : stream.title?.isNotEmpty == true
                  ? stream.title!
                  : stream.language?.isNotEmpty == true
                      ? stream.language!
                      : 'Subtitle ${index + 1}',
          language: stream.language,
        ),
      );
    }
    return List.unmodifiable(result);
  }

  void _validateAction(RemoteTarget target, RemoteAction action) {
    if (action.type == RemoteActionType.seek) {
      final ticks = action.position!.inMicroseconds * 10;
      if (!target.canSeek ||
          ticks < 0 ||
          ticks > 9007199254740991 ||
          target.durationTicks == null ||
          target.durationTicks! <= 0 ||
          ticks > target.durationTicks!) {
        throw const RemoteControlFailure(RemoteFailureCode.invalidAction);
      }
    }
    if (action.type == RemoteActionType.subtitle &&
        action.subtitleIndex! < -1) {
      throw const RemoteControlFailure(RemoteFailureCode.invalidAction);
    }
  }

  @override
  Future<void> send(RemoteTarget target, RemoteAction action) async {
    if (_commandOutstanding) {
      throw const RemoteControlFailure(RemoteFailureCode.timeoutUnknown);
    }
    if (_sending) {
      throw const RemoteControlFailure(RemoteFailureCode.invalidAction);
    }
    _sending = true;
    _lastAcceptedBaseline = null;
    final generation = _sendGeneration;
    void checkSend() {
      _checkCurrent();
      if (generation != _sendGeneration) {
        throw const RemoteControlFailure(RemoteFailureCode.stale);
      }
    }

    try {
      var fresh = await _revalidate(target);
      checkSend();
      _validateAction(fresh, action);
      if (action.type == RemoteActionType.subtitle &&
          action.subtitleIndex! >= 0) {
        final options = await subtitles(fresh);
        checkSend();
        if (!options.any(
          (option) =>
              option.sourceId == fresh.binding!.mediaSourceId &&
              option.index == action.subtitleIndex,
        )) {
          throw const RemoteControlFailure(RemoteFailureCode.invalidAction);
        }
        fresh = await _revalidate(target);
        checkSend();
        _validateAction(fresh, action);
      }
      checkSend();
      final body = RemoteControlProtocol.encode(
        userId: userId,
        sessionId: fresh.id,
        binding: fresh.binding!,
        action: action,
        controllerId: _controllerId,
        requestId: _nonce(),
        sequence: ++_sequence,
        now: _now().toUtc(),
      );
      await _request(
        () {
          _commandOutstanding = true;
          final request = _api.sessionsSessionIdCommandPost(
              sessionId: fresh.id, body: body);
          // A Future.timeout does not cancel its HTTP request. Do not start a
          // replacement command while that original request is still pending.
          unawaited(request.then<void>((_) {
            _commandOutstanding = false;
          }, onError: (Object _, StackTrace __) {
            _commandOutstanding = false;
          }));
          return request;
        },
        mutation: true,
      );
      checkSend();
      _lastAcceptedBaseline = fresh;
    } finally {
      _sending = false;
    }
  }

  @override
  void invalidatePending() => _sendGeneration++;

  Future<void> capabilities(bool enabled) async {
    _checkCurrent();
    if (!enabled) {
      // A disabled receiver must not later flush an old, unstarted progress
      // payload. The already issued request cannot be cancelled by a timeout.
      _reportLane.cancelQueued();
    }
    await _capabilityLane.submit(enabled);
  }

  Future<void> _writeCapabilities(bool enabled) async {
    await _request(
      () => _api.sessionsCapabilitiesFullPost(
        body: jellyfin.ClientCapabilitiesDto(
          playableMediaTypes: const [enums.MediaType.video],
          supportsMediaControl: enabled,
          supportsPersistentIdentifier: true,
          supportedCommands: enabled
              ? const [
                  enums.GeneralCommandType.playstate,
                  enums.GeneralCommandType.setsubtitlestreamindex,
                ]
              : const [],
        ),
      ),
      mutation: true,
      bounded: false,
    );
  }

  Future<void> report(jellyfin.PlaybackProgressInfo info,
      {bool Function()? isCurrent}) async {
    // The captured authenticated session is the only report destination.
    final own = info.copyWithWrapped(
      sessionId: const jellyfin.Wrapped<String?>.value(null),
    );
    final intent = _ReportIntent(own, isCurrent);
    intent.requireCurrent();
    await _reportLane.submit(intent);
  }

  Future<void> _writeReport(_ReportIntent intent) async {
    intent.requireCurrent();
    await _request(
      () {
        intent.requireCurrent();
        return _api.sessionsPlayingProgressPost(body: intent.progress);
      },
      mutation: true,
      bounded: false,
    );
    intent.requireCurrent();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _capabilityLane.close();
    _reportLane.close();
    if (!ownsApi) return;
    try {
      _api.client.httpClient.close();
    } catch (_) {
      /* Continue disposal. */
    }
    try {
      _api.client.dispose();
    } catch (_) {
      /* No credential-bearing errors. */
    }
  }
}

class _ReportIntent {
  _ReportIntent(this.progress, this.isCurrent);
  final jellyfin.PlaybackProgressInfo progress;
  final bool Function()? isCurrent;

  void requireCurrent() {
    bool current;
    try {
      current = isCurrent?.call() ?? true;
    } catch (_) {
      current = false;
    }
    if (!current) throw const RemoteControlFailure(RemoteFailureCode.stale);
  }
}

class _MutationEntry<T> {
  _MutationEntry(this.value, Duration timeout, void Function() checkCurrent) {
    _deadline = Timer(timeout, () {
      try {
        checkCurrent();
        fail(const RemoteControlFailure(RemoteFailureCode.timeoutUnknown));
      } on RemoteControlFailure catch (error) {
        fail(error);
      } catch (_) {
        fail(const RemoteControlFailure(RemoteFailureCode.stale));
      }
    });
  }

  final T value;
  final _completion = Completer<void>();
  late final Timer _deadline;
  Future<void> get result => _completion.future;

  void succeed() {
    if (_completion.isCompleted) return;
    _deadline.cancel();
    _completion.complete();
  }

  void fail(RemoteControlFailure error) {
    if (_completion.isCompleted) return;
    _deadline.cancel();
    _completion.completeError(error);
  }
}

/// Exactly one physical HTTP request plus one latest desired value.
/// The caller's bounded result never releases the physical request's slot.
class _LatestMutationLane<T> {
  _LatestMutationLane({
    required this.timeout,
    required this.checkCurrent,
    required this.request,
  });

  final Duration timeout;
  final void Function() checkCurrent;
  final Future<void> Function(T) request;
  _MutationEntry<T>? _active;
  _MutationEntry<T>? _queued;
  bool _closed = false;

  Future<void> submit(T value) {
    checkCurrent();
    if (_closed) {
      throw const RemoteControlFailure(RemoteFailureCode.closed);
    }
    final active = _active;
    // Equal payloads are still new observations/intents. In particular a new
    // receiver lease may resolve to a different server session on the same
    // device, and a repeated progress payload still needs a fresh check-in.
    final entry = _MutationEntry(value, timeout, checkCurrent);
    if (active == null) {
      _active = entry;
      unawaited(_run(entry));
    } else {
      cancelQueued();
      _queued = entry;
    }
    return entry.result;
  }

  void cancelQueued() {
    final queued = _queued;
    _queued = null;
    queued?.fail(const RemoteControlFailure(RemoteFailureCode.stale));
  }

  Future<void> _run(_MutationEntry<T> entry) async {
    try {
      checkCurrent();
      await request(entry.value); // Never timeout the actual request.
      entry.succeed();
    } catch (error) {
      entry.fail(error is RemoteControlFailure
          ? error
          : const RemoteControlFailure(RemoteFailureCode.timeoutUnknown));
    } finally {
      _active = null;
      final next = _queued;
      _queued = null;
      if (next != null) {
        try {
          checkCurrent();
          if (_closed) {
            throw const RemoteControlFailure(RemoteFailureCode.closed);
          }
          _active = next;
          unawaited(_run(next));
        } catch (error) {
          next.fail(error is RemoteControlFailure
              ? error
              : const RemoteControlFailure(RemoteFailureCode.stale));
        }
      }
    }
  }

  void close() {
    _closed = true;
    _queued?.fail(const RemoteControlFailure(RemoteFailureCode.closed));
    _queued = null;
    _active?.fail(const RemoteControlFailure(RemoteFailureCode.closed));
  }
}
