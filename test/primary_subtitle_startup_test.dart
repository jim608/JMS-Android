import 'dart:async';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/models/items/media_streams_model.dart';
import 'package:fladder/models/items/movie_model.dart';
import 'package:fladder/models/playback/direct_playback_model.dart';
import 'package:fladder/models/playback/playback_model.dart';
import 'package:fladder/providers/primary_subtitle_selection_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/util/dual_subtitle.dart';
import 'package:fladder/util/subtitle_selection_failure.dart';
import 'package:fladder/wrappers/media_control_wrapper.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

SubStreamModel _track(int index) => SubStreamModel(
      id: 'source:$index',
      name: 'Traditional $index',
      title: 'Traditional',
      displayTitle: 'Traditional',
      language: 'zh-Hant',
      codec: 'vtt',
      index: index,
      isDefault: true,
      isExternal: true,
      url: 'https://synthetic.invalid/subtitle/$index.vtt',
    );

DirectPlaybackModel _model(String id, int index) => DirectPlaybackModel(
      item:
          MovieModel.fromBaseDto(BaseItemDto(id: id, name: 'Synthetic'), null),
      media: Media(url: 'https://synthetic.invalid/$id'),
      playbackInfo: PlaybackInfoResponse(playSessionId: 'session-$id'),
      mediaStreams:
          MediaStreamsModel(defaultSubStreamIndex: index, versionStreams: [
        VersionStreamModel(
            name: 'Synthetic',
            index: 0,
            id: 'source-$id',
            defaultAudioStreamIndex: null,
            defaultSubStreamIndex: index,
            videoStreams: [],
            audioStreams: [],
            subStreams: [_track(index)]),
      ]),
    );

class _Player extends MediaControlsWrapper {
  _Player({required super.ref});
  final secondary = ValueNotifier(const SecondarySubtitleState());
  final requests = <int?>[];
  int epoch = 0;
  int plays = 0;
  int result = -1;
  SubtitleSelectionFailure? failure;
  Future<int> Function(int call)? duringSubtitle;
  Future<void> Function()? duringOpen;
  @override
  int get playbackStopEpoch => epoch;
  @override
  bool get hasPlayer => true;
  @override
  ValueNotifier<SecondarySubtitleState> get secondarySubtitleState => secondary;
  @override
  Future<void> stop({bool preserveSleepTimer = false}) async {}
  @override
  Future<void> dispose() async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<int> setAudioTrack(
          AudioStreamModel? model, PlaybackModel playbackModel) async =>
      -1;
  @override
  Future<void> loadVideo(PlaybackModel model, Duration position, bool play,
          {bool Function()? isCurrent}) async =>
      await duringOpen?.call();
  @override
  Future<int> setSubtitleTrack(
      SubStreamModel? model, PlaybackModel playbackModel) async {
    requests.add((model ?? playbackModel.defaultSubStream)?.index);
    if (duringSubtitle != null) return duringSubtitle!(requests.length);
    if (failure != null) throw failure!;
    return result;
  }

  @override
  Future<void> play({bool userInitiated = true}) async {
    plays++;
  }
}

class _Notifier extends VideoPlayerNotifier {
  _Notifier(super.ref, _Player player) {
    state = player;
  }
  // Exercise the production Web policy on VM without claiming browser coverage.
  @override
  bool get confirmsInitialSubtitleSelection => true;
}

class _NoReload extends PlaybackModelHelper {
  _NoReload(Ref ref) : super(ref: ref);
  @override
  Future<void> shouldReload(PlaybackModel model) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer container;
  late _Player player;
  late _Notifier notifier;
  setUp(() {
    container = ProviderContainer(overrides: [
      videoPlayerProvider.overrideWith((ref) {
        player = _Player(ref: ref);
        return notifier = _Notifier(ref, player);
      }),
      playbackModelHelper.overrideWith((ref) => _NoReload(ref)),
    ]);
    container.read(videoPlayerProvider);
  });
  tearDown(() {
    container.dispose();
    player.secondary.dispose();
  });

