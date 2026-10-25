import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/media_playback_model.dart';
import 'package:fladder/models/playback/playback_model.dart';
import 'package:fladder/models/playback/playback_queue_state.dart';
import 'package:fladder/models/settings/video_player_settings.dart';
import 'package:fladder/providers/settings/client_settings_provider.dart';
import 'package:fladder/providers/settings/video_player_settings_provider.dart';
import 'package:fladder/services/playback_diagnostics.dart';
import 'package:fladder/wrappers/media_control_wrapper.dart';

final mediaPlaybackProvider =
    StateProvider<MediaPlaybackModel>((ref) => MediaPlaybackModel());

final playBackModel = StateProvider<PlaybackModel?>((ref) => null);

final videoPlayerProvider =
    StateNotifierProvider<VideoPlayerNotifier, MediaControlsWrapper>((ref) {
  final videoPlayer = VideoPlayerNotifier(ref);
  videoPlayer.init();
  return videoPlayer;
});

class VideoPlayerNotifier extends StateNotifier<MediaControlsWrapper> {
  VideoPlayerNotifier(this.ref) : super(MediaControlsWrapper(ref: ref));

  final Ref ref;

  List<StreamSubscription> subscriptions = [];
  Future<void> _initialization = Future<void>.value();
  bool _usingSyncPlayPlayer = false;
  String? _initializationErrorClass;
  bool _initializationTimedOut = false;

  void _rememberInitializationError(Object error) {
    _initializationErrorClass = error.runtimeType.toString();
    _initializationTimedOut = error is TimeoutException;
  }

  late final mediaState = ref.read(mediaPlaybackProvider.notifier);

  MediaPlaybackModel get playbackState => ref.read(mediaPlaybackProvider);

  Future<bool> waitUntilReady() async {
    await _initialization;
    return mounted && state.hasPlayer;
  }

  /// A room may supply the first video, even when normal playback uses Native.
  /// Keep the user's saved preference intact and serialize renderer changes.
  Future<bool> prepareSyncPlayPlayback({required bool Function() isCurrent}) {
    final task = _initialization.then((_) async {
      bool current() => mounted && isCurrent();
      if (!current()) return false;
      if (state.supportsSyncPlay) return true;
      _usingSyncPlayPlayer = true;
      try {
        await _initialize(
            overridePlayer: PlayerOptions.libMPV, isCurrent: current);
        return current() && state.supportsSyncPlay;
      } catch (error) {
        _rememberInitializationError(error);
        return false;
      }
    });
    _initialization =
        task.then<void>((_) {}, onError: (Object error, StackTrace stack) {});
    return task;
  }

  Future<bool> _restoreConfiguredPlayer({bool Function()? isCurrent}) {
    final task = _initialization.then((_) async {
      bool current() => mounted && (isCurrent?.call() ?? true);
      if (!current()) return false;
      if (!_usingSyncPlayPlayer) return true;
      try {
        final configuredPlayer =
            ref.read(videoPlayerSettingsProvider).wantedPlayer;
        if (state.backend != configuredPlayer) {
          await _initialize(isCurrent: current);
        }
        if (!current()) return false;
        _usingSyncPlayPlayer = false;
        return state.hasPlayer;
      } catch (error) {
        _rememberInitializationError(error);
        return false;
      }
    });
    _initialization =
        task.then<void>((_) {}, onError: (Object error, StackTrace stack) {});
    return task;
  }

  ProviderSubscription<VideoPlayerSettingsModel>? settingsChanged;
  @override
  void dispose() {
    settingsChanged?.close();
    for (final subscription in subscriptions) {
      unawaited(subscription.cancel());
    }
    subscriptions.clear();
    final player = state;
    unawaited(_initialization.then((_) => player.dispose()));
    super.dispose();
  }

  Future<void> init() {
    final task = _initialization.then((_) async {
      await _initialize();
      _initializationErrorClass = null;
      _initializationTimedOut = false;
      if (mounted) _usingSyncPlayPlayer = false;
    });
    _initialization =
        task.then<void>((_) {}, onError: (Object error, StackTrace stack) {
      _rememberInitializationError(error);
    });
    return task;
  }

