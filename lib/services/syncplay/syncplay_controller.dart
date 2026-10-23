import 'dart:async';

import 'syncplay_clock.dart';
import 'syncplay_models.dart';

/// A room code is an exact, publicly listable GroupName (`JMS-123456`), not a
/// password or an access grant. Jellyfin authenticates each participant.
///
/// Ports are captured per identity. No network client or player is constructed.
class SyncPlayController {
  SyncPlayController({
    required SyncPlayIdentity identity,
    required SyncPlayApiPort api,
    required SyncPlayPlayerPort player,
    required Stream<Map<String, dynamic>> events,
    SyncPlayClock? clock,
    SyncPlayScheduler? scheduler,
    bool Function()? isPlayerBuffering,
    void Function()? cancelPendingPlayerActions,
    this.operationTimeout = const Duration(seconds: 10),
    this.clockPollInterval = const Duration(seconds: 60),
    this.driftCheckInterval = const Duration(seconds: 3),
    this.driftThreshold = const Duration(milliseconds: 500),
    this.maximumDriftCorrection = const Duration(seconds: 30),
  })  : _identity = identity,
        _api = api,
        _player = player,
        _isPlayerBuffering = isPlayerBuffering,
        _cancelPendingPlayerActions = cancelPendingPlayerActions,
        clock = clock ?? SyncPlayClock(),
        _scheduler = scheduler ?? const SyncPlayTimerScheduler() {
    _listen(events);
  }

  final SyncPlayClock clock;
  final SyncPlayScheduler _scheduler;
  final Duration operationTimeout;
  final Duration clockPollInterval;
  final Duration driftCheckInterval;
  final Duration driftThreshold;
  final Duration maximumDriftCorrection;
  SyncPlayIdentity _identity;
  SyncPlayApiPort _api;
  SyncPlayPlayerPort _player;
  final bool Function()? _isPlayerBuffering;
  final void Function()? _cancelPendingPlayerActions;
  final _states =
      StreamController<SyncPlayControllerState>.broadcast(sync: true);
  StreamSubscription<Map<String, dynamic>>? _subscription;
  SyncPlayStatus _status = SyncPlayStatus.idle;
  SyncPlayGroup? _group;
  SyncPlayQueue? _queue;
  SyncPlayFailure? _failure;
  bool _connected = true;
  bool _disposed = false;
  bool _loading = false;
  bool _needsReady = false;
  bool _buffering = false;
  bool? _lastReportedBuffering;
  bool? _reportingBuffering;
  int? _reportingPlaybackEpoch;
  int? _reportingCommandSerial;
  Future<void>? _bufferReportPump;
  bool _bufferReportWakeup = false;
  int _sourceEpoch = 0;
  int _operation = 0;
  int _playbackEpoch = 0;
  int _remoteDepth = 0;
  int _commandSerial = 0;
  int _participantRefresh = 0;
  String? _expectedGroupId;
  String? _expectedGroupName;
  bool _awaitingConfirmation = false;
  DateTime? _joinedAt;
  DateTime? _lastEmittedAt;
  final Map<String, DateTime> _commandIds = {};
  String? _lastCommandFingerprint;
  Completer<SyncPlayGroup>? _confirmation;
  SyncPlayCommand? _deferredCommand;
  SyncPlayCancellation? _scheduledCommand;
  SyncPlayCancellation? _clockPoll;
  SyncPlayCancellation? _driftTimer;
  SyncPlayCommand? _anchor;
  int? _clockRequestEpoch;
  int _clockSerial = 0;
  final Set<void Function()> _pendingCalls = {};
  Future<SyncPlayFailure?>? _membershipRest;
  Duration? _lastDrift;
  DateTime? _driftObservedAt;
  Duration? _lastCorrection;
  int _correctionCount = 0;

  SyncPlayIdentity get identity => _identity;
  bool get isApplyingRemote => _remoteDepth > 0;
  Stream<SyncPlayControllerState> get states => _states.stream;
  SyncPlayControllerState get state => SyncPlayControllerState(
        status: _status,
        group: _group,
        queue: _queue,
        connected: _connected,
        clockSynchronized: clock.isSynchronized,
        failure: _failure,
        diagnostics: _diagnostics,
      );

  SyncPlayDiagnostics get _diagnostics {
    final joined = !_disposed &&
        _connected &&
        _status == SyncPlayStatus.joined &&
        _group != null;
    final estimate = joined ? clock.estimate : null;
    final observed = _driftObservedAt;
    final age = observed == null ? null : clock.now.difference(observed);
    final driftCurrent = estimate != null &&
        _anchor?.type == SyncPlayCommandType.unpause &&
        !_loading &&
        !_buffering &&
        !_rawBuffering &&
        _playerMatchesQueue() &&
        _player.isPlaying &&
        age != null &&
        !age.isNegative &&
        age <= driftCheckInterval * 2;
    return SyncPlayDiagnostics(
      networkRoundTrip: estimate?.networkRoundTrip,
      clockOffset: estimate?.offset,
      clockSampleAge: estimate?.age,
      playbackDrift: driftCurrent ? _lastDrift : null,
      driftSampleAge: driftCurrent ? age : null,
      lastCorrection: joined ? _lastCorrection : null,
      correctionCount: joined ? _correctionCount : 0,
    );
  }

