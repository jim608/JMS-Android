import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide ConnectionState;

import 'package:background_downloader/background_downloader.dart';
import 'package:chopper/chopper.dart';
import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/items/audio_model.dart';
import 'package:fladder/models/items/channel_model.dart';
import 'package:fladder/models/items/chapters_model.dart';
import 'package:fladder/models/items/episode_model.dart';
import 'package:fladder/models/items/item_shared_models.dart';
import 'package:fladder/models/items/media_segments_model.dart';
import 'package:fladder/models/items/media_streams_model.dart';
import 'package:fladder/models/items/season_model.dart';
import 'package:fladder/models/items/series_model.dart';
import 'package:fladder/models/items/trick_play_model.dart';
import 'package:fladder/models/playback/direct_playback_model.dart';
import 'package:fladder/models/playback/offline_playback_model.dart';
import 'package:fladder/models/playback/playback_options_dialogue.dart';
import 'package:fladder/models/playback/playback_queue_source.dart';
import 'package:fladder/models/playback/playback_queue_state.dart';
import 'package:fladder/models/playback/transcode_playback_model.dart';
import 'package:fladder/models/playback/tv_playback_model.dart';
export 'playback_queue_source.dart';
import 'package:fladder/models/settings/video_player_settings.dart';
import 'package:fladder/models/syncing/sync_item.dart';
import 'package:fladder/models/video_stream_model.dart';
import 'package:fladder/profiles/default_profile.dart';
import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/connectivity_provider.dart';
import 'package:fladder/providers/captured_playback_reporting_provider.dart';
import 'package:fladder/providers/primary_subtitle_selection_provider.dart';
import 'package:fladder/providers/service_provider.dart';
import 'package:fladder/providers/settings/video_player_settings_provider.dart';
import 'package:fladder/providers/sync_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/services/playback_diagnostics.dart';
import 'package:fladder/services/playback_reporting_scope.dart';
import 'package:fladder/util/bitrate_helper.dart';
import 'package:fladder/util/duration_extensions.dart';
import 'package:fladder/util/localization_helper.dart';
import 'package:fladder/util/map_bool_helper.dart';
import 'package:fladder/util/selected_media_source.dart';
import 'package:fladder/util/streams_selection.dart';
import 'package:fladder/util/subtitle_selection_failure.dart';
import 'package:fladder/wrappers/media_control_wrapper.dart';

class Media {
  final String url;

  const Media({
    required this.url,
  });
}

/// Web subtitle intent is not evidence that the renderer applied the track.
/// Null preserves an unconfirmed selection; only an acknowledged Off is -1.
int? playbackSubtitleStreamIndexForReport({
  required bool web,
  required PlaybackModel model,
  PrimarySubtitleSelectionState? selection,
  MediaControlsWrapper? player,
}) {
  if (!web) return model.mediaStreams?.defaultSubStreamIndex;
  if (selection == null ||
      player == null ||
      selection.pending ||
      selection.error != null ||
      !selection.isFor(model, player)) {
    return null;
  }
  return selection.appliedIndex;
}

/// Server permission is separate from source HDR labels or display capability.
bool nativeTvServerAllowsDirectPlayback({
  required bool nativePlayer,
  required bool liveTv,
  required MediaSourceInfo source,
}) =>
    !nativePlayer ||
    !liveTv ||
    source.supportsDirectPlay == true ||
    source.supportsDirectStream == true;

/// At most one unfinished request per optional endpoint. A UI timeout does not
/// claim to cancel the shared HTTP client; later attempts skip a still-busy slot.
class PlaybackOptionalMetadataLoader {
  bool _pending = false;

  Future<T?> load<T>(
    Future<T?> Function() request, {
    required PlaybackAttemptRef attempt,
    required String step,
    required Duration budget,
    int? Function(T value)? statusCode,
    bool Function(T value)? accept,
  }) async {
    final diagnostics = PlaybackDiagnostics.instance;
    if (_pending) {
      diagnostics.record(attempt, PlaybackStage.streamSelection,
          detail: '$step busy skipped');
      return null;
    }
    _pending = true;
    diagnostics.record(attempt, PlaybackStage.streamSelection,
        event: PlaybackEvent.started, detail: step);
    final actual = Future<T?>.sync(request).then<T?>((value) {
      _pending = false;
      return value;
    }, onError: (Object error, StackTrace stack) {
      _pending = false;
      Error.throwWithStackTrace(error, stack);
    });
    try {
      final value = await actual.timeout(budget);
      if (value == null || !(accept?.call(value) ?? true)) {
        diagnostics.record(attempt, PlaybackStage.streamSelection,
            event: PlaybackEvent.note,
            httpStatus: value == null ? null : statusCode?.call(value),
            detail: '$step unavailable');
        return null;
      }
      diagnostics.record(attempt, PlaybackStage.streamSelection,
          event: PlaybackEvent.succeeded,
          httpStatus: statusCode?.call(value),
          detail: step);
      return value;
    } catch (error) {
      diagnostics.record(attempt, PlaybackStage.streamSelection,
          event: PlaybackEvent.note,
          timedOut: error is TimeoutException,
          errorClass: error.runtimeType.toString(),
          detail: '$step optional');
      return null;
    }
  }
}

