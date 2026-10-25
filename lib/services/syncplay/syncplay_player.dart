import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart'
    hide SyncPlayQueueItem;
import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/items/item_shared_models.dart';
import 'package:fladder/models/items/media_streams_model.dart';
import 'package:fladder/models/playback/playback_model.dart';
import 'package:fladder/models/playback/playback_queue_state.dart';
import 'package:fladder/models/video_stream_model.dart';
import 'package:fladder/profiles/default_profile.dart';
import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/services/syncplay/syncplay_models.dart';
import 'package:fladder/util/subtitle_delivery.dart';
import 'package:fladder/util/bitrate_helper.dart';
import 'package:fladder/wrappers/media_control_wrapper.dart';

/// One playback session shares ownership across immutable model copies.
class SyncPlayPlaybackApiOwner {
  SyncPlayPlaybackApiOwner(this.api, {this.ownsApi = false});
  final JellyfinOpenApi api;
  final bool ownsApi;
  bool closed = false;
  void close() {
    if (closed) return;
    closed = true;
    if (ownsApi) {
      try {
        api.client.httpClient.close();
      } catch (_) {/* No raw transport errors. */}
      try {
        api.client.dispose();
      } catch (_) {/* Still release both owners. */}
    }
  }
}

/// Room commands and the retained playback model have separate lifetimes.
class SyncPlayPlayerAdapter implements SyncPlayPlayerPort {
  SyncPlayPlayerAdapter(
      {required this.ref,
      required this.account,
      required this.api,
      required this.isCurrent,
      this.queue,
      this.createPlaybackApi,
      this.isPlaybackIdentityCurrent,
      this.playbackPrepared,
      this.prepareForPlayback,
      this.onLoaded,
      this.playbackProfile});

  final Ref ref;
  final AccountModel account;
  final JellyfinOpenApi api;
  final bool Function() isCurrent;
  final SyncPlayQueue? Function()? queue;
  final JellyfinOpenApi Function()? createPlaybackApi;
  final bool Function()? isPlaybackIdentityCurrent;
  final bool Function()? playbackPrepared;
  final Future<bool> Function()? prepareForPlayback;
  final void Function()? onLoaded;
  final DeviceProfile? playbackProfile;
  String? _mediaId;
  String? _playlistItemId;
  int _loadEpoch = 0;
  Completer<void> _actionCancelled = Completer<void>();
  // Jellyfin's Ready position tolerance is 500ms. Avoid manufacturing a seek
  // (and HTML waiting/canplay pulse) for an already aligned Pause/Unpause.
  static const _alignmentTolerance = Duration(milliseconds: 500);
  static const _maximumInitialAlignment = Duration(seconds: 5);
  int _beginAction() {
    _actionCancelled.complete();
    _actionCancelled = Completer<void>();
    return ++_loadEpoch;
  }

  void cancelPendingActions() {
    _beginAction();
  }

  Future<void> _waitForReady(Duration target, bool Function() current) async {
    return _waitForState(() {
      final state = _player.lastState;
      return state != null &&
          !state.buffering &&
          (state.position - target).abs() <= _alignmentTolerance;
    }, current);
  }

  Future<void> _alignLoadedMedia(
      Duration target, bool Function() current) async {
    // A returned open request is not yet a ready decoded stream. Only correct
    // a current, non-buffering load with real duration (or already aligned).
    await _waitForState(() {
      final state = _player.lastState;
      return state != null &&
          !state.buffering &&
          (state.duration > Duration.zero ||
              (state.position - target).abs() <= _alignmentTolerance);
    }, current);
    if (!current()) return;
    final position = _player.lastState?.position;
    if (position == null) return;
    final difference = (position - target).abs();
    if (difference <= _alignmentTolerance ||
        difference > _maximumInitialAlignment) {
      return;
    }
    final cancelled = _actionCancelled.future;
    // Exactly one correction, inside the controller's existing load budget.
    // Cancel releases this wait; it cannot revoke a native seek already sent.
    await Future.any([
      Future<void>.sync(() => _player.seekFromSyncPlay(target)),
      cancelled,
    ]);
  }

  Future<void> _waitForState(
      bool Function() ready, bool Function() current) async {
    if (!current() || ready()) return;
    final settled = Completer<void>();
    final cancelled = _actionCancelled.future;
    final subscription = _player.stateStream.listen((_) {
      if ((!current() || ready()) && !settled.isCompleted) settled.complete();
    });
    try {
      if (current() && !ready()) await Future.any([settled.future, cancelled]);
    } finally {
      await subscription.cancel();
    }
  }

