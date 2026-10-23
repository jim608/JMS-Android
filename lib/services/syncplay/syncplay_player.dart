import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart' hide SyncPlayQueueItem;
import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/items/item_shared_models.dart';
import 'package:fladder/models/items/media_streams_model.dart';
import 'package:fladder/models/playback/playback_model.dart';
import 'package:fladder/models/playback/playback_queue_state.dart';
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
      this.isPlaybackIdentityCurrent});

  final Ref ref;
  final AccountModel account;
  final JellyfinOpenApi api;
  final bool Function() isCurrent;
  final SyncPlayQueue? Function()? queue;
  final JellyfinOpenApi Function()? createPlaybackApi;
  final bool Function()? isPlaybackIdentityCurrent;
  String? _mediaId;
  String? _playlistItemId;
  int _loadEpoch = 0;
  void cancelPendingActions() {
    _loadEpoch++;
  }

  MediaControlsWrapper get _player => ref.read(videoPlayerProvider);
  @override
  String? get mediaId => _mediaId;
  @override
  String? get playlistItemId => _playlistItemId;
  @override
  Duration get position => isCurrent() ? (_player.lastState?.position ?? Duration.zero) : Duration.zero;
  @override
  bool get isPlaying => isCurrent() && _player.lastState?.playing == true;
  bool get isBuffering => isCurrent() && _player.lastState?.buffering == true;

  @override
  Future<void> applyRemote(SyncPlayPlayerAction action) async {
    if (!isCurrent()) return;
    if (action.type == SyncPlayPlayerActionType.load) {
      final entry = action.queueItem;
      if (entry == null) {
        throw const SyncPlayFailure(SyncPlayFailureCode.player);
      }
      final epoch = ++_loadEpoch;
      bool current() => isCurrent() && epoch == _loadEpoch;
      final notifier = ref.read(videoPlayerProvider.notifier);
      final ready = await notifier.waitUntilReady();
      if (!current()) return;
      if (!ready || !_player.supportsSyncPlay) {
        throw const SyncPlayFailure(SyncPlayFailureCode.player);
      }
      await _player.pauseFromSyncPlay();
      if (!current()) return;
      final model = await createSyncPlayPlaybackModel(
          ref: ref,
          api: createPlaybackApi?.call() ?? api,
          account: account,
          queueItem: entry,
          position: action.position,
          isCurrent: current,
          queue: queue,
          ownsApi: createPlaybackApi != null,
          isPlaybackIdentityCurrent: isPlaybackIdentityCurrent ?? isCurrent,
          isActuallyPlaying: () => _player.lastState?.playing == true);
      if (!current()) {
        model.dispose();
        return;
      }
      final bool loaded;
      try {
        loaded = await notifier.loadPlaybackItem(model, action.position, playWhenReady: false, isCurrent: current);
      } catch (_) {
        model.dispose();
        rethrow;
      }
      if (!current() || !loaded) {
        model.dispose();
        if (!current()) return;
        throw const SyncPlayFailure(SyncPlayFailureCode.player);
      }
      _mediaId = entry.mediaId;
      _playlistItemId = entry.playlistItemId;
      return;
    }
    if (action.type == SyncPlayPlayerActionType.stop) {
      final epoch = ++_loadEpoch;
      await _player.stopFromSyncPlay();
      if (!isCurrent() || epoch != _loadEpoch) return;
      _mediaId = null;
      _playlistItemId = null;
      return;
    }
    final epoch = _loadEpoch;
    bool current() => isCurrent() && epoch == _loadEpoch;
    if (action.type != SyncPlayPlayerActionType.unpause) {
      await _player.pauseFromSyncPlay();
      if (!current()) return;
    }
    await _player.seekFromSyncPlay(action.position);
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
}) async {
  final apiOwner = SyncPlayPlaybackApiOwner(api, ownsApi: ownsApi);
  try {
    void check() {
      if (!isCurrent()) throw const SyncPlayFailure(SyncPlayFailureCode.player);
    }

    check();
    final profile = ref.read(videoProfileProvider);
    final response = await api.itemsItemIdGet(itemId: queueItem.mediaId, userId: account.id);
    check();
    final dto = response.body;
    if (!response.isSuccessful || dto == null || dto.id != queueItem.mediaId || dto.mediaType != MediaType.video) {
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
            deviceProfile: profile));
    check();
    final info = playback.body;
    final source = info?.mediaSources?.firstOrNull;
    if (!playback.isSuccessful || source?.id == null || source == null || info == null) {
      throw const SyncPlayFailure(SyncPlayFailureCode.player);
    }
    final direct = source.supportsDirectPlay == true || source.supportsDirectStream == true;
    final Uri? uri = direct
        ? buildServerUriFromBase(account.credentials.url, pathSegments: [
            'Videos',
            queueItem.mediaId,
            'stream'
          ], queryParameters: {
            'Static': 'true',
            'mediaSourceId': source.id,
            'api_key': account.credentials.token,
            'PlaySessionId': info.playSessionId
          })
        : source.supportsTranscoding == true && source.transcodingUrl != null
            ? _capturedUri(account, source.transcodingUrl!)
            : null;
    if (uri == null) throw const SyncPlayFailure(SyncPlayFailureCode.player);
    final streams = _capturedStreams(source, account);
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
      relativeUrl: relativeUrl, queryParameters: {'api_key': account.credentials.token});
  if (base == null || uri == null || base.scheme != uri.scheme || base.host != uri.host || base.port != uri.port) {
    return null;
  }
  // Add the snapshot token only after rejecting a different origin.
  return uri.replace(queryParameters: {...uri.queryParameters, 'api_key': account.credentials.token});
}

