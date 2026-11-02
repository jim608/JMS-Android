import 'package:flutter/widgets.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/items/chapters_model.dart';
import 'package:fladder/models/items/item_shared_models.dart';
import 'package:fladder/models/items/media_segments_model.dart';
import 'package:fladder/models/items/media_streams_model.dart';
import 'package:fladder/models/items/trick_play_model.dart';
import 'package:fladder/models/playback/playback_queue_state.dart';
import 'package:fladder/models/playback/playback_model.dart';
import 'package:fladder/util/bitrate_helper.dart';
import 'package:fladder/util/duration_extensions.dart';
import 'package:fladder/util/subtitle_selection_failure.dart';
import 'package:fladder/wrappers/media_control_wrapper.dart';

class TranscodePlaybackModel extends PlaybackModel {
  @override
  bool get isServerTranscoded => true;

  TranscodePlaybackModel({
    required super.item,
    required super.media,
    required super.playbackInfo,
    super.reportingScope,
    super.mediaStreams,
    super.mediaSegments,
    super.chapters,
    super.trickPlay,
    super.queue = const [],
    super.playbackQueue,
    super.queueSource,
    super.bitRateOptions,
  });

  @override
  List<SubStreamModel> get subStreams =>
      [SubStreamModel.no(), ...mediaStreams?.subStreams ?? []];

  List<QueueItem> get itemsInQueue => localItemsInQueue;

  @override
  Future<TranscodePlaybackModel> setSubtitle(
      SubStreamModel? model, MediaControlsWrapper player) async {
    final wanted = model ?? defaultSubStream;
    final newIndex = await player.setSubtitleTrack(model, this);
    requireSubtitleSelectionIndex(wanted?.index, newIndex);
    return copyWith(
        mediaStreams: () =>
            mediaStreams?.copyWith(defaultSubStreamIndex: newIndex));
  }

  @override
  List<AudioStreamModel> get audioStreams =>
      [AudioStreamModel.no(), ...mediaStreams?.audioStreams ?? []];

  @override
  Future<TranscodePlaybackModel>? setAudio(
      AudioStreamModel? model, MediaControlsWrapper player) async {
    final newIndex = await player.setAudioTrack(model, this);
    return copyWith(
        mediaStreams: () =>
            mediaStreams?.copyWith(defaultAudioStreamIndex: newIndex));
  }

  @override
  Future<TranscodePlaybackModel>? setQualityOption(
          Map<Bitrate, bool> map) async =>
      copyWith(bitRateOptions: map);

  @override
  Future<PlaybackModel?> playbackStarted(Duration position, Ref ref) async {
    final reporting = reportingScope;
    if (reporting == null || !reporting.isOwned) return null;
    await reporting.start(
      PlaybackStartInfo(
        canSeek: true,
        itemId: item.id,
        mediaSourceId: mediaStreams?.currentVersionStream?.id,
        playlistItemId: currentPlaylistItemId,
        nowPlayingQueue: itemsInQueue,
        playSessionId: playbackInfo?.playSessionId,
        sessionId: playbackInfo?.playSessionId,
        subtitleStreamIndex: subtitleStreamIndexForReport(ref),
        audioStreamIndex: mediaStreams?.defaultAudioStreamIndex,
        volumeLevel: 100,
        playbackStartTimeTicks: position.toRuntimeTicks,
        playMethod: PlayMethod.transcode,
        isMuted: false,
        isPaused: false,
        repeatMode: RepeatMode.repeatall,
      ),
    );
    return null;
  }

  @override
  Future<PlaybackModel?> playbackStopped(
      Duration position, Duration? totalDuration, Ref ref) async {
    final reporting = reportingScope;
    if (reporting == null || !reporting.isOwned) return null;
    final stopPosition = resolvedStopPosition(position, totalDuration);

    await reporting.stop(
      PlaybackStopInfo(
        itemId: item.id,
        mediaSourceId: mediaStreams?.currentVersionStream?.id,
        playlistItemId: currentPlaylistItemId,
        nowPlayingQueue: itemsInQueue,
        playSessionId: playbackInfo?.playSessionId,
        positionTicks: stopPosition.toRuntimeTicks,
      ),
    );

    return null;
  }

  @override
  Future<PlaybackModel?> updatePlaybackPosition(
      Duration position, bool isPlaying, Ref ref) async {
    final reporting = reportingScope;
    if (reporting == null || !reporting.isCurrent) return null;
    await reporting.progress(
      PlaybackProgressInfo(
        canSeek: true,
        itemId: item.id,
        mediaSourceId: mediaStreams?.currentVersionStream?.id,
        playlistItemId: currentPlaylistItemId,
        nowPlayingQueue: itemsInQueue,
        playSessionId: playbackInfo?.playSessionId,
        sessionId: playbackInfo?.playSessionId,
        subtitleStreamIndex: subtitleStreamIndexForReport(ref),
        audioStreamIndex: mediaStreams?.defaultAudioStreamIndex,
        volumeLevel: 100,
        positionTicks: position.toRuntimeTicks,
        playMethod: PlayMethod.transcode,
        isPaused: !isPlaying,
        isMuted: false,
        repeatMode: RepeatMode.repeatall,
      ),
    );
    return this;
  }

  @override
  TranscodePlaybackModel? updateUserData(UserData userData) {
    return copyWith(
      item: item.copyWith(
        userData: userData,
      ),
    );
  }

  @override
  TranscodePlaybackModel updatePlaybackQueue(PlaybackQueueState newQueue) {
    return copyWith(playbackQueue: newQueue);
  }

  @override
  String toString() =>
      'TranscodePlaybackModel(item: $item, playbackInfo: $playbackInfo)';

  @override
  TranscodePlaybackModel copyWith({
    ItemBaseModel? item,
    ValueGetter<Media?>? media,
    ValueGetter<Duration>? lastPosition,
    PlaybackInfoResponse? playbackInfo,
    ValueGetter<MediaStreamsModel?>? mediaStreams,
    ValueGetter<MediaSegmentsModel?>? mediaSegments,
    ValueGetter<List<Chapter>?>? chapters,
    ValueGetter<TrickPlayModel?>? trickPlay,
    List<ItemBaseModel>? queue,
    PlaybackQueueState? playbackQueue,
    PlaybackQueueSource? queueSource,
    Map<Bitrate, bool>? bitRateOptions,
  }) {
    final updatedStreams =
        mediaStreams != null ? mediaStreams() : this.mediaStreams;
    return TranscodePlaybackModel(
      reportingScope: reportingScopeForCopy(
          item: item ?? this.item,
          playbackInfo: playbackInfo ?? this.playbackInfo,
          mediaStreams: updatedStreams),
      item: item ?? this.item,
      media: media != null ? media() : this.media,
      playbackInfo: playbackInfo ?? this.playbackInfo,
      mediaStreams: updatedStreams,
      mediaSegments:
          mediaSegments != null ? mediaSegments() : this.mediaSegments,
      chapters: chapters != null ? chapters() : this.chapters,
      trickPlay: trickPlay != null ? trickPlay() : this.trickPlay,
      queue: queue ?? this.queue,
      playbackQueue: playbackQueue ?? this.playbackQueue,
      queueSource: queueSource ?? this.queueSource,
      bitRateOptions: bitRateOptions ?? this.bitRateOptions,
    );
  }
}
