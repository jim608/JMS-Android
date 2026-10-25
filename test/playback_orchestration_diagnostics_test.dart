import 'dart:async';

import 'package:async/async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smtc_windows/src/rust/api/api.dart';
import 'package:smtc_windows/src/rust/frb_generated.dart';

import 'package:fladder/l10n/generated/app_localizations.dart';
import 'package:fladder/util/item_base_model/play_item_helpers.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout_model.dart';
import 'package:fladder/util/poster_defaults.dart';
import 'package:fladder/models/playback/playback_model.dart';
import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/items/media_streams_model.dart';
import 'package:fladder/services/playback_diagnostics.dart';
import 'package:fladder/models/settings/video_player_settings.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/wrappers/media_control_wrapper.dart';
import 'package:fladder/wrappers/players/base_player.dart';
import 'package:fladder/wrappers/players/player_states.dart';

class _Player extends Fake implements BasePlayer {
  _Player(this.ready);
  final Future<void> ready;
  @override
  PlaybackAttemptRef? diagnosticAttempt;
  @override
  Future<void> init(VideoPlayerSettingsModel settings) => ready;
  @override
  Future<void> dispose() async {}
  @override
  Stream<PlayerState> get stateStream => const Stream.empty();
}

class _Item extends Fake implements ItemBaseModel {
  @override
  FladderItemType get type => FladderItemType.movie;
}

class _Playback extends Fake implements PlaybackModel {
  _Playback({this.hasMedia = true, this.resumeError});
  @override
  bool get serverManagedQueue => false;
  final bool hasMedia;
  final Object? resumeError;
  @override
  ItemBaseModel get item => _Item();
  @override
  Media? get media =>
      hasMedia ? const Media(url: 'https://fixture.invalid/synthetic') : null;
  @override
  MediaStreamsModel? get mediaStreams => null;
  @override
  Future<Duration> resolvedStartPosition(
      [Duration? requestedStartPosition]) async {
    if (resumeError != null) throw resumeError!;
    return requestedStartPosition ?? Duration.zero;
  }
}

class _Wrapper extends MediaControlsWrapper {
  _Wrapper(
      {required super.ref, this.ready, this.openError, this.available = true});
  final Future<void>? ready;
  final Object? openError;
  final bool available;
  @override
  bool get hasPlayer => available;
  @override
  Future<void> init({PlayerOptions? overridePlayer}) async => await ready;
  @override
  Future<void> stop({bool preserveSleepTimer = false}) async {}
  @override
  Future<void> dispose() async {}
  @override
  Future<void> loadVideo(
      PlaybackModel playbackModel, Duration startPosition, bool play,
      {bool Function()? isCurrent}) async {
    if (openError != null) throw openError!;
  }
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
  setUpAll(() => RustLib.initMock(api: _SmtcApi()));
  tearDownAll(RustLib.dispose);
  late ProviderContainer container;
  setUp(() {
    container = ProviderContainer();
    PlaybackDiagnostics.instance.clear();
  });
  tearDown(() => container.dispose());

  _Notifier notifier(
      {Future<void>? ready, Object? openError, bool available = true}) {
    return container.read(Provider<_Notifier>((ref) => _Notifier(
        ref,
        _Wrapper(
            ref: ref,
            ready: ready,
            openError: openError,
            available: available))));
  }

  test(
      'init failure survives sequencing future and is available at exact toast false branch',
      () async {
    final ready = Completer<void>();
    final player = notifier(ready: ready.future, available: false);
    final init = expectLater(player.init(), throwsA(isA<TimeoutException>()));
    final attempt = PlaybackDiagnostics.instance.startAttempt();
    final load = player.loadPlaybackItem(_Playback(), Duration.zero,
        diagnosticAttempt: attempt);
    await Future<void>.delayed(Duration.zero);
    ready.completeError(
        TimeoutException('synthetic-sensitive-error-do-not-export'));
    await init;
    expect(await load, isFalse);
    final report = PlaybackDiagnostics.instance.exportText();
    expect(report, contains('playerInit'));
    expect(report, contains('TimeoutException'));
    expect(report, contains('renderer_unavailable'));
    expect(report, isNot(contains('synthetic-sensitive-error-do-not-export')));
    player.dispose();
  });

  test(
      'invalidated request is cancellation and never reported as a native failure',
      () async {
    final player = notifier();
    expect(
        await player.loadPlaybackItem(_Playback(), Duration.zero,
            isCurrent: () => false),
        isFalse);
    final report = PlaybackDiagnostics.instance.exportText();
    expect(report, contains('request_invalidated'));
    expect(report, isNot(contains('renderer_unavailable')));
    player.dispose();
  });

