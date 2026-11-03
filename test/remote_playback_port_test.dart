import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/credentials_model.dart';
import 'package:fladder/models/items/media_streams_model.dart';
import 'package:fladder/models/items/movie_model.dart';
import 'package:fladder/models/media_playback_model.dart';
import 'package:fladder/models/playback/direct_playback_model.dart';
import 'package:fladder/models/playback/playback_model.dart';
import 'package:fladder/models/settings/video_player_settings.dart';
import 'package:fladder/providers/captured_playback_reporting_provider.dart';
import 'package:fladder/providers/incognito_mode_provider.dart';
import 'package:fladder/providers/primary_subtitle_selection_provider.dart';
import 'package:fladder/providers/remote_playback_port_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/services/jellyfin_session_socket.dart';
import 'package:fladder/services/remote_control/remote_control_models.dart';
import 'package:fladder/services/remote_control/remote_receiver.dart';
import 'package:fladder/services/playback_reporting_scope.dart';
import 'package:fladder/util/dual_subtitle.dart';
import 'package:fladder/util/subtitle_offset.dart';
import 'package:fladder/util/subtitle_selection_failure.dart';
import 'package:fladder/wrappers/media_control_wrapper.dart';

SubStreamModel _track(int index) => SubStreamModel(
      name: 'Track $index',
      id: 'track-$index',
      title: 'Track $index',
      displayTitle: 'Track $index',
      language: 'zho',
      codec: 'srt',
      index: index,
      isDefault: index == 2,
      isExternal: false,
    );

AccountModel _account(String id) => AccountModel(
      name: id,
      id: id,
      avatar: '',
      lastUsed: DateTime.utc(2026),
      credentials: CredentialsModel.internal(
          token: 'synthetic-$id',
          url: 'https://fixture.invalid/jellyfin',
          serverId: 'fixture',
          deviceId: 'device-$id'),
      policy: const UserPolicy(
          authenticationProviderId: 'fixture',
          passwordResetProviderId: 'fixture',
          enableMediaPlayback: true),
    );

DirectPlaybackModel _model(
        {String source = 'source-one',
        String session = 'occurrence-one',
        int index = 2,
        PlaybackReportingScope? reportingScope}) =>
    DirectPlaybackModel(
      reportingScope: reportingScope,
      item: MovieModel.fromBaseDto(
          const BaseItemDto(
              id: 'same-item',
              name: 'Fixture',
              type: BaseItemKind.movie,
              mediaType: MediaType.video),
          null),
      media: const Media(url: 'https://media.invalid/same-path'),
      playbackInfo: PlaybackInfoResponse(playSessionId: session),
      mediaStreams: MediaStreamsModel(
          defaultSubStreamIndex: index,
          defaultAudioStreamIndex: 1,
          versionStreams: [
            VersionStreamModel(
              name: source,
              index: 0,
              id: source,
              defaultAudioStreamIndex: 1,
              defaultSubStreamIndex: index,
              videoStreams: [],
              audioStreams: [],
              subStreams: [_track(2), _track(8)],
            )
          ]),
    );

class _User extends User {
  _User(this.account);
  final AccountModel account;
  @override
  AccountModel? build() => account;
  void replace(AccountModel? next) => state = next;
}

class _SubtitleRequest {
  _SubtitleRequest(this.index, this.generation);
  final int index;
  final int generation;
  final done = Completer<int>();
}

class _Player extends Fake implements MediaControlsWrapper {
  final actions = <String>[];
  final ordinaryRoutes = <String>[];
  final remoteRoutes = <String>[];
  final subtitles = <_SubtitleRequest>[];
  final secondary = ValueNotifier(const SecondarySubtitleState());
  bool group = false;
  bool loaded = true;
  int stopEpoch = 0;
  int rendererEpoch = 0;
  int subtitleGeneration = 0;
  int cancels = 0;
  Completer<void>? actionGate;
  @override
  int get playbackStopEpoch => stopEpoch;
  @override
  int get rendererGeneration => rendererEpoch;
  @override
  bool get hasPlayer => loaded;
  @override
  bool get syncPlayActive => group;
  @override
  PlayerOptions backend = PlayerOptions.libMPV;
  @override
  bool get supportsSecondarySubtitles => false;
  @override
  ValueNotifier<SecondarySubtitleState> get secondarySubtitleState => secondary;
  @override
  SubtitleOffsetController? get subtitleOffsets => null;
  @override
  Future<void> dispose() async {}
  @override
  Future<void> play({bool userInitiated = true}) async {
    ordinaryRoutes.add('play');
    actions.add('play');
    await actionGate?.future;
  }

