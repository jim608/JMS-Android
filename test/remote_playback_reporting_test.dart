import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/credentials_model.dart';
import 'package:fladder/models/items/media_streams_model.dart';
import 'package:fladder/models/items/movie_model.dart';
import 'package:fladder/models/items/overview_model.dart';
import 'package:fladder/models/playback/direct_playback_model.dart';
import 'package:fladder/models/playback/playback_model.dart';
import 'package:fladder/models/playback/transcode_playback_model.dart';
import 'package:fladder/providers/primary_subtitle_selection_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/util/subtitle_selection_failure.dart';
import 'package:fladder/wrappers/media_control_wrapper.dart';
import 'package:fladder/services/playback_reporting_scope.dart';

class _Item extends Fake implements ItemBaseModel {
  _Item(this.id);
  @override
  final String id;
  @override
  FladderItemType get type => FladderItemType.movie;
  @override
  OverviewModel get overview => MovieModel.fromBaseDto(
        const BaseItemDto(id: 'fixture', type: BaseItemKind.movie),
        null,
      ).overview;
  // Reading streamModel would fail: reporting must use the playback selection.
}

class _Api implements PlaybackReportApi {
  final starts = <PlaybackStartInfo>[];
  final progressReports = <PlaybackProgressInfo>[];
  final stops = <PlaybackStopInfo>[];
  @override
  Future<void> start(PlaybackStartInfo info) async {
    starts.add(info);
  }

  @override
  Future<void> progress(PlaybackProgressInfo info) async {
    progressReports.add(info);
  }

  @override
  Future<void> stop(PlaybackStopInfo info) async {
    stops.add(info);
  }

  @override
  void close() {}
}

class _Ref extends Fake implements Ref {}

class _CreationRef extends Fake implements Ref {
  final account = AccountModel(
      name: 'fixture',
      id: 'account-A',
      avatar: '',
      lastUsed: DateTime.utc(2026),
      credentials: CredentialsModel.internal());
  @override
  T read<T>(ProviderListenable<T> provider) {
    if (identical(provider, userProvider)) return account as T;
    throw StateError(
        'Account invalidation must stop before another API lookup');
  }
}

class _QueueGateHelper extends PlaybackModelHelper {
  _QueueGateHelper(
      Ref ref, PlaybackReportingCapture? Function() captureReporting)
      : super(ref: ref, captureReporting: captureReporting);
  final queue = Completer<List<ItemBaseModel>>();
  @override
  Future<List<ItemBaseModel>> collectQueue(ItemBaseModel model) => queue.future;
}

class _Player extends Fake implements MediaControlsWrapper {
  int epoch = 0;
  int generation = 0;
  @override
  int get playbackStopEpoch => epoch;
  @override
  int get rendererGeneration => generation;
}

MediaStreamsModel _streams({
  int? subtitle = 4,
  int? audio = 2,
  String source = 'selected-source',
}) =>
    MediaStreamsModel(
      defaultSubStreamIndex: subtitle,
      defaultAudioStreamIndex: audio,
      versionStreams: [
        VersionStreamModel(
          name: 'selected version',
          index: 0,
          id: source,
          defaultAudioStreamIndex: 9,
          defaultSubStreamIndex: 8,
          videoStreams: [],
          audioStreams: [],
          subStreams: [],
        ),
      ],
    );