  void _emit() {
    if (!_states.isClosed) _states.add(state);
  }

  bool _current(int source, [int? operation]) =>
      !_disposed &&
      source == _sourceEpoch &&
      (operation == null || operation == _operation);

  void _listen(Stream<Map<String, dynamic>> events) {
    final source = _sourceEpoch;
    _subscription = events.listen((event) {
      if (_current(source) && _connected) _handleEvent(event);
    }, onError: (Object error, StackTrace stack) {
      if (!_current(source)) return;
      if (error is SyncPlayFailure &&
          error.code == SyncPlayFailureCode.protocol) {
        _failure = error;
        _emit();
      } else {
        setConnected(false);
      }
    }, onDone: () {
      if (_current(source)) setConnected(false);
    });
  }

  Future<T> _bounded<T>(Future<T> task) {
    final result = Completer<T>();
    late SyncPlayCancellation timeout;
    late void Function() cancel;
    void completeError(Object error, [StackTrace? stack]) {
      if (result.isCompleted) return;
      timeout.cancel();
      _pendingCalls.remove(cancel);
      result.completeError(error, stack);
    }

    cancel = () =>
        completeError(const SyncPlayFailure(SyncPlayFailureCode.disconnected));
    timeout = _scheduler.schedule(
        operationTimeout,
        () => completeError(
            const SyncPlayFailure(SyncPlayFailureCode.timeoutUnknown)));
    _pendingCalls.add(cancel);
    task.then((value) {
      if (!result.isCompleted) {
        timeout.cancel();
        _pendingCalls.remove(cancel);
        result.complete(value);
      }
    },
        onError: (Object error, StackTrace stack) =>
            completeError(error, stack));
    return result.future;
  }

  SyncPlayFailure _safeFailure(Object error) => error is SyncPlayFailure
      ? error
      : SyncPlayFailure(error is TimeoutException
          ? SyncPlayFailureCode.timeoutUnknown
          : SyncPlayFailureCode.server);

  Future<T> _membershipRequest<T>(Future<T> Function() request) {
    final result = Completer<T>();
    // Install tracking BEFORE invoking a port: a synchronous WS confirmation
    // can cause the user to stop while New/Join has not returned its response.
    _membershipRest = result.future.then<SyncPlayFailure?>((_) => null,
        onError: (Object error, StackTrace _) => _safeFailure(error));
    Future<T>.sync(request).then(result.complete,
        onError: (Object error, StackTrace stack) =>
            result.completeError(error, stack));
    return result.future;
  }

  bool _canBegin({bool reconnect = false}) {
    if (_disposed) return false;
    if (!_connected) {
      _failure = const SyncPlayFailure(SyncPlayFailureCode.disconnected);
      _emit();
      return false;
    }
    if (!reconnect && _status != SyncPlayStatus.idle) {
      _failure = const SyncPlayFailure(SyncPlayFailureCode.busy);
      _emit();
      return false;
    }
    return true;
  }

  String? _roomName(String code) {
    if (!RegExp(r'^[0-9]{6}$').hasMatch(code)) {
      _failure = const SyncPlayFailure(SyncPlayFailureCode.invalidCode);
      _emit();
      return null;
    }
    return 'JMS-$code';
  }

  int _begin(SyncPlayStatus status, String name, {String? groupId}) {
    _operation++;
    _status = status;
    _failure = null;
    _expectedGroupName = name;
    _expectedGroupId = groupId;
    _awaitingConfirmation = false;
    _confirmation = Completer<SyncPlayGroup>();
    // A WS denial can precede the REST acknowledgement. Attach an error handler
    // now rather than allowing an unhandled asynchronous error while awaiting it.
    unawaited(_confirmation!.future.then<void>((_) {}, onError: (Object _) {}));
    _invalidatePlayback();
    _queue = null;
    _joinedAt = null;
    _emit();
    return _operation;
  }

  Future<void> createRoom(String code) async {
    final name = _roomName(code);
    if (name == null || !_canBegin()) return;
    final source = _sourceEpoch;
    final op = _begin(SyncPlayStatus.creating, name);
    var sent = false;
    try {
      final groups = await _bounded(_api.listGroups());
      if (!_current(source, op)) return;
      if (groups.any((group) => group.groupName == name)) {
        throw const SyncPlayFailure(SyncPlayFailureCode.ambiguousCode);
      }
      _awaitingConfirmation = true;
      sent = true;
      final group =
          await _bounded(_membershipRequest(() => _api.newGroup(name)));
      if (!_current(source, op) || state.isJoined) return;
      if (group.groupName != name) {
        throw const FormatException('Unexpected room');
      }
      _confirmGroup(group);
    } catch (error) {
      if (_current(source, op) && !state.isJoined) {
        _operationFailed(error, sent);
      }
    }
  }