  Future<void> _initialize(
      {PlayerOptions? overridePlayer, bool Function()? isCurrent}) async {
    bool current() => mounted && (isCurrent?.call() ?? true);
    if (!current()) return;
    _initializationErrorClass = null;
    _initializationTimedOut = false;
    final player = state;
    settingsChanged?.close();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    subscriptions.clear();
    if (!current()) return;
    await player.stop();
    if (!current()) return;
    await player.dispose();
    if (!current()) return;
    await player.init(overridePlayer: overridePlayer);
    // A cancelled request may finish a renderer already being initialized.
    // Keep its local state subscriptions usable for the next explicit request.
    if (!mounted) return;

    settingsChanged = ref.listen(
      videoPlayerSettingsProvider,
      (previous, next) {
        final currentItem = ref.read(playBackModel)?.item;
        if (currentItem != null) {
          state.applyReplayGain(
            currentItem,
            settings: next,
          );
        }
      },
    );

    final subscription = state.stateStream.listen((value) {
      updateBuffering(value.buffering);
      updateBuffer(value.buffer);
      updatePlaying(value.playing);
      updatePosition(value.position);
      updateDuration(value.duration);
    });

    subscriptions.add(subscription);
  }

  Future<void> updateBuffering(bool event) async => mediaState.update((state) =>
      state.buffering == event ? state : state.copyWith(buffering: event));

  Future<void> updateBuffer(Duration buffer) async {
    mediaState.update(
      (state) => (state.buffer - buffer).inSeconds.abs() < 1
          ? state
          : state.copyWith(
              buffer: buffer,
            ),
    );
  }

  Future<void> updateDuration(Duration duration) async {
    mediaState.update((state) {
      return (state.duration - duration).inSeconds.abs() < 1
          ? state
          : state.copyWith(
              duration: duration,
            );
    });
  }

  Future<void> updatePlaying(bool event) async {
    final currentState = playbackState;
    if (!state.hasPlayer || currentState.playing == event) return;
    if (currentState.state == VideoPlayerState.disposed) return;
    mediaState.update(
      (state) => state.copyWith(playing: event),
    );
    ref
        .read(playBackModel)
        ?.updatePlaybackPosition(currentState.position, event, ref);
  }

  Future<void> updatePosition(Duration event) async {
    if (!state.hasPlayer) return;
    if (playbackState.playing == false) return;
    final currentState = playbackState;
    if (currentState.state == VideoPlayerState.disposed) return;
    final currentPosition = currentState.position;

    if ((currentPosition - event).inSeconds.abs() < 1) return;

    final position = event;

    final lastPosition = currentState.lastPosition;
    final diff = (position.inMilliseconds - lastPosition.inMilliseconds).abs();

    if (diff > const Duration(seconds: 10).inMilliseconds) {
      mediaState.update((value) => value.copyWith(
            position: event,
            lastPosition: position,
          ));
      ref
          .read(playBackModel)
          ?.updatePlaybackPosition(position, playbackState.playing, ref);
    } else {
      mediaState.update((value) => value.copyWith(
            position: event,
          ));
    }
  }

