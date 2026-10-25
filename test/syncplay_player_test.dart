import 'dart:async';
import 'package:chopper/chopper.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:smtc_windows/src/rust/api/api.dart';
import 'package:smtc_windows/src/rust/frb_generated.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart'
    hide SyncPlayQueueItem;
import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/credentials_model.dart';
import 'package:fladder/models/items/movie_model.dart';
import 'package:fladder/models/items/media_streams_model.dart';
import 'package:fladder/models/media_playback_model.dart';
import 'package:fladder/models/playback/playback_model.dart';
import 'package:fladder/models/settings/video_player_settings.dart';
import 'package:fladder/models/settings/subtitle_settings_model.dart';
import 'package:fladder/profiles/default_profile.dart';
import 'package:fladder/providers/settings/video_player_settings_provider.dart';
import 'package:fladder/providers/image_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/services/syncplay/syncplay_clock.dart';
import 'package:fladder/services/syncplay/syncplay_controller.dart';
import 'package:fladder/services/syncplay/syncplay_models.dart';
import 'package:fladder/services/syncplay/syncplay_player.dart';
import 'package:fladder/services/syncplay/syncplay_player_commands.dart';
import 'package:fladder/wrappers/media_control_wrapper.dart';
import 'package:fladder/wrappers/players/player_states.dart';
import 'package:fladder/wrappers/players/base_player.dart';

import 'syncplay_controller_test.dart' as protocol;

class _Smtc extends Fake implements SmtcInternal {}

class _Images extends Fake implements ImageNotifier {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #getItemsImageUrl ||
        invocation.memberName == #getItemsOrigImageUrl) {
      return 'https://images.example.invalid/synthetic';
    }
    return super.noSuchMethod(invocation);
  }
}

class _SmtcApi extends Fake implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #crateApiApiSmtcNew:
        return _Smtc();
      case #crateApiApiSmtcButtonPressEvent:
      case #crateApiApiSmtcRepeatModeRequestEvent:
        return const Stream<String>.empty();
      case #crateApiApiSmtcShuffleRequestEvent:
        return const Stream<bool>.empty();
      case #crateApiApiSmtcUpdateConfig:
        return Future<void>.value();
      default:
        return super.noSuchMethod(invocation);
    }
  }
}

class _ReadyPlayer extends Fake implements BasePlayer {
  _ReadyPlayer({this.resetRateOnLoad = false});
  final rates = <double>[];
  final rateAndLoadEvents = <String>[];
  final bool resetRateOnLoad;
  double rate = 1;
  Completer<void>? rateReady;
  @override
  Future<void> init(VideoPlayerSettingsModel settings) async {}
  @override
  Future<void> dispose() async {}
  @override
  Stream<PlayerState> get stateStream => const Stream.empty();
  @override
  Future<void> loadVideo(String url, bool play,
      {Duration startPosition = Duration.zero}) async {
    rateAndLoadEvents.add('load');
    if (resetRateOnLoad) rate = 1;
  }

  @override
  void applySubtitleSettings(SubtitleSettingsModel settings) {}
  @override
  Future<void> setSpeed(double speed) async {
    rates.add(speed);
    rateAndLoadEvents.add('rate:$speed');
    await rateReady?.future;
    rate = speed;
  }
}

const mediaId = '11111111111111111111111111111111';
const entry = SyncPlayQueueItem(
    mediaId: mediaId, playlistItemId: '22222222222222222222222222222222');
const dto = BaseItemDto(
    id: mediaId,
    name: '本機測試',
    type: BaseItemKind.movie,
    mediaType: MediaType.video);
final account = AccountModel(
    name: '測試',
    id: '33333333333333333333333333333333',
    avatar: '',
    lastUsed: DateTime.utc(2026),
    credentials: CredentialsModel.internal(
        url: 'https://media.example.invalid/jf',
        token: 'synthetic-only',
        serverId: mediaId));
Response<T> response<T>(T data) => Response(http.Response('', 200), data);

class _Ref extends Fake implements Ref {
  final values = <Object, Object?>{};
  @override
  T read<T>(ProviderListenable<T> provider) => values[provider] as T;
}

class _Http extends http.BaseClient {
  int closes = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      throw StateError('No real HTTP');
  @override
  void close() {
    closes++;
  }
}

final class _Client extends ChopperClient {
  _Client(this.transport) : super(client: transport);
  final _Http transport;
  int disposes = 0;
  @override
  http.Client get httpClient => transport;
  @override
  void dispose() {
    disposes++;
    super.dispose();
  }
}

