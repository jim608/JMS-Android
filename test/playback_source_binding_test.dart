import 'dart:async';

import 'package:chopper/chopper.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/credentials_model.dart';
import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/items/item_shared_models.dart';
import 'package:fladder/models/media_playback_model.dart';
import 'package:fladder/models/items/media_segments_model.dart';
import 'package:fladder/models/items/media_streams_model.dart';
import 'package:fladder/models/items/movie_model.dart';
import 'package:fladder/models/items/overview_model.dart';
import 'package:fladder/models/items/trick_play_model.dart';
import 'package:fladder/models/playback/direct_playback_model.dart';
import 'package:fladder/models/playback/playback_model.dart';
import 'package:fladder/models/playback/transcode_playback_model.dart';
import 'package:fladder/models/settings/video_player_settings.dart';
import 'package:fladder/models/syncing/sync_item.dart';
import 'package:fladder/models/syncing/sync_settings_model.dart';
import 'package:fladder/profiles/default_profile.dart';
import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/connectivity_provider.dart' as connectivity;
import 'package:fladder/providers/service_provider.dart';
import 'package:fladder/providers/settings/video_player_settings_provider.dart';
import 'package:fladder/providers/sync_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/services/playback_diagnostics.dart';
import 'package:fladder/services/syncplay/syncplay_player_commands.dart';
import 'package:fladder/util/selected_media_source.dart';
import 'package:fladder/util/subtitle_selection_failure.dart';
import 'package:fladder/wrappers/media_control_wrapper.dart';

import 'support/playback_test_ref.dart';

// These execute the real orchestration/model conversion with fake providers and
// an in-memory JellyService. No HTTP, player, media, or hardware is involved.
class _NoOfflineItem extends StateNotifier<SyncSettingsModel>
    implements SyncNotifier {
  _NoOfflineItem() : super(SyncSettingsModel());

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);


  @override
  Future<SyncedItem?> getSyncedItem(String? id) async => null;
}

class _Item extends Fake implements ItemBaseModel {
  _Item(this.streams);
  final MediaStreamsModel streams;
  final fixture = MovieModel.fromBaseDto(
      const BaseItemDto(
          id: 'movie',
          name: 'Synthetic subtitle source fixture',
          type: BaseItemKind.movie,
          mediaType: MediaType.video),
      null);
  @override
  String get id => 'movie';
  @override
  MediaStreamsModel get streamModel => streams;
  @override
  OverviewModel get overview => fixture.overview;
  @override
  UserData get userData => fixture.userData;
}

class _Api extends Fake implements JellyService {
  late ItemBaseModel item;
  late List<MediaSourceInfo> sources;
  final requests = <PlaybackInfoDto>[];
  Completer<Response<PlaybackInfoResponse>>? pending;

  @override
  Future<Response<ItemBaseModel>> usersUserIdItemsItemIdGet(
          {String? itemId}) async =>
      Response(http.Response('', 200), item);

  @override
  Future<Response<PlaybackInfoResponse>> itemsItemIdPlaybackInfoPost({
    required String? itemId,
    required PlaybackInfoDto? body,
  }) async {
    requests.add(body!);
    if (pending != null) return pending!.future;
    return Response(
        http.Response('', 200),
        PlaybackInfoResponse(
            playSessionId: 'synthetic-session', mediaSources: sources));
  }

  @override
  Future<Response<MediaSegmentsModel>?> mediaSegmentsGet(
          {required String id}) async =>
      null;

  @override
  Future<Response<TrickPlayModel>?> getTrickPlay(
          {required ItemBaseModel? item, int? width, required Ref ref}) async =>
      null;
}

class _Loader extends VideoPlayerNotifier {
  _Loader(super.ref, _Wrapper wrapper) {
    state = wrapper;
  }

  set wrapper(_Wrapper wrapper) => state = wrapper;