  Future<void> joinRoom(String code) async {
    final name = _roomName(code);
    if (name == null || !_canBegin()) return;
    final source = _sourceEpoch;
    final op = _begin(SyncPlayStatus.joining, name);
    var sent = false;
    try {
      final groups = await _bounded(_api.listGroups());
      if (!_current(source, op)) return;
      final matches = groups.where((group) => group.groupName == name).toList();
      if (matches.isEmpty) {
        throw const SyncPlayFailure(SyncPlayFailureCode.noGroup);
      }
      if (matches.length != 1) {
        throw const SyncPlayFailure(SyncPlayFailureCode.ambiguousCode);
      }
      _expectedGroupId = syncPlayId(matches.single.groupId);
      _awaitingConfirmation = true;
      sent = true;
      await _bounded(
          _membershipRequest(() => _api.joinGroup(_expectedGroupId!)));
      if (!_current(source, op) || state.isJoined) return;
      await _bounded(_confirmation!.future);
    } catch (error) {
      if (_current(source, op) && !state.isJoined) {
        _operationFailed(error, sent);
      }
    }
  }

  void _operationFailed(Object error, bool sent) {
    if (!_awaitingConfirmation &&
        _status == SyncPlayStatus.idle &&
        const {SyncPlayFailureCode.denied, SyncPlayFailureCode.noGroup}
            .contains(_failure?.code)) {
      return; // A conclusive WS denial is stronger than an ambiguous HTTP reply.
    }
    _failure = error is FormatException
        ? const SyncPlayFailure(SyncPlayFailureCode.protocol)
        : _safeFailure(error);
    _status = sent &&
            !const {SyncPlayFailureCode.denied, SyncPlayFailureCode.noGroup}
                .contains(_failure!.code)
        ? SyncPlayStatus.unknown
        : SyncPlayStatus.idle;
    if (_status != SyncPlayStatus.unknown) {
      _awaitingConfirmation = false;
      _group = null;
    }
    _emit();
  }

  void _confirmGroup(SyncPlayGroup group) {
    final id = syncPlayId(group.groupId);
    if (!_awaitingConfirmation ||
        group.groupName != _expectedGroupName ||
        (_expectedGroupId != null && id != _expectedGroupId)) {
      return;
    }
    _expectedGroupId = id;
    _group = group;
    _joinedAt = group.lastUpdatedAt;
    _status = SyncPlayStatus.joined;
    _failure = null;
    _awaitingConfirmation = false;
    if (!(_confirmation?.isCompleted ?? true)) _confirmation!.complete(group);
    _emit();
    unawaited(synchronizeClock());
  }

  Future<void> leaveRoom() async {
    if (_disposed ||
        !_connected ||
        _status == SyncPlayStatus.idle ||
        _status == SyncPlayStatus.leaving) {
      return;
    }
    final source = _sourceEpoch;
    final op = ++_operation;
    final pending = _membershipRest;
    _awaitingConfirmation = false;
    if (!(_confirmation?.isCompleted ?? true)) {
      _confirmation!.completeError(
          const SyncPlayFailure(SyncPlayFailureCode.disconnected));
    }
    for (final cancel in _pendingCalls.toList()) {
      cancel();
    }
    _status = SyncPlayStatus.leaving;
    _invalidatePlayback();
    _clockPoll?.cancel();
    _clockPoll = null;
    _clockRequestEpoch = null;
    _emit();
    try {
      if (pending != null) {
        final outcome = await _bounded(pending);
        if (!_current(source, op)) return;
        if (outcome != null &&
            outcome.code != SyncPlayFailureCode.denied &&
            outcome.code != SyncPlayFailureCode.noGroup) {
          throw const SyncPlayFailure(SyncPlayFailureCode.timeoutUnknown);
        }
      } else if (_group == null) {
        _clearMembership();
        return;
      }
      await _bounded(_api.leaveGroup());
      if (_current(source, op)) _clearMembership();
    } catch (error) {
      if (_current(source, op)) {
        _failure = _safeFailure(error);
        _status = SyncPlayStatus.unknown;
        _emit();
      }
    }
  }

  void _clearMembership() {
    _invalidatePlayback();
    _clockPoll?.cancel();
    _clockPoll = null;
    _clockRequestEpoch = null;
    _group = null;
    _queue = null;
    _joinedAt = null;
    _expectedGroupId = null;
    _expectedGroupName = null;
    _membershipRest = null;
    _awaitingConfirmation = false;
    _status = SyncPlayStatus.idle;
    _failure = null;
    _emit();
  }

  void setConnected(bool connected) {
    if (_disposed || _connected == connected) return;
    _connected = connected;
    _operation++;
    _invalidatePlayback();
    _clockPoll?.cancel();
    _clockPoll = null;
    _clockRequestEpoch = null;
    clock.reset();
    for (final cancel in _pendingCalls.toList()) {
      cancel();
    }
    _status = _group != null || _expectedGroupName != null
        ? SyncPlayStatus.disconnected
        : SyncPlayStatus.idle;
    _failure = connected
        ? null
        : const SyncPlayFailure(SyncPlayFailureCode.disconnected);
    _emit();
  }