  Future<bool> loadPlaybackItem(PlaybackModel model, Duration startPosition,
      {bool playWhenReady = true,
      bool Function()? isCurrent,
      PlaybackAttemptRef? diagnosticAttempt}) async {
    final diagnostics = PlaybackDiagnostics.instance;
    final attempt = diagnosticAttempt ?? diagnostics.startAttempt();
    state.attachPlaybackAttempt(attempt);
    diagnostics.record(attempt, PlaybackStage.syncPlay,
        detail: 'active=${state.syncPlayActive}');
    bool current() => mounted && (isCurrent?.call() ?? true);
    bool stillCurrent() {
      if (current()) return true;
      diagnostics.record(attempt, PlaybackStage.lifecycle,
          cancelled: true, detail: 'request_invalidated');
      return false;
    }

    var stage = PlaybackStage.playerInit;
    var step = 'wait_for_renderer';
    diagnostics.record(attempt, stage,
        event: PlaybackEvent.started, detail: step);
    try {
      await _initialization;
      if (!stillCurrent()) return false;
      if (_usingSyncPlayPlayer && !model.serverManagedQueue) {
        step = 'restore_renderer';
        final restored = await _restoreConfiguredPlayer(isCurrent: current);
        if (!stillCurrent()) return false;
        if (!restored) {
          diagnostics.record(attempt, stage,
              event: PlaybackEvent.failed,
              errorClass: _initializationErrorClass,
              timedOut: _initializationTimedOut,
              detail: step);
          return false;
        }
        if (!stillCurrent()) return false;
      }
      if (!state.hasPlayer) {
        diagnostics.record(attempt, stage,
            event: PlaybackEvent.failed,
            errorClass: _initializationErrorClass,
            timedOut: _initializationTimedOut,
            detail: 'renderer_unavailable');
        mediaState.update((value) => value.copyWith(
            errorPlaying: true, buffering: false, playing: false));
        return false;
      }
      diagnostics.record(attempt, stage,
          event: PlaybackEvent.succeeded, detail: 'renderer_ready');
      stage = PlaybackStage.lifecycle;
      step = 'stop_previous';
      final previousModel = ref.read(playBackModel);
      await state.stop(preserveSleepTimer: true);
      previousModel?.dispose();
      if (!stillCurrent()) return false;
      ref.read(playbackRateProvider.notifier).state = 1.0;

      final useMinimizedPlayer = model.item.type == FladderItemType.audio ||
          model.mediaStreams?.videoStreams.isEmpty == true;

      mediaState.update((state) => state.copyWith(
            state: useMinimizedPlayer
                ? VideoPlayerState.minimized
                : VideoPlayerState.fullScreen,
            fullScreen: !useMinimizedPlayer,
            buffering: true,
            errorPlaying: false,
            skippedSegments: {},
          ));

      final media = model.media;
      PlaybackModel? newPlaybackModel = model;
      stage = PlaybackStage.resume;
      step = 'resolve_start_position';
      diagnostics.record(attempt, stage,
          event: PlaybackEvent.started, detail: step);
      final effectiveStartPosition =
          await model.resolvedStartPosition(startPosition);
      if (!stillCurrent()) return false;
      diagnostics.record(attempt, stage,
          event: PlaybackEvent.succeeded, detail: step);

      if (media != null) {
        ref.read(playBackModel.notifier).update((state) => newPlaybackModel);
        stage = PlaybackStage.mediaOpen;
        step = 'open_request';
        diagnostics.record(attempt, stage,
            event: PlaybackEvent.started, detail: step);
        await state.loadVideo(model, effectiveStartPosition, playWhenReady,
            isCurrent: current);
        if (!stillCurrent()) return false;
        // Accepted by the backend; this is not evidence of a decoded frame.
        diagnostics.record(attempt, stage,
            event: PlaybackEvent.succeeded, detail: 'open_request_returned');
        step = 'volume_setup';
        await state.setVolume(ref.read(videoPlayerSettingsProvider).volume);
        if (!stillCurrent()) return false;

        step = 'audio_track_setup';
        await state.setAudioTrack(null, model);
        if (!stillCurrent()) return false;
        step = 'subtitle_track_setup';
        await state.setSubtitleTrack(null, model);
        if (!stillCurrent()) return false;

        ref
            .read(mediaPlaybackProvider.notifier)
            .update((state) => state.copyWith(
                  state: useMinimizedPlayer
                      ? VideoPlayerState.minimized
                      : VideoPlayerState.fullScreen,
                  errorPlaying: false,
                  skippedSegments: {},
                ));

        stage = PlaybackStage.lifecycle;
        step = 'start_requested';
        if (playWhenReady) await state.play(userInitiated: false);
        return stillCurrent();
      }

      diagnostics.record(attempt, PlaybackStage.streamSelection,
          event: PlaybackEvent.failed, detail: 'missing_media');
      mediaState.update((state) => state.copyWith(errorPlaying: true));
      return false;
    } catch (error) {
      diagnostics.record(attempt, stage,
          event: PlaybackEvent.failed,
          errorClass: error.runtimeType.toString(),
          timedOut: error is TimeoutException,
          detail: step);
      rethrow;
    }
  }

