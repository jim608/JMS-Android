import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.enums.swagger.dart';
import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/settings/video_player_settings.dart';
import 'package:fladder/profiles/default_profile.dart';
import 'package:fladder/models/playback/offline_playback_model.dart';
import 'package:fladder/models/playback/tv_playback_model.dart';
import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/connectivity_provider.dart' as connectivity;
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/services/syncplay/syncplay_controller.dart';
import 'package:fladder/services/syncplay/syncplay_buffering.dart';
import 'package:fladder/services/syncplay/syncplay_models.dart';
import 'package:fladder/services/syncplay/syncplay_player.dart';
import 'package:fladder/services/syncplay/syncplay_player_commands.dart';
import 'package:fladder/services/syncplay/syncplay_prebuffer.dart';
import 'package:fladder/services/syncplay/syncplay_prebuffer_coordinator.dart';
import 'package:fladder/services/syncplay/syncplay_transport.dart';
import 'package:fladder/services/syncplay/syncplay_recovery.dart';
import 'package:fladder/wrappers/media_control_wrapper.dart';

final syncPlayProvider =
    StateNotifierProvider<SyncPlayNotifier, SyncPlayViewState>((ref) {
  return SyncPlayNotifier(ref);
});

class SyncPlayViewState {
  const SyncPlayViewState({
    this.room = const SyncPlayControllerState(connected: false),
    this.busy = false,
    this.failure,
    this.preparingPlayback = false,
    this.readyHomeJoin,
    this.prebuffer,
    this.recoveryActive = false,
    this.recoveryExhausted = false,
    this.leavePending = false,
  });
  final SyncPlayControllerState room;
  final bool busy;
  final SyncPlayFailure? failure;
  final bool preparingPlayback;
  final int? readyHomeJoin;
  final SyncPlayPrebufferDecision? prebuffer;
  final bool recoveryActive;
  final bool recoveryExhausted;
  final bool leavePending;
}