  /// Rejoin the last exact group after reconnect; never issues New automatically.
  Future<void> reconnect() async {
    if (!_canBegin(reconnect: true) ||
        (_status != SyncPlayStatus.disconnected &&
            _status != SyncPlayStatus.unknown)) {
      return;
    }
    final id = _group?.groupId ?? _expectedGroupId;
    final name = _group?.groupName ?? _expectedGroupName;
    if (name == null) return;
    final source = _sourceEpoch;
    final pending = _membershipRest;
    final op = _begin(SyncPlayStatus.joining, name, groupId: id);
    try {
      var previousRequestAmbiguous = false;
      if (pending != null) {
        // A list can be empty while the previous New/Join is still being
        // processed. Settle that exact request before treating absence as
        // conclusive, otherwise another New could create a duplicate room.
        final outcome = await _bounded(pending);
        if (!_current(source, op)) return;
        previousRequestAmbiguous = outcome != null &&
            outcome.code != SyncPlayFailureCode.denied &&
            outcome.code != SyncPlayFailureCode.noGroup;
      }
      if (_expectedGroupId == null) {
        final matches = (await _bounded(_api.listGroups()))
            .where((group) => group.groupName == name)
            .toList();
        if (!_current(source, op)) return;
        if (matches.length != 1) {
          throw SyncPlayFailure(matches.isEmpty
              ? previousRequestAmbiguous
                  ? SyncPlayFailureCode.timeoutUnknown
                  : SyncPlayFailureCode.noGroup
              : SyncPlayFailureCode.ambiguousCode);
        }
        _expectedGroupId = syncPlayId(matches.single.groupId);
      }
      _awaitingConfirmation = true;
      await _bounded(
          _membershipRequest(() => _api.joinGroup(_expectedGroupId!)));
      if (_current(source, op) && !state.isJoined) {
        await _bounded(_confirmation!.future);
      }
    } catch (error) {
      if (_current(source, op) && !state.isJoined) {
        _operationFailed(error, true);
      }
    }
  }

  Future<void> switchIdentity({
    required SyncPlayIdentity identity,
    required SyncPlayApiPort api,
    required Stream<Map<String, dynamic>> events,
    SyncPlayPlayerPort? player,
  }) async {
    if (_disposed) return;
    _sourceEpoch++;
    _operation++;
    _invalidatePlayback();
    _clockPoll?.cancel();
    _clockPoll = null;
    _clockRequestEpoch = null;
    for (final cancel in _pendingCalls.toList()) {
      cancel();
    }
    final previous = _subscription;
    _identity = identity;
    _api = api;
    if (player != null) _player = player;
    clock.reset();
    _connected = true;
    _failure = null;
    _membershipRest = null;
    _remoteDepth = 0;
    _clearMembership();
    _listen(events);
    await previous?.cancel();
  }

  Future<void> synchronizeClock() async {
    if (_disposed ||
        !_connected ||
        !state.isJoined ||
        _clockRequestEpoch != null) {
      return;
    }
    final source = _sourceEpoch, op = _operation;
    final flight = ++_clockSerial;
    _clockRequestEpoch = flight;
    final sent = clock.now;
    try {
      final time = await _bounded(_api.getServerTime());
      if (!_current(source, op) || !_connected || !state.isJoined) return;
      if (!clock.recordSample(
          sentAt: sent, receivedAt: clock.now, serverTime: time)) {
        throw const SyncPlayFailure(SyncPlayFailureCode.clock);
      }
      await _bounded(_api.sendRequest(SyncPlayRequest(SyncPlayRequestType.ping,
          {'Ping': (clock.ping.inMicroseconds / 1000).round()})));
      if (!_current(source, op)) return;
      _emit();
      if (_needsReady && !_loading) await reportReady();
      _drainCommand();
    } catch (error) {
      if (_current(source, op)) {
        _failure = _safeFailure(error);
        _emit();
      }
    } finally {
      if (_clockRequestEpoch == flight) _clockRequestEpoch = null;
      if (_current(source, op)) {
        _clockPoll?.cancel();
        if (state.isJoined && _connected) {
          _clockPoll = _scheduler.schedule(clockPollInterval, () {
            _clockPoll = null;
            unawaited(synchronizeClock());
          });
        }
        _drainCommand();
      }
    }
  }

  Future<void> requestPause({bool userInitiated = false}) =>
      _request(SyncPlayRequest(SyncPlayRequestType.pause),
          userInitiated: userInitiated);
  Future<void> requestUnpause({bool userInitiated = false}) =>
      _request(SyncPlayRequest(SyncPlayRequestType.unpause),
          userInitiated: userInitiated);
  Future<void> requestSeek(Duration position,
      {bool userInitiated = false}) async {
    try {
      await _request(
          SyncPlayRequest(SyncPlayRequestType.seek,
              {'PositionTicks': syncPlayTicks(position)}),
          userInitiated: userInitiated);
    } on FormatException {
      _failure = const SyncPlayFailure(SyncPlayFailureCode.protocol);
      _emit();
    }
  }

  Future<void> setQueue(List<String> mediaIds,
      {int startIndex = 0, Duration position = Duration.zero}) async {
    try {
      if (mediaIds.isEmpty || startIndex < 0 || startIndex >= mediaIds.length) {
        throw const FormatException('Invalid queue');
      }
      final ids = mediaIds.map(syncPlayId).toList();
      await _request(
          SyncPlayRequest(SyncPlayRequestType.setNewQueue, {
            'PlayingQueue': ids,
            'PlayingItemPosition': startIndex,
            'StartPositionTicks': syncPlayTicks(position),
          }),
          requireClock: false);
    } on FormatException {
      _failure = const SyncPlayFailure(SyncPlayFailureCode.protocol);
      _emit();
    }
  }

