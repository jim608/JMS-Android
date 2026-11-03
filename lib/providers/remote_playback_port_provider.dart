import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/media_playback_model.dart';
import 'package:fladder/models/items/media_streams_model.dart';
import 'package:fladder/models/playback/playback_model.dart';
import 'package:fladder/models/settings/video_player_settings.dart';
import 'package:fladder/providers/primary_subtitle_selection_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/services/remote_control/remote_control_models.dart';
import 'package:fladder/services/remote_control/remote_receiver.dart';
import 'package:fladder/wrappers/media_control_wrapper.dart';

final remotePlaybackPortProvider = Provider<RemotePlaybackPort>((ref) {
  ref.watch(userProvider.select((value) => (value?.id, value?.credentials)));
  final port = JmsRemotePlaybackPort(ref, ref.read(userProvider));
  ref.onDispose(port.invalidate);
  return port;
});

/// Keeps remote input on the same player, subtitle owner and seek rules as UI.
class JmsRemotePlaybackPort implements RemotePlaybackPort {
  JmsRemotePlaybackPort(this.ref, this.owner);
  final Ref ref;
  final AccountModel? owner;
  bool _invalidated = false;
  int _inputEpoch = 0;
  PrimarySubtitleSelectionController? _pendingSubtitleController;
  Object? _pendingSubtitleOwner;

  bool get _current {
    if (_invalidated || owner == null) return false;
    try {
      final user = ref.read(userProvider);
      return user?.id == owner!.id &&
          user?.credentials == owner!.credentials &&
          user?.policy?.isDisabled != true &&
          user?.policy?.enableMediaPlayback != false;
    } catch (_) {
      invalidate();
      return false;
    }
  }

  void invalidate() {
    if (_invalidated) return;
    _invalidated = true;
    cancelPendingInput();
  }

  void cancelPendingInput() {
    _inputEpoch++;
    final owner = _pendingSubtitleOwner;
    if (owner != null) {
      try {
        _pendingSubtitleController?.cancelOwnedSelection(owner);
      } catch (_) {}
    }
  }

  RemotePlaybackBinding? _binding(PlaybackModel? model) {
    final source = model?.mediaStreams?.currentVersionStream?.id;
    final occurrence = model?.currentPlaylistItemId;
    if (model == null ||
        model.reportingScope?.isCurrent != true ||
        model.isAudioPlayback ||
        source == null ||
        source.isEmpty ||
        occurrence == null) {
      return null;
    }
    return RemotePlaybackBinding(
        itemId: model.item.id, mediaSourceId: source, playbackId: occurrence);
  }

  @override
  bool get blockedBySyncPlay {
    if (!_current) return true;
    try {
      return ref.read(videoPlayerProvider).syncPlayActive;
    } catch (_) {
      return true;
    }
  }

  @override
  RemotePlaybackSnapshot? get snapshot {
    if (!_current) return null;
    final model = ref.read(playBackModel);
    final binding = _binding(model);
    if (binding == null) return null;
    final media = ref.read(mediaPlaybackProvider);
    if (media.state == VideoPlayerState.disposed ||
        media.errorPlaying ||
        media.completed) {
      return null;
    }
    final player = ref.read(videoPlayerProvider);
    // Legacy NativeActivity cannot confirm remote subtitle changes or progress.
    if (player.backend == PlayerOptions.nativePlayer) return null;
    final subtitle = ref.read(primarySubtitleSelectionProvider);
    final applied = subtitle.isFor(model, player) &&
            !subtitle.pending &&
            subtitle.error == null
        ? subtitle.appliedIndex
        : null;
    return RemotePlaybackSnapshot(
        binding: binding,
        positionTicks: media.position.inMicroseconds * 10,
        durationTicks: media.duration > Duration.zero
            ? media.duration.inMicroseconds * 10
            : null,
        paused: !media.playing,
        canSeek: media.duration > Duration.zero,
        subtitleIndex: applied,
        playSessionId: model!.playbackInfo?.playSessionId,
        audioStreamIndex: model.mediaStreams?.defaultAudioStreamIndex);
  }

