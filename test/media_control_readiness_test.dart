import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smtc_windows/src/rust/api/api.dart';
import 'package:smtc_windows/src/rust/frb_generated.dart';

import 'package:fladder/models/playback/playback_model.dart';
import 'package:fladder/models/settings/video_player_settings.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/wrappers/media_control_wrapper.dart';
import 'package:fladder/wrappers/players/base_player.dart';
import 'package:fladder/wrappers/players/player_states.dart';

class _Player extends Fake implements BasePlayer {
  _Player(this.ready);
  final Future<void> ready;
  Future<void>? disposeReady;
  int initCalls = 0;
  int disposeCalls = 0;

  @override
  Future<void> init(VideoPlayerSettingsModel settings) async {
    initCalls++;
    await ready;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    await disposeReady;
  }

  @override
  Stream<PlayerState> get stateStream => const Stream.empty();
}

class _Playback extends Fake implements PlaybackModel {}

class _InitializingWrapper extends MediaControlsWrapper {
  _InitializingWrapper({required super.ref, required this.ready});
  final Future<void> ready;

  @override
  bool get hasPlayer => false;
  @override
  Future<void> init() => ready;
  @override
  Future<void> stop({bool preserveSleepTimer = false}) async {}
  @override
  Future<void> dispose() async {}
}

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
        return Future<void>.value();
      default:
        return super.noSuchMethod(invocation);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final wrapperProvider =
      Provider<MediaControlsWrapper>((ref) => MediaControlsWrapper(ref: ref));
  late ProviderContainer container;
  late MediaControlsWrapper wrapper;
  setUpAll(() => RustLib.initMock(api: _SmtcApi()));
  tearDownAll(RustLib.dispose);
  setUp(() {
    container = ProviderContainer();
    wrapper = container.read(wrapperProvider);
  });
  tearDown(() async {
    await wrapper.dispose();
    container.dispose();
  });

  test('pending renderer is unavailable until initialization succeeds',
      () async {
    final ready = Completer<void>();
    final player = _Player(ready.future);
    final task = wrapper.setup(player);
    await Future<void>.delayed(Duration.zero);
    expect(player.initCalls, 1);
    expect(wrapper.hasPlayer, isFalse);
    ready.complete();
    await task;
    expect(wrapper.hasPlayer, isTrue);
    expect(player.disposeCalls, 0);
  });

  test('texture timeout clears readiness and disposes the failed player',
      () async {
    final ready = Completer<void>();
    final player = _Player(ready.future);
    final task = wrapper.setup(player);
    final check = expectLater(task, throwsA(isA<TimeoutException>()));
    ready.completeError(TimeoutException('synthetic renderer timeout'));
    await check;
    expect(wrapper.hasPlayer, isFalse);
    expect(player.disposeCalls, 1);
    final state = container.read(mediaPlaybackProvider);
    expect(state.errorPlaying, isTrue);
    expect(state.buffering, isFalse);
    expect(state.playing, isFalse);
  });

  test('a successful retry clears the existing playback error', () async {
    final failedReady = Completer<void>();
    final failed = _Player(failedReady.future);
    final failedTask = expectLater(wrapper.setup(failed), throwsStateError);
    failedReady.completeError(StateError('synthetic renderer failure'));
    await failedTask;
    expect(container.read(mediaPlaybackProvider).errorPlaying, isTrue);
    final retry = _Player(Future<void>.value());
    await wrapper.setup(retry);
    expect(wrapper.hasPlayer, isTrue);
    expect(container.read(mediaPlaybackProvider).errorPlaying, isFalse);
    expect(failed.disposeCalls, 1);
    expect(retry.disposeCalls, 0);
  });

  test('stalled cleanup remains unavailable and reports a safe diagnostic', () async {
    final ready = Completer<void>();
    final cleanup = Completer<void>();
    final player = _Player(ready.future)..disposeReady = cleanup.future;
    final task = wrapper.setup(player);
    final check = expectLater(task, throwsA(isA<TimeoutException>()));
    ready.completeError(TimeoutException('synthetic renderer timeout'));
    await check.timeout(const Duration(seconds: 7));
    expect(wrapper.hasPlayer, isFalse);
    expect(player.disposeCalls, 1);
    expect((await wrapper.playbackDiagnostics())['player initialization'],
        'renderer initialization timed out; resource cleanup did not finish');
    cleanup.complete();
  });

  test('missing player cannot report a successful video load', () async {
    await expectLater(
        wrapper.loadVideo(_Playback(), Duration.zero, true), throwsStateError);
    expect(container.read(mediaPlaybackProvider).errorPlaying, isTrue);
    expect(wrapper.hasPlayer, isFalse);
  });

  test('disposed pending initialization cannot publish a late player',
      () async {
    final ready = Completer<void>();
    final player = _Player(ready.future);
    final task = wrapper.setup(player);
    await Future<void>.delayed(Duration.zero);
    await wrapper.dispose();
    ready.complete();
    await task;
    expect(wrapper.hasPlayer, isFalse);
    expect(player.disposeCalls, 1);
  });

  test('first playback waits for initialization and safely returns failure',
      () async {
    final ready = Completer<void>();
    final notifierProvider = Provider<_Notifier>((ref) =>
        _Notifier(ref, _InitializingWrapper(ref: ref, ready: ready.future)));
    final notifier = container.read(notifierProvider);
    final initialization = notifier.init();
    final initializationCheck =
        expectLater(initialization, throwsA(isA<TimeoutException>()));
    var completed = false;
    final loading =
        notifier.loadPlaybackItem(_Playback(), Duration.zero).then((value) {
      completed = true;
      return value;
    });
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    ready.completeError(TimeoutException('synthetic texture readiness'));
    await initializationCheck;
    expect(await loading, isFalse);
    expect(container.read(mediaPlaybackProvider).errorPlaying, isTrue);
    expect(container.read(mediaPlaybackProvider).buffering, isFalse);
    notifier.dispose();
  });
}