  Future<void> _request(SyncPlayRequest request,
      {bool report = false,
      bool requireClock = true,
      bool userInitiated = false}) async {
    // Backend callbacks must not echo a server command. An explicit user action
    // remains valid while that command's asynchronous player work is pending.
    if (_disposed || (!report && !userInitiated && isApplyingRemote)) return;
    if (!state.isJoined ||
        !_connected ||
        (requireClock && !clock.isSynchronized)) {
      _failure = SyncPlayFailure(!_connected
          ? SyncPlayFailureCode.disconnected
          : SyncPlayFailureCode.clock);
      _emit();
      return;
    }
    final source = _sourceEpoch, op = _operation;
    try {
      await _bounded(_api.sendRequest(request));
    } catch (error) {
      if (_current(source, op)) {
        _failure = _safeFailure(error);
        _emit();
      }
    }
  }

  Future<void> reportBuffering(bool buffering) async {
    try {
      if (_disposed || !state.isJoined) return;
      // A true edge has already passed the player's sustained-wait debounce.
      // The raw probe is authoritative when available; it never creates a
      // Buffer request on its own, and short seek pulses need no group pause.
      _buffering = buffering;
      if (!buffering &&
          (_lastReportedBuffering != false || _reportingBuffering == true)) {
        _needsReady = true;
      }
      await _flushBufferReports();
    } catch (_) {
      if (!_disposed) {
        _failure = const SyncPlayFailure(SyncPlayFailureCode.player);
        _emit();
      }
    }
  }

  Future<void> reportReady() async {
    if (_disposed || !state.isJoined) return;
    // Pure protocol clients without a raw backend probe explicitly declare
    // readiness here. Production clients retain the actual probe's result.
    if (_isPlayerBuffering == null) _buffering = false;
    if (_reportingBuffering != false ||
        _reportingPlaybackEpoch != _playbackEpoch ||
        _reportingCommandSerial != _commandSerial) {
      _needsReady = true;
    }
    await _flushBufferReports();
  }

  bool get _rawBuffering => _isPlayerBuffering?.call() ?? _buffering;

  Future<void> _flushBufferReports() async {
    final active = _bufferReportPump;
    if (active != null) {
      _bufferReportWakeup = true;
      return active;
    }
    if (_disposed || _loading || !state.canControl || !_playerMatchesQueue()) {
      return;
    }
    final completed = Completer<void>();
    _bufferReportPump = completed.future;
    try {
      do {
        _bufferReportWakeup = false;
        if (!_disposed &&
            !_loading &&
            state.canControl &&
            _playerMatchesQueue()) {
          final succeeded = await _sendBufferReports(
              _sourceEpoch, _playbackEpoch, _queue!.current!.playlistItemId);
          if (!succeeded) break;
        }
      } while (_bufferReportWakeup && !_disposed);
    } finally {
      // Release waiters only after retiring the pump. A new item's loader may
      // be waiting here, and its remote-completion callback must start a fresh
      // readiness drain rather than attach to an already completed old send.
      _bufferReportPump = null;
      completed.complete();
    }
  }

  Future<bool> _sendBufferReports(int source, int epoch, String queueId) async {
    final api = _api;
    try {
      while (_current(source) &&
          epoch == _playbackEpoch &&
          !_loading &&
          state.canControl &&
          _playerMatchesQueue() &&
          _queue!.current!.playlistItemId == queueId) {
        final raw = _rawBuffering;
        if (!raw && _buffering) {
          _buffering = false;
          if (_lastReportedBuffering == true) _needsReady = true;
        }
        final buffering = _buffering && raw;
        if (buffering) {
          if (_lastReportedBuffering == true) return true;
        } else {
          if (raw || isApplyingRemote || !_needsReady) return true;
          _needsReady = false;
        }
        _reportingBuffering = buffering;
        _reportingPlaybackEpoch = epoch;
        _reportingCommandSerial = _commandSerial;
        await _bounded(api.sendRequest(SyncPlayRequest(
            buffering
                ? SyncPlayRequestType.buffering
                : SyncPlayRequestType.ready,
            {
              'When': clock.serverNow.toIso8601String(),
              'PositionTicks': syncPlayTicks(_player.position),
              'IsPlaying': _player.isPlaying,
              'PlaylistItemId': queueId,
            })));
        if (!_current(source) || epoch != _playbackEpoch) return true;
        _lastReportedBuffering = buffering;
      }
      return true;
    } catch (error) {
      if (_current(source) && epoch == _playbackEpoch) {
        _failure = _safeFailure(error);
        _emit();
      }
      // A failed or ambiguous POST is not automatically retried.
      return false;
    } finally {
      _reportingBuffering = null;
      _reportingPlaybackEpoch = null;
      _reportingCommandSerial = null;
    }
  }

  void _finishRemote(int source) {
    if (source != _sourceEpoch) return;
    _remoteDepth--;
    if (!isApplyingRemote) unawaited(_flushBufferReports());
  }

  void _cancelPlayerActions() {
    try {
      _cancelPendingPlayerActions?.call();
    } catch (_) {
      // Cleanup cannot replace the safe player failure with callback details.
    }
  }

