import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:collection/collection.dart';

import 'package:fladder/models/items/media_streams_model.dart';
import 'package:fladder/models/playback/playback_model.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/util/dual_subtitle.dart';
import 'package:fladder/util/local_subtitle_selection.dart';
import 'package:fladder/util/subtitle_selection_failure.dart';
import 'package:fladder/wrappers/media_control_wrapper.dart';

bool _sameSession(PlaybackModel? a, PlaybackModel? b) =>
    a != null &&
    b != null &&
    a.runtimeType == b.runtimeType &&
    a.item.id == b.item.id &&
    a.media?.url == b.media?.url &&
    a.playbackInfo?.playSessionId == b.playbackInfo?.playSessionId &&
    a.mediaStreams?.currentVersionStream?.id ==
        b.mediaStreams?.currentVersionStream?.id;

class PrimarySubtitleSelectionState {
  const PrimarySubtitleSelectionState({
    this.model,
    this.player,
    this.stopEpoch,
    this.rendererGeneration,
    this.pending = false,
    this.requested,
    this.appliedIndex,
    this.error,
  });

  final PlaybackModel? model;
  final MediaControlsWrapper? player;
  final int? stopEpoch;
  final int? rendererGeneration;
  final bool pending;
  final SubStreamModel? requested;
  // null is unconfirmed; -1 is a successfully applied explicit Off choice.
  final int? appliedIndex;
  final SubtitleSelectionFailure? error;

  bool isFor(PlaybackModel? model, MediaControlsWrapper player) =>
      _sameSession(this.model, model) &&
      identical(this.player, player) &&
      rendererGeneration == player.rendererGeneration &&
      stopEpoch == player.playbackStopEpoch;
}

class PrimarySubtitleSelectionResult {
  const PrimarySubtitleSelectionResult({
    this.applied = false,
    this.failure,
    this.clearedSecondary,
  });

  final bool applied;
  final SubtitleSelectionFailure? failure;
  final SecondarySubtitleState? clearedSecondary;
}

class _Selection {
  _Selection(this.model, this.player, {this.isCurrent, this.owner})
      : stopEpoch = player.playbackStopEpoch,
        rendererGeneration = player.rendererGeneration;

  PlaybackModel model;
  final MediaControlsWrapper player;
  final int stopEpoch;
  final int rendererGeneration;
  final bool Function()? isCurrent;
  final Object? owner;

  bool get ownerCurrent {
    try {
      return isCurrent?.call() ?? true;
    } catch (_) {
      return false;
    }
  }
}

final primarySubtitleSelectionProvider = StateNotifierProvider<
    PrimarySubtitleSelectionController, PrimarySubtitleSelectionState>((ref) {
  final controller = PrimarySubtitleSelectionController(ref);
  ref.listen(playBackModel, (_, next) => controller.modelChanged(next));
  ref.listen(videoPlayerProvider, (_, next) => controller.playerChanged(next));
  return controller;
});