  (PlaybackModel, MediaControlsWrapper, int, int) _capture(
      RemotePlaybackBinding binding) {
    if (!_current || blockedBySyncPlay) {
      throw const RemoteControlFailure(RemoteFailureCode.denied);
    }
    final model = ref.read(playBackModel);
    if (model == null || snapshot?.binding != binding) {
      throw const RemoteControlFailure(RemoteFailureCode.stale);
    }
    final player = ref.read(videoPlayerProvider);
    return (model, player, player.playbackStopEpoch, player.rendererGeneration);
  }

  void _after(RemotePlaybackBinding binding, MediaControlsWrapper player,
      int stopEpoch, int rendererGeneration,
      {int? inputEpoch}) {
    if (!_current ||
        (inputEpoch != null && inputEpoch != _inputEpoch) ||
        blockedBySyncPlay ||
        _binding(ref.read(playBackModel)) != binding ||
        snapshot?.binding != binding ||
        player.playbackStopEpoch != stopEpoch ||
        player.rendererGeneration != rendererGeneration ||
        !identical(player, ref.read(videoPlayerProvider))) {
      throw const RemoteControlFailure(RemoteFailureCode.stale);
    }
  }

  bool _allows(RemotePlaybackBinding binding, MediaControlsWrapper player,
      int stopEpoch, int renderer, int inputEpoch) {
    try {
      _after(binding, player, stopEpoch, renderer, inputEpoch: inputEpoch);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> play(RemotePlaybackBinding binding) async {
    final (_, player, stopEpoch, renderer) = _capture(binding);
    final epoch = _inputEpoch;
    await player.playRemotely(
        isCurrent: () => _allows(binding, player, stopEpoch, renderer, epoch));
    _after(binding, player, stopEpoch, renderer, inputEpoch: epoch);
  }

  @override
  Future<void> pause(RemotePlaybackBinding binding) async {
    final (_, player, stopEpoch, renderer) = _capture(binding);
    final epoch = _inputEpoch;
    await player.pauseRemotely(
        isCurrent: () => _allows(binding, player, stopEpoch, renderer, epoch));
    _after(binding, player, stopEpoch, renderer, inputEpoch: epoch);
  }

  @override
  Future<void> seek(Duration position, RemotePlaybackBinding binding) async {
    final (_, player, stopEpoch, renderer) = _capture(binding);
    final epoch = _inputEpoch;
    final current = snapshot;
    if (current == null ||
        !current.canSeek ||
        position.isNegative ||
        position.inMicroseconds * 10 > (current.durationTicks ?? 0)) {
      throw const RemoteControlFailure(RemoteFailureCode.invalidAction);
    }
    await player.seekRemotely(position,
        isCurrent: () => _allows(binding, player, stopEpoch, renderer, epoch));
    _after(binding, player, stopEpoch, renderer, inputEpoch: epoch);
  }

  @override
  Future<void> setSubtitle(int index, RemotePlaybackBinding binding) async {
    final (model, player, stopEpoch, renderer) = _capture(binding);
    final matches = (model.subStreams ?? <SubStreamModel>[])
        .where((track) => track.index == index)
        .toList();
    if (index < -1 || (index != -1 && matches.length != 1)) {
      throw const RemoteControlFailure(RemoteFailureCode.invalidAction);
    }
    final owner = Object();
    final selection = ref.read(primarySubtitleSelectionProvider.notifier);
    _pendingSubtitleController = selection;
    _pendingSubtitleOwner = owner;
    final epoch = _inputEpoch;
    try {
      final result = await selection.select(
        index == -1 ? SubStreamModel.no() : matches.single,
        expectedModel: model,
        expectedPlayer: player,
        owner: owner,
        isCurrent: () =>
            _current &&
            epoch == _inputEpoch &&
            !blockedBySyncPlay &&
            player.playbackStopEpoch == stopEpoch &&
            player.rendererGeneration == renderer &&
            _binding(ref.read(playBackModel)) == binding &&
            identical(player, ref.read(videoPlayerProvider)),
      );
      _after(binding, player, stopEpoch, renderer, inputEpoch: epoch);
      if (!result.applied || result.failure != null) {
        throw const RemoteControlFailure(RemoteFailureCode.unsupported);
      }
    } finally {
      if (identical(_pendingSubtitleOwner, owner)) {
        _pendingSubtitleController = null;
        _pendingSubtitleOwner = null;
      }
    }
  }
}