  bool _playerMatchesQueue() =>
      _queue?.current != null &&
      _player.mediaId == _queue!.current!.mediaId &&
      _player.playlistItemId == _queue!.current!.playlistItemId;

  void _handleEvent(Map<String, dynamic> event) {
    try {
      switch (event['MessageType']) {
        case 'SyncPlayCommand':
          _receiveCommand(SyncPlayCommand.fromJson(syncPlayMap(event['Data'])));
        case 'SyncPlayGroupUpdate':
          final update = syncPlayMap(event['Data']);
          final groupId = syncPlayId(update['GroupId']);
          final type = update['Type'];
          if (type is! String) {
            throw const FormatException('Invalid group update type');
          }
          if (type == 'GroupJoined') {
            final group = SyncPlayGroup.fromJson(syncPlayMap(update['Data']));
            if (groupId != group.groupId) {
              throw const FormatException('Mismatched group');
            }
            _confirmGroup(group);
            return;
          }
          if (groupId != _group?.groupId &&
              groupId != _expectedGroupId &&
              !(_awaitingConfirmation &&
                  _expectedGroupId == null &&
                  const {'CreateGroupDenied', 'SyncPlayIsDisabled'}
                      .contains(type))) {
            return;
          }
          switch (type) {
            case 'PlayQueue':
              if (state.isJoined) {
                _receiveQueue(
                    SyncPlayQueue.fromJson(syncPlayMap(update['Data'])));
              }
            case 'GroupLeft':
              if (syncPlayId(update['Data']) != groupId) {
                throw const FormatException('Mismatched leave');
              }
              _operation++;
              _clearMembership();
            case 'GroupUpdate':
              final group = SyncPlayGroup.fromJson(syncPlayMap(update['Data']));
              if (group.groupId != groupId) {
                throw const FormatException('Mismatched group');
              }
              if (state.isJoined) {
                _participantRefresh++;
                _group = group;
                _emit();
              }
            case 'StateUpdate':
              final data = syncPlayMap(update['Data']);
              if (!const {'Idle', 'Waiting', 'Paused', 'Playing'}
                      .contains(data['State']) ||
                  data['Reason'] is! String) {
                throw const FormatException('Invalid group state');
              }
              final group = _group;
              if (group != null) {
                _group = SyncPlayGroup(
                    groupId: group.groupId,
                    groupName: group.groupName,
                    lastUpdatedAt: group.lastUpdatedAt,
                    state: data['State'] as String,
                    participants: group.participants);
                _emit();
              }
            case 'UserJoined':
            case 'UserLeft':
              if (update['Data'] is! String) {
                throw const FormatException('Invalid participant');
              }
              unawaited(_refreshParticipants());
            case 'NotInGroup':
            case 'GroupDoesNotExist':
            case 'CreateGroupDenied':
            case 'JoinGroupDenied':
            case 'LibraryAccessDenied':
            case 'SyncPlayIsDisabled':
              if (update['Data'] != null && update['Data'] is! String) {
                throw const FormatException('Invalid denial');
              }
              final failure = SyncPlayFailure(type == 'GroupDoesNotExist'
                  ? SyncPlayFailureCode.noGroup
                  : SyncPlayFailureCode.denied);
              if (!(_confirmation?.isCompleted ?? true)) {
                _confirmation!.completeError(failure);
              }
              _failure = failure;
              _status =
                  _group == null ? SyncPlayStatus.idle : SyncPlayStatus.unknown;
              _awaitingConfirmation = false;
              _invalidatePlayback();
              _emit();
            default:
              throw const FormatException('Unknown group update');
          }
      }
    } on FormatException {
      _failure = const SyncPlayFailure(SyncPlayFailureCode.protocol);
      _emit();
    }
  }

  Future<void> _refreshParticipants() async {
    if (!state.isJoined || !_connected) return;
    final source = _sourceEpoch, op = _operation;
    final refresh = ++_participantRefresh;
    final groupId = _group!.groupId;
    try {
      final groups = await _bounded(_api.listGroups());
      if (!_current(source, op) ||
          refresh != _participantRefresh ||
          !state.isJoined ||
          _group?.groupId != groupId) {
        return;
      }
      final matches =
          groups.where((group) => group.groupId == groupId).toList();
      if (matches.length == 1 &&
          matches.single.groupName == _group!.groupName) {
        _group = matches.single;
        _emit();
      }
    } catch (error) {
      if (_current(source, op) && refresh == _participantRefresh) {
        _failure = _safeFailure(error);
        _emit();
      }
    }
  }

  void _receiveQueue(SyncPlayQueue queue) {
    if (_queue != null && !queue.lastUpdate.isAfter(_queue!.lastUpdate)) return;
    final changed =
        _queue?.current?.playlistItemId != queue.current?.playlistItemId;
    _queue = queue;
    _emit();
    if (!changed) return;
    _invalidatePlayback();
    final current = queue.current;
    if (current == null) return;
    final source = _sourceEpoch, epoch = _playbackEpoch;
    _loading = true;
    unawaited(() async {
      try {
        _remoteDepth++;
        await _bounded(_player.applyRemote(SyncPlayPlayerAction(
            type: SyncPlayPlayerActionType.load,
            position: queue.position,
            queueItem: current,
            queue: queue)));
        if (!_current(source) || epoch != _playbackEpoch) return;
        _loading = false;
        _needsReady = true;
        await reportReady();
        _drainCommand();
      } catch (_) {
        if (_current(source) && epoch == _playbackEpoch) {
          _cancelPlayerActions();
          _loading = false;
          _needsReady = false;
          _failure = const SyncPlayFailure(SyncPlayFailureCode.player);
          _emit();
        }
      } finally {
        _finishRemote(source);
      }
    }());
  }