MediaStreamsModel _capturedStreams(MediaSourceInfo source, AccountModel account) {
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
            videoStreams:
                streams.where((s) => s.type == MediaStreamType.video).map(VideoStreamModel.fromMediaStream).toList(),
            audioStreams:
                streams.where((s) => s.type == MediaStreamType.audio).map(AudioStreamModel.fromMediaStream).toList(),
            subStreams: streams.where((s) => s.type == MediaStreamType.subtitle).map((s) {
              final delivery = subtitleDeliveryUrl(s.deliveryUrl, s.codec ?? '');
              return SubStreamModel(
                  name: s.title ?? '',
                  id: '${source.id}/${s.index}',
                  title: s.title ?? '',
                  displayTitle: s.displayTitle ?? '',
                  language: s.language ?? '',
                  codec: s.codec ?? '',
                  index: s.index ?? -1,
                  isDefault: s.isDefault ?? false,
                  isExternal: s.isExternal ?? false,
                  supportsExternalStream: s.supportsExternalStream ?? false,
                  url: delivery == null ? null : _capturedUri(account, delivery)?.toString());
            }).toList())
      ]);
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
  List<SubStreamModel> get subStreams => [SubStreamModel.no(), ...?mediaStreams?.subStreams];
  @override
  List<AudioStreamModel> get audioStreams => [AudioStreamModel.no(), ...?mediaStreams?.audioStreams];
  List<QueueItem> get _wireQueue => (groupQueue?.call()?.items ?? [queueItem])
      .map((entry) => QueueItem(id: entry.mediaId, playlistItemId: entry.playlistItemId))
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
  Future<PlaybackModel?> updatePlaybackPosition(Duration position, bool isPlaying, Ref ref) async {
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
  Future<PlaybackModel?> playbackStopped(Duration position, Duration? totalDuration, Ref ref) async {
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

  SyncPlayPlaybackModel _copy({ItemBaseModel? item, MediaStreamsModel? streams}) => SyncPlayPlaybackModel(
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
  PlaybackModel updateUserData(UserData userData) => _copy(item: item.copyWith(userData: userData));
  @override
  PlaybackModel updatePlaybackQueue(PlaybackQueueState newQueue) => this;
  @override
  PlaybackModel copyWith() => _copy();
  @override
  Future<PlaybackModel> setQualityOption(Map<Bitrate, bool> map) async => this;
  @override
  Future<PlaybackModel> setSubtitle(SubStreamModel? model, MediaControlsWrapper player) async {
    if (!isCurrent()) return this;
    final index = await player.setSubtitleTrack(model, this);
    if (!isCurrent()) return this;
    return _copy(streams: mediaStreams?.copyWith(defaultSubStreamIndex: index));
  }

  @override
  Future<PlaybackModel> setAudio(AudioStreamModel? model, MediaControlsWrapper player) async {
    if (!isCurrent()) return this;
    final index = await player.setAudioTrack(model, this);
    if (!isCurrent()) return this;
    return _copy(streams: mediaStreams?.copyWith(defaultAudioStreamIndex: index));
  }
}
