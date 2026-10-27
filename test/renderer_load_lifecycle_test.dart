import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:smtc_windows/src/rust/api/api.dart';
import 'package:smtc_windows/src/rust/frb_generated.dart';

import 'package:fladder/models/playback/playback_model.dart';
import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/items/media_streams_model.dart';
import 'package:fladder/services/playback_diagnostics.dart';
import 'package:fladder/models/settings/video_player_settings.dart';
import 'package:fladder/models/settings/subtitle_settings_model.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/providers/sleep_timer_provider.dart';
import 'package:fladder/wrappers/media_control_wrapper.dart';
import 'package:fladder/wrappers/players/base_player.dart';
import 'package:fladder/wrappers/players/player_states.dart';

class _Notifier extends VideoPlayerNotifier {
  _Notifier(super.ref, MediaControlsWrapper wrapper) {
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
      case #crateApiApiSmtcUpdatePlaybackStatus:
      case #crateApiApiSmtcClearMetadata:
      case #crateApiApiSmtcDisableSmtc:
        return Future<void>.value();
      default:
        return super.noSuchMethod(invocation);
    }
  }
}

class _Item extends Fake implements ItemBaseModel {
  @override
  String get id => 'synthetic-item';
  @override
  FladderItemType get type => FladderItemType.movie;
}

class _Playback extends Fake implements PlaybackModel {
  @override
  bool get serverManagedQueue => false;
  @override
  bool get ownsPlaybackResources => false;
  @override
  ItemBaseModel get item => _Item();
  @override
  Media? get media => const Media(url: 'https://fixture.invalid/synthetic');
  @override
  MediaStreamsModel? get mediaStreams => null;
  @override
  Future<Duration> resolvedStartPosition(
          [Duration? requestedStartPosition]) async =>
      requestedStartPosition ?? Duration.zero;
  @override
  Future<PlaybackModel?> playbackStopped(
          Duration position, Duration? duration, Ref ref) async =>
      null;
  @override
  void dispose() {}
}

class _Wrapper extends MediaControlsWrapper {
  _Wrapper({required super.ref});
  final initQueue = <Future<void>>[];
  final initFailures = <Object>[];
  Future<void>? openGate;
  Future<void>? stopGate;
  final events = <String>[];
  bool available = true;
  bool usingSyncRenderer = false;
  @override
  bool get supportsSyncPlay => usingSyncRenderer;
  @override
  bool get hasPlayer => available;
  Future<void> requestUserStop() => super.stop(preserveSleepTimer: true);
  @override
  Future<void> init({PlayerOptions? overridePlayer}) async {
    available = false;
    usingSyncRenderer = overridePlayer == PlayerOptions.libMPV;
    events.add('init');
    if (initQueue.isNotEmpty) await initQueue.removeAt(0);
    if (initFailures.isNotEmpty) throw initFailures.removeAt(0);
    available = true;
  }

  @override
  Future<void> dispose() async {
    available = false;
  }

  @override
  Stream<PlayerState> get stateStream => const Stream.empty();
  @override
  Future<void> stop({bool preserveSleepTimer = false}) async {
    events.add('stop-start');
    await stopGate;
    events.add('stop-end');
  }

  @override
  Future<void> loadVideo(PlaybackModel model, Duration position, bool play,
      {bool Function()? isCurrent}) async {
    events.add('open');
    await openGate;
  }

  @override
  Future<void> setVolume(double value) async {
    events.add('volume');
  }

  @override
  Future<int> setAudioTrack(
      AudioStreamModel? model, PlaybackModel playback) async {
    events.add('audio');
    return 0;
  }

  @override
  Future<int> setSubtitleTrack(
      SubStreamModel? model, PlaybackModel playback) async {
    events.add('subtitle');
    return 0;
  }

  @override
  Future<void> play({bool userInitiated = true}) async {
    events.add('play');
  }

  @override
  Future<void> openPlayer(BuildContext context) async {
    events.add('route');
  }
}

class _Subscription extends Fake implements StreamSubscription<PlayerState> {
  @override
  Future<void> cancel() async {}
}