class _Api extends Fake implements JellyfinOpenApi {
  final ownedClient = _Client(_Http());
  final reports = <Object>[];
  final itemReady = Completer<Response<BaseItemDto>>();
  final infoReady = Completer<Response<PlaybackInfoResponse>>();
  int itemCalls = 0, infoCalls = 0;
  @override
  ChopperClient get client => ownedClient;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #itemsItemIdGet:
        itemCalls++;
        expect(invocation.namedArguments[#userId], account.id);
        return itemReady.future;
      case #itemsItemIdPlaybackInfoPost:
        infoCalls++;
        expect((invocation.namedArguments[#body] as PlaybackInfoDto).userId,
            account.id);
        return infoReady.future;
      case #sessionsPlayingPost:
      case #sessionsPlayingProgressPost:
      case #sessionsPlayingStoppedPost:
        reports.add(invocation.namedArguments[#body]!);
        return Future<Response<dynamic>>.value(
            Response(http.Response('', 204), null));
      default:
        return super.noSuchMethod(invocation);
    }
  }
}

class _Commands implements SyncPlayPlayerCommands {
  @override
  bool active = true;
  final events = <String>[];
  @override
  Future<void> pause() async {
    events.add('pause');
  }

  @override
  Future<void> play() async {
    events.add('play');
  }

  @override
  Future<void> seek(Duration position) async {
    events.add('seek:${position.inSeconds}');
  }

  @override
  Future<void> stop() async {
    events.add('stop');
  }
}

class _Wrapper extends MediaControlsWrapper {
  _Wrapper(Ref ref) : super(ref: ref);
  final raw = PlayerState(playing: true, buffering: false);
  final snapshots = StreamController<PlayerState>.broadcast(sync: true);
  final events = <String>[];
  Completer<void>? seekReady, loadReady;
  bool holdBufferingOnSeek = false;
  Duration? coarseLoadLanding, coarseSeekLanding;
  bool loadedBuffering = false;
  Duration loadedDuration = const Duration(minutes: 2);
  bool? loadedPlaying;
  @override
  bool get hasPlayer => true;
  @override
  bool get supportsSyncPlay => true;
  @override
  PlayerState get lastState => raw;
  @override
  Stream<PlayerState> get stateStream => snapshots.stream;
  @override
  Future<void> pauseFromSyncPlay() async {
    events.add('remote-pause');
    raw.playing = false;
  }

  @override
  Future<void> playFromSyncPlay() async {
    events.add('remote-play');
    raw.playing = true;
  }

  @override
  Future<void> seekFromSyncPlay(Duration position) async {
    events.add('remote-seek');
    await seekReady?.future;
    raw.position = coarseSeekLanding ?? position;
    if (holdBufferingOnSeek) raw.buffering = true;
  }

  @override
  Future<void> stop({bool preserveSleepTimer = false}) async {
    events.add('stop');
  }

  @override
  Future<void> loadVideo(PlaybackModel model, Duration startPosition, bool play,
      {bool Function()? isCurrent}) async {
    loadedPlaying = play;
    events.add('load');
    await loadReady?.future;
    raw.position = coarseLoadLanding ?? startPosition;
    raw.duration = loadedDuration;
    raw.buffering = loadedBuffering;
  }

  @override
  Future<void> setVolume(double volume) async {
    events.add('volume');
  }

  @override
  Future<int> setAudioTrack(
      AudioStreamModel? model, PlaybackModel playbackModel) async {
    events.add('audio');
    return -1;
  }

  @override
  Future<int> setSubtitleTrack(
      SubStreamModel? model, PlaybackModel playbackModel) async {
    events.add('subtitle');
    return -1;
  }
}

class _Notifier extends VideoPlayerNotifier {
  _Notifier(super.ref, MediaControlsWrapper wrapper) {
    state = wrapper;
  }
}

/// Keep this regression at the command boundary. Queue loading is synthetic;
/// every playback control and the backend-ready wait use the real adapter.
class _AdapterCommands implements SyncPlayPlayerPort {
  _AdapterCommands(this.adapter);
  final SyncPlayPlayerAdapter adapter;
  @override
  String? mediaId;
  @override
  String? playlistItemId;
  @override
  Duration get position => adapter.position;
  @override
  bool get isPlaying => adapter.isPlaying;
  @override
  Future<void> applyRemote(SyncPlayPlayerAction action) async {
    if (action.type == SyncPlayPlayerActionType.load) {
      mediaId = action.queueItem!.mediaId;
      playlistItemId = action.queueItem!.playlistItemId;
      return;
    }
    await adapter.applyRemote(action);
  }
}

SyncPlayPlaybackModel _model(_Api api,
        {bool Function()? current,
        SyncPlayPlaybackApiOwner? owner,
        SyncPlayQueue? Function()? queue}) =>
    SyncPlayPlaybackModel(
        item: MovieModel.fromBaseDto(dto, null),
        media: const Media(
            url: 'https://media.example.invalid/jf/Videos/test/stream'),
        playbackInfo:
            const PlaybackInfoResponse(playSessionId: 'synthetic-session'),
        mediaStreams: MediaStreamsModel(versionStreams: []),
        api: api,
        isCurrent: current ?? () => true,
        queueItem: entry,
        groupQueue: queue,
        playMethod: PlayMethod.directstream,
        apiOwner: owner);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => RustLib.initMock(api: _SmtcApi()));

  ({_Wrapper wrapper, SyncPlayPlayerAdapter adapter}) realLoadFixture() {
    final ref = _Ref();
    final wrapper = _Wrapper(ref);
    final media = StateController(MediaPlaybackModel());
    final playback = StateController<PlaybackModel?>(null);
    ref.values.addAll({
      mediaPlaybackProvider.notifier: media,
      mediaPlaybackProvider: media.state,
      playBackModel: null,
      playBackModel.notifier: playback,
      playbackRateProvider.notifier: StateController(1.0),
      videoPlayerSettingsProvider: VideoPlayerSettingsModel(),
      videoProfileProvider: const DeviceProfile(),
      imageUtilityProvider: _Images(),
      videoPlayerProvider: wrapper,
      videoPlayerProvider.notifier: _Notifier(ref, wrapper),
    });
    final api = _Api();
    api.itemReady.complete(response(dto));
    api.infoReady.complete(response(PlaybackInfoResponse(mediaSources: [
      MediaSourceInfo(id: mediaId, supportsDirectPlay: true, mediaStreams: [])
    ])));
    final adapter = SyncPlayPlayerAdapter(
        ref: ref, account: account, api: api, isCurrent: () => true);
    addTearDown(() async {
      adapter.cancelPendingActions();
      await wrapper.snapshots.close();
    });
    return (wrapper: wrapper, adapter: adapter);
  }

  const alignmentLoad = SyncPlayPlayerAction(
      type: SyncPlayPlayerActionType.load,
      position: Duration(seconds: 8),
      queueItem: entry);

  test('initial load alignment corrects a settled coarse load exactly once',
      () async {
    final fixture = realLoadFixture();
    fixture.wrapper.coarseLoadLanding = const Duration(seconds: 6);
    await fixture.adapter.applyRemote(alignmentLoad);
    expect(fixture.wrapper.loadedPlaying, false);
    expect(fixture.wrapper.events.where((e) => e == 'load'), hasLength(1));
    expect(
        fixture.wrapper.events.where((e) => e == 'remote-seek'), hasLength(1));
    expect(fixture.wrapper.events, isNot(contains('remote-play')));
    expect(fixture.wrapper.raw.position, alignmentLoad.position);
    expect(fixture.adapter.mediaId, mediaId);
  });

  test('initial load alignment waits buffering before and after its one seek',
      () async {
    final fixture = realLoadFixture();
    fixture.wrapper
      ..coarseLoadLanding = const Duration(seconds: 6)
      ..loadedBuffering = true
      ..holdBufferingOnSeek = true;
    var completed = false;
    final loading = fixture.adapter.applyRemote(alignmentLoad)
      ..then((_) => completed = true);
    await Future<void>.delayed(Duration.zero);
    expect(fixture.wrapper.events, isNot(contains('remote-seek')));
    expect(completed, false);
    fixture.wrapper.raw.buffering = false;
    fixture.wrapper.snapshots.add(fixture.wrapper.raw);
    await Future<void>.delayed(Duration.zero);
    expect(
        fixture.wrapper.events.where((e) => e == 'remote-seek'), hasLength(1));
    expect(fixture.wrapper.raw.buffering, true);
    expect(completed, false);
    expect(fixture.adapter.mediaId, isNull);
    fixture.wrapper.raw.buffering = false;
    fixture.wrapper.snapshots.add(fixture.wrapper.raw);
    await loading;
    expect(fixture.adapter.mediaId, mediaId);
  });

  test('initial load alignment never seeks an already aligned load', () async {
    final fixture = realLoadFixture();
    await fixture.adapter.applyRemote(alignmentLoad);
    expect(fixture.wrapper.events, isNot(contains('remote-seek')));
    expect(fixture.adapter.mediaId, mediaId);
  });

  test('initial load alignment waits for a prepared duration before correcting',
      () async {
    final fixture = realLoadFixture();
    fixture.wrapper
      ..coarseLoadLanding = const Duration(seconds: 6)
      ..loadedDuration = Duration.zero;
    final loading = fixture.adapter.applyRemote(alignmentLoad);
    await Future<void>.delayed(Duration.zero);
    expect(fixture.wrapper.events, isNot(contains('remote-seek')));
    expect(fixture.adapter.mediaId, isNull);
    fixture.wrapper.raw.duration = const Duration(minutes: 2);
    fixture.wrapper.snapshots.add(fixture.wrapper.raw);
    await loading;
    expect(
        fixture.wrapper.events.where((e) => e == 'remote-seek'), hasLength(1));
  });

  test(
      'initial load alignment cancelled before readiness never sends late seek',
      () async {
    final fixture = realLoadFixture();
    fixture.wrapper
      ..coarseLoadLanding = const Duration(seconds: 6)
      ..loadedBuffering = true;
    final loading = fixture.adapter.applyRemote(alignmentLoad);
    await Future<void>.delayed(Duration.zero);
    fixture.adapter.cancelPendingActions();
    await loading;
    fixture.wrapper.raw.buffering = false;
    fixture.wrapper.snapshots.add(fixture.wrapper.raw);
    await Future<void>.delayed(Duration.zero);
    expect(fixture.wrapper.events, isNot(contains('remote-seek')));
    expect(fixture.wrapper.events, isNot(contains('remote-play')));
    expect(fixture.adapter.mediaId, isNull);
  });

  test(
      'initial load alignment cancellation retires a pending seek without Ready',
      () async {
    final fixture = realLoadFixture();
    final seek = Completer<void>();
    fixture.wrapper
      ..coarseLoadLanding = const Duration(seconds: 6)
      ..seekReady = seek;
    final loading = fixture.adapter.applyRemote(alignmentLoad);
    await Future<void>.delayed(Duration.zero);
    expect(
        fixture.wrapper.events.where((e) => e == 'remote-seek'), hasLength(1));
    fixture.adapter.cancelPendingActions();
    await loading;
    seek.complete();
    await Future<void>.delayed(Duration.zero);
    expect(
        fixture.wrapper.events.where((e) => e == 'remote-seek'), hasLength(1));
    expect(fixture.wrapper.events, isNot(contains('remote-play')));
    expect(fixture.adapter.mediaId, isNull);
  });

  test('initial load alignment does not loop when the one seek stays coarse',
      () async {
    final fixture = realLoadFixture();
    fixture.wrapper
      ..coarseLoadLanding = const Duration(seconds: 6)
      ..coarseSeekLanding = const Duration(seconds: 6);
    var completed = false;
    final loading = fixture.adapter.applyRemote(alignmentLoad)
      ..then((_) => completed = true);
    await Future<void>.delayed(Duration.zero);
    for (var i = 0; i < 3; i++) {
      fixture.wrapper.snapshots.add(fixture.wrapper.raw);
      await Future<void>.delayed(Duration.zero);
    }
    expect(
        fixture.wrapper.events.where((e) => e == 'remote-seek'), hasLength(1));
    expect(completed, false);
    expect(fixture.adapter.mediaId, isNull);
    fixture.adapter.cancelPendingActions();
    await loading;
  });

  for (final transcoded in [false, true]) {
    test(
        'room external plain delivery preserves direct SID ordering ($transcoded)',
        () async {
      final container = ProviderContainer(overrides: [
        videoProfileProvider.overrideWith((_) => const DeviceProfile())
      ]);
      addTearDown(container.dispose);
      final refProvider = Provider<Ref>((ref) => ref);
      final api = _Api();
      api.itemReady.complete(response(dto));
      api.infoReady.complete(response(PlaybackInfoResponse(mediaSources: [
        MediaSourceInfo(
            id: mediaId,
            supportsDirectPlay: !transcoded,
            supportsTranscoding: transcoded,
            transcodingUrl: 'Videos/test/master.m3u8',
            mediaStreams: [
              const MediaStream(
                  type: MediaStreamType.subtitle,
                  index: 2,
                  codec: 'srt',
                  isExternal: false,
                  deliveryMethod: SubtitleDeliveryMethod.$external,
                  deliveryUrl: 'Videos/test/Subtitles/2/Stream.srt',
                  supportsExternalStream: true)
            ])
      ])));
      final model = await createSyncPlayPlaybackModel(
          ref: container.read(refProvider),
          api: api,
          account: account,
          queueItem: entry,
          position: Duration.zero,
          isCurrent: () => true);
      final track = model.subStreams.singleWhere((track) => track.index == 2);
      expect(model.isServerTranscoded, transcoded);
      expect(track.isExternal, transcoded);
      expect(Uri.parse(track.url!).origin, 'https://media.example.invalid');
      expect(
          Uri.parse(track.url!).path, '/jf/Videos/test/Subtitles/2/Stream.srt');
      model.dispose();
    });
  }
  tearDownAll(RustLib.dispose);

  test(
      'local group pause play seek and toggle delegate once; local queue cannot advance',
      () async {
    final wrapper = _Wrapper(_Ref());
    final commands = _Commands();
    wrapper.syncPlayCommands = commands;
    await wrapper.pause();
    await wrapper.play();
    await wrapper.seek(const Duration(seconds: 9));
    await wrapper.playOrPause();
    await wrapper.skipToNext();
    await wrapper.loadPreviousVideo();
    expect(commands.events, ['pause', 'play', 'seek:9', 'pause']);
    expect(wrapper.events, isEmpty);
    commands.active = false;
    await wrapper.pause();
    await wrapper.seek(Duration.zero);
    expect(wrapper.events, ['remote-pause', 'remote-seek']);
    expect(commands.events.length, 4);
  });

  test('remote unpause waits for seek and never echoes local commands',
      () async {
    final ref = _Ref();
    final wrapper = _Wrapper(ref);
    final commands = _Commands();
    wrapper.syncPlayCommands = commands;
    ref.values[videoPlayerProvider] = wrapper;
    wrapper.seekReady = Completer<void>();
    final adapter = SyncPlayPlayerAdapter(
        ref: ref, account: account, api: _Api(), isCurrent: () => true);
    final action = adapter.applyRemote(const SyncPlayPlayerAction(
        type: SyncPlayPlayerActionType.unpause,
        position: Duration(seconds: 8)));
    await Future<void>.delayed(Duration.zero);
    expect(wrapper.events, ['remote-seek']);
    wrapper.seekReady!.complete();
    await action;
    expect(wrapper.events, ['remote-seek', 'remote-play']);
    expect(commands.events, isEmpty);
  });

  test('account invalidation during remote seek prevents late play', () async {
    var current = true;
    final ref = _Ref();
    final wrapper = _Wrapper(ref);
    wrapper.raw.position = const Duration(seconds: 10);
    ref.values[videoPlayerProvider] = wrapper;
    wrapper.seekReady = Completer<void>();
    final adapter = SyncPlayPlayerAdapter(
        ref: ref, account: account, api: _Api(), isCurrent: () => current);
    final action = adapter.applyRemote(
        const SyncPlayPlayerAction(type: SyncPlayPlayerActionType.unpause));
    current = false;
    wrapper.seekReady!.complete();
    await action;
    expect(wrapper.events, ['remote-seek']);
  });

  test(
      'cancel pending actions rejects old seek completion but permits a future command',
      () async {
    final ref = _Ref();
    final wrapper = _Wrapper(ref);
    wrapper.raw.position = const Duration(seconds: 10);
    ref.values[videoPlayerProvider] = wrapper;
    wrapper.seekReady = Completer<void>();
    final adapter = SyncPlayPlayerAdapter(
        ref: ref, account: account, api: _Api(), isCurrent: () => true);
    final old = adapter.applyRemote(
        const SyncPlayPlayerAction(type: SyncPlayPlayerActionType.unpause));
    adapter.cancelPendingActions();
    wrapper.seekReady!.complete();
    await old;
    expect(wrapper.events, ['remote-seek']);
    await adapter.applyRemote(
        const SyncPlayPlayerAction(type: SyncPlayPlayerActionType.unpause));
    expect(wrapper.events, ['remote-seek', 'remote-play']);
  });

  test('aligned pause and unpause do not manufacture seek buffering pulses',
      () async {
    final ref = _Ref();
    final wrapper = _Wrapper(ref);
    wrapper.raw.position = const Duration(milliseconds: 8100);
    ref.values[videoPlayerProvider] = wrapper;
    final adapter = SyncPlayPlayerAdapter(
        ref: ref, account: account, api: _Api(), isCurrent: () => true);
    await adapter.applyRemote(const SyncPlayPlayerAction(
        type: SyncPlayPlayerActionType.pause, position: Duration(seconds: 8)));
    await adapter.applyRemote(const SyncPlayPlayerAction(
        type: SyncPlayPlayerActionType.unpause,
        position: Duration(seconds: 8)));
    expect(wrapper.events, ['remote-pause', 'remote-play']);
    await wrapper.snapshots.close();
  });

  test('accepted seek is not media ready until actual buffering clears',
      () async {
    final ref = _Ref();
    final wrapper = _Wrapper(ref)..holdBufferingOnSeek = true;
    ref.values[videoPlayerProvider] = wrapper;
    final adapter = SyncPlayPlayerAdapter(
        ref: ref, account: account, api: _Api(), isCurrent: () => true);
    var completed = false;
    final action = adapter.applyRemote(const SyncPlayPlayerAction(
        type: SyncPlayPlayerActionType.unpause, position: Duration(seconds: 8)))
      ..then((_) => completed = true);
    await Future<void>.delayed(Duration.zero);
    expect(wrapper.events, ['remote-seek']);
    expect(completed, isFalse);
    wrapper.raw.buffering = false;
    wrapper.snapshots.add(wrapper.raw);
    await action;
    expect(wrapper.events, ['remote-seek', 'remote-play']);
    await wrapper.snapshots.close();
  });

  test('leaving cancels an actual media-ready wait without a late play',
      () async {
    final ref = _Ref();
    final wrapper = _Wrapper(ref)..holdBufferingOnSeek = true;
    ref.values[videoPlayerProvider] = wrapper;
    final adapter = SyncPlayPlayerAdapter(
        ref: ref, account: account, api: _Api(), isCurrent: () => true);
    final action = adapter.applyRemote(const SyncPlayPlayerAction(
        type: SyncPlayPlayerActionType.unpause,
        position: Duration(seconds: 8)));
    await Future<void>.delayed(Duration.zero);
    adapter.cancelPendingActions();
    await action;
    wrapper.raw.buffering = false;
    wrapper.snapshots.add(wrapper.raw);
    expect(wrapper.events, ['remote-seek']);
    await wrapper.snapshots.close();
  });

  for (final invalidation in [
    'disconnect',
    'GroupLeft',
    'LibraryAccessDenied',
    'empty queue'
  ]) {
    test(
        '$invalidation cancels an in-flight controller unpause awaiting actual backend readiness',
        () async {
      final world = protocol.World();
      final server = protocol.Server(world);
      final api = server.client('synthetic-participant');
      final ref = _Ref();
      final wrapper = _Wrapper(ref)..holdBufferingOnSeek = true;
      wrapper.raw.playing = false;
      ref.values[videoPlayerProvider] = wrapper;
      // Login identity deliberately remains current across a network disconnect.
      final adapter = SyncPlayPlayerAdapter(
          ref: ref, account: account, api: _Api(), isCurrent: () => true);
      final controller = SyncPlayController(
        identity: protocol.identity,
        api: api,
        player: _AdapterCommands(adapter),
        events: api.events.stream,
        clock: SyncPlayClock(now: () => world.now),
        scheduler: world,
        isPlayerBuffering: () => adapter.isBuffering,
        cancelPendingPlayerActions: adapter.cancelPendingActions,
      );
      addTearDown(() async {
        await controller.dispose();
        adapter.cancelPendingActions();
        await api.events.close();
        await wrapper.snapshots.close();
      });
      await controller.createRoom('123456');
      await protocol.settle();
      await controller
          .setQueue([mediaId], position: const Duration(seconds: 8));
      await protocol.settle();
      expect(controller.state.canControl, isTrue);
      await controller.requestUnpause(userInitiated: true);
      await world.advance(const Duration(milliseconds: 500));
      expect(wrapper.events, ['remote-seek']);
      expect(wrapper.raw.buffering, isTrue);
      expect(controller.isApplyingRemote, isTrue);

      final room = server.roomFor(api)!;
      switch (invalidation) {
        case 'disconnect':
          controller.setConnected(false);
        case 'GroupLeft':
          server.update(api, room, 'GroupLeft', room.groupId);
        case 'LibraryAccessDenied':
          server.update(api, room, 'LibraryAccessDenied', null);
        case 'empty queue':
          room.playlist = [];
          room.index = -1;
          room.updated = world.now;
          server.queue(api, room);
      }
      final requestsAtInvalidation = server.requests.length;
      wrapper.raw.buffering = false;
      wrapper.snapshots.add(wrapper.raw);
      await protocol.settle();

      expect(
          controller.state.status,
          switch (invalidation) {
            'disconnect' => SyncPlayStatus.disconnected,
            'GroupLeft' => SyncPlayStatus.idle,
            'LibraryAccessDenied' => SyncPlayStatus.unknown,
            _ => SyncPlayStatus.joined,
          });
      expect(wrapper.events, ['remote-seek']);
      expect(wrapper.raw.playing, isFalse);
      expect(controller.isApplyingRemote, isFalse);
      expect(server.requests.length, requestsAtInvalidation);
    });
  }

  test('a newer remote pause supersedes an unpause still awaiting its seek',
      () async {
    final ref = _Ref();
    final wrapper = _Wrapper(ref);
    final commands = _Commands();
    wrapper.syncPlayCommands = commands;
    ref.values[videoPlayerProvider] = wrapper;
    final oldSeek = Completer<void>();
    wrapper.seekReady = oldSeek;
    final adapter = SyncPlayPlayerAdapter(
        ref: ref, account: account, api: _Api(), isCurrent: () => true);
    final unpause = adapter.applyRemote(const SyncPlayPlayerAction(
        type: SyncPlayPlayerActionType.unpause,
        position: Duration(seconds: 8)));
    await Future<void>.delayed(Duration.zero);
    expect(wrapper.events, ['remote-seek']);
    wrapper.seekReady = null;
    await adapter.applyRemote(const SyncPlayPlayerAction(
        type: SyncPlayPlayerActionType.pause, position: Duration(seconds: 8)));
    expect(wrapper.raw.playing, isFalse);
    oldSeek.complete();
    await unpause;
    expect(wrapper.events, ['remote-seek', 'remote-pause', 'remote-seek']);
    expect(wrapper.raw.playing, isFalse);
    expect(commands.events, isEmpty);
  });

  test('stale item fetch never starts another request and closes owned client',
      () async {
    var current = true;
    final api = _Api();
    final ref = _Ref();
    ref.values[videoProfileProvider] = const DeviceProfile();
    final loading = createSyncPlayPlaybackModel(
        ref: ref,
        api: api,
        account: account,
        queueItem: entry,
        position: Duration.zero,
        isCurrent: () => current,
        ownsApi: true);
    final failure = expectLater(loading, throwsA(isA<SyncPlayFailure>()));
    current = false;
    api.itemReady.complete(response(dto));
    await failure;
    expect(api.itemCalls, 1);
    expect(api.infoCalls, 0);
    expect(api.ownedClient.transport.closes, 1);
    expect(api.ownedClient.disposes, 1);
  });

  for (final source in const [
    MediaSourceInfo(id: mediaId, supportsDirectPlay: true),
    MediaSourceInfo(
        id: mediaId,
        supportsTranscoding: true,
        transcodingUrl:
            'Videos/test/master.m3u8?api_key=stale-fixture&segment=1'),
    MediaSourceInfo(
        id: mediaId,
        supportsTranscoding: true,
        transcodingUrl:
            'https://media.example.invalid/jf/Videos/test/master.m3u8?api_key=stale-fixture&segment=1'),
  ]) {
    test(
        'captured playback uses canonical authentication (${source.transcodingUrl ?? 'direct'})',
        () async {
      final container = ProviderContainer(overrides: [
        videoProfileProvider.overrideWith((_) => const DeviceProfile())
      ]);
      addTearDown(container.dispose);
      final refProvider = Provider<Ref>((ref) => ref);
      final api = _Api();
      api.itemReady.complete(response(dto));
      api.infoReady
          .complete(response(PlaybackInfoResponse(mediaSources: [source])));
      final model = await createSyncPlayPlaybackModel(
          ref: container.read(refProvider),
          api: api,
          account: account,
          queueItem: entry,
          position: Duration.zero,
          isCurrent: () => true,
          ownsApi: true);
      final uri = Uri.parse(model.media!.url);
      expect(uri.origin, 'https://media.example.invalid');
      expect(uri.path, startsWith('/jf/Videos/'));
      expect(uri.queryParameters['ApiKey'], account.credentials.token);
      expect(uri.queryParameters.containsKey('api_key'), isFalse);
      if (source.supportsTranscoding == true) {
        expect(uri.queryParameters['segment'], '1');
      }
      model.dispose();
      expect(api.ownedClient.transport.closes, 1);
    });
  }

  test('foreign transcoding origin is refused before model creation', () async {
    final api = _Api();
    final ref = _Ref();
    ref.values[videoProfileProvider] = const DeviceProfile();
    api.itemReady.complete(response(dto));
    api.infoReady.complete(response(const PlaybackInfoResponse(mediaSources: [
      MediaSourceInfo(
          id: mediaId,
          supportsTranscoding: true,
          transcodingUrl: 'https://foreign.example.invalid/stream')
    ])));
    await expectLater(
        createSyncPlayPlaybackModel(
            ref: ref,
            api: api,
            account: account,
            queueItem: entry,
            position: Duration.zero,
            isCurrent: () => true),
        throwsA(isA<SyncPlayFailure>()));
  });

  test(
      'post-leave reporting survives room teardown; account invalidation blocks it; ownership shared',
      () async {
    final api = _Api();
    var accountCurrent = true;
    final owner = SyncPlayPlaybackApiOwner(api, ownsApi: true);
    SyncPlayQueue? roomQueue = SyncPlayQueue(
        lastUpdate: DateTime.utc(2026),
        items: [
          entry,
          const SyncPlayQueueItem(
              mediaId: mediaId,
              playlistItemId: '44444444444444444444444444444444')
        ],
        playingIndex: 0,
        position: Duration.zero,
        isPlaying: false,
        reason: 'NewPlaylist');
    final playback = _model(api,
        current: () => accountCurrent, owner: owner, queue: () => roomQueue);
    final copy = playback.copyWith() as SyncPlayPlaybackModel;
    await copy.playbackStarted(Duration.zero, _Ref());
    expect((api.reports.single as PlaybackStartInfo).isPaused, isTrue);
    await copy.updatePlaybackPosition(const Duration(seconds: 5), true, _Ref());
    final report = api.reports.last as PlaybackProgressInfo;
    expect(report.playlistItemId, entry.playlistItemId);
    expect(
        report.nowPlayingQueue!.map((q) => q.playlistItemId).toSet().length, 2);
    expect(api.ownedClient.transport.closes, 0);
    roomQueue = null;
    expect(copy.serverManagedQueue, isFalse);
    await copy.updatePlaybackPosition(const Duration(seconds: 5), true, _Ref());
    await copy.playbackStopped(const Duration(seconds: 5), null, _Ref());
    expect(api.reports.last, isA<PlaybackStopInfo>());
    accountCurrent = false;
    await copy.updatePlaybackPosition(const Duration(seconds: 6), true, _Ref());
    expect(api.reports.length, 4);
    copy.dispose();
    playback.dispose();
    expect(api.ownedClient.transport.closes, 1);
    expect(api.ownedClient.disposes, 1);
    expect(copy.nextVideo, isNull);
    expect(copy.previousVideo, isNull);
  });

  test(
      'direct wrapper disposal closes captured playback client once without reading disposed Ref',
      () async {
    final container = ProviderContainer();
    final refProvider = Provider<Ref>((ref) => ref);
    final ref = container.read(refProvider);
    final wrapper = MediaControlsWrapper(ref: ref);
    final api = _Api();
    final owner = SyncPlayPlaybackApiOwner(api, ownsApi: true);
    await wrapper.setup(_ReadyPlayer());
    await wrapper.loadVideo(_model(api, owner: owner), Duration.zero, false);
    container.dispose();
    await wrapper.dispose();
    await wrapper.dispose();
    expect(api.ownedClient.transport.closes, 1);
    expect(api.ownedClient.disposes, 1);
  });

  test(
      'group speed is fixed at 1x while ordinary playback still changes backend rate',
      () async {
    final container = ProviderContainer();
    final refProvider = Provider<Ref>((ref) => ref);
    final wrapper = MediaControlsWrapper(ref: container.read(refProvider));
    final backend = _ReadyPlayer();
    final commands = _Commands();
    await wrapper.setup(backend);
    wrapper.syncPlayCommands = commands;
    container.read(playbackRateProvider.notifier).state = 2;
    await wrapper.setSpeed(2);
    expect(backend.rates, isEmpty);
    expect(container.read(playbackRateProvider), 1);
    commands.active = false;
    await wrapper.setSpeed(1.5);
    expect(backend.rates, [1.5]);
    await wrapper.dispose();
    container.dispose();
  });

  for (final resetsOnLoad in [false, true]) {
    test(
        'server queue load resets and awaits the backend rate (${resetsOnLoad ? 'reset on load' : 'retained on load'})',
        () async {
      final container = ProviderContainer();
      final refProvider = Provider<Ref>((ref) => ref);
      final wrapper = MediaControlsWrapper(ref: container.read(refProvider));
      final backend = _ReadyPlayer(resetRateOnLoad: resetsOnLoad);
      final commands = _Commands()..active = false;
      wrapper.syncPlayCommands = commands;
      await wrapper.setup(backend);
      await wrapper.setSpeed(1.5);
      container.read(playbackRateProvider.notifier).state = 1.5;
      expect(backend.rate, 1.5);
      commands.active = true;
      backend.rateReady = Completer<void>();
      final queue = SyncPlayQueue(
          lastUpdate: DateTime.utc(2026),
          items: [entry],
          playingIndex: 0,
          position: Duration.zero,
          isPlaying: false,
          reason: 'NewPlaylist');
      var completed = false;
      final loading = wrapper
          .loadVideo(_model(_Api(), queue: () => queue), Duration.zero, false)
          .then((_) {
        completed = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      expect(backend.rateAndLoadEvents, ['rate:1.5', 'load', 'rate:1.0']);
      expect(commands.events, isEmpty);
      backend.rateReady!.complete();
      await loading;
      expect(backend.rate, 1.0);
      expect(container.read(playbackRateProvider), 1.0);
      await wrapper.dispose();
      container.dispose();
    });
  }

  test(
      'notifier group load stays paused and stale load cannot resume or set tracks',
      () async {
    final ref = _Ref();
    final wrapper = _Wrapper(ref);
    final media = StateController(MediaPlaybackModel());
    final playback = StateController<PlaybackModel?>(null);
    ref.values.addAll({
      mediaPlaybackProvider.notifier: media,
      mediaPlaybackProvider: media.state,
      playBackModel: null,
      playBackModel.notifier: playback,
      playbackRateProvider.notifier: StateController(1.0),
      videoPlayerSettingsProvider: VideoPlayerSettingsModel()
    });
    final notifier = _Notifier(ref, wrapper);
    final api = _Api();
    var current = true;
    wrapper.loadReady = Completer<void>();
    final loading = notifier.loadPlaybackItem(_model(api), Duration.zero,
        playWhenReady: false, isCurrent: () => current);
    await Future<void>.delayed(Duration.zero);
    expect(wrapper.loadedPlaying, isFalse);
    current = false;
    wrapper.loadReady!.complete();
    expect(await loading, isFalse);
    expect(wrapper.events, ['stop', 'load']);
  });
}