  test('missing media is distinguished from initialized renderer', () async {
    final player = notifier();
    expect(
        await player.loadPlaybackItem(
            _Playback(hasMedia: false), Duration.zero),
        isFalse);
    final report = PlaybackDiagnostics.instance.exportText();
    expect(report, contains('renderer_ready'));
    expect(report, contains('missing_media'));
    player.dispose();
  });

  test('resume error keeps its stage and original throw without raw text',
      () async {
    final player = notifier();
    final error = StateError('synthetic-resume-private-value');
    await expectLater(
        player.loadPlaybackItem(_Playback(resumeError: error), Duration.zero),
        throwsA(same(error)));
    final report = PlaybackDiagnostics.instance.exportText();
    expect(report, contains('resolve_start_position'));
    expect(report, contains('StateError'));
    expect(report, isNot(contains('open_request_returned')));
    expect(report, isNot(contains('synthetic-resume-private-value')));
    player.dispose();
  });

  test('backend open exception is recorded without claiming first frame',
      () async {
    final error = StateError('synthetic-open-private-value');
    final player = notifier(openError: error);
    await expectLater(player.loadPlaybackItem(_Playback(), Duration.zero),
        throwsA(same(error)));
    final report = PlaybackDiagnostics.instance.exportText();
    expect(report, contains('mediaOpen'));
    expect(report, contains('StateError'));
    expect(report, isNot(contains('firstFrame')));
    expect(report, isNot(contains('open_request_returned')));
    expect(report, isNot(contains('synthetic-open-private-value')));
    player.dispose();
  });

  test('server transcode reasons use only known enum constants', () {
    final summary = playbackTranscodeReasonSummary(
        'https://fixture.invalid/stream?api_key=synthetic-secret&TranscodeReasons=VideoCodecNotSupported,synthetic-secret-value');
    expect(summary, 'Video Codec Not Supported, unknown');
    expect(summary, isNot(contains('synthetic')));
    expect(summary, isNot(contains('fixture.invalid')));
    expect(
        playbackTranscodeReasonSummary(
            '/relative?TranscodeReasons=AudioCodecNotSupported'),
        'Audio Codec Not Supported');
    expect(playbackTranscodeReasonSummary('/relative?TranscodeReasons=%ZZ'),
        'unknown');
  });

  test('optional metadata timeout does not accumulate requests across attempts',
      () async {
    final loader = PlaybackOptionalMetadataLoader();
    final pending = Completer<String?>();
    var requests = 0;
    Future<String?> request() {
      requests++;
      return pending.future;
    }

    final first = PlaybackDiagnostics.instance.startAttempt();
    expect(
        await loader.load(request,
            attempt: first,
            step: 'media_segments',
            budget: const Duration(milliseconds: 1)),
        isNull);
    for (var i = 0; i < 5; i++) {
      expect(
          await loader.load(request,
              attempt: PlaybackDiagnostics.instance.startAttempt(),
              step: 'media_segments',
              budget: Duration.zero),
          isNull);
    }
    expect(requests, 1);
    expect(PlaybackDiagnostics.instance.exportText(), contains('busy skipped'));
    final beforeLate = PlaybackDiagnostics.instance.exportText();
    pending.complete('late value must not affect a new model');
    await Future<void>.delayed(Duration.zero);
    expect(PlaybackDiagnostics.instance.exportText(), beforeLate);
    expect(
        await loader.load(() async {
          requests++;
          return 'new value';
        },
            attempt: PlaybackDiagnostics.instance.startAttempt(),
            step: 'media_segments',
            budget: const Duration(seconds: 1)),
        'new value');
    expect(requests, 2);
  });

  test('parallel optional endpoints do not serialize behind a hung request',
      () async {
    final segments = PlaybackOptionalMetadataLoader();
    final trickPlay = PlaybackOptionalMetadataLoader();
    final pending = Completer<String?>();
    final attempt = PlaybackDiagnostics.instance.startAttempt();
    var secondStarted = false;
    final first = segments.load(() => pending.future,
        attempt: attempt,
        step: 'media_segments',
        budget: const Duration(milliseconds: 1));
    final second = trickPlay.load(() async {
      secondStarted = true;
      return 'preview';
    },
        attempt: attempt,
        step: 'trick_play',
        budget: const Duration(milliseconds: 1));
    expect(secondStarted, isTrue);
    expect(await first, isNull);
    expect(await second, 'preview');
    pending.complete('discarded late segments');
    await Future<void>.delayed(Duration.zero);
  });