  MediaControlsWrapper get _player => ref.read(videoPlayerProvider);
  @override
  String? get mediaId => _mediaId;
  @override
  String? get playlistItemId => _playlistItemId;
  @override
  Duration get position => isCurrent() && (playbackPrepared?.call() ?? true)
      ? (_player.lastState?.position ?? Duration.zero)
      : Duration.zero;
  @override
  bool get isPlaying =>
      isCurrent() &&
      (playbackPrepared?.call() ?? true) &&
      _player.lastState?.playing == true;
  bool get isBuffering =>
      isCurrent() &&
      (playbackPrepared?.call() ?? true) &&
      _player.lastState?.buffering == true;

  @override
  Future<void> applyRemote(SyncPlayPlayerAction action) async {
    if (!isCurrent()) return;
    if (action.type == SyncPlayPlayerActionType.load) {
      final entry = action.queueItem;
      if (entry == null) {
        throw const SyncPlayFailure(SyncPlayFailureCode.player);
      }
      final epoch = _beginAction();
      bool current() => isCurrent() && epoch == _loadEpoch;
      // Resolve the room item using this participant's account before touching
      // existing playback or lazily preparing a built-in backend.
      final model = await createSyncPlayPlaybackModel(
          ref: ref,
          api: createPlaybackApi?.call() ?? api,
          account: account,
          queueItem: entry,
          position: action.position,
          isCurrent: current,
          queue: queue,
          ownsApi: createPlaybackApi != null,
          profile: playbackProfile,
          isPlaybackIdentityCurrent: isPlaybackIdentityCurrent ?? isCurrent,
          isActuallyPlaying: () => _player.lastState?.playing == true);
      var retained = false;
      try {
        if (!current()) return;
        final notifier = ref.read(videoPlayerProvider.notifier);
        final ready =
            await (prepareForPlayback?.call() ?? notifier.waitUntilReady());
        if (!current()) return;
        if (!ready || !_player.supportsSyncPlay) {
          throw const SyncPlayFailure(SyncPlayFailureCode.player);
        }
        await _player.pauseFromSyncPlay();
        if (!current()) return;
        final loaded = await notifier.loadPlaybackItem(model, action.position,
            playWhenReady: false, isCurrent: current);
        if (!current()) return;
        if (!loaded) throw const SyncPlayFailure(SyncPlayFailureCode.player);
        await _alignLoadedMedia(action.position, current);
        if (!current()) return;
        await _waitForReady(action.position, current);
        if (!current()) return;
        _mediaId = entry.mediaId;
        _playlistItemId = entry.playlistItemId;
        retained = true;
        onLoaded?.call();
      } finally {
        if (!retained) model.dispose();
      }
      return;
    }
    if (!(playbackPrepared?.call() ?? true)) return;
    if (action.type == SyncPlayPlayerActionType.stop) {
      final epoch = _beginAction();
      await _player.stopFromSyncPlay();
      if (!isCurrent() || epoch != _loadEpoch) return;
      _mediaId = null;
      _playlistItemId = null;
      return;
    }
    final epoch = _beginAction();
    bool current() => isCurrent() && epoch == _loadEpoch;
    if (action.type != SyncPlayPlayerActionType.unpause) {
      await _player.pauseFromSyncPlay();
      if (!current()) return;
    }
    final offset =
        (_player.lastState?.position ?? Duration.zero) - action.position;
    if (action.type == SyncPlayPlayerActionType.seek ||
        offset.abs() > _alignmentTolerance) {
      await _player.seekFromSyncPlay(action.position);
      if (!current()) return;
    }
    await _waitForReady(action.position, current);
    if (!current()) return;
    if (action.type == SyncPlayPlayerActionType.unpause) {
      await _player.playFromSyncPlay();
    }
  }
}

