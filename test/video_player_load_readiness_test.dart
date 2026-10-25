import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smtc_windows/src/rust/api/api.dart';
import 'package:smtc_windows/src/rust/frb_generated.dart';

import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/items/media_streams_model.dart';
import 'package:fladder/models/playback/playback_model.dart';
import 'package:fladder/models/settings/video_player_settings.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/wrappers/media_control_wrapper.dart';
import 'package:fladder/wrappers/players/player_states.dart';

class _Item extends Fake implements ItemBaseModel {
  @override
  FladderItemType get type => FladderItemType.movie;
}

class _Playback extends Fake implements PlaybackModel {
  _Playback({this.serverManagedQueue = false});
  @override
  final bool serverManagedQueue;
  @override
  ItemBaseModel get item => _Item();
  @override
  Media get media => const Media(url: 'https://fixture.invalid/synthetic');
  @override
  MediaStreamsModel? get mediaStreams => null;
  @override
  Future<Duration> resolvedStartPosition(
          [Duration? requestedStartPosition]) async =>
      requestedStartPosition ?? Duration.zero;
  @override
  void dispose() {}
}

class _Wrapper extends MediaControlsWrapper {
  _Wrapper({required super.ref});
  final snapshots = StreamController<PlayerState>.broadcast(sync: true);
  // A previous video's last snapshot must never make the new open ready.
  final previousSnapshot = PlayerState(buffering: false, playing: true);
  Future<void> Function()? duringLoad;
  Future<void> Function()? duringStop;
  Future<void> Function()? duringSubtitleSetup;
  bool? requestedPlay;
  int playCalls = 0;
  @override
  bool get hasPlayer => true;
  @override
  Stream<PlayerState> get stateStream => snapshots.stream;
  @override
  PlayerState get lastState => previousSnapshot;
  @override
  Future<void> init({PlayerOptions? overridePlayer}) async {}
  @override
  Future<void> stop({bool preserveSleepTimer = false}) async =>
      await duringStop?.call();
  @override
  Future<void> dispose() async {}
  @override
  Future<void> loadVideo(
      PlaybackModel playbackModel, Duration startPosition, bool play,
      {bool Function()? isCurrent}) async {
    requestedPlay = play;
    await duringLoad?.call();
  }

  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<int> setAudioTrack(
          AudioStreamModel? model, PlaybackModel playbackModel) async =>
      -1;
  @override
  Future<int> setSubtitleTrack(
      SubStreamModel? model, PlaybackModel playbackModel) async {
    await duringSubtitleSetup?.call();
    return -1;
  }

  @override
  Future<void> play({bool userInitiated = true}) async {
    playCalls++;
  }

  void emit({required bool buffering}) =>
      snapshots.add(PlayerState(buffering: buffering));
}

class _Notifier extends VideoPlayerNotifier {
  _Notifier(super.ref, _Wrapper wrapper) {
    state = wrapper;
  }
}

class _Smtc extends Fake implements SmtcInternal {}

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => RustLib.initMock(api: _SmtcApi()));
  tearDownAll(RustLib.dispose);
  late ProviderContainer container;
  late _Wrapper wrapper;
  late _Notifier notifier;
  setUp(() async {
    container = ProviderContainer();
    notifier = container.read(Provider<_Notifier>((ref) {
      wrapper = _Wrapper(ref: ref);
      return _Notifier(ref, wrapper);
    }));
    // Exercise the production subscription; no synthetic mirroring of its logic.
    await notifier.init();
  });
  tearDown(() async {
    notifier.dispose();
    await wrapper.snapshots.close();
    container.dispose();
  });

  test('backend ready during open is retained after load completion', () async {
    wrapper.duringLoad = () async => wrapper.emit(buffering: false);
    expect(await notifier.loadPlaybackItem(_Playback(), Duration.zero), isTrue);
    expect(container.read(mediaPlaybackProvider).buffering, isFalse);
    expect(wrapper.playCalls, 1);
  });

  test('backend ready during track setup is retained after load completion',
      () async {
    wrapper.duringSubtitleSetup = () async => wrapper.emit(buffering: false);
    expect(await notifier.loadPlaybackItem(_Playback(), Duration.zero), isTrue);
    expect(container.read(mediaPlaybackProvider).buffering, isFalse);
  });

  test('old ready snapshot with no fresh event keeps new media buffering',
      () async {
    expect(wrapper.lastState.buffering, isFalse);
    expect(await notifier.loadPlaybackItem(_Playback(), Duration.zero), isTrue);
    expect(container.read(mediaPlaybackProvider).buffering, isTrue);
  });

  test('paused room load can finish ready without starting playback', () async {
    container.read(mediaPlaybackProvider.notifier).update((value) =>
        value.copyWith(position: const Duration(minutes: 9, seconds: 29)));
    wrapper.duringStop = () async => container
        .read(mediaPlaybackProvider.notifier)
        .update(
            (value) => value.copyWith(position: Duration.zero, playing: false));
    wrapper.duringLoad = () async => wrapper.snapshots.add(PlayerState(
        position: const Duration(minutes: 9, seconds: 29),
        playing: false,
        buffering: false));
    expect(
        await notifier.loadPlaybackItem(_Playback(serverManagedQueue: true),
            const Duration(minutes: 9, seconds: 29),
            playWhenReady: false),
        isTrue);
    expect(container.read(mediaPlaybackProvider).buffering, isFalse);
    expect(wrapper.requestedPlay, isFalse);
    expect(wrapper.playCalls, 0);
    expect(container.read(mediaPlaybackProvider).playing, isFalse);
    expect(container.read(mediaPlaybackProvider).position,
        const Duration(minutes: 9, seconds: 29));
    expect(container.read(mediaPlaybackProvider).lastPosition,
        const Duration(minutes: 9, seconds: 29));
  });

  test('paused room load cannot overwrite a newer seek during track setup',
      () async {
    wrapper.duringLoad = () async => wrapper.emit(buffering: false);
    wrapper.duringSubtitleSetup = () async => container
        .read(mediaPlaybackProvider.notifier)
        .update((value) => value.copyWith(
            position: const Duration(minutes: 12),
            lastPosition: const Duration(minutes: 12)));
    expect(
        await notifier.loadPlaybackItem(_Playback(serverManagedQueue: true),
            const Duration(minutes: 9, seconds: 29),
            playWhenReady: false),
        isTrue);
    expect(container.read(mediaPlaybackProvider).position,
        const Duration(minutes: 12));
    expect(container.read(mediaPlaybackProvider).playing, isFalse);
    expect(wrapper.playCalls, 0);
  });

  test('latest fresh buffering event remains authoritative', () async {
    wrapper.duringLoad = () async {
      wrapper.emit(buffering: false);
      wrapper.emit(buffering: true);
    };
    expect(await notifier.loadPlaybackItem(_Playback(), Duration.zero), isTrue);
    expect(container.read(mediaPlaybackProvider).buffering, isTrue);
  });

  test('invalidated open cannot run final setup or request play', () async {
    var current = true;
    wrapper.duringLoad = () async {
      wrapper.emit(buffering: false);
      container.read(mediaPlaybackProvider.notifier).update(
          (value) => value.copyWith(position: const Duration(seconds: 42)));
      current = false;
    };
    expect(
        await notifier.loadPlaybackItem(_Playback(), Duration.zero,
            isCurrent: () => current),
        isFalse);
    expect(wrapper.playCalls, 0);
    expect(container.read(mediaPlaybackProvider).position,
        const Duration(seconds: 42));
  });
}