  @override
  Future<void> pause() async {
    ordinaryRoutes.add('pause');
    actions.add('pause');
    await actionGate?.future;
  }

  @override
  Future<void> seek(Duration position) async {
    ordinaryRoutes.add('seek');
    actions.add('seek:${position.inMilliseconds}');
    await actionGate?.future;
  }

  Future<void> _remoteAction(String action, bool Function() isCurrent) async {
    void requireCurrent() {
      if (!isCurrent()) {
        throw const RemoteControlFailure(RemoteFailureCode.stale);
      }
    }

    requireCurrent();
    remoteRoutes.add(action);
    actions.add(action);
    await actionGate?.future;
    requireCurrent();
  }

  @override
  Future<void> playRemotely({required bool Function() isCurrent}) =>
      _remoteAction('play', isCurrent);
  @override
  Future<void> pauseRemotely({required bool Function() isCurrent}) =>
      _remoteAction('pause', isCurrent);
  @override
  Future<void> seekRemotely(Duration position,
          {required bool Function() isCurrent}) =>
      _remoteAction('seek:${position.inMilliseconds}', isCurrent);

  @override
  void cancelPendingSubtitleSelection() {
    cancels++;
    subtitleGeneration++;
  }

  @override
  Future<int> setSubtitleTrack(
      SubStreamModel? track, PlaybackModel model) async {
    final request = _SubtitleRequest(
        (track ?? model.defaultSubStream)?.index ?? -1, subtitleGeneration);
    subtitles.add(request);
    final applied = await request.done.future;
    if (request.generation != subtitleGeneration) {
      throw const SubtitleSelectionFailure(
          SubtitleSelectionFailureReason.unavailable);
    }
    return applied;
  }
}

class _Video extends VideoPlayerNotifier {
  _Video(super.ref, _Player player) {
    state = player;
  }
  void replace(_Player player) => state = player;
}

class _Reload extends Fake implements PlaybackModelHelper {
  int reloads = 0;
  @override
  Future<void> shouldReload(PlaybackModel model) async {
    reloads++;
  }
}

class _Fixture {
  _Fixture() {
    container = ProviderContainer(overrides: [
      userProvider.overrideWith(() => _User(account)),
      playBackModel.overrideWith((_) => null),
      incognitoProvider.overrideWithValue(false),
      capturedPlaybackApiFactoryProvider.overrideWithValue((owner) {
        capturedAccounts.add(owner);
        return JellyfinOpenApi.create(
            baseUrl: Uri.parse(owner.credentials.url),
            httpClient: MockClient((request) async {
              reportingRequests.add(request);
              return http.Response('', 204);
            }));
      }),
      mediaPlaybackProvider.overrideWith((_) => MediaPlaybackModel(
          state: VideoPlayerState.fullScreen,
          playing: true,
          position: const Duration(seconds: 10),
          duration: const Duration(minutes: 2))),
      videoPlayerProvider.overrideWith((ref) => _Video(ref, player)),
      playbackModelHelper.overrideWithValue(reload),
    ]);
    reporting = container.read(capturedPlaybackReportingProvider);
    model = scopedModel();
    replaceModel(model);
    port = container.read(remotePlaybackPortProvider) as JmsRemotePlaybackPort;
  }
  final account = _account('user-a');
  late final DirectPlaybackModel model;
  final player = _Player();
  final reload = _Reload();
  late final ProviderContainer container;
  late final CapturedPlaybackReporting reporting;
  late final JmsRemotePlaybackPort port;
  final capturedAccounts = <AccountModel>[];
  final reportingRequests = <http.Request>[];
  RemotePlaybackBinding get binding => RemotePlaybackBinding(
      itemId: model.item.id,
      mediaSourceId: 'source-one',
      playbackId: 'jms-remote-occurrence-one');
  DirectPlaybackModel scopedModel(
      {String source = 'source-one',
      String session = 'occurrence-one',
      int index = 2}) {
    final capture = reporting.capture()!;
    final scope = capture.bind(
        itemId: 'same-item',
        mediaSourceId: source,
        playSessionId: session,
        playlistItemId: 'jms-remote-$session');
    return _model(
        source: source, session: session, index: index, reportingScope: scope);
  }

  void replaceModel(PlaybackModel? next) {
    container.read(playBackModel.notifier).state = next;
    if (next?.reportingScope case final scope?) {
      expect(scope.activate(), isTrue);
    }
  }

  void dispose() {
    container.dispose();
    player.secondary.dispose();
  }
}

Matcher _failure([RemoteFailureCode? code]) => code == null
    ? isA<RemoteControlFailure>()
    : isA<RemoteControlFailure>()
        .having((error) => error.code, 'safe category', code);

