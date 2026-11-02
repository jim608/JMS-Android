import 'dart:async';
import 'dart:developer';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:audio_service/audio_service.dart';
import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:smtc_windows/smtc_windows.dart'
    if (dart.library.html) 'package:fladder/stubs/web/smtc_web.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/items/audio_model.dart';
import 'package:fladder/models/items/channel_model.dart';
import 'package:fladder/models/items/item_stream_model.dart';
import 'package:fladder/models/items/media_streams_model.dart';
import 'package:fladder/models/media_playback_model.dart';
import 'package:fladder/models/playback/audio_prefetch_buffer.dart';
import 'package:fladder/models/playback/audio_url_resolver.dart';
import 'package:fladder/models/playback/playback_model.dart';
import 'package:fladder/models/playback/playback_queue_state.dart';
import 'package:fladder/models/settings/video_player_settings.dart';
import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/audio_lyrics_provider.dart';
import 'package:fladder/providers/live_tv_provider.dart';
import 'package:fladder/providers/primary_subtitle_selection_provider.dart';
import 'package:fladder/providers/segment_skip_provider.dart';
import 'package:fladder/providers/settings/client_settings_provider.dart';
import 'package:fladder/providers/settings/subtitle_settings_provider.dart';
import 'package:fladder/providers/settings/video_player_settings_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/providers/window_title_provider.dart';
import 'package:fladder/services/playback_diagnostics.dart';
import 'package:fladder/services/remote_control/remote_control_models.dart';
import 'package:fladder/services/syncplay/syncplay_player_commands.dart';
import 'package:fladder/services/syncplay/syncplay_prebuffer.dart';
import 'package:fladder/util/syncplay_buffer_probe.dart';
import 'package:fladder/src/video_player_helper.g.dart' hide PlaybackState;
import 'package:fladder/util/localization_helper.dart';
import 'package:fladder/util/dual_subtitle.dart';
import 'package:fladder/util/subtitle_offset.dart';
import 'package:fladder/wrappers/players/base_player.dart';
import 'package:fladder/wrappers/players/lib_mdk.dart'
    if (dart.library.html) 'package:fladder/stubs/web/lib_mdk_web.dart';
import 'package:fladder/wrappers/players/lib_mpv.dart';
import 'package:fladder/wrappers/players/native_player.dart';
import 'package:fladder/wrappers/players/player_states.dart';
import 'package:fladder/providers/sleep_timer_provider.dart';
import 'package:fladder/util/jms_test_profile_policy.dart';

part 'audio_queue_handler.dart';

class _ScopedPlayerState {
  const _ScopedPlayerState(this.state, this.isCurrent);
  final PlayerState state;
  final bool Function() isCurrent;
}