void main() {
  test(
      'playback creation captures account before its first await and rejects a stale attempt',
      () async {
    var current = true, captures = 0;
    final capture = PlaybackReportingCapture(
        api: _Api(), isCurrent: () => current, isPlaybackCurrent: (_) => true);
    final helper = _QueueGateHelper(_CreationRef(), () {
      captures++;
      return capture;
    });
    final creating = helper.createPlaybackModel(null, _Item('movie'));
    expect(captures, 1);
    current = false;
    helper.queue.complete([]);
    expect(await creating, isNull);
    capture.close();
  });
  for (final transcode in [false, true]) {
    final label = transcode ? 'Transcode' : 'Direct';
    PlaybackModel create({
      String? playSession = 'occurrence-one',
      MediaStreamsModel? streams,
      List<ItemBaseModel> queue = const [],
      _Api? api,
    }) {
      final item = _Item('movie');
      final info = PlaybackInfoResponse(playSessionId: playSession);
      final selectedStreams = streams ?? _streams();
      final capture = PlaybackReportingCapture(
          api: api ?? _Api(),
          isCurrent: () => true,
          isPlaybackCurrent: (_) => true);
      final scope = capture.bind(
          itemId: item.id,
          mediaSourceId: selectedStreams.currentVersionStream?.id,
          playSessionId: playSession,
          playlistItemId: playSession == null || playSession.isEmpty
              ? null
              : 'jms-remote-$playSession');
      scope.activate();
      return transcode
          ? TranscodePlaybackModel(
              item: item,
              reportingScope: scope,
              media: null,
              playbackInfo: info,
              mediaStreams: selectedStreams,
              queue: queue,
            )
          : DirectPlaybackModel(
              item: item,
              reportingScope: scope,
              media: null,
              playbackInfo: info,
              mediaStreams: selectedStreams,
              queue: queue,
            );
    }

    test(
      '$label Start Progress Stop report selected source streams and occurrence',
      () async {
        final api = _Api();
        final model = create(
          queue: [_Item('previous'), _Item('movie'), _Item('next')],
          api: api,
        );
        final actualRef = _Ref();
        await model.playbackStarted(const Duration(seconds: 1), actualRef);
        await model.updatePlaybackPosition(
          const Duration(seconds: 5),
          false,
          actualRef,
        );
        await model.playbackStopped(
          const Duration(seconds: 6),
          null,
          actualRef,
        );
        expect(api.starts.single.mediaSourceId, 'selected-source');
        expect(api.progressReports.single.mediaSourceId, 'selected-source');
        expect(api.stops.single.mediaSourceId, 'selected-source');
        expect(api.starts.single.subtitleStreamIndex, 4);
        expect(api.progressReports.single.subtitleStreamIndex, 4);
        expect(api.starts.single.audioStreamIndex, 2);
        expect(api.progressReports.single.audioStreamIndex, 2);
        expect(api.progressReports.single.isPaused, isTrue);
        expect(api.progressReports.single.positionTicks, 50000000);
        for (final json in [
          api.starts.single.toJson(),
          api.progressReports.single.toJson(),
          api.stops.single.toJson(),
        ]) {
          expect(json['PlaylistItemId'], 'jms-remote-occurrence-one');
        }
        for (final queue in [
          api.starts.single.nowPlayingQueue!,
          api.progressReports.single.nowPlayingQueue!,
          api.stops.single.nowPlayingQueue!,
        ]) {
          expect(
            queue.singleWhere((entry) => entry.id == 'movie').playlistItemId,
            'jms-remote-occurrence-one',
          );
        }
      },
    );

    test(
      '$label copies preserve occurrence while replay replaces it and missing id disables binding',
      () {
        final model = create();
        final dynamic selected = transcode
            ? (model as TranscodePlaybackModel).copyWith(
                mediaStreams: () => _streams(subtitle: -1),
              )
            : (model as DirectPlaybackModel).copyWith(
                mediaStreams: () => _streams(subtitle: -1),
              );
        expect(selected.currentPlaylistItemId, model.currentPlaylistItemId);
        expect(
            identical(selected.reportingScope, model.reportingScope), isTrue);
        final dynamic replay = transcode
            ? (model as TranscodePlaybackModel).copyWith(
                playbackInfo:
                    const PlaybackInfoResponse(playSessionId: 'replay'))
            : (model as DirectPlaybackModel).copyWith(
                playbackInfo:
                    const PlaybackInfoResponse(playSessionId: 'replay'));
        expect(identical(replay.reportingScope, model.reportingScope), isFalse);
        expect(
            identical(
                replay.reportingScope.capture, model.reportingScope!.capture),
            isTrue);
        expect(replay.reportingScope.isCurrent, isFalse);
        expect(
          create(playSession: 'occurrence-two').currentPlaylistItemId,
          'jms-remote-occurrence-two',
        );
        expect(create(playSession: null).currentPlaylistItemId, isNull);
        expect(create(playSession: '').currentPlaylistItemId, isNull);
      },
    );

    test(
        '$label unbound model fails closed without reading a mutable account API',
        () async {
      final item = _Item('unbound');
      final PlaybackModel model = transcode
          ? TranscodePlaybackModel(
              item: item,
              media: null,
              playbackInfo:
                  const PlaybackInfoResponse(playSessionId: 'unbound'),
              mediaStreams: _streams())
          : DirectPlaybackModel(
              item: item,
              media: null,
              playbackInfo:
                  const PlaybackInfoResponse(playSessionId: 'unbound'),
              mediaStreams: _streams());
      final ref = _Ref();
      expect(await model.playbackStarted(Duration.zero, ref), isNull);
      expect(
          await model.updatePlaybackPosition(Duration.zero, true, ref), isNull);
      expect(await model.playbackStopped(Duration.zero, null, ref), isNull);
    });

    test(
      '$label every progress preserves marker and confirmed Off or pending null',
      () async {
        final api = _Api(),
            model = create(streams: _streams(subtitle: -1, audio: 3), api: api);
        await model.updatePlaybackPosition(Duration.zero, true, _Ref());
        await model.updatePlaybackPosition(
          const Duration(seconds: 1),
          true,
          _Ref(),
        );
        expect(
          api.progressReports.every(
            (report) => report.playlistItemId == model.currentPlaylistItemId,
          ),
          isTrue,
        );
        expect(
          api.progressReports
              .every((report) => report.subtitleStreamIndex == -1),
          isTrue,
        );
        final pending =
            create(streams: _streams(subtitle: null, audio: null), api: api);
        await pending.updatePlaybackPosition(Duration.zero, true, _Ref());
        expect(api.progressReports.last.subtitleStreamIndex, isNull);
        expect(api.progressReports.last.audioStreamIndex, isNull);
        expect(
          api.progressReports.last.toJson().containsKey('SubtitleStreamIndex'),
          isFalse,
        );
        expect(
          api.progressReports.last.nowPlayingQueue!.single.playlistItemId,
          pending.currentPlaylistItemId,
        );
      },
    );

    test(
        '$label Web reporting only acknowledges current successful renderer selection',
        () {
      final model = create(), player = _Player();
      PrimarySubtitleSelectionState state(
              {bool pending = false,
              int? applied = 7,
              bool failed = false,
              PlaybackModel? forModel,
              MediaControlsWrapper? forPlayer,
              int? generation,
              int epoch = 0}) =>
          PrimarySubtitleSelectionState(
              model: forModel ?? model,
              player: forPlayer ?? player,
              rendererGeneration: generation ?? player.rendererGeneration,
              stopEpoch: epoch,
              pending: pending,
              appliedIndex: applied,
              error: failed
                  ? const SubtitleSelectionFailure(
                      SubtitleSelectionFailureReason.unavailable)
                  : null);
      int? report(PrimarySubtitleSelectionState? selection) =>
          playbackSubtitleStreamIndexForReport(
              web: true, model: model, player: player, selection: selection);
      expect(report(state()),
          7); // Confirmed index, even when requested/default differs.
      expect(report(state(applied: -1)), -1);
      expect(report(state(applied: null)), isNull);
      expect(report(null), isNull);
      expect(report(state(pending: true)), isNull);
      expect(report(state(failed: true)), isNull);
      expect(report(state(forModel: create(playSession: 'new-occurrence'))),
          isNull);
      expect(
          report(state(
              forModel: create(streams: _streams(source: 'other-source')))),
          isNull);
      expect(report(state(forPlayer: _Player())), isNull);
      expect(report(state(generation: 1)), isNull);
      final previousRenderer = state();
      player.generation++;
      expect(report(previousRenderer), isNull);
      expect(report(state()), 7);
      expect(report(state(epoch: 1)), isNull);
      player.epoch = 1;
      expect(report(state()), isNull);
      expect(
          playbackSubtitleStreamIndexForReport(
              web: false,
              model: model,
              player: player,
              selection: state(failed: true)),
          4);
    });
  }
}
