import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/items/movie_model.dart';
import 'package:fladder/models/media_playback_model.dart';
import 'package:fladder/models/playback/playback_model.dart';
import 'package:fladder/models/settings/client_settings_model.dart';
import 'package:fladder/models/settings/subtitle_settings_model.dart';
import 'package:fladder/models/settings/video_player_settings.dart';
import 'package:fladder/providers/segment_skip_provider.dart';
import 'package:fladder/providers/settings/client_settings_provider.dart';
import 'package:fladder/providers/settings/subtitle_settings_provider.dart';
import 'package:fladder/providers/settings/video_player_settings_provider.dart';
import 'package:fladder/providers/sleep_timer_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/services/playback_reporting_scope.dart';
import 'package:fladder/services/remote_control/remote_control_models.dart';
import 'package:fladder/services/syncplay/syncplay_player_commands.dart';
import 'package:fladder/util/jms_test_profile_policy.dart';
import 'package:fladder/util/localization_helper.dart';
import 'package:fladder/util/sleep_timer.dart';
import 'package:fladder/wrappers/media_control_wrapper.dart';
import 'package:fladder/wrappers/players/base_player.dart';
import 'package:fladder/wrappers/players/player_states.dart';

class _Subscription<T> extends Fake implements ProviderSubscription<T> {
  @override
  void close() {}
}

class _Ref extends Fake implements Ref {
  final values = <Object, Object?>{};
  @override
  T read<T>(ProviderListenable<T> provider) {
    if (values.containsKey(provider)) return values[provider] as T;
    final model = values[playBackModel] as PlaybackModel?;
    if (T == _typeOf<ItemBaseModel?>()) return model?.item as T;
    if (T == _typeOf<Future<Duration>?>()) return model?.startDuration() as T;
    throw StateError('Unexpected fixture provider: $provider');
  }

  @override
  ProviderSubscription<T> listen<T>(ProviderListenable<T> provider,
          void Function(T? previous, T next) listener,
          {void Function(Object, StackTrace)? onError,
          bool fireImmediately = false}) =>
      _Subscription<T>();
}

Type _typeOf<T>() => T;

class _Scope extends Fake implements PlaybackReportingScope {
  bool valid = true;
  @override
  bool get isCurrent => valid;
  @override
  bool get isOwned => valid;
  @override
  bool activate() => valid;
}

class _Playback extends PlaybackModel {
  _Playback(String session, this.scope)
      : super(
            item: MovieModel.fromBaseDto(
                const BaseItemDto(
                    id: 'item',
                    name: 'Fixture',
                    type: BaseItemKind.movie,
                    mediaType: MediaType.video),
                null),
            media: const Media(url: 'https://fixture.invalid/synthetic'),
            playbackInfo: PlaybackInfoResponse(playSessionId: session),
            reportingScope: scope);
  final _Scope scope;
  final reports = <String>[];
  @override
  Future<Duration> startDuration() async => Duration.zero;
  @override
  Future<PlaybackModel?> playbackStarted(Duration position, Ref ref) async {
    reports.add('start');
    return null;
  }

  @override
  Future<PlaybackModel?> updatePlaybackPosition(
      Duration position, bool playing, Ref ref) async {
    reports.add('progress:$playing');
    return null;
  }

  @override
  Future<PlaybackModel?> playbackStopped(
      Duration position, Duration? duration, Ref ref) async {
    reports.add('stop');
    return null;
  }
}

class _Player extends Fake implements BasePlayer {
  _Player({bool sourceSync = true})
      : input = StreamController<PlayerState>.broadcast(sync: sourceSync);
  final StreamController<PlayerState> input;
  final calls = <String>[];
  Completer<void>? actionGate;
  @override
  PlayerState lastState = PlayerState(
      playing: true, duration: const Duration(seconds: 100), buffering: false);
  @override
  Stream<PlayerState> get stateStream => input.stream;
  @override
  Future<void> init(VideoPlayerSettingsModel settings) async {}
  @override
  Future<void> dispose() async {
    await input.close();
  }