/// Build only through the immutable account/API snapshot. No normal playback
/// helper, provider-selected service, offline fallback, or local queue expansion.
Future<SyncPlayPlaybackModel> createSyncPlayPlaybackModel({
  required Ref ref,
  required JellyfinOpenApi api,
  required AccountModel account,
  required SyncPlayQueueItem queueItem,
  required Duration position,
  required bool Function() isCurrent,
  SyncPlayQueue? Function()? queue,
  bool ownsApi = false,
  bool Function()? isPlaybackIdentityCurrent,
  bool Function()? isActuallyPlaying,
  DeviceProfile? profile,
}) async {
  final apiOwner = SyncPlayPlaybackApiOwner(api, ownsApi: ownsApi);
  try {
    void check() {
      if (!isCurrent()) throw const SyncPlayFailure(SyncPlayFailureCode.player);
    }

    check();
    final deviceProfile = profile ?? ref.read(videoProfileProvider);
    final response =
        await api.itemsItemIdGet(itemId: queueItem.mediaId, userId: account.id);
    check();
    final dto = response.body;
    if (!response.isSuccessful ||
        dto == null ||
        dto.id != queueItem.mediaId ||
        dto.mediaType != MediaType.video) {
      throw const SyncPlayFailure(SyncPlayFailureCode.player);
    }
    final playback = await api.itemsItemIdPlaybackInfoPost(
        itemId: queueItem.mediaId,
        body: PlaybackInfoDto(
            userId: account.id,
            startTimeTicks: syncPlayTicks(position),
            enableDirectPlay: true,
            enableDirectStream: true,
            enableTranscoding: true,
            autoOpenLiveStream: true,
            deviceProfile: deviceProfile));
    check();
    final info = playback.body;
    final source = info?.mediaSources?.firstOrNull;
    if (!playback.isSuccessful ||
        source?.id == null ||
        source == null ||
        info == null) {
      throw const SyncPlayFailure(SyncPlayFailureCode.player);
    }
    final direct = source.supportsDirectPlay == true ||
        source.supportsDirectStream == true;
    final Uri? uri = direct
        ? buildServerUriFromBase(account.credentials.url, pathSegments: [
            'Videos',
            queueItem.mediaId,
            'stream'
          ], queryParameters: {
            'Static': 'true',
            'mediaSourceId': source.id,
            'ApiKey': account.credentials.token,
            'PlaySessionId': info.playSessionId
          })
        : source.supportsTranscoding == true && source.transcodingUrl != null
            ? _capturedUri(account, source.transcodingUrl!)
            : null;
    if (uri == null) throw const SyncPlayFailure(SyncPlayFailureCode.player);
    final streams = _capturedStreams(source, account, transcoded: !direct);
    check();
    return SyncPlayPlaybackModel(
        item: ItemBaseModel.fromBaseDto(dto, ref),
        media: Media(url: uri.toString()),
        playbackInfo: info,
        mediaStreams: streams,
        api: api,
        isCurrent: isPlaybackIdentityCurrent ?? isCurrent,
        queueItem: queueItem,
        groupQueue: queue,
        playMethod: direct ? PlayMethod.directstream : PlayMethod.transcode,
        apiOwner: apiOwner,
        isActuallyPlaying: isActuallyPlaying);
  } catch (_) {
    apiOwner.close();
    rethrow;
  }
}

Uri? _capturedUri(AccountModel account, String relativeUrl) {
  final base = Uri.tryParse(account.credentials.url);
  final uri = buildServerUriFromBase(account.credentials.url,
      relativeUrl: relativeUrl,
      queryParameters: {'ApiKey': account.credentials.token});
  if (base == null ||
      uri == null ||
      base.scheme != uri.scheme ||
      base.host != uri.host ||
      base.port != uri.port) {
    return null;
  }
  // Add the snapshot token only after rejecting a different origin.
  final query = {...uri.queryParameters, 'ApiKey': account.credentials.token}
    ..remove('api_key');
  return uri.replace(queryParameters: query);
}

