import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart'
    hide SyncPlayQueueItem;
import 'package:fladder/models/items/media_streams_model.dart';
import 'package:fladder/models/items/movie_model.dart';
import 'package:fladder/models/playback/playback_model.dart';
import 'package:fladder/models/settings/video_player_settings.dart';
import 'package:fladder/l10n/generated/app_localizations.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/screens/video_player/components/video_player_options_sheet.dart';
import 'package:fladder/services/syncplay/syncplay_models.dart';
import 'package:fladder/services/syncplay/syncplay_player.dart';
import 'package:fladder/util/local_subtitle_selection.dart';
import 'package:fladder/util/dual_subtitle.dart';
import 'package:fladder/util/subtitle_offset.dart';
import 'package:fladder/wrappers/media_control_wrapper.dart';

class _Ref extends Fake implements Ref {
  final reads = <Object>[];
  @override
  T read<T>(ProviderListenable<T> provider) {
    reads.add(provider);
    throw StateError('Must not renegotiate room playback');
  }
}

class _Api extends Fake implements JellyfinOpenApi {}

class _Player extends Fake implements MediaControlsWrapper {
  final choices = <int>[];
  int? returnedIndex;
  Completer<int>? selectionReady;
  bool playing = true;
  final position = const Duration(minutes: 3);
  final secondary = ValueNotifier(const SecondarySubtitleState());
  @override
  PlayerOptions get backend => PlayerOptions.libMPV;
  @override
  ValueNotifier<SecondarySubtitleState> get secondarySubtitleState => secondary;
  @override
  SubtitleOffsetController? get subtitleOffsets => null;
  @override
  Future<int> setSubtitleTrack(
      SubStreamModel? model, PlaybackModel playbackModel) async {
    choices.add(model?.index ?? -1);
    if (selectionReady != null) return selectionReady!.future;
    return returnedIndex ?? model?.index ?? -1;
  }
}

class _Notifier extends VideoPlayerNotifier {
  _Notifier(super.ref, _Player player) {
    state = player;
  }
}

Future<ProviderContainer> _openSelection(
    WidgetTester tester, SyncPlayPlaybackModel model, _Player player) async {
  final container = ProviderContainer(overrides: [
    playBackModel.overrideWith((ref) => model),
    videoPlayerProvider.overrideWith((ref) => _Notifier(ref, player)),
  ]);
  addTearDown(container.dispose);
  addTearDown(player.secondary.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
              body: Builder(
                  builder: (context) => TextButton(
                      onPressed: () => showSubSelection(context),
                      child: const Text('Select')))))));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Select'));
  await tester.pumpAndSettle();
  return container;
}

const _entry = SyncPlayQueueItem(
    mediaId: 'synthetic-item', playlistItemId: 'synthetic-queue-entry');
final _queue = SyncPlayQueue(
    lastUpdate: DateTime.utc(2026),
    items: [_entry],
    playingIndex: 0,
    position: const Duration(minutes: 3),
    isPlaying: true,
    reason: 'NewPlaylist');

SubStreamModel _track(int index, {bool external = false}) => SubStreamModel(
    name: 'Synthetic subtitle',
    id: 'synthetic-$index',
    title: 'Synthetic subtitle',
    displayTitle: 'Synthetic subtitle',
    language: 'en',
    codec: 'srt',
    index: index,
    isDefault: false,
    isExternal: external,
    url: external ? 'https://media.example.invalid/subtitle.srt' : null);

SyncPlayPlaybackModel _model(PlayMethod method,
        {bool Function()? current,
        SyncPlayQueue? Function()? queue,
        SubtitleDeliveryMethod? delivery,
        int? defaultIndex}) =>
    SyncPlayPlaybackModel(
        item: MovieModel.fromBaseDto(
            const BaseItemDto(
                id: 'synthetic-item',
                name: 'Synthetic item',
                type: BaseItemKind.movie,
                mediaType: MediaType.video),
            null),
        media: const Media(url: 'https://media.example.invalid/stream'),
        playbackInfo: PlaybackInfoResponse(
            playSessionId: 'synthetic-session',
            mediaSources: [
              MediaSourceInfo(
                  id: 'synthetic-source',
                  defaultSubtitleStreamIndex: defaultIndex,
                  mediaStreams: [
                    MediaStream(
                        type: MediaStreamType.subtitle,
                        index: 2,
                        deliveryMethod: delivery)
                  ])
            ]),
        mediaStreams: MediaStreamsModel(
            defaultSubStreamIndex: defaultIndex,
            versionStreams: [
              VersionStreamModel(
                  name: 'Synthetic source',
                  index: 0,
                  id: 'synthetic-source',
                  defaultAudioStreamIndex: null,
                  defaultSubStreamIndex: defaultIndex,
                  videoStreams: [],
                  audioStreams: [],
                  subStreams: [_track(2), _track(3), _track(4, external: true)])
            ]),
        api: _Api(),
        isCurrent: current ?? () => true,
        groupQueue: queue ?? () => _queue,
        queueItem: _entry,
        playMethod: method);