/// Extract only server-defined enum reasons; never return URL or arbitrary text.
String playbackTranscodeReasonSummary(String? transcodingUrl) {
  if (transcodingUrl == null) return 'not provided';
  if (transcodingUrl.length > 8192) return 'unavailable';
  try {
    final query = Uri.tryParse(transcodingUrl)?.queryParameters;
    final raw = query?.entries
        .firstWhereOrNull(
            (entry) => entry.key.toLowerCase() == 'transcodereasons')
        ?.value;
    if (raw == null || raw.isEmpty) return 'not provided';
    final values = raw.split(',').take(12).map((part) {
      final reason = TranscodeReason.values.firstWhereOrNull(
          (reason) => reason.value?.toLowerCase() == part.trim().toLowerCase());
      return reason?.value?.replaceAllMapped(RegExp(r'([a-z])([A-Z])'),
              (match) => '${match[1]} ${match[2]}') ??
          'unknown';
    }).toSet();
    return values.join(', ');
  } on FormatException {
    return 'unavailable';
  }
}

extension PlaybackModelExtension on PlaybackModel? {
  SubStreamModel? get defaultSubStream {
    final streams = this?.subStreams;
    if (streams == null) return null;
    return streams.firstWhereOrNull((element) =>
            element.index == this?.mediaStreams?.defaultSubStreamIndex) ??
        SubStreamModel.no();
  }

  AudioStreamModel? get defaultAudioStream {
    final streams = this?.audioStreams;
    if (streams == null) return null;
    return streams.firstWhereOrNull((element) =>
            element.index == this?.mediaStreams?.defaultAudioStreamIndex) ??
        AudioStreamModel.no();
  }

  String? label(BuildContext context) => switch (this) {
        DirectPlaybackModel _ => PlaybackType.directStream.name(context),
        TranscodePlaybackModel _ => PlaybackType.transcode.name(context),
        OfflinePlaybackModel _ => PlaybackType.offline.name(context),
        TvPlaybackModel _ => PlaybackType.tv.name(context),
        PlaybackModel model when model.playbackType != null =>
          model.playbackType!.name(context),
        _ => context.localized.unknown,
      };
}

class PlaybackModel {
  /// Group playback keeps queue progression on the server.
  bool get serverManagedQueue => false;
  bool get ownsPlaybackResources => false;

  /// Captured delivery type remains available after room membership ends.
  PlaybackType? get playbackType => null;

  /// Describes the selected output, independently of the playback session type.
  /// Original source HDR labels do not classify a server-transcoded stream.
  bool get isServerTranscoded => false;
  final ItemBaseModel item;
  final Media? media;
  final PlaybackQueueState playbackQueue;
  List<ItemBaseModel> get queue => playbackQueue.queue;
  List<ItemBaseModel> get nextUpQueue => playbackQueue.nextUpQueue;
  final PlaybackQueueSource? queueSource;
  final MediaSegmentsModel? mediaSegments;
  final PlaybackInfoResponse? playbackInfo;
  final PlaybackReportingScope? reportingScope;

  PlaybackReportingScope? reportingScopeForCopy(
          {required ItemBaseModel item,
          required PlaybackInfoResponse? playbackInfo,
          required MediaStreamsModel? mediaStreams}) =>
      reportingScope?.rebind(
          itemId: item.id,
          mediaSourceId: mediaStreams?.currentVersionStream?.id,
          playSessionId: playbackInfo?.playSessionId,
          playlistItemId: _reportingPlaylistItemId(playbackInfo));

  int? subtitleStreamIndexForReport(Ref ref) =>
      playbackSubtitleStreamIndexForReport(
        web: kIsWeb,
        model: this,
        selection: kIsWeb ? ref.read(primarySubtitleSelectionProvider) : null,
        player: kIsWeb ? ref.read(videoPlayerProvider) : null,
      );

  /// The server echoes this occurrence marker to session discovery. A replay
  /// receives a new PlaySessionId; subtitle/audio copies keep the same marker.
  /// Group queues, offline playback and live TV retain their own semantics.
  String? get currentPlaylistItemId {
    if (serverManagedQueue ||
        (this is! DirectPlaybackModel && this is! TranscodePlaybackModel)) {
      return null;
    }
    return _reportingPlaylistItemId(playbackInfo);
  }

  List<QueueItem> get localItemsInQueue {
    final currentIndex = queue.indexWhere((entry) => entry.id == item.id);
    final entries = queue
        .mapIndexed(
          (index, entry) => QueueItem(
            id: entry.id,
            playlistItemId: index == currentIndex
                ? currentPlaylistItemId
                : 'playlistItem$index',
          ),
        )
        .toList();
    if (currentIndex < 0) {
      entries.insert(
        0,
        QueueItem(id: item.id, playlistItemId: currentPlaylistItemId),
      );
    }
    return entries;
  }

  Map<Bitrate, bool> bitRateOptions;

  List<Chapter>? chapters = [];
  TrickPlayModel? trickPlay;

  Future<PlaybackModel?> updatePlaybackPosition(
          Duration position, bool isPlaying, Ref ref) =>
      throw UnimplementedError();
  Future<PlaybackModel?> playbackStarted(Duration position, Ref ref) =>
      throw UnimplementedError();
  Future<PlaybackModel?> playbackStopped(
          Duration position, Duration? totalDuration, Ref ref) =>
      throw UnimplementedError();

  void dispose() {}

  final MediaStreamsModel? mediaStreams;
  List<SubStreamModel>? get subStreams => throw UnimplementedError();
  List<AudioStreamModel>? get audioStreams => throw UnimplementedError();

  bool get isAudioPlayback =>
      item is AudioModel || item.type == FladderItemType.audio;

  Duration resolvedStopPosition(Duration position, Duration? totalDuration) {
    if (!isAudioPlayback) return position;
    return totalDuration ?? item.overview.runTime ?? position;
  }

  Future<Duration> resolvedStartPosition(
      [Duration? requestedStartPosition]) async {
    if (isAudioPlayback) return Duration.zero;
    return requestedStartPosition ?? await startDuration() ?? Duration.zero;
  }

  Future<Duration>? startDuration() async =>
      isAudioPlayback ? Duration.zero : item.userData.playBackPosition;