/// Owns track operations for the playback session, independently of any menu.
class PrimarySubtitleSelectionController
    extends StateNotifier<PrimarySubtitleSelectionState> {
  PrimarySubtitleSelectionController(this.ref)
      : super(const PrimarySubtitleSelectionState());

  final Ref ref;
  _Selection? _active;
  _Selection? _initial;

  bool _current(_Selection operation) =>
      mounted &&
      operation.ownerCurrent &&
      identical(_active, operation) &&
      identical(ref.read(playBackModel), operation.model) &&
      identical(ref.read(videoPlayerProvider), operation.player) &&
      operation.rendererGeneration == operation.player.rendererGeneration &&
      operation.player.playbackStopEpoch == operation.stopEpoch;

  void modelChanged(PlaybackModel? model) {
    if (_initial != null && identical(_initial!.model, model)) return;
    if (_active != null && identical(_active!.model, model)) return;
    if (identical(state.model, model)) return;
    final sameSession = _sameSession(state.model, model) &&
        state.player != null &&
        state.rendererGeneration == state.player!.rendererGeneration &&
        state.stopEpoch == state.player!.playbackStopEpoch;
    final pending = _active != null || state.pending;
    _active = null;
    _initial = null;
    if (sameSession) {
      state = PrimarySubtitleSelectionState(
        model: model,
        player: state.player,
        rendererGeneration: state.rendererGeneration,
        stopEpoch: state.stopEpoch,
        requested: state.requested,
        appliedIndex: pending ? null : state.appliedIndex,
        error: pending
            ? const SubtitleSelectionFailure(
                SubtitleSelectionFailureReason.unavailable)
            : state.error,
      );
      return;
    }
    state = const PrimarySubtitleSelectionState();
  }

  void playerChanged(MediaControlsWrapper player) {
    if (identical(state.player, player)) return;
    _active = null;
    _initial = null;
    state = const PrimarySubtitleSelectionState();
  }

  Object beginInitial(PlaybackModel model, MediaControlsWrapper player) {
    final token = _Selection(model, player);
    _initial = token;
    _active = null;
    if (mounted) {
      state = PrimarySubtitleSelectionState(
        model: model,
        player: player,
        rendererGeneration: player.rendererGeneration,
        stopEpoch: token.stopEpoch,
        pending: true,
        requested: model.mediaStreams?.currentSubStream,
      );
    }
    return token;
  }

  void cancelInitial(Object token) {
    if (!identical(_initial, token)) return;
    final initial = _initial!;
    _initial = null;
    if (!mounted) return;
    state = PrimarySubtitleSelectionState(
      model: state.model,
      player: state.player,
      rendererGeneration: state.rendererGeneration,
      stopEpoch: initial.player.playbackStopEpoch,
      requested: state.requested,
      appliedIndex: state.appliedIndex,
      error: state.error ??
          const SubtitleSelectionFailure(
              SubtitleSelectionFailureReason.unavailable),
    );
  }

  void recordInitial(PlaybackModel model, MediaControlsWrapper player,
      {Object? token, int? appliedIndex, SubtitleSelectionFailure? failure}) {
    if (!mounted ||
        (token != null &&
            (!identical(token, _initial) ||
                _initial!.stopEpoch != player.playbackStopEpoch)) ||
        (token != null &&
            _initial!.rendererGeneration != player.rendererGeneration) ||
        !identical(ref.read(playBackModel), model) ||
        !identical(ref.read(videoPlayerProvider), player)) {
      return;
    }
    if (token == null && (_active != null || _initial != null)) return;
    _active = null;
    _initial = null;
    state = PrimarySubtitleSelectionState(
      model: model,
      player: player,
      rendererGeneration: player.rendererGeneration,
      stopEpoch: player.playbackStopEpoch,
      requested: model.mediaStreams?.currentSubStream,
      appliedIndex: appliedIndex,
      error: failure,
    );
  }

  Future<PrimarySubtitleSelectionResult> select(SubStreamModel? track,
      {PlaybackModel? expectedModel,
      MediaControlsWrapper? expectedPlayer,
      bool Function()? isCurrent,
      Object? owner}) async {
    if (!mounted || _active != null || _initial != null) {
      return const PrimarySubtitleSelectionResult();
    }
    try {
      if (isCurrent?.call() == false) {
        return const PrimarySubtitleSelectionResult();
      }
    } catch (_) {
      return const PrimarySubtitleSelectionResult();
    }
    final model = ref.read(playBackModel);
    if (model == null) return const PrimarySubtitleSelectionResult();
    final player = ref.read(videoPlayerProvider);
    if ((expectedModel != null && !identical(expectedModel, model)) ||
        (expectedPlayer != null && !identical(expectedPlayer, player))) {
      return const PrimarySubtitleSelectionResult();
    }
    if (track != null && track.index < -1) {
      return const PrimarySubtitleSelectionResult();
    }
    final canonical = track == null
        ? model.mediaStreams?.currentSubStream
        : track.index == -1
            ? SubStreamModel.no()
            : model.subStreams?.firstWhereOrNull((candidate) =>
                candidate.index == track.index && candidate.id == track.id);
    if (canonical == null) return const PrimarySubtitleSelectionResult();
    final operation =
        _Selection(model, player, isCurrent: isCurrent, owner: owner);
    _active = operation;
    final requested = canonical;
    var appliedIndex = state.isFor(model, player)
        ? state.appliedIndex
        : model.mediaStreams?.defaultSubStreamIndex;
    var applied = false;
    final previousSecondary = player.secondarySubtitleState.value.selected;

    void publish({required bool pending, SubtitleSelectionFailure? error}) {
      state = PrimarySubtitleSelectionState(
        model: operation.model,
        player: player,
        rendererGeneration: operation.rendererGeneration,
        stopEpoch: operation.stopEpoch,
        pending: pending,
        requested: requested,
        appliedIndex: appliedIndex,
        error: error,
      );
    }

    publish(pending: true);
    try {
      SubtitleSelectionFailure? failure;
      final selected = await trySelectLocalSubtitle(
        model: model,
        track: canonical,
        player: player,
        isCurrent: () => _current(operation),
        onUnavailable: (value) => failure = value,
      );
      if (!_current(operation)) return const PrimarySubtitleSelectionResult();
      if (selected == null) {
        publish(pending: false, error: failure);
        return PrimarySubtitleSelectionResult(failure: failure);
      }
      applied = true;
      appliedIndex = selected.mediaStreams?.defaultSubStreamIndex;
      operation.model = selected;
      ref.read(playBackModel.notifier).state = selected;
      publish(pending: true);
      await ref.read(playbackModelHelper).shouldReload(selected);
      if (!_current(operation)) return const PrimarySubtitleSelectionResult();
      publish(pending: false);
      return PrimarySubtitleSelectionResult(
        applied: true,
        clearedSecondary: previousSecondary != null &&
                player.secondarySubtitleState.value.selected == null
            ? player.secondarySubtitleState.value
            : null,
      );
    } catch (error) {
      if (!_current(operation)) return const PrimarySubtitleSelectionResult();
      final failure = error is SubtitleSelectionFailure
          ? error
          : const SubtitleSelectionFailure(
              SubtitleSelectionFailureReason.unavailable);
      publish(pending: false, error: failure);
      return PrimarySubtitleSelectionResult(applied: applied, failure: failure);
    } finally {
      if (identical(_active, operation)) {
        _active = null;
        if (mounted && state.pending) {
          state = PrimarySubtitleSelectionState(
            model: operation.model,
            player: player,
            rendererGeneration: operation.rendererGeneration,
            stopEpoch: player.playbackStopEpoch,
            requested: requested,
            error: const SubtitleSelectionFailure(
                SubtitleSelectionFailureReason.unavailable),
          );
        }
      }
    }
  }

  /// Only the exact caller that started the active selection may revoke it.
  void cancelOwnedSelection(Object owner) {
    final operation = _active;
    if (operation == null || !identical(operation.owner, owner)) return;
    _active = null;
    final sameRenderer =
        operation.rendererGeneration == operation.player.rendererGeneration &&
            operation.stopEpoch == operation.player.playbackStopEpoch;
    if (sameRenderer) operation.player.cancelPendingSubtitleSelection();
    if (!mounted ||
        !sameRenderer ||
        !identical(ref.read(playBackModel), operation.model) ||
        !identical(ref.read(videoPlayerProvider), operation.player)) {
      return;
    }
    state = PrimarySubtitleSelectionState(
        model: operation.model,
        player: operation.player,
        stopEpoch: operation.stopEpoch,
        rendererGeneration: operation.rendererGeneration,
        requested: state.requested,
        appliedIndex: state.appliedIndex,
        error: const SubtitleSelectionFailure(
            SubtitleSelectionFailureReason.unavailable));
  }
}
