import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/models/account_model.dart';
import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/jellyfin_session_socket_provider.dart';
import 'package:fladder/providers/remote_playback_port_provider.dart';
import 'package:fladder/providers/syncplay_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/services/remote_control/remote_control_controller.dart';
import 'package:fladder/services/remote_control/remote_control_models.dart';
import 'package:fladder/services/remote_control/remote_control_transport.dart';
import 'package:fladder/services/remote_control/remote_receiver.dart';
import 'package:fladder/util/brand.dart';

export 'remote_playback_port_provider.dart' show remotePlaybackPortProvider;

class RemoteControlViewState {
  const RemoteControlViewState({
    this.controller = const RemoteControlState(),
    this.receiverStatus = RemoteReceiverState.disabled,
    this.receivingEnabled = false,
    this.receiverBusy = false,
    this.controllerOpen = false,
    this.failure,
  });
  final RemoteControlState controller;
  final RemoteReceiverState receiverStatus;
  final bool receivingEnabled;
  final bool receiverBusy;
  final bool controllerOpen;
  final RemoteControlFailure? failure;

  RemoteControlViewState copyWith(
          {RemoteControlState? controller,
          RemoteReceiverState? receiverStatus,
          bool? receivingEnabled,
          bool? receiverBusy,
          bool? controllerOpen,
          RemoteControlFailure? failure,
          bool clearFailure = false}) =>
      RemoteControlViewState(
        controller: controller ?? this.controller,
        receiverStatus: receiverStatus ?? this.receiverStatus,
        receivingEnabled: receivingEnabled ?? this.receivingEnabled,
        receiverBusy: receiverBusy ?? this.receiverBusy,
        controllerOpen: controllerOpen ?? this.controllerOpen,
        failure: clearFailure ? null : failure ?? this.failure,
      );
}

final remoteControlProvider =
    StateNotifierProvider<RemoteControlNotifier, RemoteControlViewState>(
        (ref) => RemoteControlNotifier(ref));

typedef RemoteAccountApiFactory = JellyfinOpenApi Function(
    AccountModel account);
final remoteAccountApiFactoryProvider = Provider<RemoteAccountApiFactory>(
    (ref) => (account) => createJellyfinApiForAccount(
        ref,
        account.credentials.url,
        Map<String, String>.unmodifiable(account.credentials.header(ref)),
        privateLink: true));

class _ReceiverApi implements RemoteReceiverApi {
  _ReceiverApi(this.transport, this.ref, this.player, this.isCurrent);
  final RemoteControlTransport transport;
  final Ref ref;
  final RemotePlaybackPort player;
  // Produces a per-payload lease; an off/on cycle must not revive old progress.
  final bool Function() Function() isCurrent;
  @override
  Future<String?> ownSessionId() => transport.ownSessionId();
  @override
  Future<void> capabilities(bool enabled) => transport.capabilities(enabled);
  @override
  Future<void> report(PlaybackProgressInfo progress) {
    final lease = isCurrent();
    bool current() {
      try {
        if (!lease() || player.blockedBySyncPlay) return false;
        final snapshot = player.snapshot;
        return snapshot != null &&
            snapshot.binding.itemId == progress.itemId &&
            snapshot.binding.mediaSourceId == progress.mediaSourceId &&
            snapshot.binding.playbackId == progress.playlistItemId &&
            snapshot.playSessionId == progress.playSessionId;
      } catch (_) {
        return false;
      }
    }

    if (!current()) return Future<void>.value();
    if (player is JmsRemotePlaybackPort) {
      // Use the ordinary player's physical writer. A second progress client
      // could let a delayed pre-seek report overwrite the remote result.
      final scope = ref.read(playBackModel)?.reportingScope;
      if (scope == null || !scope.isCurrent) return Future<void>.value();
      return scope.progress(progress,
          isCurrent: () => current() && scope.isCurrent);
    }
    return transport.report(progress, isCurrent: current);
  }
}

/// No connection, capability advertisement or discovery occurs on construction.
/// All REST and socket identities are immutable snapshots of one login.
class RemoteControlNotifier extends StateNotifier<RemoteControlViewState> {
  RemoteControlNotifier(this.ref) : super(const RemoteControlViewState()) {
    ref.listen(userProvider, (previous, next) {
      if (previous?.id != next?.id ||
          previous?.credentials != next?.credentials ||
          next?.policy?.isDisabled == true ||
          next?.policy?.enableMediaPlayback == false) {
        _generation++;
        _detach();
        if (!_disposed) state = const RemoteControlViewState();
      }
    });
    ref.listen(syncPlayProvider, (_, next) {
      if (_playerPort case JmsRemotePlaybackPort port) {
        if (port.blockedBySyncPlay) port.cancelPendingInput();
      }
    });
  }
  final Ref ref;
  int _generation = 0;
  int _controllerEpoch = 0;
  int _receiverEpoch = 0;
  bool _disposed = false;
  Future<void>? _controllerStarting;
  Future<void>? _receiverStarting;
  RemoteControlController? _controller;
  RemoteControlTransport? _controllerTransport;
  RemoteReceiverController? _receiver;
  RemoteControlTransport? _receiverTransport;
  RemotePlaybackPort? _playerPort;
  StreamSubscription<RemoteControlState>? _controllerSubscription;
  StreamSubscription<RemoteReceiverState>? _receiverSubscription;