  PlaybackModel? updateUserData(UserData userData) =>
      throw UnimplementedError();

  Future<PlaybackModel>? setSubtitle(
          SubStreamModel? model, MediaControlsWrapper player) =>
      throw UnimplementedError();
  Future<PlaybackModel>? setAudio(
          AudioStreamModel? model, MediaControlsWrapper player) =>
      throw UnimplementedError();
  Future<PlaybackModel>? setQualityOption(Map<Bitrate, bool> map) =>
      throw UnimplementedError();

  PlaybackModel updatePlaybackQueue(PlaybackQueueState newQueue) =>
      throw UnimplementedError();

  ItemBaseModel? get nextVideo => playbackQueue.nextItem(item.id);
  ItemBaseModel? get previousVideo => playbackQueue.previousItem(item.id);

  PlaybackModel copyWith() => throw UnimplementedError();

  PlaybackModel({
    required this.playbackInfo,
    this.reportingScope,
    this.mediaStreams,
    required this.item,
    required this.media,
    List<ItemBaseModel> queue = const [],
    PlaybackQueueState? playbackQueue,
    this.queueSource,
    this.bitRateOptions = const {},
    this.mediaSegments,
    this.chapters,
    this.trickPlay,
  }) : playbackQueue = playbackQueue ??
            PlaybackQueueState.fromQueue(
              queue,
              initialItemId: item.id,
            );
}

final playbackModelHelper = Provider<PlaybackModelHelper>((ref) {
  return PlaybackModelHelper(
      ref: ref,
      captureReporting: () =>
          ref.read(capturedPlaybackReportingProvider).capture());
});

String? _reportingPlaylistItemId(PlaybackInfoResponse? info) {
  final session = info?.playSessionId;
  return session == null || session.isEmpty ? null : 'jms-remote-$session';
}

class PlaybackModelHelper {
  const PlaybackModelHelper({required this.ref, this.captureReporting});

  final Ref ref;
  final PlaybackReportingCapture? Function()? captureReporting;
  static final _segmentsLoader = PlaybackOptionalMetadataLoader();
  static final _trickPlayLoader = PlaybackOptionalMetadataLoader();
  static const _optionalMetadataBudget = Duration(seconds: 3);

  JellyService get api => ref.read(jellyApiProvider);

  MediaStreamsModel _streamsForSelectedSource(
    SelectedPlaybackMediaSource selected, {
    required int? audioStreamIndex,
  }) {
    final streams =
        MediaStreamsModel.fromMediaStreamsList([selected.source], ref).copyWith(
      defaultAudioStreamIndex: audioStreamIndex,
      defaultSubStreamIndex: selected.subtitleStreamIndex,
    );
    for (final subtitle in streams.subStreams) {
      subtitle.id = selected.subtitleKey(subtitle.index);
    }
    return streams;
  }

  Future<PlaybackModel?> loadNewVideo(ItemBaseModel newItem) async {
    if (ref.read(playBackModel)?.serverManagedQueue == true ||
        ref.read(videoPlayerProvider).syncPlayActive) {
      return null;
    }
    ref.read(videoPlayerProvider).pause();
    ref
        .read(mediaPlaybackProvider.notifier)
        .update((state) => state.copyWith(buffering: true));
    final currentModel = ref.read(playBackModel);
    final newModel = (await createPlaybackModel(
          null,
          newItem,
          oldModel: currentModel,
        )) ??
        await _createOfflinePlaybackModel(
          newItem,
          null,
          await ref.read(syncProvider.notifier).getSyncedItem(newItem.id),
          oldModel: currentModel,
        );
    if (newModel == null) return null;
    final advancedQueue = currentModel?.playbackQueue
        .advanceFromCurrentTo(currentModel.item.id, newItem.id);
    final modelToLoad = advancedQueue != null
        ? newModel.updatePlaybackQueue(advancedQueue)
        : newModel;
    ref
        .read(videoPlayerProvider.notifier)
        .loadPlaybackItem(modelToLoad, Duration.zero);
    return modelToLoad;
  }

  Future<void> loadTVChannel(ChannelModel? channel) async {
    if (channel == null) return;
    ref.read(videoPlayerProvider).pause();
    ref
        .read(mediaPlaybackProvider.notifier)
        .update((state) => state.copyWith(buffering: true));
    final currentModel = ref.read(playBackModel);

    PlaybackModel? serverModel;
    try {
      serverModel = await createPlaybackModel(
        null,
        channel,
        forcedPlaybackType: PlaybackType.tv,
        oldModel: currentModel,
      ).timeout(const Duration(seconds: 8), onTimeout: () {
        return null;
      });
    } catch (e) {
      serverModel = null;
    }

    final newModel = serverModel ??
        await _createOfflinePlaybackModel(
          channel,
          null,
          await ref.read(syncProvider.notifier).getSyncedItem(channel.id),
          oldModel: currentModel,
        );

    if (newModel == null) {
      ref
          .read(mediaPlaybackProvider.notifier)
          .update((state) => state.copyWith(buffering: false));
      return;
    }
    ref
        .read(videoPlayerProvider.notifier)
        .loadPlaybackItem(newModel, Duration.zero);
  }