class MediaControlsWrapper extends BaseAudioHandler
    implements VideoPlayerControlsCallback {
  MediaControlsWrapper({required this.ref});

  BasePlayer? _player;
  BasePlayer? _initializingDiagnosticPlayer;
  PlaybackAttemptRef? _diagnosticAttempt;

  void attachPlaybackAttempt(PlaybackAttemptRef attempt) {
    _diagnosticAttempt = attempt;
    _player?.diagnosticAttempt = attempt;
    _initializingDiagnosticPlayer?.diagnosticAttempt = attempt;
  }

  PlaybackModel? _resourceOwningPlaybackModel;
  int _setupGeneration = 0;
  int _videoLoadGeneration = 0;
  int _playbackStopEpoch = 0;
  bool _internalPlaybackStop = false;

  int get playbackStopEpoch => _playbackStopEpoch;
  int get rendererGeneration => _setupGeneration;
  String _initializationFailure = '';
  BasePlayer? _previousPlayer;
  final StreamController<_ScopedPlayerState> _stateController =
      StreamController.broadcast();
  StreamSubscription<PlayerState>? _playerStateSubscription;

  bool get hasPlayer => _player != null;
  SubtitleOffsetController? get subtitleOffsets => _player?.subtitleOffsets;
  final _secondaryUnavailable = ValueNotifier(
    const SecondarySubtitleState(
        issue: SecondarySubtitleIssue.unsupportedBackend),
  );
  bool get supportsSecondarySubtitles =>
      _player?.supportsSecondarySubtitles ?? false;
  ValueListenable<SecondarySubtitleState> get secondarySubtitleState =>
      _player?.secondarySubtitles ?? _secondaryUnavailable;
  Future<void> setSecondarySubtitleTrack(
          SubStreamModel? model, PlaybackModel playbackModel) async =>
      _player?.setSecondarySubtitleTrack(model, playbackModel);

  PlayerOptions? get backend => switch (_player) {
        LibMPV _ => PlayerOptions.libMPV,
        LibMDK _ => PlayerOptions.libMDK,
        NativePlayer _ => PlayerOptions.nativePlayer,
        _ => null,
      };

  Stream<PlayerState> get stateStream => _stateController.stream
      .where((event) => event.isCurrent())
      .map((event) => event.state);
  PlayerState? get lastState => _player?.lastState;
  SyncPlayPlayerCommands? _syncPlayCommands;
  int _syncPlayBindingEpoch = 0;
  SyncPlayPlayerCommands? get syncPlayCommands => _syncPlayCommands;
  set syncPlayCommands(SyncPlayPlayerCommands? commands) {
    if (identical(commands, _syncPlayCommands)) return;
    _syncPlayCommands = commands;
    _syncPlayBindingEpoch++;
    final player = _player;
    if (player is LibMPV) player.invalidateSyncPlayBufferObservation();
  }

  bool get syncPlayActive => syncPlayCommands?.active == true;
  bool get supportsSyncPlay =>
      _player is LibMPV || (!kIsWeb && _player is LibMDK);

  Future<int?> configureSyncPlayBufferBudget() async {
    final player = _player;
    if (player is! LibMPV) return null;
    final bytes = await player.configureSyncPlayBufferBudget();
    return player == _player ? bytes : null;
  }

  Future<SyncPlayBufferSample> readSyncPlayBufferSample() async {
    final player = _player;
    if (player is LibMPV) {
      final binding = _syncPlayBindingEpoch;
      final wasActive = syncPlayActive;
      final sample = await player.readSyncPlayBufferSample();
      if (player != _player ||
          binding != _syncPlayBindingEpoch ||
          (wasActive && !syncPlayActive)) {
        return unknownSyncPlayBufferSample();
      }
      if (wasActive && binding == _syncPlayBindingEpoch && syncPlayActive) {
        player.reconcileSyncPlayBufferSample(sample);
      }
      return sample;
    }
    // Unsupported engines expose no measured buffer contract. Copying their
    // current scalar playback state permits only the labelled unknown fallback.
    final state = player?.lastState;
    return state == null
        ? unknownSyncPlayBufferSample()
        : SyncPlayBufferSample(
            position: state.position,
            buffering: state.buffering,
            duration: state.duration,
            observedAt: DateTime.now());
  }

  Widget? subtitleWidget(bool showOverlay, {GlobalKey? controlsKey}) =>
      _player?.subtitles(showOverlay, controlsKey: controlsKey);
  Widget? videoWidget(Key key, BoxFit fit) => _player?.videoWidget(key, fit);
  Object get ambientFrameSource => _player?.ambientFrameSource ?? this;
  Future<ui.Image?> captureAmbientFrame(double maxDimension) async =>
      await _player?.captureAmbientFrame(maxDimension);

  Future<Map<String, String>> playbackDiagnostics() async =>
      await _player?.playbackDiagnostics() ??
      {
        'backend': 'unknown (no player)',
        if (_initializationFailure.isNotEmpty)
          'player initialization': _initializationFailure,
      };

  final Ref ref;

  List<StreamSubscription> subscriptions = [];
  ProviderSubscription? _subtitleSettingsSubscription;
  ProviderSubscription<PlaybackModel?>? _playbackModelSubscription;
  SMTCWindows? smtc;

  bool initializedWrapper = false;
  bool _isStopped = false;
  Future<void>? _pendingStop;
  bool _isNewPlayback = false;
  bool _isAudioQueueMode = false;
  bool _audioQueueTransitioning = false;
  bool _audioQueueCompletionPending = false;
  bool _wakelockEnabled = false;

  AudioPrefetchBuffer? _prefetchBuffer;
  List<ItemBaseModel> _mpvPlaylistItems = [];
  int _mpvPlaylistCurrentIndex = 0;
  StreamSubscription<int>? _playlistIndexSub;
  bool _syncingPlaylist = false;
  bool _syncPlaylistPending = false;
  bool _audioQueueRefillInProgress = false;
  bool _audioQueueSourceDepleted = false;
  int _audioQueueNextStartIndex = 0;

  Future<void> init({PlayerOptions? overridePlayer}) async {
    if (!initializedWrapper) {
      initializedWrapper = true;
      if (!JmsTestProfilePolicy.enabled) {
        if (!kIsWeb && Platform.isAndroid) {
          VideoPlayerControlsCallback.setUp(this);
        }
        await AudioService.init(
          builder: () => this,
          config: const AudioServiceConfig(
            androidNotificationChannelId:
                'nl.jknaapen.fladder.channel.playback',
            androidNotificationChannelName: 'Media playback',
            androidNotificationIcon: 'drawable/ic_notification',
            androidNotificationOngoing: true,
            androidStopForegroundOnPause: true,
            rewindInterval: Duration(seconds: 10),
            fastForwardInterval: Duration(seconds: 15),
            androidNotificationChannelDescription: "Playback",
            androidShowNotificationBadge: true,
          ),
        );
      }
    }

    final player = switch (
        overridePlayer ?? ref.read(videoPlayerSettingsProvider).wantedPlayer) {
      PlayerOptions.libMDK => LibMDK(),
      PlayerOptions.libMPV => LibMPV(),
      PlayerOptions.nativePlayer => NativePlayer(),
    };

    await setup(player);
  }

  Future<void> dispose() async {
    syncPlayCommands = null;
    final ownedPlaybackModel = _resourceOwningPlaybackModel;
    _resourceOwningPlaybackModel = null;
    _setupGeneration++;
    _videoLoadGeneration++;
    final player = _player;
    _player = null;
    try {
      _subtitleSettingsSubscription?.close();
      _subtitleSettingsSubscription = null;
      _playbackModelSubscription?.close();
      _playbackModelSubscription = null;
      await _playerStateSubscription?.cancel();
      _playerStateSubscription = null;
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      subscriptions.clear();
    } finally {
      try {
        await player?.dispose();
      } finally {
        ownedPlaybackModel?.dispose();
      }
    }
  }

  Future<void> setup(BasePlayer newPlayer) async {
    final generation = ++_setupGeneration;
    _videoLoadGeneration++;
    final oldPlayer = _player;
    _player = null;
    _initializationFailure = '';
    _initializingDiagnosticPlayer = newPlayer;
    if (_diagnosticAttempt case final attempt?) {
      newPlayer.diagnosticAttempt = attempt;
    }
    try {
      await _playerStateSubscription?.cancel();
      _playerStateSubscription = null;
      if (oldPlayer != null &&
          oldPlayer != newPlayer &&
          _previousPlayer != oldPlayer) {
        await oldPlayer.dispose();
      }
      await newPlayer.init(ref.read(videoPlayerSettingsProvider));
      if (generation != _setupGeneration) {
        await newPlayer.dispose();
        return;
      }
      _player = newPlayer;
      _initPlayer();
      _subscribePlayerState();
      ref
          .read(mediaPlaybackProvider.notifier)
          .update((state) => state.copyWith(errorPlaying: false));
    } catch (error) {
      if (generation == _setupGeneration) {
        _player = null;
        _initializationFailure = error is TimeoutException
            ? 'renderer initialization timed out'
            : 'player initialization failed';
        _markPlayerFailure();
      }
      try {
        await newPlayer.dispose().timeout(const Duration(seconds: 5));
      } catch (_) {
        if (generation == _setupGeneration) {
          _initializationFailure += '; resource cleanup did not finish';
        }
      }
      rethrow;
    } finally {
      if (identical(_initializingDiagnosticPlayer, newPlayer)) {
        _initializingDiagnosticPlayer = null;
      }
    }
  }

  void _markPlayerFailure() {
    ref.read(mediaPlaybackProvider.notifier).update((state) => state.copyWith(
          errorPlaying: true,
          buffering: false,
          playing: false,
        ));
  }

  void _initPlayer() {
    _subtitleSettingsSubscription?.close();
    _playbackModelSubscription?.close();
    for (var element in subscriptions) {
      element.cancel();
    }
    subscriptions.clear();
    _subscribePlayer();
    _subtitleSettingsSubscription =
        ref.listen(subtitleSettingsProvider, (_, next) {
      _player?.applySubtitleSettings(next);
    });
    _playbackModelSubscription = ref.listen(playBackModel, (_, __) {
      _subscribePlayerState();
    });
  }

  void _subscribePlayerState() {
    _playerStateSubscription?.cancel();
    final player = _player;
    if (player == null) return;

    final generation = _videoLoadGeneration;
    final renderer = _setupGeneration;
    final model = ref.read(playBackModel);
    final scope = model?.reportingScope;
    bool current() {
      try {
        return identical(_player, player) &&
            generation == _videoLoadGeneration &&
            renderer == _setupGeneration &&
            (scope?.isCurrent ?? true) &&
            _samePlaybackOccurrence(model, ref.read(playBackModel));
      } catch (_) {
        return false;
      }
    }

    _playerStateSubscription = player.stateStream.listen((state) {
      if (identical(_player, player) && !_stateController.isClosed) {
        if (current()) _stateController.add(_ScopedPlayerState(state, current));
      }
    });
  }

  Future<void> loadVideo(PlaybackModel model, Duration startPosition, bool play,
      {bool Function()? isCurrent}) async {
    if (!(isCurrent?.call() ?? true)) return;
    final player = _player;
    if (player == null) {
      _markPlayerFailure();
      throw StateError('Video player is not ready');
    }
    final reportingScope = model.reportingScope;
    if (reportingScope != null && !reportingScope.isOwned) return;
    final generation = ++_videoLoadGeneration;
    bool current() =>
        generation == _videoLoadGeneration &&
        (isCurrent?.call() ?? true) &&
        (reportingScope?.isOwned ?? true);
    if (reportingScope != null && !reportingScope.activate()) return;
    _subscribePlayerState();
    ref.read(sleepTimerProvider).bindMedia(model.item.id);
    ref.read(segmentSkipSessionProvider).bindItem(model.item.id);
    if (model.ownsPlaybackResources) _resourceOwningPlaybackModel = model;
    try {
      if (_player is LibMPV) {
        (_player as LibMPV).setMusicPlaybackMode(false);
        (_player as LibMPV).prepareVideoColor(model);
      }
      if (_player is NativePlayer) {
        final context = ref.read(localizationContextProvider);
        await (_player as NativePlayer)
            .sendPlaybackDataToNative(context, model, startPosition);
        if (!current() || !identical(_player, player)) return;
      }
      _isNewPlayback = play;
      _isStopped = false;
      await player.loadVideo(model.media?.url ?? "",
          play && ref.read(sleepTimerProvider).allowsPlayback,
          startPosition: startPosition);
      if (!current() || !identical(_player, player)) {
        // A cancelled open may have accepted play=true before returning. Stop
        // only if no replacement load/renderer has taken ownership meanwhile.
        if (generation == _videoLoadGeneration && identical(_player, player)) {
          _isStopped = true;
          await player.stop();
        }
        return;
      }
      if (model.serverManagedQueue) {
        // Backend rate can survive stop/open. Reset it after loading, bypassing
        // the local speed control that is blocked while a room is active.
        await player.setSpeed(1.0);
        if (!current() || !identical(_player, player)) return;
        ref.read(playbackRateProvider.notifier).state = 1.0;
      }
      _player?.applySubtitleSettings(ref.read(subtitleSettingsProvider));

      final context = ref.read(localizationContextProvider);
      if (context != null) {
        ref
            .read(windowTitleProvider.notifier)
            .setPlayTitle(model.item.windowTitle(context.localized));
      }
    } finally {
      if (current() && identical(_player, player)) _isStopped = false;
    }
  }

  Future<void> updateTVGuide(TVGuideModel guide) async {
    if (_player is NativePlayer) {
      (_player as NativePlayer).sendTVGuideModel(guide);
    }
  }

  Future<void> _restorePreviousPlayer() async {
    if (_previousPlayer == null) return;
    await setup(_previousPlayer!);
    _previousPlayer = null;
  }

  Future<void> openPlayer(BuildContext context) async => _player?.open(context);

  Future<void> _updatePositionWithRetry(
      PlaybackModel model, Duration position, bool isPlaying) async {
    try {
      await model.updatePlaybackPosition(position, isPlaying, ref);
    } catch (error, stackTrace) {
      log('Failed to send playing: $isPlaying state to server. Retrying once. Error: $error\n$stackTrace');
      try {
        await Future.delayed(const Duration(milliseconds: 250));
        await model.updatePlaybackPosition(position, isPlaying, ref);
      } catch (retryError, retryStackTrace) {
        log('Retry failed for playing: $isPlaying state update. Error: $retryError\n$retryStackTrace');
      }
    }
  }

  void _subscribePlayer() {
    if (!JmsTestProfilePolicy.enabled && !kIsWeb && Platform.isWindows) {
      smtc = SMTCWindows(
        config: const SMTCConfig(
          fastForwardEnabled: true,
          nextEnabled: false,
          pauseEnabled: true,
          playEnabled: true,
          rewindEnabled: true,
          prevEnabled: false,
          stopEnabled: true,
        ),
      );

      if (smtc != null) {
        subscriptions.add(
          smtc!.buttonPressStream.listen((event) {
            switch (event) {
              case PressedButton.play:
                play();
                break;
              case PressedButton.pause:
                pause();
                break;
              case PressedButton.fastForward:
                fastForward();
                break;
              case PressedButton.rewind:
                rewind();
                break;
              case PressedButton.stop:
                stop();
                break;
              case PressedButton.previous:
                skipToPrevious();
                break;
              case PressedButton.next:
                skipToNext();
                break;
              case PressedButton.record:
                break;
              case PressedButton.channelUp:
                break;
              case PressedButton.channelDown:
                break;
            }
          }),
        );
      }
    }

    subscriptions.add(stateStream.listen(_updateStateStream));
  }

  Future<void> _updateStateStream(PlayerState value) async {
    if (_isStopped) return;
    if (value.completed && !_isAudioQueueMode) {
      ref.read(segmentSkipSessionProvider).markCompleted();
      ref.read(sleepTimerProvider).completed();
    }

    if (value.completed &&
        _isAudioQueueMode &&
        !_audioQueueTransitioning &&
        !_audioQueueCompletionPending) {
      _audioQueueCompletionPending = true;
      unawaited(_onAudioTrackCompleted()
          .whenComplete(() => _audioQueueCompletionPending = false));
    }

    final keepForegroundAlive = value.playing ||
        value.buffering ||
        _audioQueueTransitioning ||
        _audioQueueCompletionPending;

    playbackState.add(playbackState.value.copyWith(
      bufferedPosition: value.buffer,
      processingState: value.buffering
          ? AudioProcessingState.buffering
          : AudioProcessingState.ready,
      updatePosition: value.position,
      playing: keepForegroundAlive,
    ));

    smtc?.setPosition(value.position);
    smtc?.setPlaybackStatus(
        keepForegroundAlive ? PlaybackStatus.playing : PlaybackStatus.paused);

    return unawaited(_applyWakelock(_shouldKeepScreenOn(keepForegroundAlive)));
  }

  @override
  Future<void> skipToNext() async {
    if (syncPlayActive) return;
    if (_isAudioQueueMode) {
      final wasRepeatOne = await _disableRepeatOneForSkip();
      if (!wasRepeatOne &&
          _player is LibMPV &&
          _isMpvPlaylistInSync() &&
          _mpvPlaylistItems.length > _mpvPlaylistCurrentIndex + 1) {
        final current = _mpvPlaylistItems[_mpvPlaylistCurrentIndex];
        final next = _mpvPlaylistItems[_mpvPlaylistCurrentIndex + 1];
        if (!_shouldCrossfade(current, next, manual: true)) {
          await (_player as LibMPV).playerNext();
          await Future.delayed(const Duration(milliseconds: 125));
          await _player?.play();
          return;
        }
      }
      await _playNextQueueItem(manual: true);
      await _player?.play();
      return;
    }
    return loadNextVideo();
  }

  @override
  Future<void> skipToPrevious() async {
    if (syncPlayActive) return;
    if (_isAudioQueueMode) {
      if (_player?.lastState.position != null &&
          _player!.lastState.position >= const Duration(seconds: 3)) {
        await _player?.seek(Duration.zero);
        await Future.delayed(const Duration(milliseconds: 125));
        await _player?.play();
        return;
      }
      final wasRepeatOne = await _disableRepeatOneForSkip();
      if (!wasRepeatOne &&
          _player is LibMPV &&
          _isMpvPlaylistInSync() &&
          _mpvPlaylistCurrentIndex > 0) {
        final current = _mpvPlaylistItems[_mpvPlaylistCurrentIndex];
        final previous = _mpvPlaylistItems[_mpvPlaylistCurrentIndex - 1];
        if (!_shouldCrossfade(current, previous, manual: true)) {
          await (_player as LibMPV).playerPrevious();
          await Future.delayed(const Duration(milliseconds: 125));
          await _player?.play();
          return;
        }
      }
      await _playPreviousQueueItem();
      return;
    }
    return loadPreviousVideo();
  }

  bool _shouldKeepScreenOn(bool playing) {
    final item = ref.read(playBackModel.select((value) => value?.item));
    return playing && item is! AudioModel;
  }

  /// [force] re-applies even when the cached state already matches, since
  /// Android silently clears the keep-screen-on flag while we still think it's set.
  Future<void> _applyWakelock(bool shouldEnable, {bool force = false}) async {
    if (!force && shouldEnable == _wakelockEnabled) return;
    _wakelockEnabled = shouldEnable;
    if (shouldEnable) {
      await WakelockPlus.enable();
    } else {
      await WakelockPlus.disable();
    }
  }

  Future<void> reassertWakelock() async =>
      _applyWakelock(_shouldKeepScreenOn(_player?.lastState.playing ?? false),
          force: true);

  bool _samePlaybackOccurrence(
          PlaybackModel? expected, PlaybackModel? actual) =>
      identical(expected, actual) ||
      (expected != null &&
          actual != null &&
          expected.runtimeType == actual.runtimeType &&
          expected.item.id == actual.item.id &&
          expected.playbackInfo?.playSessionId ==
              actual.playbackInfo?.playSessionId &&
          expected.mediaStreams?.currentVersionStream?.id ==
              actual.mediaStreams?.currentVersionStream?.id &&
          expected.media?.url == actual.media?.url);

  bool Function() _localPlaybackCurrent(
      PlaybackModel? model, BasePlayer? player) {
    final renderer = _setupGeneration;
    final load = _videoLoadGeneration;
    final stop = _playbackStopEpoch;
    final scope = model?.reportingScope;
    return () {
      try {
        return renderer == _setupGeneration &&
            load == _videoLoadGeneration &&
            stop == _playbackStopEpoch &&
            identical(player, _player) &&
            (scope?.isCurrent ?? true) &&
            _samePlaybackOccurrence(model, ref.read(playBackModel));
      } catch (_) {
        return false;
      }
    };
  }

  (BasePlayer, bool Function()) _remoteOperation(bool Function() ownerCurrent) {
    final player = _player;
    final model = ref.read(playBackModel);
    final renderer = _setupGeneration;
    final load = _videoLoadGeneration;
    final stop = _playbackStopEpoch;
    final room = _syncPlayBindingEpoch;
    bool current() {
      try {
        return ownerCurrent() &&
            !syncPlayActive &&
            !_isStopped &&
            player != null &&
            model != null &&
            renderer == _setupGeneration &&
            load == _videoLoadGeneration &&
            stop == _playbackStopEpoch &&
            room == _syncPlayBindingEpoch &&
            identical(player, _player) &&
            (model.reportingScope?.isCurrent ?? true) &&
            _samePlaybackOccurrence(model, ref.read(playBackModel));
      } catch (_) {
        return false;
      }
    }

    _requireRemoteCurrent(current);
    return (player!, current);
  }

  void _requireRemoteCurrent(bool Function() current) {
    if (!current()) throw const RemoteControlFailure(RemoteFailureCode.stale);
  }

  /// Remote callers revoke the entire operation, including post-backend REST
  /// and UI work. Ordinary local controls keep their existing entry points.
  Future<void> playRemotely({required bool Function() isCurrent}) async {
    final (player, current) = _remoteOperation(isCurrent);
    final sleepTimer = ref.read(sleepTimerProvider);
    sleepTimer.manualPlay();
    sleepTimer.refresh();
    _requireRemoteCurrent(current);
    if (!sleepTimer.allowsPlayback) {
      throw const RemoteControlFailure(RemoteFailureCode.denied);
    }
    await player.play();
    _requireRemoteCurrent(current);
    unawaited(_applyWakelock(!ref.read(playBackModel)!.isAudioPlayback));
    final position = await ref.read(playBackModel)?.startDuration();
    _requireRemoteCurrent(current);
    if (_isNewPlayback || !playbackState.value.playing) {
      _isNewPlayback = false;
      await ref
          .read(playBackModel)
          ?.playbackStarted(position ?? Duration.zero, ref);
      _requireRemoteCurrent(current);
    }
    await _refreshMediaControls(
        model: ref.read(playBackModel), playing: true, isCurrent: current);
    _requireRemoteCurrent(current);
    await super.play();
  }

  Future<void> pauseRemotely({required bool Function() isCurrent}) async {
    final (player, current) = _remoteOperation(isCurrent);
    if (!player.lastState.playing) return;
    await player.pause();
    _requireRemoteCurrent(current);
    final position = player.lastState.position;
    playbackState.add(playbackState.value.copyWith(
        playing: false,
        updatePosition: position,
        controls: [MediaControl.play]));
    unawaited(_applyWakelock(false));
    final model = ref.read(playBackModel)!;
    await model.updatePlaybackPosition(position, false, ref);
    _requireRemoteCurrent(current);
    await _refreshMediaControls(
        model: ref.read(playBackModel), playing: false, isCurrent: current);
    _requireRemoteCurrent(current);
    await super.pause();
  }

  Future<void> seekRemotely(Duration position,
      {required bool Function() isCurrent}) async {
    final (player, current) = _remoteOperation(isCurrent);
    final duration = player.lastState.duration;
    if (position.isNegative ||
        duration <= Duration.zero ||
        position > duration) {
      throw const RemoteControlFailure(RemoteFailureCode.invalidAction);
    }
    ref
        .read(segmentSkipSessionProvider)
        .manualSeek(ref.read(mediaPlaybackProvider).position, position);
    await player.seek(position);
    _requireRemoteCurrent(current);
    if (!player.lastState.playing) {
      ref
          .read(mediaPlaybackProvider.notifier)
          .update((state) => state.copyWith(position: position));
    }
    await super.seek(position);
  }

  @override
  Future<void> pause() async {
    final commands = syncPlayCommands;
    if (commands?.active == true) return commands!.pause();
    return pauseFromSyncPlay();
  }

  /// Apply a server-authoritative pause without sending a local room request.
  Future<void> pauseFromSyncPlay() async {
    if (_isStopped) return;
    final model = ref.read(playBackModel);
    if (model == null || !(_player?.lastState.playing == true)) return;
    final current = _localPlaybackCurrent(model, _player);
    if (!current()) return;
    await _player?.pause();
    if (_isStopped || !current()) return;
    final position = _player?.lastState.position ?? Duration.zero;
    playbackState.add(playbackState.value.copyWith(
      playing: false,
      updatePosition: position,
      controls: [MediaControl.play],
    ));
    unawaited(_applyWakelock(false));
    final playerState = _player;
    if (playerState != null) {
      await _updatePositionWithRetry(model, position, false);
      if (_isStopped || !current()) return;
      await _refreshMediaControls(
          model: model, playing: false, isCurrent: current);
    }
    return super.pause();
  }

  @override
  Future<void> play({bool userInitiated = true}) async {
    final commands = syncPlayCommands;
    if (commands?.active == true) return commands!.play();
    return _playLocally(userInitiated: userInitiated);
  }

  Future<void> playFromSyncPlay() => _playLocally(userInitiated: false);

  Future<void> _playLocally({required bool userInitiated}) async {
    final initialModel = ref.read(playBackModel);
    final reportScope = initialModel?.reportingScope;
    // Audio queue opens bypass loadVideo(); accepting an explicit play is its
    // actual playback commit, not a speculative model/preflight activation.
    if (reportScope != null &&
        !reportScope.isCurrent &&
        !reportScope.activate()) {
      return;
    }
    final current = _localPlaybackCurrent(initialModel, _player);
    if (!current()) return;
    final sleepTimer = ref.read(sleepTimerProvider);
    if (userInitiated) sleepTimer.manualPlay();
    sleepTimer.refresh();
    if (!sleepTimer.allowsPlayback) return;
    final playBackItem = ref.read(playBackModel.select((value) => value?.item));
    if (playBackItem is AudioModel) {
      _isStopped = false;
    }
    unawaited(_applyWakelock(_shouldKeepScreenOn(true)));

    await _player?.play();
    if (_isStopped || !current()) return;

    final currentPosition =
        await ref.read(playBackModel.select((value) => value?.startDuration()));
    if (_isStopped || !current()) return;
    if (_isNewPlayback || !playbackState.value.playing) {
      _isNewPlayback = false;
      await ref
          .read(playBackModel)
          ?.playbackStarted(currentPosition ?? Duration.zero, ref);
      if (_isStopped || !current()) return;
    }
    if (playBackItem == null) return;

    final playbackModel = ref.read(playBackModel);
    if (playbackModel != null) {
      await _refreshMediaControls(
          model: playbackModel, playing: true, isCurrent: current);
    }

    return super.play();
  }

  Future<void> _refreshMediaControls(
      {PlaybackModel? model,
      required bool playing,
      bool Function()? isCurrent}) async {
    if (_isStopped || isCurrent?.call() == false) return;
    if (!ref.read(clientSettingsProvider).enableMediaKeys) return;
    final playbackModel = model ?? ref.read(playBackModel);
    if (playbackModel == null) return;

    final playBackItem = playbackModel.item;
    final poster = playBackItem.images?.primary ??
        (playBackItem is ItemStreamModel
            ? playBackItem.parentImages?.primary
            : null);
    final currentPosition = _player?.lastState.position ??
        await playbackModel.startDuration() ??
        Duration.zero;
    if (_isStopped || isCurrent?.call() == false) return;

    windowSMTCSetup(playBackItem, currentPosition, playing);

    final hasNextVideo =
        ref.read(playBackModel.select((value) => value?.nextVideo != null));
    final hasPreviousVideo =
        ref.read(playBackModel.select((value) => value?.previousVideo != null));

    final queue = playbackModel.queue;
    final currentQueueIndex =
        queue.indexWhere((entry) => entry.id == playbackModel.item.id);
    final hasAudioQueue = queue.length > 1;
    final hasNextAudio = hasAudioQueue &&
        (currentQueueIndex >= 0 ? currentQueueIndex < queue.length - 1 : true);
    final hasPreviousAudio = _isAudioQueueMode ||
        (hasAudioQueue && (currentQueueIndex > 0 || currentQueueIndex == -1));

    final canSkipNext = hasNextVideo || hasNextAudio;
    final canSkipPrevious = hasPreviousVideo || hasPreviousAudio;

    final isMusic = playBackItem is AudioModel;

    final album = playBackItem is AudioModel ? playBackItem.album : null;
    final artist =
        playBackItem is AudioModel ? playBackItem.artistModel?.name : null;

    mediaItem.add(MediaItem(
      id: playBackItem.id,
      album: album,
      artist: artist,
      title: playBackItem.title,
      genre: playBackItem.overview.genres.join(', '),
      rating: Rating.newHeartRating(playBackItem.userData.isFavourite),
      duration: playBackItem.overview.runTime ?? const Duration(seconds: 0),
      artUri: poster != null ? _imageDataToUri(poster.path) : null,
    ));
    playbackState.add(PlaybackState(
      playing: playing,
      updatePosition: currentPosition,
      bufferedPosition:
          _player?.lastState.buffer ?? playbackState.value.bufferedPosition,
      controls: [
        if (playing) MediaControl.pause else MediaControl.play,
        if (canSkipNext) MediaControl.skipToNext,
        if (canSkipPrevious) MediaControl.skipToPrevious,
      ],
      systemActions: {
        if (canSkipNext) MediaAction.skipToNext,
        if (canSkipPrevious) MediaAction.skipToPrevious,
        MediaAction.seek,
        if (!isMusic) MediaAction.fastForward,
        MediaAction.setSpeed,
        if (!isMusic) MediaAction.rewind,
      },
      processingState: (_player?.lastState.buffering ?? false)
          ? AudioProcessingState.buffering
          : AudioProcessingState.ready,
    ));
  }

  Future<void> windowSMTCSetup(ItemBaseModel playBackItem,
      Duration currentPosition, bool playing) async {
    if (JmsTestProfilePolicy.enabled) return;
    final mainContext = ref.read(localizationContextProvider);
    final poster = playBackItem.images?.primary ??
        (playBackItem is ItemStreamModel
            ? playBackItem.parentImages?.primary
            : null);

    //Windows setup
    smtc?.updateMetadata(MusicMetadata(
      title: playBackItem.title,
      artist: mainContext != null
          ? playBackItem.label(mainContext.localized)
          : null,
      thumbnail:
          poster != null ? _imageDataToUri(poster.path).toString() : null,
    ));
    smtc?.updateTimeline(
      PlaybackTimeline(
        startTimeMs: 0,
        endTimeMs: (playBackItem.overview.runTime ?? const Duration(seconds: 0))
            .inMilliseconds,
        positionMs: currentPosition.inMilliseconds,
        minSeekTimeMs: 0,
        maxSeekTimeMs:
            (playBackItem.overview.runTime ?? const Duration(seconds: 0))
                .inMilliseconds,
      ),
    );

    smtc?.enableSmtc();
    smtc?.setPlaybackStatus(
        playing ? PlaybackStatus.playing : PlaybackStatus.paused);
  }

  @override
  Future<void> stop({bool preserveSleepTimer = false}) async {
    if (!_internalPlaybackStop) {
      _playbackStopEpoch++;
      ref.read(segmentSkipSessionProvider).reset();
    }
    final commands = syncPlayCommands;
    if (!preserveSleepTimer && commands?.active == true) await commands!.stop();
    return _stopLocally(preserveSleepTimer: preserveSleepTimer);
  }

  /// This scoped flag covers only the synchronous call into stop(), never the
  /// awaited operation. A concurrent user/room stop still revokes the request.
  Future<void> stopBeforePlayback({bool preserveSleepTimer = true}) {
    final previous = _internalPlaybackStop;
    _internalPlaybackStop = true;
    try {
      return stop(preserveSleepTimer: preserveSleepTimer);
    } finally {
      _internalPlaybackStop = previous;
    }
  }

  Future<void> stopFromSyncPlay() {
    _playbackStopEpoch++;
    ref.read(segmentSkipSessionProvider).reset();
    return _stopLocally(preserveSleepTimer: true);
  }

  Future<void> _stopLocally({required bool preserveSleepTimer}) {
    final pending = _pendingStop;
    if (pending != null) {
      // Coalescing the backend operation must not discard a later caller's
      // request to end the sleep-timer session.
      if (!preserveSleepTimer) ref.read(sleepTimerProvider).endSession();
      return pending;
    }
    late final Future<void> stopping;
    stopping = _performLocalStop(preserveSleepTimer: preserveSleepTimer)
        .whenComplete(() {
      if (identical(_pendingStop, stopping)) _pendingStop = null;
    });
    _pendingStop = stopping;
    return stopping;
  }

  Future<void> _performLocalStop({required bool preserveSleepTimer}) async {
    final stopGeneration = ++_videoLoadGeneration;
    if (!preserveSleepTimer) ref.read(sleepTimerProvider).endSession();
    if (_isStopped) return;
    _isStopped = true;

    if (_player is LibMPV) {
      (_player as LibMPV).setMusicPlaybackMode(false);
    }

    smtc?.setPlaybackStatus(PlaybackStatus.stopped);
    smtc?.clearMetadata();
    smtc?.disableSmtc();
    mediaItem.value = null;
    playbackState.add(
      playbackState.value.copyWith(
        playing: false,
        processingState: AudioProcessingState.completed,
        controls: [],
      ),
    );

    final playbackModel = ref.read(playBackModel);
    if (playbackModel == null) return;
    final reportCapture = playbackModel.reportingScope?.capture;

    ref
        .read(mediaPlaybackProvider.notifier)
        .update((state) => state.copyWith(state: VideoPlayerState.disposed));
    unawaited(_applyWakelock(false));

    final player = _player;
    try {
      await player?.stop();
    } catch (_) {
      // A failed native stop did not finish title/model/session cleanup.
      // Keep it retryable, without changing a replacement player's state.
      if (stopGeneration == _videoLoadGeneration &&
          identical(_player, player)) {
        _isStopped = false;
      }
      rethrow;
    }
    if (stopGeneration == _videoLoadGeneration &&
        identical(_player, player) &&
        identical(ref.read(playBackModel), playbackModel) &&
        (reportCapture?.isCurrent ?? true)) {
      ref.read(windowTitleProvider.notifier).setPlayTitle(null);
    }

    final position = player?.lastState.position;
    final totalDuration = player?.lastState.duration;

    // Small delay so we don't post right after playback/progress update
    await Future.delayed(const Duration(seconds: 1));

    try {
      await playbackModel.playbackStopped(
          position ?? Duration.zero, totalDuration, ref);
    } finally {
      playbackModel.dispose();
    }

    if (!identical(ref.read(playBackModel), playbackModel) ||
        stopGeneration != _videoLoadGeneration ||
        !identical(_player, player) ||
        reportCapture?.isCurrent == false) {
      return;
    }

    ref.read(playBackModel.notifier).update((_) => null);

    ref
        .read(mediaPlaybackProvider.notifier)
        .update((state) => state.copyWith(position: Duration.zero));

    if (_isAudioQueueMode) {
      _isAudioQueueMode = false;
      _playlistIndexSub?.cancel();
      _playlistIndexSub = null;
      _prefetchBuffer?.invalidate();
      _prefetchBuffer = null;
      _mpvPlaylistItems = [];
      _mpvPlaylistCurrentIndex = 0;
      _syncingPlaylist = false;
      _syncPlaylistPending = false;
      await _restorePreviousPlayer();
    }

    return super.stop();
  }

  Future<void> playOrPause() async {
    final commands = syncPlayCommands;
    if (commands?.active == true) {
      return lastState?.playing == true ? commands!.pause() : commands!.play();
    }
    await _player?.playOrPause();
    if (_isStopped) return;
    final playing = _player?.lastState.playing ?? false;

    final position = _player?.lastState.position ?? Duration.zero;
    playbackState.add(playbackState.value.copyWith(
      playing: playing,
      updatePosition: position,
      controls: [playing ? MediaControl.pause : MediaControl.play],
    ));

    unawaited(_applyWakelock(_shouldKeepScreenOn(playing)));

    final playerState = _player;
    if (playerState != null) {
      ref
          .read(mediaPlaybackProvider.notifier)
          .update((state) => state.copyWith(position: position));

      final model = ref.read(playBackModel);
      if (model != null) {
        await _updatePositionWithRetry(
            model, position, playerState.lastState.playing);
        if (_isStopped) return;
        await _refreshMediaControls(model: model, playing: playing);
      }
    }
  }

  Uri _imageDataToUri(String path) {
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return Uri.parse(path);
    }
    return Uri.file(path);
  }

  bool _isMpvPlaylistInSync() {
    final playbackModel = ref.read(playBackModel);
    if (playbackModel == null) return false;
    if (_mpvPlaylistItems.isEmpty) return false;
    if (_mpvPlaylistCurrentIndex < 0 ||
        _mpvPlaylistCurrentIndex >= _mpvPlaylistItems.length) {
      return false;
    }
    return _mpvPlaylistItems[_mpvPlaylistCurrentIndex].id ==
        playbackModel.item.id;
  }

  Future<int> setAudioTrack(
          AudioStreamModel? model, PlaybackModel playbackModel) async =>
      await _player?.setAudioTrack(model, playbackModel) ?? -1;

  Future<int> setSubtitleTrack(
          SubStreamModel? model, PlaybackModel playbackModel) async =>
      await _player?.setSubtitleTrack(model, playbackModel) ?? -1;

  void cancelPendingSubtitleSelection() =>
      _player?.cancelPendingSubtitleSelection();

  Future<void> setVolume(double volume) async {
    //Do not set volume on Android/iOS since we use the system volume for that.
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      _player?.setVolume(100);
      return;
    }
    return _player?.setVolume(volume);
  }

  @override
  Future<void> seek(Duration position) async {
    ref
        .read(segmentSkipSessionProvider)
        .manualSeek(ref.read(mediaPlaybackProvider).position, position);
    return _seekThroughPlaybackRules(position);
  }

  Future<void> seekSegmentAutomatically(Duration position) =>
      _seekThroughPlaybackRules(position);

  Future<void> _seekThroughPlaybackRules(Duration position) async {
    final commands = syncPlayCommands;
    if (commands?.active == true) return commands!.seek(position);
    return seekFromSyncPlay(position);
  }

  /// Await the backend seek, so a scheduled resume cannot overtake it.
  Future<void> seekFromSyncPlay(Duration position) async {
    final current = _localPlaybackCurrent(ref.read(playBackModel), _player);
    if (!current()) return;
    await _player?.seek(position);
    if (!current()) return;
    if (_player?.lastState.playing == false) {
      ref
          .read(mediaPlaybackProvider.notifier)
          .update((state) => state.copyWith(position: position));
    }
    return super.seek(position);
  }

  @override
  Future<void> setSpeed(double speed) async {
    if (syncPlayActive) {
      ref.read(playbackRateProvider.notifier).state = 1.0;
      return;
    }
    await _player?.setSpeed(speed);
    return super.setSpeed(speed);
  }

  //Native player calls
  @override
  Future<void> loadNextVideo() async {
    if (syncPlayActive) return;
    final nextVideo =
        ref.read(playBackModel.select((value) => value?.nextVideo));
    final buffering =
        ref.read(mediaPlaybackProvider.select((value) => value.buffering));
    if (nextVideo != null && !buffering) {
      ref.read(playbackModelHelper).loadNewVideo(nextVideo);
    }
  }

  @override
  Future<void> loadPreviousVideo() async {
    if (syncPlayActive) return;
    final previousVideo =
        ref.read(playBackModel.select((value) => value?.previousVideo));
    final buffering =
        ref.read(mediaPlaybackProvider.select((value) => value.buffering));
    if (previousVideo != null && !buffering) {
      ref.read(playbackModelHelper).loadNewVideo(previousVideo);
    }
  }

  @override
  void onStop() => stop();

  @override
  void swapAudioTrack(int value) async {
    final playbackModel = ref.read(playBackModel);
    final newModel = await playbackModel?.setAudio(
        playbackModel.audioStreams
            ?.firstWhere((element) => element.index == value),
        this);
    ref.read(playBackModel.notifier).update((state) => newModel);
    if (newModel != null) {
      await ref.read(playbackModelHelper).shouldReload(newModel);
    }
  }

  @override
  void swapSubtitleTrack(int value) async {
    if (_stateController.isClosed) return;
    final playbackModel = ref.read(playBackModel);
    if (playbackModel == null) return;
    final track = playbackModel.subStreams
        ?.firstWhereOrNull((element) => element.index == value);
    if (track == null) return;
    final context = ref.read(localizationContextProvider);
    final controller = ref.read(primarySubtitleSelectionProvider.notifier);
    final result = await controller.select(track,
        expectedModel: playbackModel, expectedPlayer: this);
    if (result.failure != null &&
        !_stateController.isClosed &&
        context != null &&
        context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(context.localized.jmsSecondaryUnavailable)));
    }
  }

  @override
  Future<void> loadProgram(GuideChannel selection) async {
    final channelId = selection.channelId;
    final model = await ref.read(liveTvProvider.notifier).fetchDashboard();
    final channel = model.channels.firstWhereOrNull((c) => c.id == channelId);
    if (channel != null) {
      await ref.read(playbackModelHelper).loadTVChannel(channel);
    }
  }

  @override
  Future<List<GuideProgram>> fetchProgramsForChannel(String channelId) async {
    final channel = (await ref
            .read(jellyApiProvider)
            .usersUserIdItemsItemIdGet(itemId: channelId))
        .body as ChannelModel;

    final programs = await ref
        .read(liveTvProvider.notifier)
        .fetchProgramsForChannel(channel);

    final context = ref.read(localizationContextProvider);

    return programs
        .map((p) => GuideProgram(
              id: p.id,
              channelId: channelId,
              name: p.name,
              startMs: p.startDate.millisecondsSinceEpoch,
              endMs: p.endDate.millisecondsSinceEpoch,
              primaryPoster: p.images?.primary?.path,
              overview: p.overview,
              subTitle: context != null ? p.subLabel(context.localized) : null,
            ))
        .toList();
  }

  Future<Uint8List?> takeScreenshot() {
    final player = _player;

    if (player == null) {
      return Future.value(null);
    }

    return player.takeScreenshot();
  }
}