/// Delivers a captured callback even after cancellation, like an already queued
/// event from a replaced native player. It never emits actual native traffic.
class _CapturedStream extends Stream<PlayerState> {
  void Function(PlayerState)? callback;
  @override
  StreamSubscription<PlayerState> listen(void Function(PlayerState)? onData,
      {Function? onError, void Function()? onDone, bool? cancelOnError}) {
    callback = onData;
    return _Subscription();
  }
}

class _StatePlayer extends Fake implements BasePlayer {
  final stream = _CapturedStream();
  final stopped = Completer<void>();
  final stopQueue = <Future<void>>[];
  Future<void>? openGate;
  int stops = 0;
  @override
  PlayerState lastState = PlayerState();
  @override
  Future<void> stop() {
    stops++;
    return stopQueue.isNotEmpty ? stopQueue.removeAt(0) : stopped.future;
  }

  @override
  Future<void> loadVideo(String url, bool play,
          {Duration startPosition = Duration.zero}) async =>
      await openGate;
  @override
  void applySubtitleSettings(SubtitleSettingsModel settings) {}
  @override
  Future<void> init(VideoPlayerSettingsModel settings) async {}
  @override
  Future<void> dispose() async {}
  @override
  Stream<PlayerState> get stateStream => stream;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const wakelockChannel =
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle';
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
            wakelockChannel,
            (_) async =>
                const StandardMessageCodec().encodeMessage(<Object?>[null]));
  });
  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(wakelockChannel, null);
  });
  setUpAll(() => RustLib.initMock(api: _SmtcApi()));
  tearDownAll(RustLib.dispose);
  late ProviderContainer container;
  late _Wrapper wrapper;
  late _Notifier notifier;
  setUp(() {
    container = ProviderContainer();
    wrapper = container.read(Provider((ref) => _Wrapper(ref: ref)));
    notifier = container.read(Provider((ref) => _Notifier(ref, wrapper)));
    PlaybackDiagnostics.instance.clear();
  });
  tearDown(() {
    notifier.dispose();
    container.dispose();
  });

  test('reinitialization during open invalidates late track and play actions',
      () async {
    final open = Completer<void>();
    wrapper.openGate = open.future;
    final attempt = PlaybackDiagnostics.instance.startAttempt();
    final loading = notifier.loadPlaybackItem(_Playback(), Duration.zero,
        diagnosticAttempt: attempt);
    await Future<void>.delayed(Duration.zero);
    expect(wrapper.events, contains('open'));
    await notifier.init();
    open.complete();
    expect(await loading, isFalse);
    expect(wrapper.events, isNot(contains('volume')));
    expect(wrapper.events, isNot(contains('audio')));
    expect(wrapper.events, isNot(contains('subtitle')));
    expect(wrapper.events, isNot(contains('play')));
    expect(notifier.isPlaybackAttemptCurrent(attempt), isFalse);
  });

  test('rapid replacement ignores the older open completion', () async {
    final oldOpen = Completer<void>();
    wrapper.openGate = oldOpen.future;
    final firstAttempt = PlaybackDiagnostics.instance.startAttempt();
    final first = notifier.loadPlaybackItem(_Playback(), Duration.zero,
        diagnosticAttempt: firstAttempt);
    await Future<void>.delayed(Duration.zero);
    wrapper.openGate = null;
    final nextAttempt = PlaybackDiagnostics.instance.startAttempt();
    expect(
        await notifier.loadPlaybackItem(_Playback(), Duration.zero,
            diagnosticAttempt: nextAttempt),
        isTrue);
    final plays = wrapper.events.where((e) => e == 'play').length;
    oldOpen.complete();
    expect(await first, isFalse);
    expect(wrapper.events.where((e) => e == 'play').length, plays);
    expect(notifier.isPlaybackAttemptCurrent(firstAttempt), isFalse);
    expect(notifier.isPlaybackAttemptCurrent(nextAttempt), isTrue);
  });

  test('cancelled pending open cannot apply tracks or start playback',
      () async {
    final open = Completer<void>();
    wrapper.openGate = open.future;
    var current = true;
    final loading = notifier.loadPlaybackItem(_Playback(), Duration.zero,
        isCurrent: () => current);
    await Future<void>.delayed(Duration.zero);
    current = false;
    open.completeError(StateError('synthetic stale open'));
    expect(await loading, isFalse);
    expect(wrapper.events, isNot(contains('audio')));
    expect(wrapper.events, isNot(contains('play')));
    expect(PlaybackDiagnostics.instance.exportText(),
        contains('request_invalidated'));
    expect(PlaybackDiagnostics.instance.exportText(),
        isNot(contains('synthetic stale open')));
  });

  test('pending stop prevents the next media open', () async {
    final stopped = Completer<void>();
    wrapper.stopGate = stopped.future;
    final loading = notifier.loadPlaybackItem(_Playback(), Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(wrapper.events, contains('stop-start'));
    expect(wrapper.events, isNot(contains('open')));
    stopped.complete();
    expect(await loading, isTrue);
    expect(wrapper.events.indexOf('stop-end'),
        lessThan(wrapper.events.indexOf('open')));
  });

  test('load waits for the latest queued renderer and cancels old request',
      () async {
    final firstReady = Completer<void>();
    final latestReady = Completer<void>();
    wrapper.initQueue.addAll([firstReady.future, latestReady.future]);
    final firstInit = notifier.init();
    final loading = notifier.loadPlaybackItem(_Playback(), Duration.zero);
    final latestInit = notifier.init();
    var completed = false;
    loading.then((_) => completed = true);
    firstReady.complete();
    await firstInit;
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    expect(wrapper.events, isNot(contains('open')));
    latestReady.complete();
    await latestInit;
    expect(await loading, isFalse);
    expect(await notifier.waitUntilReady(), isTrue);
  });

  test('explicit play recovers one failed early renderer setup', () async {
    wrapper.initFailures.add(StateError('synthetic startup failure'));
    await expectLater(notifier.init(), throwsA(isA<StateError>()));
    expect(await notifier.waitUntilReady(), isFalse);

    final attempt = PlaybackDiagnostics.instance.startAttempt();
    expect(
        await notifier.loadPlaybackItem(_Playback(), Duration.zero,
            diagnosticAttempt: attempt),
        isTrue);
    expect(wrapper.events.where((event) => event == 'init'), hasLength(2));
    expect(wrapper.events.where((event) => event == 'open'), hasLength(1));
    expect(wrapper.events, contains('play'));
    final log = PlaybackDiagnostics.instance.exportText();
    expect(log, contains('renderer_retry'));
    expect(log, isNot(contains('synthetic startup failure')));
  });

  test('failed renderer retry is bounded to one setup per play', () async {
    wrapper.initFailures.addAll([
      StateError('synthetic startup failure'),
      TimeoutException('synthetic retry failure'),
    ]);
    await expectLater(notifier.init(), throwsA(isA<StateError>()));

    expect(await notifier.loadPlaybackItem(_Playback(), Duration.zero), isFalse);
    expect(wrapper.events.where((event) => event == 'init'), hasLength(2));
    expect(wrapper.events, isNot(contains('open')));
    expect(wrapper.events, isNot(contains('play')));
    final log = PlaybackDiagnostics.instance.exportText();
    expect(log, contains('error=StateError'));
    expect(log, contains('error=TimeoutException'));
    expect(log, contains('renderer_unavailable'));
    expect(log, isNot(contains('synthetic startup failure')));
    expect(log, isNot(contains('synthetic retry failure')));
  });

  test('concurrent loads share renderer recovery and only latest opens',
      () async {
    wrapper.initFailures.add(StateError('synthetic startup failure'));
    await expectLater(notifier.init(), throwsA(isA<StateError>()));
    final ready = Completer<void>();
    wrapper.initQueue.add(ready.future);

    final first = notifier.loadPlaybackItem(_Playback(), Duration.zero);
    await Future<void>.delayed(Duration.zero);
    final second = notifier.loadPlaybackItem(_Playback(), Duration.zero);
    ready.complete();

    expect(await first, isFalse);
    expect(await second, isTrue);
    expect(wrapper.events.where((event) => event == 'init'), hasLength(2));
    expect(wrapper.events.where((event) => event == 'open'), hasLength(1));
    expect(wrapper.events.where((event) => event == 'play'), hasLength(1));
  });

  test('user stop during renderer retry revokes the pending play', () async {
    wrapper.initFailures.add(StateError('synthetic startup failure'));
    await expectLater(notifier.init(), throwsA(isA<StateError>()));
    final ready = Completer<void>();
    wrapper.initQueue.add(ready.future);

    final loading = notifier.loadPlaybackItem(_Playback(), Duration.zero);
    await Future<void>.delayed(Duration.zero);
    await wrapper.requestUserStop();
    ready.complete();

    expect(await loading, isFalse);
    expect(wrapper.events, isNot(contains('open')));
    expect(wrapper.events, isNot(contains('play')));
  });

  testWidgets('reinit after successful load prevents stale route opening',
      (tester) async {
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (value) {
      context = value;
      return const SizedBox();
    })));
    await tester.runAsync(() async {
      final attempt = PlaybackDiagnostics.instance.startAttempt();
      expect(
          await notifier.loadPlaybackItem(_Playback(), Duration.zero,
              diagnosticAttempt: attempt),
          isTrue);
      await notifier.init();
      await notifier.openPlaybackAttempt(context, attempt,
          isCurrent: () => notifier.isPlaybackAttemptCurrent(attempt));
    });
    expect(wrapper.events, isNot(contains('route')));
  });

  test('queued state callback from replaced player is ignored', () async {
    final actual =
        container.read(Provider((ref) => MediaControlsWrapper(ref: ref)));
    final first = _StatePlayer();
    final next = _StatePlayer();
    final observed = <PlayerState>[];
    final subscription = actual.stateStream.listen(observed.add);
    await actual.setup(first);
    final oldCallback = first.stream.callback!;
    await actual.setup(next);
    oldCallback(PlayerState(duration: const Duration(seconds: 99)));
    next.stream.callback!(PlayerState(duration: const Duration(seconds: 2)));
    await Future<void>.delayed(Duration.zero);
    expect(
        observed.map((event) => event.duration), [const Duration(seconds: 2)]);
    await subscription.cancel();
    await actual.dispose();
  });
  test('wrapper stop stays pending until the native stop actually completes',
      () async {
    final actual =
        container.read(Provider((ref) => MediaControlsWrapper(ref: ref)));
    final player = _StatePlayer();
    await actual.setup(player);
    container.read(playBackModel.notifier).state = _Playback();
    var completed = false;
    final stopping = actual.stopFromSyncPlay().then((_) => completed = true);
    var replacementCompleted = false;
    final replacementStop =
        actual.stopFromSyncPlay().then((_) => replacementCompleted = true);
    // The old implementation returned after its 1s reporting delay despite
    // a still-pending native stop. Keep this gate unresolved past that delay.
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(completed, isFalse);
    expect(replacementCompleted, isFalse);
    player.stopped.complete();
    await Future.wait([stopping, replacementStop])
        .timeout(const Duration(seconds: 4));
    expect(completed, isTrue);
    expect(replacementCompleted, isTrue);
    await actual.dispose();
  });
  test('cancelled current backend open stops only its own player', () async {
    final actual =
        container.read(Provider((ref) => MediaControlsWrapper(ref: ref)));
    final player = _StatePlayer()..stopped.complete();
    final pending = Completer<void>();
    player.openGate = pending.future;
    await actual.setup(player);
    var current = true;
    final loading = actual.loadVideo(_Playback(), Duration.zero, true,
        isCurrent: () => current);
    await Future<void>.delayed(Duration.zero);
    current = false;
    pending.complete();
    await loading;
    expect(player.stops, 1);
    await actual.dispose();
  });

  test('late cancelled open cannot stop a replacement on the same player',
      () async {
    final actual =
        container.read(Provider((ref) => MediaControlsWrapper(ref: ref)));
    final player = _StatePlayer()..stopped.complete();
    final pending = Completer<void>();
    player.openGate = pending.future;
    await actual.setup(player);
    var current = true;
    final first = actual.loadVideo(_Playback(), Duration.zero, true,
        isCurrent: () => current);
    await Future<void>.delayed(Duration.zero);
    current = false;
    player.openGate = null;
    await actual.loadVideo(_Playback(), Duration.zero, true);
    pending.complete();
    await first;
    expect(player.stops, 0);
    await actual.dispose();
  });
  test('coalesced stop preserves a later caller intent to end sleep timer',
      () async {
    final actual =
        container.read(Provider((ref) => MediaControlsWrapper(ref: ref)));
    final player = _StatePlayer();
    await actual.setup(player);
    container.read(playBackModel.notifier).state = _Playback();
    final timer = container.read(sleepTimerProvider);
    timer.countdown(const Duration(minutes: 1));
    final first = actual.stopFromSyncPlay();
    expect(timer.deadline, isNotNull);
    var secondDone = false;
    final second =
        actual.stop(preserveSleepTimer: false).then((_) => secondDone = true);
    expect(timer.deadline, isNull);
    expect(secondDone, isFalse);
    expect(player.stops, 1);
    player.stopped.complete();
    await Future.wait([first, second]);
    expect(secondDone, isTrue);
    await actual.dispose();
  });
  test('failed native stop keeps owned cleanup retryable and propagates error',
      () async {
    final actual =
        container.read(Provider((ref) => MediaControlsWrapper(ref: ref)));
    final player = _StatePlayer();
    final failed = Completer<void>();
    player.stopQueue.addAll([failed.future, Future<void>.value()]);
    await actual.setup(player);
    final model = _Playback();
    container.read(playBackModel.notifier).state = model;
    final error = StateError('synthetic native stop failure');
    final stopping = actual.stopFromSyncPlay();
    final checked = expectLater(stopping, throwsA(same(error)));
    failed.completeError(error);
    await checked;
    expect(container.read(playBackModel), same(model));
    expect(player.stops, 1);
    await actual.stopFromSyncPlay();
    expect(player.stops, 2);
    expect(container.read(playBackModel), isNull);
    await actual.dispose();
  });
  testWidgets('user stop during pending open revokes tracks play and route',
      (tester) async {
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (value) {
      context = value;
      return const SizedBox();
    })));
    await tester.runAsync(() async {
      final open = Completer<void>();
      wrapper.openGate = open.future;
      final attempt = PlaybackDiagnostics.instance.startAttempt();
      final loading = notifier.loadPlaybackItem(_Playback(), Duration.zero,
          diagnosticAttempt: attempt);
      await Future<void>.delayed(Duration.zero);
      expect(wrapper.events, contains('open'));
      await wrapper.requestUserStop();
      open.complete();
      expect(await loading, isFalse);
      await notifier.openPlaybackAttempt(context, attempt);
      expect(wrapper.events, isNot(contains('audio')));
      expect(wrapper.events, isNot(contains('subtitle')));
      expect(wrapper.events, isNot(contains('play')));
      expect(wrapper.events, isNot(contains('route')));
    });
  });

  testWidgets('internal SyncPlay renderer replacement revokes accepted route',
      (tester) async {
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (value) {
      context = value;
      return const SizedBox();
    })));
    await tester.runAsync(() async {
      final attempt = PlaybackDiagnostics.instance.startAttempt();
      expect(
          await notifier.loadPlaybackItem(_Playback(), Duration.zero,
              diagnosticAttempt: attempt),
          isTrue);
      expect(notifier.isPlaybackAttemptCurrent(attempt), isTrue);
      expect(await notifier.prepareSyncPlayPlayback(isCurrent: () => true),
          isTrue);
      expect(wrapper.usingSyncRenderer, isTrue);
      expect(notifier.isPlaybackAttemptCurrent(attempt), isFalse);
      await notifier.openPlaybackAttempt(context, attempt);
      expect(wrapper.events, isNot(contains('route')));
    });
  });
  testWidgets(
      'user stop during pending initialization cannot be adopted by load',
      (tester) async {
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (value) {
      context = value;
      return const SizedBox();
    })));
    await tester.runAsync(() async {
      final ready = Completer<void>();
      wrapper.initQueue.add(ready.future);
      final initialization = notifier.init();
      final attempt = PlaybackDiagnostics.instance.startAttempt();
      final loading = notifier.loadPlaybackItem(_Playback(), Duration.zero,
          diagnosticAttempt: attempt);
      await Future<void>.delayed(Duration.zero);
      expect(wrapper.events, contains('init'));
      expect(wrapper.events, isNot(contains('open')));
      await wrapper.requestUserStop();
      ready.complete();
      await initialization;
      expect(await loading, isFalse);
      await notifier.openPlaybackAttempt(context, attempt);
      expect(wrapper.events, isNot(contains('open')));
      expect(wrapper.events, isNot(contains('play')));
      expect(wrapper.events, isNot(contains('route')));
    });
  });
}