  @override
  void applySubtitleSettings(SubtitleSettingsModel settings) {}
  @override
  Future<void> play() async {
    calls.add('play');
    await actionGate?.future;
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    await actionGate?.future;
  }

  @override
  Future<void> seek(Duration position) async {
    calls.add('seek');
    await actionGate?.future;
  }

  @override
  Future<void> loadVideo(String url, bool play,
      {Duration startPosition = Duration.zero}) async {}
}

class _Group extends Fake implements SyncPlayPlayerCommands {
  @override
  bool get active => true;
}

class _Harness {
  _Harness({bool sourceSync = true}) : player = _Player(sourceSync: sourceSync);
  final ref = _Ref();
  final _Player player;
  final scope = _Scope();
  final media = StateController(MediaPlaybackModel(
      state: VideoPlayerState.fullScreen,
      position: const Duration(seconds: 12),
      playing: true));
  late final model = _Playback('occurrence', scope);
  late final sleep = SleepTimerController(pause: () async {});
  late final wrapper = MediaControlsWrapper(ref: ref);
  bool ownerCurrent = true;
  Future<void> init() async {
    ref.values.addAll({
      playBackModel: model,
      mediaPlaybackProvider: media.state,
      mediaPlaybackProvider.notifier: media,
      sleepTimerProvider: sleep,
      videoPlayerSettingsProvider: VideoPlayerSettingsModel(),
      subtitleSettingsProvider: const SubtitleSettingsModel(),
      segmentSkipSessionProvider: SegmentSkipSession(),
      clientSettingsProvider:
          ClientSettingsModel.defaultModel().copyWith(enableMediaKeys: false),
      localizationContextProvider: null
    });
    await wrapper.setup(player);
  }

  Future<void> action(String action) => switch (action) {
        'play' => wrapper.playRemotely(isCurrent: () => ownerCurrent),
        'pause' => wrapper.pauseRemotely(isCurrent: () => ownerCurrent),
        _ => wrapper.seekRemotely(const Duration(seconds: 35),
            isCurrent: () => ownerCurrent),
      };
  Future<void> close() async {
    await wrapper.dispose();
    sleep.dispose();
    media.dispose();
    await player.input.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const wakelockChannel =
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle';
  setUpAll(() {
    JmsTestProfilePolicy.enableRuntimeIsolation();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
            wakelockChannel,
            (_) async =>
                const StandardMessageCodec().encodeMessage(<Object?>[null]));
  });
  tearDownAll(() {
    JmsTestProfilePolicy.resetRuntimeIsolationForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(wakelockChannel, null);
  });

  for (final action in ['play', 'pause', 'seek']) {
    for (final change in ['account', 'model', 'renderer', 'disable']) {
      test(
          'pending remote $action cannot write REST or UI after $change changes',
          () async {
        final h = _Harness();
        await h.init();
        h.player.actionGate = Completer<void>();
        final operation = h.action(action);
        final failed =
            expectLater(operation, throwsA(isA<RemoteControlFailure>()));
        expect(h.player.calls, [action]);
        if (change == 'account') {
          h.ownerCurrent = false;
          h.scope.valid = false;
        }
        if (change == 'disable') h.ownerCurrent = false;
        if (change == 'model') {
          h.ref.values[playBackModel] = _Playback('replay', _Scope());
        }
        if (change == 'renderer') await h.wrapper.setup(_Player());
        h.player.actionGate!.complete();
        await failed;
        expect(h.model.reports, isEmpty);
        expect(h.wrapper.playbackState.value.playing, isFalse);
        expect(h.media.state.position, const Duration(seconds: 12));
        await h.close();
      });
    }
  }

  test(
      'remote pause and seek retain normal reporting and manual-seek behavior while current',
      () async {
    final h = _Harness();
    await h.init();
    await h.action('pause');
    expect(h.model.reports, ['progress:false']);
    h.player.lastState.playing = false;
    await h.action('seek');
    expect(h.media.state.position, const Duration(seconds: 35));
    expect(h.player.calls, ['pause', 'seek']);
    await h.close();
  });