  test('optional metadata HTTP failure is nullable and status-only', () async {
    final loader = PlaybackOptionalMetadataLoader();
    final attempt = PlaybackDiagnostics.instance.startAttempt();
    expect(
        await loader.load(() async => 503,
            attempt: attempt,
            step: 'trick_play',
            budget: const Duration(seconds: 1),
            statusCode: (value) => value,
            accept: (value) => value == 200),
        isNull);
    final report = PlaybackDiagnostics.instance.exportText();
    expect(report, contains('503'));
    expect(report, contains('trick_play unavailable'));
  });

  test(
      'optional metadata success remains available and thrown errors are bounded',
      () async {
    final loader = PlaybackOptionalMetadataLoader();
    final attempt = PlaybackDiagnostics.instance.startAttempt();
    expect(
        await loader.load(() async => 'metadata',
            attempt: attempt,
            step: 'trick_play',
            budget: const Duration(seconds: 1)),
        'metadata');
    expect(
        await loader.load<String>(
            () async => throw StateError('synthetic-private-message'),
            attempt: attempt,
            step: 'trick_play',
            budget: const Duration(seconds: 1)),
        isNull);
    final report = PlaybackDiagnostics.instance.exportText();
    expect(report, contains('StateError'));
    expect(report, isNot(contains('synthetic-private-message')));
  });

  test('attempt attaches before player initialization', () async {
    final wrapper =
        container.read(Provider((ref) => MediaControlsWrapper(ref: ref)));
    final attempt = PlaybackDiagnostics.instance.startAttempt();
    wrapper.attachPlaybackAttempt(attempt);
    final player = _Player(Future.value());
    await wrapper.setup(player);
    expect(player.diagnosticAttempt, same(attempt));
    await wrapper.dispose();
  });

  test('attempt attaches to initialization already in progress', () async {
    final wrapper =
        container.read(Provider((ref) => MediaControlsWrapper(ref: ref)));
    final ready = Completer<void>();
    final player = _Player(ready.future);
    final setup = wrapper.setup(player);
    await Future<void>.delayed(Duration.zero);
    final attempt = PlaybackDiagnostics.instance.startAttempt();
    wrapper.attachPlaybackAttempt(attempt);
    expect(player.diagnosticAttempt, same(attempt));
    ready.complete();
    await setup;
    expect(player.diagnosticAttempt, same(attempt));
    await wrapper.dispose();
  });

  testWidgets(
      'pending loader offers diagnostics without cancel or wrong route pop',
      (tester) async {
    final pending = Completer<void>();
    final operation = CancelableOperation<void>.fromFuture(pending.future);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      theme: ThemeData(visualDensity: VisualDensity.compact),
      builder: (context, child) => AdaptiveLayout(
        data: const AdaptiveLayoutModel(
          viewSize: ViewSize.desktop,
          layoutMode: LayoutMode.dual,
          inputDevice: InputDevice.pointer,
          platform: TargetPlatform.linux,
          isDesktop: true,
          posterDefaults: PosterDefaults(size: 180, ratio: 0.7),
          controller: {},
          sideBarWidth: 0,
          topBarHeight: 0,
          statusBarHeight: 0,
        ),
        child: child!,
      ),
      home: Builder(
          builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () =>
                      showPlaybackLoadingIndicator(context, null, operation),
                  child: const Text('Start pending open'),
                ),
              )),
    ));
    await tester.tap(find.text('Start pending open'));
    await tester.pump(const Duration(milliseconds: 300));
    final diagnosticButton =
        find.widgetWithText(TextButton, 'Playback diagnostics');
    expect(diagnosticButton, findsOneWidget);
    expect(tester.getSize(diagnosticButton).height, greaterThanOrEqualTo(48));
    expect(operation.isCompleted, isFalse);
    await tester.tap(diagnosticButton);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('playback-diagnostics-preview')),
        findsOneWidget);
    expect(operation.isCanceled, isFalse);
    expect(operation.isCompleted, isFalse);
    // Completing loading beneath the diagnostic must not pop the diagnostic.
    pending.complete();
    closePlaybackLoadingIndicator(operation);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('playback-diagnostics-preview')),
        findsOneWidget);
    expect(operation.isCanceled, isFalse);
    expect(find.byType(Dialog, skipOffstage: false), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Close'));
    await tester.pumpAndSettle();
    expect(find.text('Start pending open'), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