  test('unavailable initial subtitle is unconfirmed and video can play',
      () async {
    final model = _model('initial', 2);
    expect(await notifier.loadPlaybackItem(model, Duration.zero), isTrue);
    final status = container.read(primarySubtitleSelectionProvider);
    expect(status.pending, isFalse);
    expect(status.appliedIndex, isNull);
    expect(status.error?.reason, SubtitleSelectionFailureReason.unavailable);
    expect(
        container.read(playBackModel)?.mediaStreams?.defaultSubStreamIndex, 2);
    expect(player.plays, 1);
    player.result = 2;
    final retry = await container
        .read(primarySubtitleSelectionProvider.notifier)
        .select(model.subStreams[1]);
    expect(retry.applied, isTrue);
    expect(container.read(primarySubtitleSelectionProvider).appliedIndex, 2);
    expect(container.read(primarySubtitleSelectionProvider).error, isNull);
  });

  test('typed initial subtitle failure is optional, never confirmed Off',
      () async {
    player.failure = const SubtitleSelectionFailure(
        SubtitleSelectionFailureReason.unavailable);
    expect(await notifier.loadPlaybackItem(_model('typed', 2), Duration.zero),
        isTrue);
    final status = container.read(primarySubtitleSelectionProvider);
    expect(status.appliedIndex, isNull);
    expect(status.error, isNotNull);
    expect(status.pending, isFalse);
    expect(player.plays, 1);
  });

  test('initial selection blocks a concurrent user request until confirmed',
      () async {
    final entered = Completer<void>();
    final answer = Completer<int>();
    player.duringSubtitle = (_) {
      entered.complete();
      return answer.future;
    };
    final model = _model('pending', 2);
    final load = notifier.loadPlaybackItem(model, Duration.zero);
    await entered.future;
    expect(container.read(primarySubtitleSelectionProvider).pending, isTrue);
    expect(
        (await container
                .read(primarySubtitleSelectionProvider.notifier)
                .select(model.subStreams[1]))
            .applied,
        isFalse);
    expect(player.requests, [2]);
    answer.complete(2);
    expect(await load, isTrue);
    expect(container.read(primarySubtitleSelectionProvider).pending, isFalse);
    expect(container.read(primarySubtitleSelectionProvider).appliedIndex, 2);
  });

  test('late initial result cannot replace a newer playback selection',
      () async {
    final entered = Completer<void>();
    final first = Completer<int>();
    player.duringSubtitle = (call) {
      if (call == 1) {
        entered.complete();
        return first.future;
      }
      return Future.value(3);
    };
    final oldLoad = notifier.loadPlaybackItem(_model('old', 2), Duration.zero);
    await entered.future;
    expect(await notifier.loadPlaybackItem(_model('new', 3), Duration.zero),
        isTrue);
    first.complete(2);
    expect(await oldLoad, isFalse);
    expect(container.read(playBackModel)?.item.id, 'new');
    expect(container.read(primarySubtitleSelectionProvider).appliedIndex, 3);
    expect(container.read(primarySubtitleSelectionProvider).pending, isFalse);
  });

  test('stop during initial selection releases only that pending token',
      () async {
    final entered = Completer<void>();
    final answer = Completer<int>();
    player.duringSubtitle = (_) {
      entered.complete();
      return answer.future;
    };
    final load = notifier.loadPlaybackItem(_model('stopped', 2), Duration.zero);
    await entered.future;
    player.epoch++;
    answer.complete(2);
    expect(await load, isFalse);
    final status = container.read(primarySubtitleSelectionProvider);
    expect(status.pending, isFalse);
    expect(status.appliedIndex, isNull);
    expect(player.plays, 0);
  });

  test('open failure releases initial token without confirming requested track',
      () async {
    player.duringOpen = () async {
      throw StateError('Synthetic open failure');
    };
    await expectLater(
        notifier.loadPlaybackItem(_model('failed-open', 2), Duration.zero),
        throwsStateError);
    final status = container.read(primarySubtitleSelectionProvider);
    expect(status.pending, isFalse);
    expect(status.appliedIndex, isNull);
    expect(status.error, isNotNull);
  });
}