  Future<OfflinePlaybackModel?> _createOfflinePlaybackModel(
    ItemBaseModel item,
    MediaStreamsModel? streamModel,
    SyncedItem? syncedItem, {
    PlaybackModel? oldModel,
    PlaybackQueueSource? queueSource,
  }) async {
    final ItemBaseModel? syncedItemModel = syncedItem?.itemModel;
    if (syncedItemModel == null ||
        syncedItem == null ||
        !await syncedItem.videoFile.exists()) {
      return null;
    }

    final children =
        await ref.read(syncProvider.notifier).getSiblings(syncedItem);

    final syncedItems =
        children.where((element) => element.videoFile.existsSync()).toList();
    final itemQueue = syncedItems.map((e) => e.itemModel).nonNulls;

    return OfflinePlaybackModel(
      item: syncedItemModel,
      syncedItem: syncedItem,
      trickPlay: syncedItem.trickPlayModel,
      mediaSegments: syncedItem.mediaSegments,
      media: Media(url: syncedItem.videoFile.path),
      queue: itemQueue.nonNulls.toList(),
      playbackQueue: oldModel?.playbackQueue,
      queueSource: queueSource ?? oldModel?.queueSource,
      syncedQueue: children,
      mediaStreams: item.streamModel ?? syncedItemModel.streamModel,
    );
  }

  Future<PlaybackModel?> createPlaybackModel(
    BuildContext? context,
    ItemBaseModel? item, {
    PlaybackModel? oldModel,
    List<ItemBaseModel>? libraryQueue,
    PlaybackQueueSource? queueSource,
    bool showPlaybackOptions = false,
    PlaybackType? forcedPlaybackType,
    Duration? startPosition,
    PlaybackAttemptRef? diagnosticAttempt,
  }) async {
    // Capture before queue/details/negotiation await. An account ABA cannot
    // attach this delayed playback attempt to the newly logged-in account.
    final reportingCapture = captureReporting?.call();
    final diagnostics = PlaybackDiagnostics.instance;
    final attempt = diagnosticAttempt ?? diagnostics.startAttempt();
    var stage = PlaybackStage.itemDetails;
    var step = 'queue_selection';
    diagnostics.record(attempt, stage,
        event: PlaybackEvent.started, detail: step);
    try {
      if (item == null) {
        diagnostics.record(attempt, stage,
            event: PlaybackEvent.failed, detail: 'missing_item');
        return null;
      }
      final userId = ref.read(userProvider)?.id;
      if (userId?.isEmpty == true) {
        diagnostics.record(attempt, stage,
            event: PlaybackEvent.failed, detail: 'missing_user');
        return null;
      }

      final queue = oldModel?.queue ?? libraryQueue ?? await collectQueue(item);
      if (reportingCapture != null && !reportingCapture.isCurrent) return null;
      final effectiveQueueSource = oldModel?.queueSource ?? queueSource;

      final firstItemToPlay = switch (item) {
        SeriesModel _ ||
        SeasonModel _ =>
          (queue.whereType<EpisodeModel>().toList().nextUp),
        _ => item,
      };

      if (firstItemToPlay == null) {
        diagnostics.record(attempt, stage,
            event: PlaybackEvent.failed, detail: 'empty_queue');
        return null;
      }

      step = 'item_request';
      diagnostics.record(attempt, stage,
          event: PlaybackEvent.started, detail: step);
      final fullItemResponse =
          await api.usersUserIdItemsItemIdGet(itemId: firstItemToPlay.id);
      if (reportingCapture != null && !reportingCapture.isCurrent) return null;

      final fullItem = fullItemResponse.body;

      if (fullItem == null) {
        diagnostics.record(attempt, stage,
            event: PlaybackEvent.failed,
            httpStatus: fullItemResponse.statusCode,
            detail: 'empty_item_response');
        return null;
      }
      diagnostics.record(attempt, stage,
          event: PlaybackEvent.succeeded,
          httpStatus: fullItemResponse.statusCode,
          detail: step);
      stage = PlaybackStage.streamSelection;
      step = 'offline_lookup';

      SyncedItem? syncedItem =
          await ref.read(syncProvider.notifier).getSyncedItem(fullItem.id);

      final firstItemIsSynced =
          syncedItem != null && syncedItem.status == TaskStatus.complete;

      final actualStartPosition =
          startPosition ?? fullItem.userData.playBackPosition;

      final options = {
        PlaybackType.directStream,
        PlaybackType.transcode,
        if (firstItemIsSynced) PlaybackType.offline,
      };

      final isOffline = ref.read(offlineStateProvider);

      if (firstItemToPlay is AudioModel && firstItemIsSynced) {
        final offlinePlayback = await _createOfflinePlaybackModel(
          fullItem,
          item.streamModel,
          syncedItem,
          oldModel: oldModel,
          queueSource: effectiveQueueSource,
        );

        if (offlinePlayback != null) {
          diagnostics.record(attempt, stage,
              event: PlaybackEvent.succeeded,
              detail: 'offline',
              sourceKind: PlaybackSourceKind.localFile);
          return offlinePlayback;
        }
      }

      Future<PlaybackModel?> getOfflineModel() async {
        final model = await _createOfflinePlaybackModel(
          fullItem,
          item.streamModel,
          syncedItem,
          oldModel: oldModel,
          queueSource: effectiveQueueSource,
        );
        diagnostics.record(attempt, PlaybackStage.streamSelection,
            event:
                model == null ? PlaybackEvent.failed : PlaybackEvent.succeeded,
            detail: model == null ? 'offline_unavailable' : 'offline',
            sourceKind: PlaybackSourceKind.localFile);
        return model;
      }

      Future<PlaybackModel?> getServerModel(PlaybackType type) =>
          _createServerPlaybackModel(
            fullItem,
            item.streamModel,
            forcedPlaybackType ?? type,
            oldModel: oldModel,
            libraryQueue: queue,
            queueSource: effectiveQueueSource,
            startPosition: actualStartPosition,
            diagnosticAttempt: attempt,
            reportingCapture: reportingCapture,
          );

      if (((showPlaybackOptions || firstItemIsSynced) && !isOffline) &&
          context != null) {
        final playbackType = await showPlaybackTypeSelection(
          context: context,
          options: options,
        );

        if (!context.mounted || playbackType == null) {
          diagnostics.record(attempt, PlaybackStage.lifecycle,
              cancelled: true, detail: 'selection_cancelled');
          return null;
        }

        return switch (playbackType) {
          PlaybackType.directStream ||
          PlaybackType.transcode ||
          PlaybackType.tv =>
            await getServerModel(playbackType),
          PlaybackType.offline => await getOfflineModel(),
        };
      }

      if (isOffline) {
        return await getOfflineModel();
      }

      return await getServerModel(PlaybackType.directStream) ??
          await getOfflineModel();
    } catch (error) {
      diagnostics.record(attempt, stage,
          event: PlaybackEvent.failed,
          errorClass: error.runtimeType.toString(),
          timedOut: error is TimeoutException,
          detail: step);
      return null;
    }
  }