  void _receiveCommand(SyncPlayCommand command) {
    if (!state.isJoined ||
        command.groupId != _group!.groupId ||
        _joinedAt == null ||
        command.emittedAt.isBefore(_joinedAt!) ||
        (_lastEmittedAt != null &&
            command.emittedAt.isBefore(_lastEmittedAt!))) {
      return;
    }
    if (command.type != SyncPlayCommandType.stop &&
        command.playlistItemId != _queue?.current?.playlistItemId) {
      return;
    }
    final previous = _commandIds[command.fingerprint];
    if (previous != null) {
      if (!command.emittedAt.isAfter(previous) ||
          _lastCommandFingerprint != command.fingerprint) {
        return;
      }
      _commandIds[command.fingerprint] = command.emittedAt;
      _lastEmittedAt = command.emittedAt;
      // The server resends the same target when Ready reports an incorrect
      // position. Fresh corrections are not replays of the original packet.
      if (command.when.isAfter(clock.serverNow)) return;
      final aligned =
          (_player.position - command.position).abs() <= driftThreshold;
      if (command.type == SyncPlayCommandType.unpause && _player.isPlaying) {
        return;
      }
      if ((command.type == SyncPlayCommandType.pause ||
              command.type == SyncPlayCommandType.seek) &&
          !_player.isPlaying &&
          aligned) {
        if (command.type == SyncPlayCommandType.seek) {
          // A corrective WS packet can precede the previous Ready HTTP ack.
          // Its acknowledgement is a new generation, not a duplicate edge.
          _commandSerial++;
          unawaited(reportReady());
        }
        return;
      }
    } else {
      _commandIds[command.fingerprint] = command.emittedAt;
      if (_commandIds.length > 64) {
        _commandIds.remove(_commandIds.keys.first);
      }
    }
    _lastCommandFingerprint = command.fingerprint;
    _lastEmittedAt = command.emittedAt;
    _commandSerial++;
    _driftTimer?.cancel();
    _driftTimer = null;
    _anchor = null;
    _lastDrift = null;
    _driftObservedAt = null;
    _scheduledCommand?.cancel();
    _scheduledCommand = null;
    _deferredCommand = command;
    _drainCommand();
    _emit();
  }

  void _drainCommand() {
    final command = _deferredCommand;
    if (command == null || _loading || !state.isJoined || !_connected) return;
    if (!clock.isSynchronized) {
      // A failed time read retains this command until the scheduled poll.
      // Draining or receiving another correction must not bypass that wait
      // and recursively retry the unavailable endpoint without a delay.
      if (_clockPoll == null) unawaited(synchronizeClock());
      return;
    }
    if (command.type != SyncPlayCommandType.stop && !_playerMatchesQueue()) {
      return;
    }
    _deferredCommand = null;
    final source = _sourceEpoch, epoch = _playbackEpoch;
    final serial = _commandSerial;
    final delay = clock.toLocal(command.when).difference(clock.now);
    if (delay > const Duration(minutes: 1)) {
      _failure = const SyncPlayFailure(SyncPlayFailureCode.protocol);
      _emit();
      return;
    }
    _scheduledCommand?.cancel();
    _scheduledCommand =
        _scheduler.schedule(delay.isNegative ? Duration.zero : delay, () {
      _scheduledCommand = null;
      if (_current(source) &&
          epoch == _playbackEpoch &&
          serial == _commandSerial &&
          state.canControl &&
          (command.type == SyncPlayCommandType.stop || _playerMatchesQueue())) {
        unawaited(_applyCommand(command, source, epoch, serial));
      } else if (_current(source) &&
          epoch == _playbackEpoch &&
          _connected &&
          state.isJoined &&
          !clock.isSynchronized) {
        _deferredCommand = command;
        _drainCommand();
      }
    });
  }