void main() {
  testWidgets(
      'subtitle dialog explains unsupported choice and retains room playback',
      (tester) async {
    final player = _Player();
    final model = _model(PlayMethod.transcode,
        delivery: SubtitleDeliveryMethod.encode, defaultIndex: 2);
    final container = await _openSelection(tester, model, player);
    await tester.tap(find.byWidgetPredicate((widget) =>
        widget is ListTile &&
        widget.title is Text &&
        (widget.title as Text).data == 'Off'));
    await tester.pump();
    expect(
        find.text(
            'This subtitle track is not available in the current video stream.'),
        findsOneWidget);
    expect(container.read(playBackModel), same(model));
    expect(player.choices, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'subtitle dialog ignores pending choice after another model is selected',
      (tester) async {
    final player = _Player()..selectionReady = Completer<int>();
    final model = _model(PlayMethod.directstream, defaultIndex: 3);
    final container = await _openSelection(tester, model, player);
    await tester.tap(find.byWidgetPredicate((widget) =>
        widget is ListTile &&
        widget.title is Text &&
        (widget.title as Text).data == 'Off'));
    await tester.pump();
    final replacement = _model(PlayMethod.directstream, defaultIndex: 4);
    container.read(playBackModel.notifier).state = replacement;
    player.selectionReady!.complete(-1);
    await tester.pump();
    expect(container.read(playBackModel), same(replacement));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final method in [PlayMethod.directstream, PlayMethod.transcode]) {
    test('$method local subtitle choices keep the room model and playback',
        () async {
      final ref = _Ref();
      final player = _Player();
      PlaybackModel model = _model(method);
      expect(model.isServerTranscoded, method == PlayMethod.transcode);
      final originalApi = (model as SyncPlayPlaybackModel).api;
      final media = model.media;

      for (final track in [
        _track(2),
        _track(3),
        _track(4, external: true),
        SubStreamModel.no()
      ]) {
        model = (await model.setSubtitle(track, player))!;
        await PlaybackModelHelper(ref: ref).shouldReload(model);
        expect(model, isA<SyncPlayPlaybackModel>());
        expect((model as SyncPlayPlaybackModel).api, same(originalApi));
        expect(model.serverManagedQueue, isTrue);
        expect(model.media, same(media));
        expect(model.mediaStreams?.defaultSubStreamIndex, track.index);
        expect(player.playing, isTrue);
        expect(player.position, const Duration(minutes: 3));
      }
      expect(ref.reads, isEmpty);
      expect(player.choices, [2, 3, 4, -1]);
    });
  }

  test('stale subtitle selection leaves the room model and player untouched',
      () async {
    final player = _Player();
    final model = _model(PlayMethod.directstream, current: () => false);
    expect(await model.setSubtitle(_track(2), player), same(model));
    expect(player.choices, isEmpty);
  });

  test('burned-in room subtitles reject local changes without reopening',
      () async {
    final player = _Player();
    final model = _model(PlayMethod.transcode,
        delivery: SubtitleDeliveryMethod.encode, defaultIndex: 2);
    expect(await model.setSubtitle(null, player), same(model));
    expect(await model.setSubtitle(_track(2), player), same(model));
    for (final choice in [_track(3), SubStreamModel.no()]) {
      await expectLater(
          model.setSubtitle(choice, player),
          throwsA(isA<SyncPlayTrackSelectionFailure>().having(
              (failure) => failure.reason,
              'reason',
              SyncPlayTrackSelectionFailureReason.requiresServerReload)));
    }
    expect(model.mediaStreams?.defaultSubStreamIndex, 2);
    expect(model.serverManagedQueue, isTrue);
    expect(player.choices, isEmpty);
  });

  for (final method in [
    SubtitleDeliveryMethod.encode,
    SubtitleDeliveryMethod.drop,
    SubtitleDeliveryMethod.hls
  ]) {
    test('transcoded $method target is not presented as a local success',
        () async {
      final player = _Player();
      final model =
          _model(PlayMethod.transcode, delivery: method, defaultIndex: -1);
      await expectLater(model.setSubtitle(_track(2), player),
          throwsA(isA<SyncPlayTrackSelectionFailure>()));
      expect(player.choices, isEmpty);
      expect(model.mediaStreams?.defaultSubStreamIndex, -1);
    });
  }

  for (final method in [
    SubtitleDeliveryMethod.drop,
    SubtitleDeliveryMethod.hls
  ]) {
    test('initial $method track preserves the playable room stream', () async {
      final player = _Player();
      final model =
          _model(PlayMethod.transcode, delivery: method, defaultIndex: 2);
      expect(await model.setSubtitle(null, player), same(model));
      expect(player.choices, isEmpty);
    });
  }

  test('initial unavailable optional track does not fail room playback',
      () async {
    final player = _Player()..returnedIndex = -1;
    final model = _model(PlayMethod.directstream, defaultIndex: 3);
    expect(await model.setSubtitle(null, player), same(model));
    expect(model.serverManagedQueue, isTrue);
  });

  test('missing backend track reports unavailable and preserves selected model',
      () async {
    final player = _Player()..returnedIndex = -1;
    final model = _model(PlayMethod.directstream, defaultIndex: 3);
    await expectLater(
        model.setSubtitle(_track(2), player),
        throwsA(isA<SyncPlayTrackSelectionFailure>().having(
            (failure) => failure.reason,
            'reason',
            SyncPlayTrackSelectionFailureReason.unavailable)));
    expect(model.mediaStreams?.defaultSubStreamIndex, 3);
    expect(model.serverManagedQueue, isTrue);
  });

  test('UI selection catches unsupported without publishing or reloading',
      () async {
    final player = _Player();
    final model = _model(PlayMethod.transcode,
        delivery: SubtitleDeliveryMethod.encode, defaultIndex: 2);
    final failures = <SyncPlayTrackSelectionFailure>[];
    final selected = await trySelectLocalSubtitle(
        model: model,
        track: SubStreamModel.no(),
        player: player,
        isCurrent: () => true,
        onUnavailable: failures.add);
    expect(selected, isNull);
    expect(failures.single.reason,
        SyncPlayTrackSelectionFailureReason.requiresServerReload);
    expect(player.choices, isEmpty);
  });

  test('stale UI does not start an operation or show a failure notice',
      () async {
    final player = _Player();
    final failures = <SyncPlayTrackSelectionFailure>[];
    final selected = await trySelectLocalSubtitle(
        model: _model(PlayMethod.directstream),
        track: _track(2),
        player: player,
        isCurrent: () => false,
        onUnavailable: failures.add);
    expect(selected, isNull);
    expect(player.choices, isEmpty);
    expect(failures, isEmpty);
  });

  test('completed old track selection cannot replace the newly selected item',
      () async {
    var current = true;
    final player = _Player()..selectionReady = Completer<int>();
    final failures = <SyncPlayTrackSelectionFailure>[];
    final selection = trySelectLocalSubtitle(
        model: _model(PlayMethod.directstream),
        track: _track(2),
        player: player,
        isCurrent: () => current,
        onUnavailable: failures.add);
    current = false;
    player.selectionReady!.complete(2);
    expect(await selection, isNull);
    expect(failures, isEmpty);
  });

  test('late unavailable result is ignored after the UI was disposed',
      () async {
    var current = true;
    final player = _Player()..selectionReady = Completer<int>();
    final failures = <SyncPlayTrackSelectionFailure>[];
    final selection = trySelectLocalSubtitle(
        model: _model(PlayMethod.directstream),
        track: _track(2),
        player: player,
        isCurrent: () => current,
        onUnavailable: failures.add);
    current = false;
    player.selectionReady!.complete(-1);
    expect(await selection, isNull);
    expect(failures, isEmpty);
  });

  test('leaving the room during selection does not create another room model',
      () async {
    var current = true;
    final player = _Player()..selectionReady = Completer<int>();
    final model = _model(PlayMethod.directstream, current: () => current);
    final selection = model.setSubtitle(_track(2), player);
    current = false;
    player.selectionReady!.complete(2);
    expect(await selection, same(model));
  });
}