  Future<PlaybackModel?> _createServerPlaybackModel(
    ItemBaseModel item,
    MediaStreamsModel? streamModel,
    PlaybackType? type, {
    PlaybackModel? oldModel,
    required List<ItemBaseModel> libraryQueue,
    PlaybackQueueSource? queueSource,
    Duration? startPosition,
    required PlaybackAttemptRef diagnosticAttempt,
    PlaybackReportingCapture? reportingCapture,
  }) async {
    if (reportingCapture != null && !reportingCapture.isCurrent) return null;
    final diagnostics = PlaybackDiagnostics.instance;
    final attempt = diagnosticAttempt;
    var stage = PlaybackStage.playbackInfo;
    var step = 'playback_info_request';
    diagnostics.record(attempt, stage,
        event: PlaybackEvent.started, detail: step);
    try {
      final userId = ref.read(userProvider)?.id;
      if (userId?.isEmpty == true) {
        diagnostics.record(attempt, stage,
            event: PlaybackEvent.failed, detail: 'missing_user');
        return null;
      }

      final newStreamModel = streamModel ?? item.streamModel;
      final videoPlayerSettings = ref.read(videoPlayerSettingsProvider);
      final maxBitRate = selectPlaybackBitrate(
        homeInternet: ref.read(connectivityStatusProvider).homeInternet,
        maxHomeBitrate: videoPlayerSettings.maxHomeBitrate,
        maxInternetBitrate: videoPlayerSettings.maxInternetBitrate,
      );

      Map<Bitrate, bool> qualityOptions = getVideoQualityOptions(
        VideoQualitySettings(
          maxBitRate: maxBitRate,
          videoBitRate: newStreamModel?.videoStreams.firstOrNull?.bitRate ?? 0,
          videoCodec: newStreamModel?.videoStreams.firstOrNull?.codec,
        ),
      );

      final audioStreamIndex = selectAudioStream(
          ref.read(userProvider.select((value) =>
              value?.userConfiguration?.rememberAudioSelections ?? true)),
          oldModel?.mediaStreams?.currentAudioStream,
          newStreamModel?.audioStreams,
          newStreamModel?.defaultAudioStreamIndex);

      final subStreamIndex = selectSubStream(
          ref.read(userProvider.select((value) =>
              value?.userConfiguration?.rememberSubtitleSelections ?? true)),
          oldModel?.mediaStreams?.currentSubStream,
          newStreamModel?.subStreams,
          newStreamModel?.defaultSubStreamIndex);

//Native player does not allow for loading external subtitles with transcoding
      final isNativePlayer =
          videoPlayerSettings.wantedPlayer == PlayerOptions.nativePlayer;
      final isExternalSub =
          newStreamModel?.currentSubStream?.isExternal == true;

      final requestedBitrate =
          qualityOptions.enabledFirst.keys.firstOrNull?.bitRate;
      final profileKind = type == PlaybackType.tv && !isNativePlayer
          ? 'tv_unspecified'
          : kIsWeb
              ? 'web'
              : isNativePlayer
                  ? 'native_sdr'
                  : 'default_av';
      diagnostics.record(attempt, stage,
          detail:
              'profile=$profileKind pref=${videoPlayerSettings.wantedPlayer.name} '
              'direct_req=${type != PlaybackType.transcode} bitrate=${requestedBitrate ?? 0}');
      final playbackRequest = PlaybackInfoDto(
        startTimeTicks: startPosition?.toRuntimeTicks,
        audioStreamIndex: audioStreamIndex,
        subtitleStreamIndex: subStreamIndex,
        enableTranscoding: true,
        autoOpenLiveStream: true,
        deviceProfile: playbackDeviceProfile(
          profile: ref.read(videoProfileProvider),
          player: videoPlayerSettings.wantedPlayer,
          liveTv: type == PlaybackType.tv,
        ),
        userId: userId,
        enableDirectPlay: type != PlaybackType.transcode,
        enableDirectStream: type != PlaybackType.transcode,
        alwaysBurnInSubtitleWhenTranscoding: isNativePlayer && isExternalSub,
        maxStreamingBitrate: requestedBitrate,
        mediaSourceId: newStreamModel?.currentVersionStream?.id,
      );
      final Response<PlaybackInfoResponse>? response =
          reportingCapture == null || type == PlaybackType.tv
              ? await api.itemsItemIdPlaybackInfoPost(
                  itemId: item.id, body: playbackRequest)
              : await reportingCapture.negotiatePlaybackInfo(
                  itemId: item.id, body: playbackRequest);
      if (response == null) return null;

      PlaybackInfoResponse? playbackInfo = response.body;
      if (reportingCapture != null && !reportingCapture.isCurrent) return null;

      if (playbackInfo == null) {
        diagnostics.record(attempt, stage,
            event: PlaybackEvent.failed,
            httpStatus: response.statusCode,
            detail: 'empty_playback_info');
        return null;
      }
      diagnostics.record(attempt, stage,
          event: PlaybackEvent.succeeded,
          httpStatus: response.statusCode,
          detail: step);
      stage = PlaybackStage.streamSelection;
      step = 'media_source';
      diagnostics.record(attempt, stage,
          event: PlaybackEvent.started, detail: step);

      final binding = resolvePlaybackMediaSource(
        playbackInfo.mediaSources,
        requestedMediaSourceId: newStreamModel?.currentVersionStream?.id,
        subtitleStreamIndex: subStreamIndex,
      );
      final selectedSource = binding.selection;
      if (selectedSource == null) {
        diagnostics.record(attempt, stage,
            event: PlaybackEvent.failed,
            // Fixed short codes survive conservative opaque-ID redaction;
            // never put source IDs, indexes, or server metadata in this field.
            detail: switch (binding.issue) {
              PlaybackSourceBindingIssue.missingSources =>
                'source_list_missing',
              PlaybackSourceBindingIssue.missingSourceId => 'source_id_missing',
              PlaybackSourceBindingIssue.missingRequestedSource =>
                'source_missing',
              PlaybackSourceBindingIssue.ambiguousSourceId =>
                'source_id_duplicate',
              PlaybackSourceBindingIssue.ambiguousSources => 'source_ambiguous',
              PlaybackSourceBindingIssue.missingSubtitle => 'subtitle_missing',
              PlaybackSourceBindingIssue.ambiguousSubtitle =>
                'subtitle_duplicate',
              null => 'source_unavailable',
            });
        return null;
      }
      final mediaSource = selectedSource.source;

      diagnostics.record(attempt, stage,
          detail: 'direct_play=${mediaSource.supportsDirectPlay == true} '
              'direct_stream=${mediaSource.supportsDirectStream == true} '
              'transcode=${mediaSource.supportsTranscoding == true}');
      diagnostics.record(attempt, stage,
          detail:
              'transcode reasons: ${playbackTranscodeReasonSummary(mediaSource.transcodingUrl)}');
      if (!nativeTvServerAllowsDirectPlayback(
        nativePlayer: isNativePlayer,
        liveTv: type == PlaybackType.tv,
        source: mediaSource,
      )) {
        diagnostics.record(attempt, stage,
            event: PlaybackEvent.failed, detail: 'native_tv_server_policy');
        return null;
      }

      final mediaStreamsWithUrls = _streamsForSelectedSource(
        selectedSource,
        audioStreamIndex: audioStreamIndex,
      );

      // Chapters/preview thumbnails are nullable and must not indefinitely
      // delay the already-authorized main stream. Both share one short budget.
      step = 'optional_metadata';
      final metadataClock = Stopwatch()..start();
      Duration remaining() {
        final value = _optionalMetadataBudget - metadataClock.elapsed;
        return value.isNegative ? Duration.zero : value;
      }

      final segmentsFuture = _segmentsLoader.load<Response<MediaSegmentsModel>>(
        () => api.mediaSegmentsGet(id: item.id),
        attempt: attempt,
        step: 'media_segments',
        budget: remaining(),
        statusCode: (response) => response.statusCode,
        accept: (response) => response.isSuccessful,
      );
      final trickPlayFuture = _trickPlayLoader.load<Response<TrickPlayModel>>(
        () => api.getTrickPlay(item: item, ref: ref),
        attempt: attempt,
        step: 'trick_play',
        budget: remaining(),
        statusCode: (response) => response.statusCode,
        accept: (response) => response.isSuccessful,
      );
      final mediaSegments = await segmentsFuture;
      final trickPlayResp = await trickPlayFuture;
      if (reportingCapture != null && !reportingCapture.isCurrent) return null;
      metadataClock.stop();

      final trickPlay = trickPlayResp?.body;
      final chapters = item.overview.chapters ?? [];

      step = 'stream_url';
      final mediaPath = isValidVideoUrl(mediaSource.path ?? "");

      if (type == PlaybackType.tv && mediaPath != null) {
        final tvModel = TvPlaybackModel(
          channel: item as ChannelModel,
          isNativePlayerBackend: isNativePlayer,
          item: item,
          queue: libraryQueue,
          playbackQueue: oldModel?.playbackQueue,
          queueSource: queueSource,
          playbackInfo: playbackInfo,
          media: Media(url: mediaPath),
        );
        diagnostics.record(attempt, stage,
            event: PlaybackEvent.succeeded,
            detail: 'live_direct',
            sourceKind: PlaybackSourceKind.networkStream);
        return tvModel;
      }

      if ((mediaSource.supportsDirectStream ?? false) ||
          (mediaSource.supportsDirectPlay ?? false)) {
        final Map<String, String?> directOptions = {
          'Static': 'true',
          'mediaSourceId': mediaSource.id,
          'ApiKey': ref.read(userProvider)?.credentials.token,
        };

        if (mediaSource.eTag != null) {
          directOptions['Tag'] = mediaSource.eTag;
        }

        if (mediaSource.liveStreamId != null) {
          directOptions['LiveStreamId'] = mediaSource.liveStreamId;
        }

        final playbackUrl = buildServerUrl(
          ref,
          pathSegments: ['Videos', mediaSource.id!, 'stream'],
          queryParameters: directOptions,
        );

        diagnostics.record(attempt, stage,
            event: PlaybackEvent.succeeded,
            detail: 'direct_stream',
            sourceKind: PlaybackSourceKind.networkStream);
        return DirectPlaybackModel(
          reportingScope: reportingCapture?.bind(
              itemId: item.id,
              mediaSourceId: mediaStreamsWithUrls.currentVersionStream?.id,
              playSessionId: playbackInfo.playSessionId,
              playlistItemId: _reportingPlaylistItemId(playbackInfo)),
          item: item,
          queue: libraryQueue,
          playbackQueue: oldModel?.playbackQueue,
          queueSource: queueSource,
          mediaSegments: mediaSegments?.body,
          chapters: chapters,
          playbackInfo: playbackInfo,
          trickPlay: trickPlay,
          media: Media(url: mediaPath ?? playbackUrl),
          mediaStreams: mediaStreamsWithUrls,
          bitRateOptions: qualityOptions,
        );
      } else if ((mediaSource.supportsTranscoding ?? false) &&
          mediaSource.transcodingUrl != null) {
        diagnostics.record(attempt, stage,
            event: PlaybackEvent.succeeded,
            detail: 'transcode',
            sourceKind: PlaybackSourceKind.networkStream);
        return TranscodePlaybackModel(
          reportingScope: reportingCapture?.bind(
              itemId: item.id,
              mediaSourceId: mediaStreamsWithUrls.currentVersionStream?.id,
              playSessionId: playbackInfo.playSessionId,
              playlistItemId: _reportingPlaylistItemId(playbackInfo)),
          item: item,
          queue: libraryQueue,
          playbackQueue: oldModel?.playbackQueue,
          queueSource: queueSource,
          mediaSegments: mediaSegments?.body,
          chapters: chapters,
          trickPlay: trickPlay,
          playbackInfo: playbackInfo,
          media: Media(
              url:
                  buildServerUrl(ref, relativeUrl: mediaSource.transcodingUrl)),
          mediaStreams: mediaStreamsWithUrls,
          bitRateOptions: qualityOptions,
        );
      }
      diagnostics.record(attempt, stage,
          event: PlaybackEvent.failed, detail: 'no_compatible_stream');
      return null;
    } catch (error) {
      diagnostics.record(attempt, stage,
          event: PlaybackEvent.failed,
          errorClass: error.runtimeType.toString(),
          timedOut: error is TimeoutException,
          detail: step);
      return null;
    }
  }