  bool _current(AccountModel account, int generation) {
    if (_disposed || generation != _generation) return false;
    final next = ref.read(userProvider);
    return next?.id == account.id &&
        next?.credentials == account.credentials &&
        next?.policy?.isDisabled != true &&
        next?.policy?.enableMediaPlayback != false;
  }

  AccountModel _account() {
    final account = ref.read(userProvider);
    if (account == null || account.id.isEmpty) {
      throw const RemoteControlFailure(RemoteFailureCode.denied);
    }
    return account;
  }

  JellyfinOpenApi _api(AccountModel account) =>
      ref.read(remoteAccountApiFactoryProvider)(account);

  Future<void> _verify(
      JellyfinOpenApi api, AccountModel account, int generation) async {
    final known = account.policy;
    if (known != null) {
      if (known.isDisabled == true || known.enableMediaPlayback != true) {
        throw const RemoteControlFailure(RemoteFailureCode.denied);
      }
    } else {
      final response =
          await api.usersMeGet().timeout(const Duration(seconds: 10));
      if (!response.isSuccessful ||
          response.body?.id != account.id ||
          response.body?.policy?.isDisabled == true ||
          response.body?.policy?.enableMediaPlayback != true) {
        throw const RemoteControlFailure(RemoteFailureCode.denied);
      }
    }
    if (!_current(account, generation)) {
      throw const RemoteControlFailure(RemoteFailureCode.closed);
    }
  }

  RemoteControlTransport _transport(
          JellyfinOpenApi api, AccountModel account, int generation) =>
      RemoteControlTransport(
          api: api,
          userId: account.id,
          deviceId: account.credentials.deviceId,
          serverId: account.credentials.serverId,
          client: Brand.name,
          isCurrent: () => _current(account, generation));

  Future<void> startController() async {
    if (_disposed || _controller != null) return;
    final pending = _controllerStarting;
    if (pending != null) return pending;
    final epoch = ++_controllerEpoch;
    final operation = _startController(epoch);
    _controllerStarting = operation;
    try {
      await operation;
    } finally {
      if (identical(_controllerStarting, operation)) _controllerStarting = null;
    }
  }

  Future<void> _startController(int epoch) async {
    JellyfinOpenApi? api;
    var handedOff = false;
    try {
      final account = _account();
      final generation = _generation;
      state = state.copyWith(controllerOpen: true, clearFailure: true);
      api = _api(account);
      await _verify(api, account, generation);
      if (epoch != _controllerEpoch || !_current(account, generation)) {
        return;
      }
      final transport = _transport(api, account, generation);
      final controller = RemoteControlController(
          api: transport, isCurrent: () => _current(account, generation));
      _controllerTransport = transport;
      _controller = controller;
      handedOff = true;
      _controllerSubscription = controller.states.listen((next) {
        if (identical(_controller, controller) &&
            _current(account, generation)) {
          state = state.copyWith(controller: next);
        }
      });
      await controller.start();
    } catch (error) {
      if (epoch == _controllerEpoch && !_disposed) {
        state = state.copyWith(failure: _safe(error));
      }
    } finally {
      if (!handedOff) _closeApi(api);
    }
  }

  Future<void> stopController() async {
    final epoch = ++_controllerEpoch;
    _controllerStarting = null;
    final controller = _controller;
    final transport = _controllerTransport;
    _controller = null;
    _controllerTransport = null;
    final cancelled = _controllerSubscription?.cancel();
    _controllerSubscription = null;
    await cancelled;
    await controller?.close();
    await transport?.close();
    if (!_disposed && epoch == _controllerEpoch) {
      state = state.copyWith(
          controller: const RemoteControlState(),
          controllerOpen: false,
          clearFailure: true);
    }
  }

  Future<void> refresh() async {
    if (_controller == null) {
      await startController();
    } else {
      await _controller!.refresh();
    }
  }

  Future<void> selectTarget(RemoteTarget? target) async =>
      _controller?.select(target);
  Future<void> dispatch(RemoteAction action) async =>
      _controller?.dispatch(action);