  Future<void> _applyCommand(
      SyncPlayCommand command, int source, int epoch, int serial) async {
    var position = command.position;
    if (command.type == SyncPlayCommandType.unpause) {
      final elapsed = clock.serverNow.difference(command.when);
      if (!elapsed.isNegative) position += elapsed;
    }
    try {
      syncPlayTicks(position);
    } on FormatException {
      if (_current(source) &&
          epoch == _playbackEpoch &&
          serial == _commandSerial) {
        _failure = const SyncPlayFailure(SyncPlayFailureCode.protocol);
        _emit();
      }
      return;
    }
    try {
      _remoteDepth++;
      await _bounded(_player.applyRemote(SyncPlayPlayerAction(
          type: switch (command.type) {
            SyncPlayCommandType.pause => SyncPlayPlayerActionType.pause,
            SyncPlayCommandType.unpause => SyncPlayPlayerActionType.unpause,
            SyncPlayCommandType.seek => SyncPlayPlayerActionType.seek,
            SyncPlayCommandType.stop => SyncPlayPlayerActionType.stop,
          },
          position: position,
          queueItem: _queue?.current,
          queue: _queue)));
      if (_current(source) &&
          epoch == _playbackEpoch &&
          serial == _commandSerial &&
          (command.type == SyncPlayCommandType.seek ||
              command.type == SyncPlayCommandType.unpause)) {
        await reportReady();
      }
      if (_current(source) &&
          epoch == _playbackEpoch &&
          serial == _commandSerial &&
          command.type != SyncPlayCommandType.stop) {
        _anchor = command;
        _scheduleDrift();
      }
    } catch (_) {
      if (_current(source) &&
          epoch == _playbackEpoch &&
          serial == _commandSerial) {
        _cancelPlayerActions();
        _needsReady = false;
        _failure = const SyncPlayFailure(SyncPlayFailureCode.player);
        _emit();
      }
    } finally {
      _finishRemote(source);
    }
  }

  void _scheduleDrift() {
    _driftTimer?.cancel();
    _driftTimer = null;
    if (_disposed ||
        !_connected ||
        !state.isJoined ||
        _anchor?.type != SyncPlayCommandType.unpause) {
      return;
    }
    final source = _sourceEpoch,
        epoch = _playbackEpoch,
        serial = _commandSerial;
    _driftTimer = _scheduler.schedule(driftCheckInterval, () {
      _driftTimer = null;
      if (_current(source) &&
          epoch == _playbackEpoch &&
          serial == _commandSerial) {
        unawaited(_correctDrift(source, epoch, serial));
      }
    });
  }

  Future<void> _correctDrift(int source, int epoch, int serial) async {
    final anchor = _anchor;
    if (anchor == null ||
        anchor.type != SyncPlayCommandType.unpause ||
        _loading ||
        _buffering ||
        _rawBuffering ||
        !state.canControl ||
        !_playerMatchesQueue()) {
      if (_lastDrift != null) {
        _lastDrift = null;
        _driftObservedAt = null;
        _emit();
      }
      _scheduleDrift();
      return;
    }
    try {
      final playing = anchor.type == SyncPlayCommandType.unpause;
      if (_player.isPlaying != playing) return;
      var target = anchor.position;
      if (playing) {
        final elapsed = clock.serverNow.difference(anchor.when);
        if (!elapsed.isNegative) target += elapsed;
      }
      final position = _player.position;
      final difference = target - position;
      _lastDrift = difference;
      _driftObservedAt = clock.now;
      if (difference.abs() <= driftThreshold) {
        _emit();
        return;
      }
      // Bound each correction, so a bad sample cannot make one enormous jump.
      if (difference.abs() > maximumDriftCorrection) {
        target = position +
            (difference.isNegative
                ? -maximumDriftCorrection
                : maximumDriftCorrection);
      }
      syncPlayTicks(target);
      _remoteDepth++;
      try {
        await _bounded(_player.applyRemote(SyncPlayPlayerAction(
          type: playing
              ? SyncPlayPlayerActionType.unpause
              : SyncPlayPlayerActionType.seek,
          position: target,
          queueItem: _queue?.current,
          queue: _queue,
        )));
        if (_current(source) &&
            epoch == _playbackEpoch &&
            serial == _commandSerial) {
          _lastCorrection = target - position;
          _correctionCount++;
          _emit();
        }
        if (_current(source) &&
            epoch == _playbackEpoch &&
            serial == _commandSerial &&
            !playing) {
          await reportReady();
        }
      } finally {
        _finishRemote(source);
      }
    } catch (_) {
      if (_current(source) &&
          epoch == _playbackEpoch &&
          serial == _commandSerial) {
        _cancelPlayerActions();
        _needsReady = false;
        _anchor = null;
        _failure = const SyncPlayFailure(SyncPlayFailureCode.player);
        _emit();
      }
    } finally {
      if (_current(source) &&
          epoch == _playbackEpoch &&
          serial == _commandSerial) {
        _scheduleDrift();
      }
    }
  }

  void _invalidatePlayback() {
    _playbackEpoch++;
    _commandSerial++;
    // Controller epochs also revoke work already awaiting the real backend.
    // A disconnect, removed room or replaced queue must not resume an old
    // Unpause when buffering happens to finish after invalidation.
    _cancelPlayerActions();
    _lastDrift = null;
    _driftObservedAt = null;
    _lastCorrection = null;
    _correctionCount = 0;
    _participantRefresh++;
    _scheduledCommand?.cancel();
    _scheduledCommand = null;
    _deferredCommand = null;
    _driftTimer?.cancel();
    _driftTimer = null;
    _anchor = null;
    _loading = false;
    _needsReady = false;
    _buffering = false;
    _lastReportedBuffering = null;
    _lastEmittedAt = null;
    _commandIds.clear();
    _lastCommandFingerprint = null;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _sourceEpoch++;
    _operation++;
    _invalidatePlayback();
    _clockPoll?.cancel();
    _clockPoll = null;
    for (final cancel in _pendingCalls.toList()) {
      cancel();
    }
    _status = SyncPlayStatus.disposed;
    _emit();
    await _subscription?.cancel();
    await _states.close();
  }
}