/// Explicitly opened by the room dialog. No socket, room, or sharing at startup.
/// Every asynchronous operation remains bound to the captured login generation.
class SyncPlayNotifier extends StateNotifier<SyncPlayViewState>
    implements SyncPlayPlayerCommands {
  SyncPlayNotifier(this.ref) : super(const SyncPlayViewState()) {
    _accountSubscription = ref.listen(userProvider, (previous, next) {
      if (!_sameLogin(previous, next)) {
        _permissionOperation++;
        _permissionChecking = false;
        _permissionFailed = false;
      }
      if (!_sameLogin(previous, next) ||
          previous?.policy?.syncPlayAccess != next?.policy?.syncPlayAccess) {
        _detach();
      }
    });
  }

  final Ref ref;
  ProviderSubscription<AccountModel?>? _accountSubscription;
  ProviderSubscription<connectivity.ConnectionState>? _connectivitySubscription;
  AppLifecycleListener? _lifecycle;
  SyncPlayRecovery? _recovery;
  SyncPlayTransport? _transport;
  SyncPlayController? _controller;
  SyncPlayPlayerAdapter? _player;
  StreamSubscription<SyncPlayControllerState>? _stateSubscription;
  StreamSubscription<bool>? _connectionSubscription;
  StreamSubscription? _playerSubscription;
  int _generation = 0;
  int _uiOperation = 0;
  MediaControlsWrapper? _wrapper;
  bool _disposed = false;
  SyncPlayBufferingReporter? _bufferingReporter;
  SyncPlayPrebufferCoordinator? _prebuffer;
  static const _prebufferConfig = SyncPlayPrebufferConfig();
  int _permissionOperation = 0;
  bool _permissionChecking = false;
  bool _permissionFailed = false;
  int _homeSerial = 0;
  int? _homeJoinAttempt;
  int? _readyHomeJoin;
  bool _homeMode = false;
  bool _preparingPlayback = false;
  bool _localLeaveIntent = false;

  SyncPlayViewState _view(
          {SyncPlayControllerState? room,
          bool busy = false,
          SyncPlayFailure? failure}) =>
      SyncPlayViewState(
          room: room ?? state.room,
          busy: busy,
          failure: failure,
          preparingPlayback: _preparingPlayback,
          readyHomeJoin: _readyHomeJoin,
          prebuffer: _prebuffer?.decision,
          recoveryActive: _recovery?.active ?? false,
          recoveryExhausted: _recovery?.exhausted ?? false,
          leavePending: _controller?.leaveRequested ?? false);

  /// Home joining is independent of the currently selected media/backend.
  /// The captured room item is authorized before preparing a built-in player.
  bool get canJoinFromHome {
    final account = ref.read(userProvider);
    return canJoin &&
        account != null &&
        account.credentials.token.isNotEmpty &&
        account.credentials.deviceId.isNotEmpty;
  }

  int? beginHomeJoin(String code) {
    if (_disposed ||
        state.busy ||
        _preparingPlayback ||
        !canJoinFromHome ||
        state.room.status != SyncPlayStatus.idle) {
      return null;
    }
    final ticket = ++_homeSerial;
    _homeJoinAttempt = ticket;
    _readyHomeJoin = null;
    _homeMode = true;
    _preparingPlayback = true;
    unawaited(joinRoom(code));
    return ticket;
  }

  Future<void> cancelHomeJoin(int ticket) async {
    if (_disposed || ticket != _homeJoinAttempt) return;
    _homeJoinAttempt = null;
    _readyHomeJoin = null;
    _preparingPlayback = false;
    await stop();
  }

  int? beginHomeReconnect() {
    if (_disposed ||
        state.busy ||
        !canJoinFromHome ||
        !const {SyncPlayStatus.unknown, SyncPlayStatus.disconnected}
            .contains(state.room.status)) {
      return null;
    }
    final ticket = ++_homeSerial;
    _homeJoinAttempt = ticket;
    _readyHomeJoin = null;
    _homeMode = true;
    _preparingPlayback = true;
    unawaited(reconnect());
    return ticket;
  }

  bool consumeHomeJoin(int ticket) {
    if (_disposed ||
        ticket != _homeJoinAttempt ||
        ticket != _readyHomeJoin ||
        !state.room.isJoined ||
        state.room.failure != null ||
        _player?.playlistItemId != state.room.queue?.current?.playlistItemId ||
        _player?.mediaId != state.room.queue?.current?.mediaId) {
      return false;
    }
    _homeJoinAttempt = null;
    _readyHomeJoin = null;
    state = _view(room: state.room, busy: state.busy, failure: state.failure);
    return true;
  }

  static bool _sameLogin(AccountModel? a, AccountModel? b) =>
      a?.id == b?.id && a?.credentials == b?.credentials;

  bool get permissionChecking => _permissionChecking;
  bool get permissionKnown =>
      !_permissionChecking &&
      !_permissionFailed &&
      ref.read(userProvider)?.policy?.syncPlayAccess != null;

  bool get canJoin =>
      permissionKnown &&
      switch (ref.read(userProvider)?.policy?.syncPlayAccess) {
        SyncPlayUserAccessType.createandjoingroups ||
        SyncPlayUserAccessType.joingroups =>
          true,
        _ => false,
      };
  bool get canCreate =>
      permissionKnown &&
      ref.read(userProvider)?.policy?.syncPlayAccess ==
          SyncPlayUserAccessType.createandjoingroups;

  /// Explicit dialog-open refresh; opening the panel never creates a socket.
  Future<void> refreshPermission() async {
    if (_disposed || _permissionChecking) return;
    final account = ref.read(userProvider);
    if (account == null) return;
    final operation = ++_permissionOperation;
    bool current() =>
        !_disposed &&
        operation == _permissionOperation &&
        _sameLogin(account, ref.read(userProvider));
    _permissionChecking = true;
    _permissionFailed = false;
    void notify() {
      state = _view(room: state.room, busy: state.busy, failure: state.failure);
    }

    notify();
    void Function()? closeApi;
    try {
      final api = createJellyfinApiForAccount(ref, account.credentials.url,
          Map<String, String>.unmodifiable(account.credentials.header(ref)),
          privateLink: true);
      closeApi = () {
        try {
          api.client.httpClient.close();
        } catch (_) {}
        try {
          api.client.dispose();
        } catch (_) {}
      };
      final response =
          await api.usersMeGet().timeout(const Duration(seconds: 10));
      if (!current()) return;
      final user = response.body;
      if (!response.isSuccessful ||
          user?.id != account.id ||
          user?.policy == null) {
        _permissionFailed = true;
        return;
      }
      ref
          .read(userProvider.notifier)
          .updateRuntimePolicyForAccount(account, user!.policy!);
    } catch (_) {
      if (current()) _permissionFailed = true;
    } finally {
      closeApi?.call();
      if (current()) {
        _permissionChecking = false;
        notify();
      }
    }
  }

  bool get supported {
    final model = ref.read(playBackModel);
    final player = ref.read(videoPlayerProvider);
    return model != null &&
        model is! OfflinePlaybackModel &&
        model is! TvPlaybackModel &&
        !model.isAudioPlayback &&
        player.supportsSyncPlay;
  }

  @override
  bool get active =>
      !_disposed &&
      _controller != null &&
      !_localLeaveIntent &&
      !_controller!.leaveRequested &&
      (state.busy ||
          !const {SyncPlayStatus.idle, SyncPlayStatus.disposed}
              .contains(_controller!.state.status));

  Future<bool> _ensureSession() async {
    if (_disposed || !(_homeMode ? canJoinFromHome : supported && canJoin)) {
      return false;
    }
    if (_controller == null ||
        (_controller!.state.status == SyncPlayStatus.idle &&
            !_controller!.leaveRequested)) {
      _localLeaveIntent = false;
    }
    if (_transport != null) return _transport!.connected;
    final account = ref.read(userProvider);
    if (account == null ||
        account.credentials.token.isEmpty ||
        account.credentials.deviceId.isEmpty) {
      return false;
    }
    final generation = ++_generation;
    bool current() =>
        !_disposed &&
        generation == _generation &&
        _sameLogin(account, ref.read(userProvider));
    final headers =
        Map<String, String>.unmodifiable(account.credentials.header(ref));
    final api = createJellyfinApiForAccount(
        ref, account.credentials.url, headers,
        privateLink: true);
    SyncPlayTransport? constructedTransport;
    try {
      final transport = SyncPlayTransport(
        api: api,
        baseUri: Uri.parse(account.credentials.url),
        token: account.credentials.token,
        deviceId: account.credentials.deviceId,
        isCurrent: current,
      );
      constructedTransport = transport;
      _transport = transport;
      final player = SyncPlayPlayerAdapter(
        ref: ref,
        account: account,
        api: api,
        isCurrent: current,
        queue: () => current() ? _controller?.state.queue : null,
        createPlaybackApi: () => createJellyfinApiForAccount(
            ref, account.credentials.url, headers,
            privateLink: true),
        isPlaybackIdentityCurrent: () =>
            !_disposed && _sameLogin(account, ref.read(userProvider)),
        playbackPrepared: () => !_homeMode || _wrapper != null,
        playbackProfile:
            _homeMode ? defaultProfile(PlayerOptions.libMPV) : null,
        prepareForPlayback: _homeMode
            ? () async {
                if (_wrapper != null) return current();
                final ticket = _homeJoinAttempt;
                bool preparingCurrent() =>
                    current() && ticket != null && ticket == _homeJoinAttempt;
                if (!preparingCurrent()) return false;
                final ready = await ref
                    .read(videoPlayerProvider.notifier)
                    .prepareSyncPlayPlayback(isCurrent: preparingCurrent);
                if (!ready || !preparingCurrent()) {
                  return false;
                }
                _bindPlayer(
                    controller: _controller!,
                    player: _player!,
                    current: current);
                return true;
              }
            : null,
        onLoaded: () {
          if (!current() || _homeJoinAttempt == null) return;
          _preparingPlayback = false;
          _readyHomeJoin = _homeJoinAttempt;
          state = _view(room: _controller!.state, busy: state.busy);
        },
      );
      _player = player;
      final controller = SyncPlayController(
        identity: SyncPlayIdentity(
            sourceId: account.credentials.url,
            userId: account.id,
            sessionId: '${account.credentials.deviceId}:$generation'),
        api: transport,
        player: player,
        events: transport.events,
        isPlayerBuffering: () => player.isBuffering,
        mediaReadiness: () => _prebuffer?.ready ?? false,
        bufferedAhead: () => _prebuffer?.ahead,
        targetBufferedAhead: () => _prebuffer?.target,
        slowWaitBudget: _prebufferConfig.maximumWait,
        cancelPendingPlayerActions: player.cancelPendingActions,
      );
      _controller = controller;
      controller.setConnected(false);
      _recovery = SyncPlayRecovery(
        readState: () => controller.state,
        isCurrent: current,
        reconnectTransport: transport.reconnect,
        rejoinKnownGroup: (isRecoveryCurrent) => controller.reconnect(
            automatic: true, isRecoveryCurrent: isRecoveryCurrent),
        revalidate: () async {
          await controller.refreshMembership();
          if (current() && controller.state.isJoined) {
            await controller.synchronizeClock();
          }
        },
        onChanged: () {
          if (current()) {
            state = _view(room: controller.state, busy: state.busy);
          }
        },
      );
      _lifecycle = AppLifecycleListener(onResume: () => _recovery?.wake());
      _connectivitySubscription = ref.listen(
        connectivity.connectivityStatusProvider,
        (previous, next) {
          if (current() &&
              previous == connectivity.ConnectionState.offline &&
              next != connectivity.ConnectionState.offline) {
            _recovery?.wake();
          }
        },
      );
      _stateSubscription = controller.states.listen((room) {
        if (current()) {
          _bufferingReporter?.refreshQueue();
          _prebuffer?.refresh();
          if (_homeJoinAttempt != null &&
              state.room.queue?.current?.playlistItemId !=
                  room.queue?.current?.playlistItemId) {
            _readyHomeJoin = null;
            _preparingPlayback = true;
          }
          if (!room.isJoined &&
              const {
                SyncPlayStatus.idle,
                SyncPlayStatus.unknown,
                SyncPlayStatus.disconnected
              }.contains(room.status)) {
            _readyHomeJoin = null;
            if (state.room.group != null) _preparingPlayback = false;
          }
          if (room.failure != null) _preparingPlayback = false;
          state = _view(room: room, busy: state.busy);
          _recovery?.observe(room);
        }
      });
      _connectionSubscription = transport.connections.listen((connected) {
        if (current()) controller.setConnected(connected);
      });
      if (!_homeMode) {
        _bindPlayer(controller: controller, player: player, current: current);
      }
      await transport.connect();
      if (!current()) return false;
      controller.setConnected(transport.connected);
      return transport.connected;
    } catch (_) {
      if (constructedTransport == null) {
        try {
          api.client.httpClient.close();
        } catch (_) {}
        try {
          api.client.dispose();
        } catch (_) {}
      } else if (!current()) {
        await constructedTransport.close();
      }
      if (current()) {
        _detach();
        state = const SyncPlayViewState(
            failure: SyncPlayFailure(SyncPlayFailureCode.disconnected));
      }
      return false;
    }
  }

  void _bindPlayer(
      {required SyncPlayController controller,
      required SyncPlayPlayerAdapter player,
      required bool Function() current}) {
    if (_wrapper != null) return;
    final wrapper = ref.read(videoPlayerProvider);
    _wrapper = wrapper;
    wrapper.syncPlayCommands = this;
    final bufferingReporter = SyncPlayBufferingReporter(
      isCurrent: current,
      isBuffering: () => player.isBuffering,
      queueKey: () {
        final room = controller.state;
        final entry = room.queue?.current;
        return room.isJoined && room.connected && entry != null
            ? (room.group!.groupId, entry.playlistItemId)
            : null;
      },
      report: (buffering) => unawaited(controller.reportBuffering(buffering)),
    );
    _bufferingReporter = bufferingReporter;
    final prebuffer = SyncPlayPrebufferCoordinator(
      isCurrent: () => current() && identical(_wrapper, wrapper),
      isActive: () {
        final room = controller.state;
        final entry = room.queue?.current;
        return room.isJoined &&
            room.connected &&
            !controller.isLoading &&
            room.failure?.code != SyncPlayFailureCode.player &&
            entry != null &&
            player.mediaId == entry.mediaId &&
            player.playlistItemId == entry.playlistItemId;
      },
      generation: () => (controller.mediaBufferEpoch, wrapper),
      readSample: wrapper.readSyncPlayBufferSample,
      verifiedForwardBudget: wrapper.configureSyncPlayBufferBudget,
      config: _prebufferConfig,
      onDecision: (_) {
        if (current() && identical(_wrapper, wrapper)) {
          unawaited(controller.notifyMediaReadinessChanged());
        }
      },
    );
    _prebuffer = prebuffer;
    prebuffer.refresh();
    _playerSubscription = wrapper.stateStream.listen((snapshot) {
      if (!current() || !controller.state.isJoined) {
        return;
      }
      bufferingReporter.update(snapshot.buffering);
      prebuffer.refresh();
    });
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_disposed || state.busy) return;
    final operationId = ++_uiOperation;
    state = _view(room: state.room, busy: true);
    try {
      await operation();
    } catch (_) {
      if (!_disposed && operationId == _uiOperation) {
        state = _view(
            room: state.room,
            failure: const SyncPlayFailure(SyncPlayFailureCode.server));
      }
    } finally {
      if (!_disposed && operationId == _uiOperation) {
        state = _view(room: state.room, failure: state.failure);
      }
    }
  }

  Future<void> createRoom() => _run(() async {
        if (!canCreate || !supported) return;
        final itemId = ref.read(playBackModel)?.item.id;
        final position =
            ref.read(videoPlayerProvider).lastState?.position ?? Duration.zero;
        if (itemId == null || !await _ensureSession()) return;
        final controller = _controller!;
        final generation = _generation;
        final code = (100000 + Random.secure().nextInt(900000)).toString();
        await controller.createRoom(code);
        if (_disposed ||
            generation != _generation ||
            !controller.state.isJoined) {
          return;
        }
        await controller.synchronizeClock();
        if (_disposed || generation != _generation) return;
        await controller.setQueue([itemId], position: position);
      });

  Future<void> joinRoom(String code) => _run(() async {
        if (!canJoin || !(_homeMode || supported) || !await _ensureSession()) {
          return;
        }
        await _controller!.joinRoom(code);
      });

  Future<void> leaveRoom() => _run(() async {
        _localLeaveIntent = true;
        _recovery?.cancel();
        _player?.cancelPendingActions();
        final controller = _controller;
        await controller?.leaveRoom();
        if (identical(controller, _controller) &&
            controller?.state.status == SyncPlayStatus.idle) {
          _detach();
        }
      });

  Future<void> reconnect() => _run(() async {
        final transport = _transport;
        final controller = _controller;
        if (transport == null || controller == null) return;
        if (controller.leaveRequested) {
          _localLeaveIntent = true;
          _recovery?.cancel();
          if (!transport.connected) await transport.reconnect();
          if (!identical(controller, _controller)) return;
          await controller.leaveRoom();
          if (identical(controller, _controller) &&
              controller.state.status == SyncPlayStatus.idle) {
            _detach();
          }
          return;
        }
        if (!(_homeMode || supported) || !canJoin) return;
        _recovery?.manualRetry();
        await transport.reconnect();
        await controller.reconnect();
      });

  @override
  Future<void> pause() async {
    await _controller?.requestPause(userInitiated: true);
  }

  @override
  Future<void> play() async {
    await _controller?.requestUnpause(userInitiated: true);
  }

  @override
  Future<void> seek(Duration position) async {
    await _controller?.requestSeek(position, userInitiated: true);
  }

  @override
  Future<void> stop() async {
    if (_disposed) return;
    _localLeaveIntent = true;
    _recovery?.cancel();
    // Stop is allowed during New/Join. Revoke in-flight player loads before
    // waiting for a server acknowledgement, so closing cannot reopen playback.
    _player?.cancelPendingActions();
    final controller = _controller;
    if (controller == null) return;
    final operationId = ++_uiOperation;
    state = _view(room: controller.state, busy: true);
    try {
      await controller.leaveRoom();
      if (identical(controller, _controller) &&
          controller.state.status == SyncPlayStatus.idle) {
        _detach();
      }
    } finally {
      if (!_disposed && operationId == _uiOperation) {
        state = _view(room: controller.state);
      }
    }
  }

  void _detach() {
    _localLeaveIntent = false;
    _recovery?.dispose();
    _recovery = null;
    _lifecycle?.dispose();
    _lifecycle = null;
    _connectivitySubscription?.close();
    _connectivitySubscription = null;
    _homeJoinAttempt = null;
    _readyHomeJoin = null;
    _homeMode = false;
    _preparingPlayback = false;
    ++_generation; // Revoke stale callbacks before the first asynchronous cleanup.
    _player?.cancelPendingActions();
    _player = null;
    ++_uiOperation;
    final controller = _controller;
    final transport = _transport;
    _controller = null;
    _transport = null;
    _bufferingReporter?.dispose();
    _bufferingReporter = null;
    _prebuffer?.dispose();
    _prebuffer = null;
    unawaited(_stateSubscription?.cancel());
    unawaited(_connectionSubscription?.cancel());
    unawaited(_playerSubscription?.cancel());
    _stateSubscription = null;
    _connectionSubscription = null;
    _playerSubscription = null;
    final wrapper = _wrapper;
    _wrapper = null;
    if (wrapper != null && identical(wrapper.syncPlayCommands, this)) {
      wrapper.syncPlayCommands = null;
    }
    unawaited(controller?.dispose());
    unawaited(transport?.close());
    if (!_disposed) state = const SyncPlayViewState();
  }

  @override
  void dispose() {
    _disposed = true;
    _accountSubscription?.close();
    _detach();
    super.dispose();
  }
}