MediaStreamsModel _capturedStreams(MediaSourceInfo source, AccountModel account,
    {bool transcoded = false}) {
  final streams = source.mediaStreams ?? const <MediaStream>[];
  return MediaStreamsModel(
      defaultAudioStreamIndex: source.defaultAudioStreamIndex,
      defaultSubStreamIndex: source.defaultSubtitleStreamIndex,
      versionStreams: [
        VersionStreamModel(
            name: source.name ?? '',
            index: 0,
            id: source.id,
            defaultAudioStreamIndex: source.defaultAudioStreamIndex,
            defaultSubStreamIndex: source.defaultSubtitleStreamIndex,
            videoStreams: streams
                .where((s) => s.type == MediaStreamType.video)
                .map(VideoStreamModel.fromMediaStream)
                .toList(),
            audioStreams: streams
                .where((s) => s.type == MediaStreamType.audio)
                .map(AudioStreamModel.fromMediaStream)
                .toList(),
            subStreams: streams
                .where((s) => s.type == MediaStreamType.subtitle)
                .map((s) {
              final delivery =
                  subtitleDeliveryUrl(s.deliveryUrl, s.codec ?? '');
              return SubStreamModel(
                  name: s.title ?? '',
                  id: '${source.id}/${s.index}',
                  title: s.title ?? '',
                  displayTitle: s.displayTitle ?? '',
                  language: s.language ?? '',
                  codec: s.codec ?? '',
                  index: s.index ?? -1,
                  isDefault: s.isDefault ?? false,
                  isExternal: s.isExternal == true ||
                      (transcoded &&
                          s.deliveryMethod ==
                              SubtitleDeliveryMethod.$external &&
                          delivery != null),
                  supportsExternalStream: s.supportsExternalStream ?? false,
                  url: delivery == null
                      ? null
                      : _capturedUri(account, delivery)?.toString());
            }).toList())
      ]);
}

enum SyncPlayTrackSelectionFailureReason { requiresServerReload, unavailable }

/// A local track choice must never silently replace a room playback session.
class SyncPlayTrackSelectionFailure implements Exception {
  const SyncPlayTrackSelectionFailure(this.reason);
  final SyncPlayTrackSelectionFailureReason reason;
  @override
  String toString() => 'SyncPlayTrackSelectionFailure: ${reason.name}';
}

/// Session reporting remains bound to the account which joined the room.
class SyncPlayPlaybackModel extends PlaybackModel {
  SyncPlayPlaybackModel(
      {required super.item,
      required super.media,
      required super.playbackInfo,
      required super.mediaStreams,
      required this.api,
      required this.isCurrent,
      required this.queueItem,
      this.groupQueue,
      required this.playMethod,
      SyncPlayPlaybackApiOwner? apiOwner,
      this.isActuallyPlaying})
      : _apiOwner = apiOwner ?? SyncPlayPlaybackApiOwner(api),
        super(queue: const []);

  final JellyfinOpenApi api;
  final bool Function() isCurrent;
  final SyncPlayQueueItem queueItem;
  final SyncPlayQueue? Function()? groupQueue;
  final PlayMethod playMethod;
  @override
  bool get isServerTranscoded => playMethod == PlayMethod.transcode;
  @override
  PlaybackType get playbackType =>
      isServerTranscoded ? PlaybackType.transcode : PlaybackType.directStream;
  final SyncPlayPlaybackApiOwner _apiOwner;
  final bool Function()? isActuallyPlaying;
  bool get _available => !_apiOwner.closed && isCurrent();
  @override
  void dispose() => _apiOwner.close();
  @override
  bool get serverManagedQueue => _available && groupQueue?.call() != null;
  @override
  bool get ownsPlaybackResources => true;
  @override
  ItemBaseModel? get nextVideo => null;
  @override
  ItemBaseModel? get previousVideo => null;
  @override
  List<SubStreamModel> get subStreams =>
      [SubStreamModel.no(), ...?mediaStreams?.subStreams];
  @override
  List<AudioStreamModel> get audioStreams =>
      [AudioStreamModel.no(), ...?mediaStreams?.audioStreams];
  List<QueueItem> get _wireQueue => (groupQueue?.call()?.items ?? [queueItem])
      .map((entry) =>
          QueueItem(id: entry.mediaId, playlistItemId: entry.playlistItemId))
      .toList();

  @override
  Future<PlaybackModel?> playbackStarted(Duration position, Ref ref) async {
    if (!_available) return null;
    await api.sessionsPlayingPost(
        body: PlaybackStartInfo(
            itemId: item.id,
            mediaSourceId: mediaStreams?.currentVersionStream?.id,
            playSessionId: playbackInfo?.playSessionId,
            playlistItemId: queueItem.playlistItemId,
            nowPlayingQueue: _wireQueue,
            canSeek: true,
            isPaused: !(isActuallyPlaying?.call() ?? false),
            playbackStartTimeTicks: syncPlayTicks(position),
            playMethod: playMethod));
    return null;
  }

  @override
  Future<PlaybackModel?> updatePlaybackPosition(
      Duration position, bool isPlaying, Ref ref) async {
    if (!_available) return null;
    await api.sessionsPlayingProgressPost(
        body: PlaybackProgressInfo(
            itemId: item.id,
            mediaSourceId: mediaStreams?.currentVersionStream?.id,
            playSessionId: playbackInfo?.playSessionId,
            playlistItemId: queueItem.playlistItemId,
            nowPlayingQueue: _wireQueue,
            canSeek: true,
            isPaused: !isPlaying,
            positionTicks: syncPlayTicks(position),
            playMethod: playMethod));
    return null;
  }