  final loaded = <PlaybackModel>[];
  bool Function()? ownership;
  bool? playWhenReady;
  Duration? requestedStartPosition;
  @override
  Future<bool> loadPlaybackItem(PlaybackModel model, Duration startPosition,
      {bool playWhenReady = true,
      bool Function()? isCurrent,
      PlaybackAttemptRef? diagnosticAttempt}) async {
    ownership = isCurrent;
    this.playWhenReady = playWhenReady;
    requestedStartPosition = startPosition;
    loaded.add(model);
    return true;
  }
}

class _Wrapper extends Fake implements MediaControlsWrapper {
  @override
  Future<void> dispose() async {}

  int stopEpoch = 0;
  bool roomActive = false;
  @override
  int get playbackStopEpoch => stopEpoch;
  @override
  bool get syncPlayActive => roomActive;
  @override
  SyncPlayPlayerCommands? get syncPlayCommands => null;
}

MediaSourceInfo source(String id, String script,
        {bool transcode = false, List<MediaStream>? subtitles}) =>
    MediaSourceInfo(
      id: id,
      name: 'Synthetic $id',
      supportsDirectPlay: !transcode,
      supportsTranscoding: transcode,
      transcodingUrl: transcode ? '/Videos/$id/master.m3u8' : null,
      defaultAudioStreamIndex: 1,
      defaultSubtitleStreamIndex: 47,
      mediaStreams: [
        const MediaStream(
            type: MediaStreamType.video,
            index: 0,
            codec: 'h264',
            bitRate: 1000000,
            width: 1280,
            height: 720),
        const MediaStream(type: MediaStreamType.audio, index: 1, codec: 'aac'),
        ...subtitles ??
            [
              MediaStream(
                  type: MediaStreamType.subtitle,
                  index: 47,
                  codec: 'srt',
                  language: 'zh-$script',
                  displayTitle: script == 'Hant' ? '繁體中文' : '简体中文',
                  supportsExternalStream: true,
                  deliveryUrl: '/Videos/$id/Subtitles/47/Stream.vtt')
            ],
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Ref ref;
  late ProviderContainer container;
  late _Api api;
  late _Loader loader;
  late _Wrapper wrapper;
  late PlaybackModelHelper helper;
  late MediaSourceInfo sourceA;
  late MediaSourceInfo sourceB;

  setUp(() {
    api = _Api();
    wrapper = _Wrapper();
    sourceA = source('A', 'Hans');
    sourceB = source('B', 'Hant');
    final account = AccountModel(
        name: 'Synthetic',
        id: 'user',
        avatar: '',
        lastUsed: DateTime(2026),
        credentials: CredentialsModel(
            token: 'synthetic', url: 'https://fixture.invalid'));
    container = ProviderContainer.test(overrides: [
      jellyApiProvider.overrideWithValue(api),
      userProvider.overrideWithValue(account),
      serverUrlProvider.overrideWith((ref) => 'https://fixture.invalid'),
      syncProvider.overrideWith((ref) => _NoOfflineItem()),
      connectivity.offlineStateProvider.overrideWithValue(false),
      connectivity.connectivityStatusProvider.overrideWithValue(
          connectivity.ConnectionState.wifi),
      videoPlayerSettingsProvider.overrideWith((ref) =>
          VideoPlayerSettingsProviderNotifier(ref)..applyRestoredSettings(
            VideoPlayerSettingsModel(playerOptions: PlayerOptions.libMPV),
          )),
      videoProfileProvider.overrideWith((ref) => defaultProfile(PlayerOptions.libMPV)),
      videoPlayerProvider.overrideWith((ref) => _Loader(ref, wrapper)),
      mediaPlaybackProvider.overrideWith((ref) => MediaPlaybackModel(
        position: const Duration(seconds: 5), playing: true)),
    ]);
    ref = playbackTestRef(container);
    loader = container.read(videoPlayerProvider.notifier) as _Loader;
    final preplay =
        MediaStreamsModel.fromMediaStreamsList([sourceA, sourceB], ref)
            .copyWith(versionStreamIndex: 1);
    api.item = _Item(preplay);
    helper = PlaybackModelHelper(ref: ref);
    PlaybackDiagnostics.instance.clear();
  });

  Future<PlaybackModel?> initial() =>
      helper.createPlaybackModel(null, api.item, libraryQueue: [api.item]);

  void expectTraditional(PlaybackModel model) {
    expect(model.mediaStreams?.currentVersionStream?.id, 'B');
    expect(model.defaultSubStream?.index, 47);
    expect(model.defaultSubStream?.displayTitle, '繁體中文');
    expect(model.defaultSubStream?.language, 'zh-Hant');
    expect(model.defaultSubStream?.id, playbackSubtitleKey('B', 47));
    expect(Uri.parse(model.defaultSubStream!.url!).path,
        '/Videos/B/Subtitles/47/Stream.srt');
    expect(Uri.parse(model.media!.url).path, contains('/Videos/B/'));
  }

  test('initial negotiation binds reordered video and subtitle source by ID',
      () async {
    api.sources = [sourceB, sourceA];
    final model = await initial();
    expect(model, isA<DirectPlaybackModel>());
    expectTraditional(model!);
    expect(api.requests.single.mediaSourceId, 'B');
    expect(api.requests.single.subtitleStreamIndex, 47);
  });

  test('filtered one-source response keeps requested nonzero preplay version',
      () async {
    api.sources = [sourceB];
    final model = await initial();
    expect(model, isNotNull);
    expectTraditional(model!);
  });

  test(
      'initial and reload use the same source despite different response order',
      () async {
    api.sources = [sourceB, sourceA];
    final model = (await initial())!;
    container.read(playBackModel.notifier).state = model;
    api.sources = [sourceA, source('B', 'Hant', transcode: true)];
    await helper.shouldReload(model);
    expect(loader.loaded.single, isA<TranscodePlaybackModel>());
    expectTraditional(loader.loaded.single);
    expect(
        loader.loaded.single.defaultSubStream?.id, model.defaultSubStream?.id);
    expect(api.requests.map((request) => request.mediaSourceId), ['B', 'B']);
    expect(
        api.requests.map((request) => request.subtitleStreamIndex), [47, 47]);
  });

  test('missing selected source cannot silently become another source',
      () async {
    api.sources = [sourceA];
    expect(await initial(), isNull);
    expect(PlaybackDiagnostics.instance.exportText(),
        contains('source_missing'));
    expect(loader.loaded, isEmpty);
  });

  test('missing selected subtitle cannot silently become server default',
      () async {
    api.sources = [
      source('B', 'Hant', subtitles: [
        const MediaStream(
            type: MediaStreamType.subtitle,
            index: 2,
            codec: 'srt',
            language: 'zh-Hans',
            displayTitle: '简体中文')
      ])
    ];
    expect(await initial(), isNull);
    expect(PlaybackDiagnostics.instance.exportText(),
        contains('subtitle_missing'));
  });

  test('reload rejects missing selected source without replacing player model',
      () async {
    api.sources = [sourceB];
    final model = (await initial())!;
    container.read(playBackModel.notifier).state = model;
    api.sources = [sourceA];
    await expectLater(
        helper.shouldReload(model),
        throwsA(isA<SubtitleSelectionFailure>().having((error) => error.reason,
            'reason', SubtitleSelectionFailureReason.unavailable)));
    expect(loader.loaded, isEmpty);
    expectTraditional(model);
  });

  test('explicit Off survives initial and reload despite source defaults',
      () async {
    final preplay =
        (api.item as _Item).streams.copyWith(defaultSubStreamIndex: -1);
    api.item = _Item(preplay);
    api.sources = [sourceB, sourceA];
    final model = (await initial())!;
    container.read(playBackModel.notifier).state = model;
    expect(model.defaultSubStream?.index, -1);
    api.sources = [sourceA, source('B', 'Hant', transcode: true)];
    await helper.shouldReload(model);
    expect(loader.loaded.single.defaultSubStream?.index, -1);
    expect(
        api.requests.map((request) => request.subtitleStreamIndex), [-1, -1]);
    expect(loader.loaded.single.mediaStreams?.currentVersionStream?.id, 'B');
  });

  test('normal initial play does not borrow an unrelated retained old model',
      () async {
    final unrelated = DirectPlaybackModel(
        item: api.item,
        media: const Media(url: 'https://fixture.invalid/old'),
        mediaStreams: MediaStreamsModel.fromMediaStreamsList([sourceA], ref));
    container.read(playBackModel.notifier).state = unrelated;
    api.sources = [sourceA, sourceB];
    final model = (await initial())!;
    expectTraditional(model);
    expect(api.requests.single.subtitleStreamIndex, 47);
  });

  for (final invalidation in ['model', 'player', 'stop', 'room']) {
    test('late reload response cannot reopen after $invalidation changes',
        () async {
      api.sources = [sourceB];
      final model = (await initial())!;
      container.read(playBackModel.notifier).state = model;
      api.pending = Completer<Response<PlaybackInfoResponse>>();
      final pendingReload = helper.shouldReload(model);
      switch (invalidation) {
        case 'model':
          container.read(playBackModel.notifier).state = (model as DirectPlaybackModel).copyWith();
          break;
        case 'player':
          loader.wrapper = _Wrapper();
          break;
        case 'stop':
          wrapper.stopEpoch++;
          break;
        case 'room':
          wrapper.roomActive = true;
          break;
      }
      api.pending!.complete(Response(
          http.Response('', 200),
          PlaybackInfoResponse(
              mediaSources: [source('B', 'Hant', transcode: true)])));
      await pendingReload;
      expect(loader.loaded, isEmpty);
    });
  }

  test('replacement load guard permits only the authorized exact model',
      () async {
    api.sources = [sourceB];
    final model = (await initial())!;
    container.read(playBackModel.notifier).state = model;
    api.sources = [source('B', 'Hant', transcode: true)];
    await helper.shouldReload(model);
    final authorized = loader.loaded.single as TranscodePlaybackModel;
    expect(loader.ownership!(), isTrue);
    container.read(playBackModel.notifier).state = authorized;
    expect(loader.ownership!(), isTrue);
    container.read(playBackModel.notifier).state = authorized.copyWith();
    expect(loader.ownership!(), isFalse);
  });

  test('subtitle transcode reload preserves a paused playback request',
      () async {
    api.sources = [sourceB];
    final model = (await initial())!;
    container.read(playBackModel.notifier).state = model;
    container.read(mediaPlaybackProvider.notifier).update((state) => state.copyWith(playing: false));
    api.sources = [source('B', 'Hant', transcode: true)];
    await helper.shouldReload(model);
    expect(loader.loaded.single, isA<TranscodePlaybackModel>());
    expect(loader.playWhenReady, isFalse);
  });

  test('pause and seek during negotiation win over the earlier reload request',
      () async {
    api.sources = [sourceB];
    final model = (await initial())!;
    container.read(playBackModel.notifier).state = model;
    api.pending = Completer<Response<PlaybackInfoResponse>>();
    final pendingReload = helper.shouldReload(model);
    container.read(mediaPlaybackProvider.notifier).update((state) => state.copyWith(
      playing: false,
      position: const Duration(seconds: 42),
    ));
    api.pending!.complete(Response(
        http.Response('', 200),
        PlaybackInfoResponse(
            mediaSources: [source('B', 'Hant', transcode: true)])));
    await pendingReload;
    expect(api.requests.last.startTimeTicks, 50000000);
    expect(loader.loaded.single, isA<TranscodePlaybackModel>());
    expect(loader.playWhenReady, isFalse);
    expect(loader.requestedStartPosition, const Duration(seconds: 42));
  });
}