Future<void> _flush() => Future<void>.delayed(Duration.zero);

class _ReceiverApi implements RemoteReceiverApi {
  final advertised = <bool>[];
  final reports = <PlaybackProgressInfo>[];
  @override
  Future<String?> ownSessionId() async => 'fixture-receiver';
  @override
  Future<void> capabilities(bool enabled) async => advertised.add(enabled);
  @override
  Future<void> report(PlaybackProgressInfo progress) async =>
      reports.add(progress);
}

class _ReceiverSocket implements JellyfinSessionSocket {
  final input = StreamController<Object?>.broadcast(sync: true);
  @override
  Future<void> get ready async {}
  @override
  Stream<Object?> get messages => input.stream;
  @override
  void send(String value) {}
  @override
  Future<void> close() => input.close();
}

void main() {
  test(
    'legacy NativeActivity cannot advertise mutate or report; LibMPV remains available',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      expect(fixture.port.snapshot?.binding, fixture.binding);
      expect(fixture.model.reportingScope?.isCurrent, isTrue);
      fixture.player.backend = PlayerOptions.nativePlayer;

      final api = _ReceiverApi();
      final receiver = RemoteReceiverController(
        api: api,
        socketFactory: (_) => _ReceiverSocket(),
        socketUri: Uri.parse('wss://fixture.invalid/jellyfin/socket'),
        currentUserId: fixture.account.id,
        player: fixture.port,
        isCurrent: () => true,
      );
      addTearDown(receiver.close);
      await receiver.enable();
      await _flush();
      expect(fixture.port.snapshot, isNull);
      expect(api.advertised, [false]);
      expect(api.reports, isEmpty);
      for (final action in <Future<void> Function()>[
        () => fixture.port.play(fixture.binding),
        () => fixture.port.pause(fixture.binding),
        () => fixture.port.seek(const Duration(seconds: 45), fixture.binding),
        () => fixture.port.setSubtitle(8, fixture.binding),
      ]) {
        await expectLater(action(), throwsA(_failure(RemoteFailureCode.stale)));
      }
      expect(fixture.player.actions, isEmpty);
      expect(fixture.player.subtitles, isEmpty);
      expect(
        fixture.container.read(primarySubtitleSelectionProvider).appliedIndex,
        isNull,
      );
      expect(fixture.container.read(playBackModel), same(fixture.model));
      expect(api.reports, isEmpty);

      await receiver.disable();
      fixture.player.backend = PlayerOptions.libMPV;
      expect(fixture.port.snapshot?.binding, fixture.binding);
      await fixture.port.play(fixture.binding);
      await fixture.port.pause(fixture.binding);
      await fixture.port.seek(const Duration(seconds: 45), fixture.binding);
      final subtitle = fixture.port.setSubtitle(8, fixture.binding);
      await _flush();
      fixture.player.subtitles.single.done.complete(8);
      await subtitle;
      expect(fixture.player.actions, ['play', 'pause', 'seek:45000']);
      expect(fixture.port.snapshot?.subtitleIndex, 8);
      await receiver.enable();
      await _flush();
      expect(api.advertised, [false, true]);
      expect(api.reports.single.subtitleStreamIndex, 8);
      expect(api.reports.single.playlistItemId, fixture.binding.playbackId);
    },
  );

  test(
      'snapshot binds actual source and occurrence without treating unknown subtitles as Off',
      () {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final snapshot = fixture.port.snapshot!;
    expect(snapshot.binding, fixture.binding);
    expect(snapshot.positionTicks, 100000000);
    expect(snapshot.durationTicks, 1200000000);
    expect(snapshot.playSessionId, 'occurrence-one');
    expect(snapshot.audioStreamIndex, 1);
    expect(snapshot.subtitleIndex, isNull);
  });

  test(
      'play pause and seek use only the guarded remote routes on the captured wrapper',
      () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    await fixture.port.pause(fixture.binding);
    await fixture.port.play(fixture.binding);
    await fixture.port.seek(const Duration(seconds: 45), fixture.binding);
    expect(fixture.player.actions, ['pause', 'play', 'seek:45000']);
    expect(fixture.player.remoteRoutes, ['pause', 'play', 'seek:45000']);
    expect(fixture.player.ordinaryRoutes, isEmpty);
  });

  test('group control and out-of-range seeks never reach the wrapper',
      () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    fixture.player.group = true;
    await expectLater(
        fixture.port.seek(const Duration(seconds: 5), fixture.binding),
        throwsA(_failure(RemoteFailureCode.denied)));
    fixture.player.group = false;
    await expectLater(
        fixture.port.seek(const Duration(seconds: -1), fixture.binding),
        throwsA(_failure(RemoteFailureCode.invalidAction)));
    await expectLater(
        fixture.port.seek(const Duration(minutes: 3), fixture.binding),
        throwsA(_failure(RemoteFailureCode.invalidAction)));
    expect(fixture.player.actions, isEmpty);
  });

  test('same-item replay and a different source invalidate old remote bindings',
      () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    for (final replacement in [
      fixture.scopedModel(session: 'occurrence-two'),
      fixture.scopedModel(source: 'source-two')
    ]) {
      fixture.replaceModel(replacement);
      await expectLater(fixture.port.pause(fixture.binding),
          throwsA(_failure(RemoteFailureCode.stale)));
    }
    expect(fixture.player.actions, isEmpty);
  });

  test(
      'player replacement during an awaited action cannot publish success for the new player',
      () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final replacement = _Player();
    addTearDown(replacement.secondary.dispose);
    fixture.player.actionGate = Completer<void>();
    final pending = fixture.port.pause(fixture.binding);
    final assertion =
        expectLater(pending, throwsA(_failure(RemoteFailureCode.stale)));
    (fixture.container.read(videoPlayerProvider.notifier) as _Video)
        .replace(replacement);
    fixture.player.actionGate!.complete();
    await assertion;
    expect(replacement.actions, isEmpty);
  });

  test('stopped playback is unavailable and cannot accept the old binding',
      () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    fixture.player.stopEpoch++;
    fixture.container.read(mediaPlaybackProvider.notifier).state =
        MediaPlaybackModel(
            state: VideoPlayerState.disposed,
            duration: const Duration(minutes: 2));
    expect(fixture.port.snapshot, isNull);
    await expectLater(fixture.port.play(fixture.binding), throwsA(_failure()));
    expect(fixture.player.actions, isEmpty);
  });

  test(
      'a stop during pending wrapper input revokes the result even if the model stays installed',
      () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    fixture.player.actionGate = Completer<void>();
    final pending = fixture.port.pause(fixture.binding);
    final assertion =
        expectLater(pending, throwsA(_failure(RemoteFailureCode.stale)));
    fixture.player.stopEpoch++;
    fixture.player.actionGate!.complete();
    await assertion;
  });

  test('replacing the backend inside the same wrapper revokes pending input',
      () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    fixture.player.actionGate = Completer<void>();
    final pending = fixture.port.play(fixture.binding);
    final assertion =
        expectLater(pending, throwsA(_failure(RemoteFailureCode.stale)));
    fixture.player.rendererEpoch++;
    fixture.player.actionGate!.complete();
    await assertion;
  });

  test('applied subtitles and explicit Off go through PrimarySubtitleSelection',
      () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    for (final index in [8, -1]) {
      final pending = fixture.port.setSubtitle(index, fixture.binding);
      await _flush();
      expect(fixture.player.subtitles.last.index, index);
      fixture.player.subtitles.last.done.complete(index);
      await pending;
      expect(fixture.port.snapshot?.subtitleIndex, index);
    }
    expect(fixture.reload.reloads, 2);
  });

  test('subtitle failure and pending state never become confirmed Off',
      () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final pending = fixture.port.setSubtitle(8, fixture.binding);
    final assertion = expectLater(pending, throwsA(_failure()));
    await _flush();
    expect(fixture.port.snapshot?.subtitleIndex, isNull);
    fixture.player.subtitles.single.done.completeError(
        const SubtitleSelectionFailure(
            SubtitleSelectionFailureReason.unavailable));
    await assertion;
    expect(fixture.port.snapshot?.subtitleIndex, isNull);
    expect(
        fixture.container
            .read(playBackModel)
            ?.mediaStreams
            ?.defaultSubStreamIndex,
        2);
  });

  test(
      'canceling a remote subtitle revokes its backend result without stopping playback',
      () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final pending = fixture.port.setSubtitle(8, fixture.binding);
    final assertion = expectLater(pending, throwsA(_failure()));
    await _flush();
    fixture.port.cancelPendingInput();
    expect(fixture.player.cancels, 1);
    fixture.player.subtitles.single.done.complete(8);
    await assertion;
    expect(fixture.player.actions, isEmpty);
    expect(
        fixture.container
            .read(playBackModel)
            ?.mediaStreams
            ?.defaultSubStreamIndex,
        2);
    expect(fixture.port.snapshot?.subtitleIndex, isNot(-1));
  });

  test(
      'canceling rejected remote input does not cancel an ordinary UI selection',
      () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final ui = fixture.container
        .read(primarySubtitleSelectionProvider.notifier)
        .select(_track(8));
    await _flush();
    final remote = fixture.port.setSubtitle(2, fixture.binding);
    final assertion = expectLater(remote, throwsA(_failure()));
    fixture.port.cancelPendingInput();
    expect(fixture.player.cancels, 0);
    fixture.player.subtitles.single.done.complete(8);
    expect((await ui).applied, true);
    await assertion;
    expect(fixture.port.snapshot?.subtitleIndex, 8);
  });

  test('account A to B to A never revives a captured playback port', () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final user = fixture.container.read(userProvider.notifier) as _User;
    user.replace(_account('user-b'));
    expect(fixture.port.snapshot, isNull);
    user.replace(fixture.account);
    expect(fixture.port.snapshot, isNull);
    await expectLater(fixture.port.pause(fixture.binding), throwsA(_failure()));
    expect(fixture.player.actions, isEmpty);
  });

  test(
      'account B cannot control account A playback even when its binding is identical',
      () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final oldModel = fixture.model;
    expect(oldModel.reportingScope?.isCurrent, isTrue);
    (fixture.container.read(userProvider.notifier) as _User)
        .replace(_account('user-b'));
    final currentB = fixture.container.read(remotePlaybackPortProvider)
        as JmsRemotePlaybackPort;
    expect(oldModel.reportingScope?.isCurrent, isFalse);
    expect(currentB.snapshot, isNull);
    await expectLater(currentB.pause(fixture.binding),
        throwsA(_failure(RemoteFailureCode.stale)));
    expect(fixture.player.actions, isEmpty);

    // Matching item/source/occurrence strings are insufficient ownership proof.
    // A real account-B capture is required before the same binding is usable.
    final ownedByB = fixture.scopedModel();
    fixture.replaceModel(ownedByB);
    expect(ownedByB.reportingScope?.isCurrent, isTrue);
    expect(fixture.capturedAccounts.map((owner) => owner.id),
        ['user-a', 'user-b']);
    expect(currentB.snapshot?.binding, fixture.binding);
    await currentB.pause(fixture.binding);
    expect(fixture.player.remoteRoutes, ['pause']);
    expect(fixture.player.ordinaryRoutes, isEmpty);
  });

  for (final action in [
    RemoteActionType.play,
    RemoteActionType.pause,
    RemoteActionType.seek
  ]) {
    test(
        'receiver opt-out revokes pending ${action.name} without canceling ordinary controls',
        () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      fixture.player.actionGate = Completer<void>();
      final pending = switch (action) {
        RemoteActionType.play => fixture.port.play(fixture.binding),
        RemoteActionType.pause => fixture.port.pause(fixture.binding),
        RemoteActionType.seek =>
          fixture.port.seek(const Duration(seconds: 45), fixture.binding),
        RemoteActionType.subtitle => throw StateError('Not a transport action'),
      };
      final assertion =
          expectLater(pending, throwsA(_failure(RemoteFailureCode.stale)));
      await _flush();
      expect(fixture.player.remoteRoutes, hasLength(1));
      fixture.port.cancelPendingInput();
      fixture.player.actionGate!.complete();
      await assertion;
      expect(fixture.player.cancels, 0);
      expect(fixture.port.snapshot, isNotNull);

      fixture.player.actionGate = null;
      switch (action) {
        case RemoteActionType.play:
          await fixture.player.play();
        case RemoteActionType.pause:
          await fixture.player.pause();
        case RemoteActionType.seek:
          await fixture.player.seek(const Duration(seconds: 45));
        case RemoteActionType.subtitle:
          throw StateError('Not a transport action');
      }
      expect(fixture.player.ordinaryRoutes, [action.name]);
      expect(fixture.player.remoteRoutes, hasLength(1));
      expect(fixture.container.read(mediaPlaybackProvider).state,
          VideoPlayerState.fullScreen);
    });
  }

  test(
      'account change cancels only the pending remote subtitle backend generation',
      () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final pending = fixture.port.setSubtitle(8, fixture.binding);
    final assertion = expectLater(pending, throwsA(_failure()));
    await _flush();
    (fixture.container.read(userProvider.notifier) as _User)
        .replace(_account('user-b'));
    expect(fixture.player.cancels, 1);
    fixture.player.subtitles.single.done.complete(8);
    await assertion;
    expect(fixture.port.snapshot, isNull);
    expect(
        fixture.container
            .read(playBackModel)
            ?.mediaStreams
            ?.defaultSubStreamIndex,
        2);
    expect(fixture.player.actions, isEmpty);
  });
}