  @override
  Future<PlaybackModel?> playbackStopped(
      Duration position, Duration? totalDuration, Ref ref) async {
    if (!_available) return null;
    await api.sessionsPlayingStoppedPost(
        body: PlaybackStopInfo(
            itemId: item.id,
            mediaSourceId: mediaStreams?.currentVersionStream?.id,
            playSessionId: playbackInfo?.playSessionId,
            playlistItemId: queueItem.playlistItemId,
            nowPlayingQueue: _wireQueue,
            positionTicks: syncPlayTicks(position)));
    return null;
  }

  SyncPlayPlaybackModel _copy(
          {ItemBaseModel? item, MediaStreamsModel? streams}) =>
      SyncPlayPlaybackModel(
          item: item ?? this.item,
          media: media,
          playbackInfo: playbackInfo,
          mediaStreams: streams ?? mediaStreams,
          api: api,
          isCurrent: isCurrent,
          queueItem: queueItem,
          groupQueue: groupQueue,
          playMethod: playMethod,
          apiOwner: _apiOwner,
          isActuallyPlaying: isActuallyPlaying);
  @override
  PlaybackModel updateUserData(UserData userData) =>
      _copy(item: item.copyWith(userData: userData));
  @override
  PlaybackModel updatePlaybackQueue(PlaybackQueueState newQueue) => this;
  @override
  PlaybackModel copyWith() => _copy();
  @override
  Future<PlaybackModel> setQualityOption(Map<Bitrate, bool> map) async => this;
  @override
  Future<PlaybackModel> setSubtitle(
      SubStreamModel? model, MediaControlsWrapper player) async {
    if (!isCurrent()) return this;
    final wanted = model ?? defaultSubStream;
    if (isServerTranscoded) {
      final source = playbackInfo?.mediaSources?.firstWhereOrNull((source) =>
              source.id == mediaStreams?.currentVersionStream?.id) ??
          playbackInfo?.mediaSources?.firstOrNull;
      final sourceStreams = source?.mediaStreams ?? const <MediaStream>[];
      final burnedIn = sourceStreams.firstWhereOrNull((stream) =>
          stream.type == MediaStreamType.subtitle &&
          stream.index == source?.defaultSubtitleStreamIndex &&
          stream.deliveryMethod == SubtitleDeliveryMethod.encode);
      // Burned-in pixels cannot be changed by selecting a local decoder track.
      // Preserve the current stream, including initialization of that track.
      if (burnedIn != null) {
        if (wanted?.index == burnedIn.index) return this;
        throw const SyncPlayTrackSelectionFailure(
            SyncPlayTrackSelectionFailureReason.requiresServerReload);
      }
      final delivery = sourceStreams
          .firstWhereOrNull((stream) => stream.index == wanted?.index)
          ?.deliveryMethod;
      if (wanted != null && wanted.index >= 0) {
        if (delivery == SubtitleDeliveryMethod.encode) {
          throw const SyncPlayTrackSelectionFailure(
              SyncPlayTrackSelectionFailureReason.requiresServerReload);
        }
        if (delivery == SubtitleDeliveryMethod.drop ||
            delivery == SubtitleDeliveryMethod.hls) {
          if (model == null) return this;
          throw const SyncPlayTrackSelectionFailure(
              SyncPlayTrackSelectionFailureReason.unavailable);
        }
      }
    }
    final index = await player.setSubtitleTrack(model, this);
    if (!isCurrent()) return this;
    if (wanted != null && wanted.index >= 0 && index != wanted.index) {
      if (model == null) return this;
      throw const SyncPlayTrackSelectionFailure(
          SyncPlayTrackSelectionFailureReason.unavailable);
    }
    return _copy(streams: mediaStreams?.copyWith(defaultSubStreamIndex: index));
  }

  @override
  Future<PlaybackModel> setAudio(
      AudioStreamModel? model, MediaControlsWrapper player) async {
    if (!isCurrent()) return this;
    final index = await player.setAudioTrack(model, this);
    if (!isCurrent()) return this;
    return _copy(
        streams: mediaStreams?.copyWith(defaultAudioStreamIndex: index));
  }
}