  Future<bool> loadAudioPlaybackItem(
    PlaybackModel model,
    List<ItemBaseModel> queue,
    int currentIndex,
    Duration startPosition,
  ) async {
    await _initialization;
    if (!mounted) return false;
    if (_usingSyncPlayPlayer && !model.serverManagedQueue) {
      if (!await _restoreConfiguredPlayer()) return false;
    }
    if (!mounted || !state.hasPlayer) return false;
    final currentPlayerState = ref.read(mediaPlaybackProvider).state;
    final keepFullScreenLayout =
        currentPlayerState == VideoPlayerState.fullScreen;
    final playbackSettings = ref.read(mediaPlaybackProvider);

    final initializedQueueState = PlaybackQueueState.fromQueue(
      queue,
      initialItemId: queue[currentIndex.clamp(0, queue.length - 1)].id,
      shuffleEnabled: playbackSettings.shuffleEnabled,
      repeatMode: playbackSettings.repeatMode,
    );
    final queuedModel = model.updatePlaybackQueue(initializedQueueState);
    final effectiveStartPosition =
        await queuedModel.resolvedStartPosition(startPosition);

    ref.read(playBackModel.notifier).update((state) => queuedModel);
    ref.read(playbackRateProvider.notifier).state = 1.0;

    mediaState.update((state) => state.copyWith(
          state: keepFullScreenLayout
              ? VideoPlayerState.fullScreen
              : VideoPlayerState.minimized,
          fullScreen: keepFullScreenLayout,
          buffering: true,
          errorPlaying: false,
          skippedSegments: {},
          duration: queuedModel.item.overview.runTime ?? Duration.zero,
        ));

    await state.loadAudioQueue(
        queue, currentIndex, effectiveStartPosition, true);
    await state.setVolume(ref.read(videoPlayerSettingsProvider).volume);

    mediaState.update((state) => state.copyWith(
          buffering: false,
          playing: true,
          position: effectiveStartPosition,
          duration: queuedModel.item.overview.runTime ?? Duration.zero,
        ));
    return true;
  }

  Future<void> reorderAudioQueueSection(
    AudioQueueSection section,
    int oldIndex,
    int newIndex,
  ) async {
    await state.reorderAudioQueueSection(section, oldIndex, newIndex);
  }

  Future<void> addToTemporaryQueue(List<ItemBaseModel> items) async {
    await state.addToTemporaryQueue(items);
  }

  Future<void> clearTemporaryQueue() async {
    state.clearTemporaryQueue();
  }

  Future<void> removeAudioQueueItem(ItemBaseModel item) async {
    await state.removeAudioQueueItem(item.id);
  }

  Future<void> removeAudioQueueSectionItem(
    AudioQueueSection section,
    int sectionIndex,
  ) async {
    await state.removeAudioQueueSectionItem(section, sectionIndex);
  }

  Future<void> playAudioQueueItem(ItemBaseModel item) async {
    if (ref.read(playBackModel) == null) return;
    await state.jumpToQueueItem(item);
  }

  Future<void> openPlayer(BuildContext context) async =>
      state.openPlayer(context);

  Future<bool> takeScreenshot() async {
    final syncPath = ref.read(clientSettingsProvider).syncPath;
    // Early return here if we don't have a set/valid path. Skips actually taking the screenshot
    // which would be discarded.
    if (syncPath == null) {
      return false;
    }

    final screenshotsPath = p.join(syncPath, "Screenshots");
    final screenshotBuf = await state.takeScreenshot();

    if (screenshotBuf != null) {
      final savePathDirectory = Directory(screenshotsPath);

      // Should we try to create the directory instead?
      if (!await savePathDirectory.exists()) {
        return false;
      }

      final fileExtension = "png";
      final paddingAmount = 3;

      int maxNumber = 0;

      await for (var file in savePathDirectory.list()) {
        final finalSegment = file.uri.pathSegments.last;

        if (file is File && p.extension(finalSegment) == ".$fileExtension") {
          final match = RegExp(r'(\d+)').firstMatch(finalSegment);

          if (match != null) {
            final fileNumber = int.parse(match.group(0)!);

            if (fileNumber > maxNumber) {
              maxNumber = fileNumber;
            }
          }
        }
      }

      maxNumber += 1;

      final maxNumberStr = maxNumber.toString().padLeft(paddingAmount, '0');
      final screenshotName = '$maxNumberStr.$fileExtension';
      final screenshotPath = p.join(screenshotsPath, screenshotName);

      final screenshotFile = File(screenshotPath);
      await screenshotFile.writeAsBytes(screenshotBuf);

      return true;
    }

    return false;
  }
}