  test(
      'remote play retains explicit sleep-timer resume and start report while current',
      () async {
    final h = _Harness();
    await h.init();
    h.sleep.afterEpisode('item');
    h.sleep.bindMedia('item');
    h.sleep.completed();
    await h.action('play');
    expect(h.sleep.allowsPlayback, isTrue);
    expect(h.model.reports, ['start']);
    await h.close();
  });

  test('SyncPlay refuses every remote route without issuing a room command',
      () async {
    final h = _Harness();
    await h.init();
    h.wrapper.syncPlayCommands = _Group();
    for (final action in ['play', 'pause', 'seek']) {
      await expectLater(h.action(action), throwsA(isA<RemoteControlFailure>()));
    }
    expect(h.player.calls, isEmpty);
    expect(h.model.reports, isEmpty);
    await h.close();
  });

  test(
      'ordinary play pause seek keep their existing paths while scope is current',
      () async {
    final h = _Harness();
    await h.init();
    await h.wrapper.play();
    await h.wrapper.pause();
    h.player.lastState.playing = false;
    await h.wrapper.seek(const Duration(seconds: 25));
    expect(h.model.reports, ['start', 'progress:false']);
    expect(h.player.calls, ['play', 'pause', 'seek']);
    expect(h.media.state.position, const Duration(seconds: 25));
    await h.close();
  });

  test(
      'ordinary pending pause also drops new REST/UI commits when account scope expires',
      () async {
    final h = _Harness();
    await h.init();
    h.player.actionGate = Completer<void>();
    final operation = h.wrapper.pause();
    h.scope.valid = false;
    h.player.actionGate!.complete();
    await operation;
    expect(h.model.reports, isEmpty);
    expect(h.wrapper.playbackState.value.playing, isFalse);
    await h.close();
  });

  for (final action in ['play', 'pause', 'seek']) {
    for (final replacement in ['renderer', 'model']) {
      test(
          'ordinary pending $action cannot commit into a replacement $replacement',
          () async {
        final h = _Harness();
        await h.init();
        h.player.actionGate = Completer<void>();
        final operation = switch (action) {
          'play' => h.wrapper.play(),
          'pause' => h.wrapper.pause(),
          _ => h.wrapper.seek(const Duration(seconds: 35)),
        };
        if (replacement == 'renderer') await h.wrapper.setup(_Player());
        if (replacement == 'model') {
          h.ref.values[playBackModel] = _Playback('replay', _Scope());
        }
        h.player.actionGate!.complete();
        await operation;
        expect(h.model.reports, isEmpty);
        expect(h.media.state.position, const Duration(seconds: 12));
        expect(h.wrapper.playbackState.value.playing, isFalse);
        await h.close();
      });
    }
  }

  test(
      'backend queued event retains the subscription occurrence through delayed delivery',
      () async {
    final h = _Harness(sourceSync: false);
    await h.init();
    final delivered = <PlayerState>[];
    final sub = h.wrapper.stateStream.listen(delivered.add);
    h.player.input.add(
        PlayerState(completed: true, position: const Duration(seconds: 90)));
    h.ref.values[playBackModel] = _Playback('new-occurrence', _Scope());
    await Future<void>.delayed(Duration.zero);
    expect(delivered, isEmpty);
    expect(h.wrapper.playbackState.value.updatePosition, Duration.zero);
    await sub.cancel();
    await h.close();
  });

  test(
      'queued renderer event cannot reach UI after account or occurrence changes',
      () async {
    for (final account in [true, false]) {
      final h = _Harness();
      await h.init();
      final delivered = <PlayerState>[];
      final sub = h.wrapper.stateStream.listen(delivered.add);
      h.player.input.add(
          PlayerState(playing: true, position: const Duration(seconds: 80)));
      if (account) {
        h.scope.valid = false;
      } else {
        h.ref.values[playBackModel] = _Playback('new-occurrence', _Scope());
      }
      await Future<void>.delayed(Duration.zero);
      expect(delivered, isEmpty);
      expect(h.wrapper.playbackState.value.updatePosition, Duration.zero);
      await sub.cancel();
      await h.close();
    }
  });
}