  Uri _socketUri(AccountModel account) {
    final base = Uri.parse(account.credentials.url);
    if (!const {'http', 'https'}.contains(base.scheme) ||
        !base.hasAuthority ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment ||
        account.credentials.token.isEmpty ||
        account.credentials.deviceId.isEmpty) {
      throw const RemoteControlFailure(RemoteFailureCode.protocol);
    }
    final paths = base.pathSegments.toList();
    while (paths.isNotEmpty && paths.last.isEmpty) {
      paths.removeLast();
    }
    return base
        .replace(scheme: base.scheme == 'https' ? 'wss' : 'ws', pathSegments: [
      ...paths,
      'socket'
    ], queryParameters: {
      'ApiKey': account.credentials.token,
      'deviceId': account.credentials.deviceId,
    });
  }

  Future<void> setReceiving(bool value) async {
    final epoch = ++_receiverEpoch;
    if (_disposed) return;
    state = state.copyWith(
        receivingEnabled: value, receiverBusy: true, clearFailure: true);
    if (!value) {
      if (_playerPort case JmsRemotePlaybackPort port) {
        port.cancelPendingInput();
      }
      await _receiver?.disable();
      if (!_disposed && epoch == _receiverEpoch) {
        state = state.copyWith(
            receiverStatus: RemoteReceiverState.disabled,
            receivingEnabled: false,
            receiverBusy: false);
      }
      return;
    }
    try {
      if (_receiver == null) {
        final operation = _receiverStarting ??= _prepareReceiver();
        try {
          await operation;
        } finally {
          if (identical(operation, _receiverStarting)) _receiverStarting = null;
        }
      }
      if (!_disposed && epoch == _receiverEpoch) await _receiver?.enable();
    } catch (error) {
      if (!_disposed && epoch == _receiverEpoch) {
        state = state.copyWith(
            receiverStatus: RemoteReceiverState.error,
            receivingEnabled: false,
            failure: _safe(error));
      }
    } finally {
      if (!_disposed && epoch == _receiverEpoch) {
        state = state.copyWith(receiverBusy: false);
      }
    }
  }

  Future<void> _prepareReceiver() async {
    JellyfinOpenApi? api;
    var handedOff = false;
    try {
      final account = _account();
      final generation = _generation;
      api = _api(account);
      await _verify(api, account, generation);
      if (!state.receivingEnabled || !_current(account, generation)) {
        return;
      }
      final transport = _transport(api, account, generation);
      final player = ref.read(remotePlaybackPortProvider);
      _playerPort = player;
      final receiver = RemoteReceiverController(
          api: _ReceiverApi(transport, ref, player, () {
            final epoch = _receiverEpoch;
            return () =>
                epoch == _receiverEpoch &&
                state.receivingEnabled &&
                _current(account, generation);
          }),
          socketFactory: jellyfinSessionSocketFactoryForAccount(ref, account,
              isCurrent: () => _current(account, generation),
              headers: Map<String, String>.unmodifiable(
                  account.credentials.header(ref))),
          socketUri: _socketUri(account),
          currentUserId: account.id,
          player: player,
          isCurrent: () => _current(account, generation));
      _receiver = receiver;
      _receiverTransport = transport;
      handedOff = true;
      _receiverSubscription = receiver.states.listen((next) {
        if (identical(_receiver, receiver) && _current(account, generation)) {
          state = state.copyWith(
              receiverStatus: next, receivingEnabled: receiver.enabled);
        }
      });
    } finally {
      if (!handedOff) _closeApi(api);
    }
  }

  static void _closeApi(JellyfinOpenApi? api) {
    if (api == null) return;
    try {
      api.client.httpClient.close();
    } catch (_) {}
    try {
      api.client.dispose();
    } catch (_) {}
  }

  static RemoteControlFailure _safe(Object error) =>
      error is RemoteControlFailure
          ? error
          : const RemoteControlFailure(RemoteFailureCode.server);

  void _detach() {
    _controllerEpoch++;
    _receiverEpoch++;
    _controllerStarting = null;
    _receiverStarting = null;
    final controller = _controller;
    final ct = _controllerTransport;
    final receiver = _receiver;
    final rt = _receiverTransport;
    _controller = null;
    _controllerTransport = null;
    _receiver = null;
    _receiverTransport = null;
    final cs = _controllerSubscription?.cancel();
    final rs = _receiverSubscription?.cancel();
    _controllerSubscription = null;
    _receiverSubscription = null;
    if (_playerPort case JmsRemotePlaybackPort port) port.invalidate();
    _playerPort = null;
    unawaited(() async {
      await cs;
      await rs;
      await controller?.close();
      await ct?.close();
      await receiver?.close();
      await rt?.close();
    }()
        .catchError((Object _) {}));
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _detach();
    super.dispose();
  }
}
