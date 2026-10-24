import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/items/media_streams_model.dart';
import 'package:fladder/models/items/movie_model.dart';
import 'package:fladder/models/playback/playback_model.dart';
import 'package:fladder/models/playback/playback_queue_state.dart';
import 'package:fladder/models/settings/video_player_settings.dart';
import 'package:fladder/providers/settings/video_player_settings_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/wrappers/media_control_wrapper.dart';
import 'package:fladder/wrappers/players/player_states.dart';

class _Wrapper extends MediaControlsWrapper {
  _Wrapper(Ref ref) : super(ref: ref);

  PlayerOptions selected = PlayerOptions.nativePlayer;
  final changes = <PlayerOptions?>[];
  Completer<void>? initializationGate;
  Completer<void>? stopGate;
  int stops = 0;
  int disposals = 0;
  int loads = 0;
  bool failInitialization = false;
  final events = StreamController<PlayerState>.broadcast();

  @override
  bool get hasPlayer => true;
  @override
  PlayerOptions get backend => selected;
  @override
  bool get supportsSyncPlay => selected != PlayerOptions.nativePlayer;
  @override
  Stream<PlayerState> get stateStream => events.stream;
  @override
  Future<void> stop({bool preserveSleepTimer = false}) async {
    stops++;
    await stopGate?.future;
  }

  @override
  Future<void> dispose() async => disposals++;
  @override
  Future<void> init({PlayerOptions? overridePlayer}) async {
    changes.add(overridePlayer);
    await initializationGate?.future;
    if (failInitialization) throw StateError('synthetic renderer failure');
    selected =
        overridePlayer ?? ref.read(videoPlayerSettingsProvider).wantedPlayer;
  }

  @override
  Future<void> loadVideo(PlaybackModel model, Duration startPosition, bool play,
          {bool Function()? isCurrent}) async =>
      loads++;
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<int> setAudioTrack(
          AudioStreamModel? model, PlaybackModel playbackModel) async =>
      0;
  @override
  Future<int> setSubtitleTrack(
          SubStreamModel? model, PlaybackModel playbackModel) async =>
      0;
}

class _Video extends VideoPlayerNotifier {
  _Video(super.ref) {
    state = _Wrapper(ref);
  }
}

class _Model extends Fake implements PlaybackModel {
  _Model({this.managed = false, this.stopBeforeAudioQueue = false});
  final bool managed;
  final bool stopBeforeAudioQueue;
  @override
  bool get serverManagedQueue => managed;
  @override
  ItemBaseModel get item => MovieModel.fromBaseDto(
      const BaseItemDto(
          id: 'fixture-video', name: 'Fixture', type: BaseItemKind.movie),
      null);
  @override
  Media get media => const Media(url: 'https://fixture.example.invalid/video');
  @override
  MediaStreamsModel? get mediaStreams => null;
  @override
  Future<Duration> resolvedStartPosition(
          [Duration? requestedStartPosition]) async =>
      requestedStartPosition ?? Duration.zero;
  @override
  PlaybackModel updatePlaybackQueue(PlaybackQueueState newQueue) {
    if (stopBeforeAudioQueue) {
      throw StateError('synthetic audio queue boundary');
    }
    return this;
  }

  @override
  void dispose() {}
}

void main() {
  late ProviderContainer container;
  late _Video video;
  late _Wrapper wrapper;

  setUp(() {
    container = ProviderContainer(overrides: [
      videoPlayerSettingsProvider.overrideWith((ref) =>
          VideoPlayerSettingsProviderNotifier(ref)
            ..applyRestoredSettings(VideoPlayerSettingsModel(
                playerOptions: PlayerOptions.nativePlayer))),
      videoPlayerProvider.overrideWith((ref) => _Video(ref)),
    ]);
    video = container.read(videoPlayerProvider.notifier) as _Video;
    wrapper = container.read(videoPlayerProvider) as _Wrapper;
  });
  tearDown(() async {
    container.dispose();
    await wrapper.events.close();
  });

  test('existing supported renderer needs no destructive initialization',
      () async {
    wrapper.selected = PlayerOptions.libMPV;
    expect(await video.prepareSyncPlayPlayback(isCurrent: () => true), isTrue);
    expect(wrapper.changes, isEmpty);
    expect(wrapper.stops, 0);
    expect(wrapper.disposals, 0);
  });

  test('room video uses temporary MPV; ordinary video restores saved Native',
      () async {
    expect(await video.prepareSyncPlayPlayback(isCurrent: () => true), isTrue);
    expect(wrapper.selected, PlayerOptions.libMPV);
    expect(container.read(videoPlayerSettingsProvider).wantedPlayer,
        PlayerOptions.nativePlayer);
    expect(
        await video.loadPlaybackItem(_Model(managed: true), Duration.zero,
            playWhenReady: false),
        isTrue);
    expect(wrapper.changes, [PlayerOptions.libMPV]);
    expect(
        await video.loadPlaybackItem(_Model(), Duration.zero,
            playWhenReady: false),
        isTrue);
    expect(wrapper.changes, [PlayerOptions.libMPV, null]);
    expect(wrapper.selected, PlayerOptions.nativePlayer);
    expect(container.read(videoPlayerSettingsProvider).wantedPlayer,
        PlayerOptions.nativePlayer);
  });

  test('ordinary audio restores configured renderer before opening its queue',
      () async {
    expect(await video.prepareSyncPlayPlayback(isCurrent: () => true), isTrue);
    // AudioQueueHandler is a static extension that initializes a real MPV.
    // Stop at model construction after restoration, before invoking that path.
    final model = _Model(stopBeforeAudioQueue: true);
    await expectLater(
        video.loadAudioPlaybackItem(model, [model.item], 0, Duration.zero),
        throwsStateError);
    expect(wrapper.selected, PlayerOptions.nativePlayer);
    expect(wrapper.changes, [PlayerOptions.libMPV, null]);
  });

  test('cancelled request queued behind initialization cannot replace renderer',
      () async {
    final gate = Completer<void>();
    wrapper.initializationGate = gate;
    final initializing = video.init();
    var current = true;
    final preparing = video.prepareSyncPlayPlayback(isCurrent: () => current);
    await Future<void>.delayed(Duration.zero);
    current = false;
    gate.complete();
    await initializing;
    expect(await preparing, isFalse);
    expect(wrapper.changes, [null]);
    expect(wrapper.selected, PlayerOptions.nativePlayer);
  });

  test('cancellation while stopping prevents disposal and replacement',
      () async {
    final gate = Completer<void>();
    wrapper.stopGate = gate;
    var current = true;
    final preparing = video.prepareSyncPlayPlayback(isCurrent: () => current);
    await Future<void>.delayed(Duration.zero);
    current = false;
    gate.complete();
    expect(await preparing, isFalse);
    expect(wrapper.stops, 1);
    expect(wrapper.disposals, 0);
    expect(wrapper.changes, isEmpty);
  });

  test(
      'renderer preparation failure is a retryable false without changing preference',
      () async {
    wrapper.failInitialization = true;
    expect(await video.prepareSyncPlayPlayback(isCurrent: () => true), isFalse);
    expect(container.read(videoPlayerSettingsProvider).wantedPlayer,
        PlayerOptions.nativePlayer);
    wrapper.failInitialization = false;
    expect(await video.prepareSyncPlayPlayback(isCurrent: () => true), isTrue);
    expect(wrapper.selected, PlayerOptions.libMPV);
  });
}