  String? isValidVideoUrl(String path) {
    Uri? uri = Uri.tryParse(path);
    return (uri != null && uri.hasScheme && uri.hasAuthority) ? path : null;
  }

  Future<List<ItemBaseModel>> collectQueue(ItemBaseModel model) async {
    switch (model) {
      case EpisodeModel _:
      case SeriesModel _:
      case SeasonModel _:
        List<EpisodeModel> episodeList =
            ((await fetchEpisodesFromSeries(model.streamId)).body ?? [])
              ..removeWhere(
                  (element) => element.status != EpisodeStatus.available);
        return episodeList;
      default:
        return [];
    }
  }

  Future<Response<List<EpisodeModel>>> fetchEpisodesFromSeries(
      String seriesId) async {
    final response = await api.showsSeriesIdEpisodesGet(
      seriesId: seriesId,
      fields: [
        ItemFields.overview,
        ItemFields.originaltitle,
        ItemFields.mediastreams,
        ItemFields.mediasources,
        ItemFields.mediasourcecount,
        ItemFields.width,
        ItemFields.height,
      ],
    );
    return Response(
        response.base,
        (response.body?.items
                ?.map((e) => EpisodeModel.fromBaseDto(e, ref))
                .toList() ??
            []));
  }

  Future<void> shouldReload(PlaybackModel playbackModel) async {
    if (playbackModel is OfflinePlaybackModel) {
      return;
    }
    // Android applies Native TV track choices locally in the same UI handler.
    // Keep its TV model instead of entering the generic VOD reload path.
    if (playbackModel is TvPlaybackModel &&
        playbackModel.isNativePlayerBackend) {
      return;
    }

    // Room track choices are applied locally by SyncPlayPlaybackModel. Generic
    // VOD renegotiation replaces that model and releases the room-owned player
    // session even when only the local subtitle/audio selection changed.
    if (playbackModel.serverManagedQueue) return;
    final reportingCapture = playbackModel.reportingScope?.capture;
    if (reportingCapture != null && !reportingCapture.isCurrent) return;

    final item = playbackModel.item;

    final userId = ref.read(userProvider)?.id;
    if (userId?.isEmpty == true) return;

    final ownerModel = ref.read(playBackModel);
    final ownerPlayer = ref.read(videoPlayerProvider);
    if (!identical(ownerModel, playbackModel) || ownerPlayer.syncPlayActive) {
      return;
    }
    final ownerStopEpoch = ownerPlayer.playbackStopEpoch;
    final ownerRenderer =
        reportingCapture == null ? null : ownerPlayer.rendererGeneration;
    final ownerRoom = ownerPlayer.syncPlayCommands;
    PlaybackModel? authorizedReplacement;
    bool stillOwnsPlayback({bool allowReplacement = false}) {
      final currentModel = ref.read(playBackModel);
      return identical(ref.read(videoPlayerProvider), ownerPlayer) &&
          (reportingCapture?.isCurrent ?? true) &&
          (ownerRenderer == null ||
              ownerPlayer.rendererGeneration == ownerRenderer) &&
          ownerPlayer.playbackStopEpoch == ownerStopEpoch &&
          identical(ownerPlayer.syncPlayCommands, ownerRoom) &&
          !ownerPlayer.syncPlayActive &&
          (identical(currentModel, ownerModel) ||
              (allowReplacement &&
                  authorizedReplacement != null &&
                  identical(currentModel, authorizedReplacement)));
    }

    final currentPosition =
        ref.read(mediaPlaybackProvider.select((value) => value.position));

    final audioIndex = selectAudioStream(
        ref.read(userProvider.select((value) =>
            value?.userConfiguration?.rememberAudioSelections ?? true)),
        playbackModel.mediaStreams?.currentAudioStream,
        playbackModel.audioStreams,
        playbackModel.mediaStreams?.defaultAudioStreamIndex);
    final subIndex = selectSubStream(
        ref.read(userProvider.select((value) =>
            value?.userConfiguration?.rememberSubtitleSelections ?? true)),
        playbackModel.mediaStreams?.currentSubStream,
        playbackModel.subStreams,
        playbackModel.mediaStreams?.defaultSubStreamIndex);

    if (!stillOwnsPlayback()) return;
    final playbackRequest = PlaybackInfoDto(
      startTimeTicks: currentPosition.toRuntimeTicks,
      audioStreamIndex: audioIndex,
      enableDirectPlay: true,
      enableDirectStream: true,
      subtitleStreamIndex: subIndex,
      enableTranscoding: true,
      autoOpenLiveStream: true,
      deviceProfile: ref.read(videoProfileProvider),
      userId: userId,
      maxStreamingBitrate: playbackModel
          .bitRateOptions.enabledFirst.entries.firstOrNull?.key.bitRate,
      mediaSourceId: playbackModel.mediaStreams?.currentVersionStream?.id,
    );
    final Response<PlaybackInfoResponse>? response = reportingCapture == null
        ? await api.itemsItemIdPlaybackInfoPost(
            itemId: item.id, body: playbackRequest)
        : await reportingCapture.negotiatePlaybackInfo(
            itemId: item.id, body: playbackRequest);
    if (response == null) return;

    if (!stillOwnsPlayback()) return;
    PlaybackInfoResponse playbackInfo = response.bodyOrThrow;

    final binding = resolvePlaybackMediaSource(
      playbackInfo.mediaSources,
      requestedMediaSourceId:
          playbackModel.mediaStreams?.currentVersionStream?.id,
      subtitleStreamIndex: subIndex,
    );
    final selectedSource = binding.selection;
    if (selectedSource == null) {
      throw const SubtitleSelectionFailure(
          SubtitleSelectionFailureReason.unavailable);
    }
    final mediaSource = selectedSource.source;
    final mediaStreamsWithUrls = _streamsForSelectedSource(
      selectedSource,
      audioStreamIndex: audioIndex,
    );

    PlaybackModel? newModel;

    if ((mediaSource.supportsDirectStream ?? false) ||
        (mediaSource.supportsDirectPlay ?? false)) {
      final Map<String, String?> directOptions = {
        'Static': 'true',
        'mediaSourceId': mediaSource.id,
        'ApiKey': ref.read(userProvider)?.credentials.token,
      };

      if (mediaSource.eTag != null) {
        directOptions['Tag'] = mediaSource.eTag;
      }

      if (mediaSource.liveStreamId != null) {
        directOptions['LiveStreamId'] = mediaSource.liveStreamId;
      }

      final directPlay = buildServerUrl(
        ref,
        pathSegments: ['Videos', mediaSource.id ?? '', 'stream'],
        queryParameters: directOptions,
      );

      final mediaPath = isValidVideoUrl(mediaSource.path ?? "");

      newModel = DirectPlaybackModel(
        reportingScope: reportingCapture?.bind(
            itemId: playbackModel.item.id,
            mediaSourceId: mediaStreamsWithUrls.currentVersionStream?.id,
            playSessionId: playbackInfo.playSessionId,
            playlistItemId: _reportingPlaylistItemId(playbackInfo)),
        item: playbackModel.item,
        queue: playbackModel.queue,
        playbackQueue: playbackModel.playbackQueue,
        mediaSegments: playbackModel.mediaSegments,
        chapters: playbackModel.chapters,
        playbackInfo: playbackInfo,
        trickPlay: playbackModel.trickPlay,
        media: Media(url: mediaPath ?? directPlay),
        mediaStreams: mediaStreamsWithUrls,
        bitRateOptions: playbackModel.bitRateOptions,
      );
    } else if ((mediaSource.supportsTranscoding ?? false) &&
        mediaSource.transcodingUrl != null) {
      newModel = TranscodePlaybackModel(
        reportingScope: reportingCapture?.bind(
            itemId: playbackModel.item.id,
            mediaSourceId: mediaStreamsWithUrls.currentVersionStream?.id,
            playSessionId: playbackInfo.playSessionId,
            playlistItemId: _reportingPlaylistItemId(playbackInfo)),
        item: playbackModel.item,
        queue: playbackModel.queue,
        playbackQueue: playbackModel.playbackQueue,
        mediaSegments: playbackModel.mediaSegments,
        chapters: playbackModel.chapters,
        playbackInfo: playbackInfo,
        trickPlay: playbackModel.trickPlay,
        media: Media(
            url: buildServerUrl(ref, relativeUrl: mediaSource.transcodingUrl)),
        mediaStreams: mediaStreamsWithUrls,
        bitRateOptions: playbackModel.bitRateOptions,
      );
    }
    if (newModel == null) return;
    if (newModel.runtimeType != playbackModel.runtimeType ||
        newModel is TranscodePlaybackModel) {
      if (!stillOwnsPlayback()) return;
      // This exact response-owned replacement may publish itself during open.
      // A menu operation's old-model guard cannot own that handoff, and an
      // unrelated same-item replacement must never inherit it.
      authorizedReplacement = newModel;
      // A pause or seek while negotiation was pending is newer user intent.
      final reloadPosition =
          ref.read(mediaPlaybackProvider.select((value) => value.position));
      final reloadPlaying =
          ref.read(mediaPlaybackProvider.select((value) => value.playing));
      await ref.read(videoPlayerProvider.notifier).loadPlaybackItem(
          newModel, reloadPosition,
          playWhenReady: reloadPlaying,
          isCurrent: () => stillOwnsPlayback(allowReplacement: true));
    }
  }
}
