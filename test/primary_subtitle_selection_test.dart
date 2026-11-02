import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/l10n/generated/app_localizations.dart';
import 'package:fladder/models/items/media_streams_model.dart';
import 'package:fladder/models/items/movie_model.dart';
import 'package:fladder/models/playback/direct_playback_model.dart';
import 'package:fladder/models/playback/playback_model.dart';
import 'package:fladder/models/playback/transcode_playback_model.dart';
import 'package:fladder/models/settings/video_player_settings.dart';
import 'package:fladder/providers/primary_subtitle_selection_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/screens/video_player/components/video_player_options_sheet.dart';
import 'package:fladder/util/dual_subtitle.dart';
import 'package:fladder/util/subtitle_offset.dart';
import 'package:fladder/util/subtitle_selection_failure.dart';
import 'package:fladder/wrappers/media_control_wrapper.dart';

SubStreamModel _track(int index) => SubStreamModel(
    name: 'Synthetic $index',
    id: 'synthetic-$index',
    title: 'Synthetic $index',
    displayTitle: 'Synthetic $index',
    language: index == 2 ? 'zh-Hant' : 'zh-Hans',
    codec: 'srt',
    index: index,
    isDefault: index == 2,
    isExternal: false);

DirectPlaybackModel _model({
  String id = 'synthetic-item',
  int index = 2,
  String sourceId = 'synthetic-source',
}) =>
    DirectPlaybackModel(
        item: MovieModel.fromBaseDto(
            BaseItemDto(
                id: id,
                name: id,
                type: BaseItemKind.movie,
                mediaType: MediaType.video),
            null),
        media: const Media(url: 'https://media.example.invalid/stream'),
        playbackInfo:
            const PlaybackInfoResponse(playSessionId: 'synthetic-session'),
        mediaStreams:
            MediaStreamsModel(defaultSubStreamIndex: index, versionStreams: [
          VersionStreamModel(
              name: 'Synthetic source',
              index: 0,
              id: sourceId,
              defaultAudioStreamIndex: null,
              defaultSubStreamIndex: index,
              videoStreams: [],
              audioStreams: [],
              subStreams: [_track(2), _track(3)])
        ]));

class _Player extends Fake implements MediaControlsWrapper {
  final choices = <int>[];
  final pending = <Completer<int>>[];
  final secondary = ValueNotifier(const SecondarySubtitleState());
  bool playing = true;
  int stopEpoch = 0;
  int rendererEpoch = 0;
  int subtitleCancellations = 0;
  @override
  int get playbackStopEpoch => stopEpoch;
  @override
  int get rendererGeneration => rendererEpoch;
  @override
  void cancelPendingSubtitleSelection() {
    subtitleCancellations++;
  }

  @override
  Future<void> dispose() async {}
  @override
  PlayerOptions get backend => PlayerOptions.libMPV;
  @override
  bool get supportsSecondarySubtitles => false;
  @override
  ValueNotifier<SecondarySubtitleState> get secondarySubtitleState => secondary;
  @override
  SubtitleOffsetController? get subtitleOffsets => null;
  @override
  Future<int> setSubtitleTrack(SubStreamModel? track, PlaybackModel model) {
    choices.add((track ?? model.defaultSubStream)?.index ?? -1);
    final completion = Completer<int>();
    pending.add(completion);
    return completion.future;
  }
}

class _Notifier extends VideoPlayerNotifier {
  _Notifier(super.ref, _Player player) {
    state = player;
  }
  void replace(_Player player) {
    state = player;
  }
}

class _Reload extends Fake implements PlaybackModelHelper {
  final models = <PlaybackModel>[];
  SubtitleSelectionFailure? failure;
  Future<void> Function(PlaybackModel)? onReload;
  @override
  Future<void> shouldReload(PlaybackModel model) async {
    models.add(model);
    if (failure != null) throw failure!;
    await onReload?.call(model);
  }
}

class _Fixture {
  _Fixture() {
    container = ProviderContainer(overrides: [
      playBackModel.overrideWith((ref) => model),
      videoPlayerProvider.overrideWith((ref) => _Notifier(ref, player)),
      playbackModelHelper.overrideWithValue(reload),
    ]);
  }
  final model = _model();
  final player = _Player();
  final reload = _Reload();
  late final ProviderContainer container;
  PrimarySubtitleSelectionController get controller =>
      container.read(primarySubtitleSelectionProvider.notifier);
  PrimarySubtitleSelectionState get selection =>
      container.read(primarySubtitleSelectionProvider);
  int? get selected =>
      container.read(playBackModel)?.mediaStreams?.defaultSubStreamIndex;
  void dispose() {
    container.dispose();
    player.secondary.dispose();
  }
}

Finder _row(String title) => find.byWidgetPredicate((widget) =>
    widget is ListTile &&
    widget.title is Text &&
    (widget.title as Text).data == title);

Future<void> _open(WidgetTester tester, _Fixture fixture) async {
  await tester.pumpWidget(UncontrolledProviderScope(
      container: fixture.container,
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
}

void main() {
  for (final transcode in [false, true]) {
    test(
        '${transcode ? 'Transcode' : 'Direct'} failure preserves selection; explicit Off succeeds',
        () async {
      final initial = _model();
      final PlaybackModel model = transcode
          ? TranscodePlaybackModel(
              item: initial.item,
              media: initial.media,
              playbackInfo: initial.playbackInfo,
              mediaStreams: initial.mediaStreams)
          : initial;
      final player = _Player();
      addTearDown(player.secondary.dispose);
      for (final returned in [-1, 3]) {
        final selection = model.setSubtitle(_track(2), player)!;
        final assertion = expectLater(
            selection,
            throwsA(isA<SubtitleSelectionFailure>().having(
                (failure) => failure.reason,
                'reason',
                SubtitleSelectionFailureReason.unavailable)));
        player.pending.last.complete(returned);
        await assertion;
        expect(model.mediaStreams?.defaultSubStreamIndex, 2);
      }
      final wrongOff = model.setSubtitle(SubStreamModel.no(), player)!;
      final wrongOffAssertion =
          expectLater(wrongOff, throwsA(isA<SubtitleSelectionFailure>()));
      player.pending.last.complete(2);
      await wrongOffAssertion;
      final off = model.setSubtitle(SubStreamModel.no(), player)!;
      player.pending.last.complete(-1);
      expect((await off).mediaStreams?.defaultSubStreamIndex, -1);
      expect(player.playing, isTrue);
    });
  }

  test('failure never publishes Off or reloads; retry can recover', () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final first = fixture.controller.select(_track(2));
    fixture.player.pending.last.complete(-1);
    expect((await first).failure?.reason,
        SubtitleSelectionFailureReason.unavailable);
    expect(fixture.container.read(playBackModel), same(fixture.model));
    expect(fixture.selected, 2);
    expect(fixture.reload.models, isEmpty);
    expect(fixture.selection.pending, isFalse);
    final retry = fixture.controller.select(_track(2));
    fixture.player.pending.last.complete(2);
    expect((await retry).applied, isTrue);
    expect(fixture.selected, 2);
    expect(fixture.selection.error, isNull);
    expect(fixture.reload.models, hasLength(1));
    expect(fixture.player.playing, isTrue);
  });

  test('sequential A Off B keeps the confirmed model while playing', () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    for (final index in [2, -1, 3]) {
      final selection = fixture.controller
          .select(index < 0 ? SubStreamModel.no() : _track(index));
      fixture.player.pending.last.complete(index);
      expect((await selection).applied, isTrue);
      expect(fixture.selected, index);
      expect(fixture.selection.appliedIndex, index);
      expect(fixture.player.playing, isTrue);
    }
    expect(fixture.player.choices, [2, -1, 3]);
  });

  test('a second pending choice is ignored and remains retryable', () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final first = fixture.controller.select(_track(2));
    expect((await fixture.controller.select(_track(3))).applied, isFalse);
    expect(fixture.player.choices, [2]);
    fixture.player.pending.last.complete(2);
    await first;
    final retry = fixture.controller.select(_track(3));
    fixture.player.pending.last.complete(3);
    await retry;
    expect(fixture.selected, 3);
  });

  test('revoked or throwing remote owner preserves an existing UI confirmation',
      () async {
    for (final ownerCurrent in <bool Function()>[
      () => false,
      () => throw StateError('Owner was revoked'),
    ]) {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      fixture.controller
          .recordInitial(fixture.model, fixture.player, appliedIndex: 2);
      final confirmed = fixture.selection;

      final result = await fixture.controller.select(_track(3),
          expectedModel: fixture.model,
          expectedPlayer: fixture.player,
          isCurrent: ownerCurrent);

      expect(result.applied, isFalse);
      expect(fixture.player.choices, isEmpty);
      expect(fixture.reload.models, isEmpty);
      expect(fixture.selected, 2);
      expect(fixture.selection, same(confirmed));
      expect(fixture.selection.appliedIndex, 2);
      expect(fixture.selection.error, isNull);
    }
  });

  test('remote owner revoked during selection cannot publish and UI can retry',
      () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    var ownerCurrent = true;
    final remote = fixture.controller.select(_track(3),
        expectedModel: fixture.model,
        expectedPlayer: fixture.player,
        isCurrent: () => ownerCurrent);
    expect(fixture.selection.pending, isTrue);
    ownerCurrent = false;
    fixture.player.pending.single.complete(3);

    expect((await remote).applied, isFalse);
    expect(fixture.container.read(playBackModel), same(fixture.model));
    expect(fixture.selected, 2);
    expect(fixture.reload.models, isEmpty);
    expect(fixture.selection.pending, isFalse);
    expect(fixture.selection.appliedIndex, isNull);
    expect(fixture.selection.error?.reason,
        SubtitleSelectionFailureReason.unavailable);

    final local = fixture.controller.select(_track(3));
    fixture.player.pending.last.complete(3);
    expect((await local).applied, isTrue);
    expect(fixture.selected, 3);
    expect(fixture.selection.appliedIndex, 3);
    expect(fixture.selection.error, isNull);
  });

  test('stale expected model or player cannot replace current UI confirmation',
      () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final stalePlayer = _Player();
    addTearDown(stalePlayer.secondary.dispose);
    fixture.controller
        .recordInitial(fixture.model, fixture.player, appliedIndex: 2);
    final confirmed = fixture.selection;

    expect(
        (await fixture.controller.select(_track(3),
                expectedModel: _model(), expectedPlayer: fixture.player))
            .applied,
        isFalse);
    expect(
        (await fixture.controller.select(_track(3),
                expectedModel: fixture.model, expectedPlayer: stalePlayer))
            .applied,
        isFalse);
    expect(fixture.player.choices, isEmpty);
    expect(fixture.selection, same(confirmed));
    expect(fixture.reload.models, isEmpty);
  });

  for (final change in ['same-item replay', 'media source replacement']) {
    test('$change invalidates a pending remote subtitle completion', () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      final remote = fixture.controller.select(_track(3),
          expectedModel: fixture.model,
          expectedPlayer: fixture.player,
          isCurrent: () => true);
      final replacement = change == 'same-item replay'
          ? fixture.model.copyWith(
              playbackInfo: const PlaybackInfoResponse(
                  playSessionId: 'different-occurrence'))
          : _model(sourceId: 'different-source');
      fixture.container.read(playBackModel.notifier).state = replacement;
      fixture.player.pending.single.complete(3);

      expect((await remote).applied, isFalse);
      expect(fixture.container.read(playBackModel), same(replacement));
      expect(fixture.selected, 2);
      expect(fixture.reload.models, isEmpty);
      expect(fixture.selection.pending, isFalse);
      expect(fixture.selection.appliedIndex, isNull);
    });
  }

  test('new item invalidates the old operation and permits a new selection',
      () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final old = fixture.controller.select(_track(2));
    fixture.container.read(playBackModel.notifier).state =
        _model(id: 'new-item');
    final replacement = fixture.controller.select(_track(3));
    expect(fixture.player.choices, [2, 3]);
    fixture.player.pending[1].complete(3);
    await replacement;
    fixture.player.pending[0].complete(2);
    expect((await old).applied, isFalse);
    expect(fixture.container.read(playBackModel)?.item.id, 'new-item');
    expect(fixture.selected, 3);
    expect(fixture.reload.models, hasLength(1));
  });

  test('player replacement and stop invalidate pending completion', () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final old = fixture.controller.select(_track(2));
    final replacement = _Player();
    addTearDown(replacement.secondary.dispose);
    (fixture.container.read(videoPlayerProvider.notifier) as _Notifier)
        .replace(replacement);
    fixture.player.pending.single.complete(2);
    expect((await old).applied, isFalse);
    expect(fixture.reload.models, isEmpty);
    final stopping = fixture.controller.select(_track(3));
    replacement.stopEpoch++;
    replacement.pending.single.complete(3);
    expect((await stopping).applied, isFalse);
    expect(fixture.selected, 2);
    expect(fixture.selection.pending, isFalse);
  });

  test('same wrapper with a replacement renderer rejects pending completion',
      () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final pending = fixture.controller.select(_track(3),
        expectedModel: fixture.model,
        expectedPlayer: fixture.player,
        isCurrent: () => true);
    fixture.player.rendererEpoch++;
    fixture.player.pending.single.complete(3);

    expect((await pending).applied, isFalse);
    expect(fixture.container.read(playBackModel), same(fixture.model));
    expect(fixture.selected, 2);
    expect(fixture.reload.models, isEmpty);
    expect(fixture.selection.pending, isFalse);
    expect(fixture.selection.appliedIndex, isNull);
    expect(fixture.selection.isFor(fixture.model, fixture.player), isFalse);
  });

  test('a remote owner cannot cancel a normal UI subtitle selection', () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final local = fixture.controller.select(_track(3));
    final pendingState = fixture.selection;

    fixture.controller.cancelOwnedSelection(Object());

    expect(fixture.player.subtitleCancellations, 0);
    expect(fixture.selection, same(pendingState));
    expect(fixture.selection.pending, isTrue);
    fixture.player.pending.single.complete(3);
    expect((await local).applied, isTrue);
    expect(fixture.selected, 3);
  });

  test('only the exact remote owner cancels its pending backend selection',
      () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final owner = Object();
    final remote = fixture.controller.select(_track(3), owner: owner);
    final pendingState = fixture.selection;

    fixture.controller.cancelOwnedSelection(Object());
    expect(fixture.player.subtitleCancellations, 0);
    expect(fixture.selection, same(pendingState));

    fixture.controller.cancelOwnedSelection(owner);
    expect(fixture.player.subtitleCancellations, 1);
    expect(fixture.selection.pending, isFalse);
    expect(fixture.selection.error?.reason,
        SubtitleSelectionFailureReason.unavailable);
    fixture.player.pending.single.complete(3);
    expect((await remote).applied, isFalse);
    expect(fixture.selected, 2);
    expect(fixture.reload.models, isEmpty);
  });

  test('a cancelled remote owner cannot cancel or overwrite the next UI choice',
      () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final owner = Object();
    final remote = fixture.controller.select(_track(3), owner: owner);
    fixture.controller.cancelOwnedSelection(owner);
    final local = fixture.controller.select(SubStreamModel.no());
    final localPendingState = fixture.selection;

    fixture.controller.cancelOwnedSelection(owner);

    expect(fixture.player.subtitleCancellations, 1);
    expect(fixture.selection, same(localPendingState));
    expect(fixture.selection.pending, isTrue);
    expect(fixture.player.choices, [3, -1]);
    fixture.player.pending[1].complete(-1);
    expect((await local).applied, isTrue);
    fixture.player.pending[0].complete(3);
    expect((await remote).applied, isFalse);
    expect(fixture.selected, -1);
    expect(fixture.selection.appliedIndex, -1);
    expect(fixture.selection.error, isNull);
    expect(fixture.reload.models, hasLength(1));
  });

  testWidgets(
      'dismissed dialog still commits the current session without disposed ref access',
      (tester) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    await _open(tester, fixture);
    await tester.tap(_row('Synthetic 3'));
    await tester.pump();
    expect(tester.widget<ListTile>(_row('Synthetic 2')).onTap, isNull);
    Navigator.of(tester.element(find.byType(SimpleDialog))).pop();
    await tester.pumpAndSettle();
    fixture.player.pending.single.complete(3);
    await tester.pumpAndSettle();
    expect(fixture.selected, 3);
    expect(fixture.reload.models, hasLength(1));
    expect(fixture.selection.pending, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'unconfirmed startup failure highlights neither Off nor the requested track and can retry',
      (tester) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    fixture.controller.recordInitial(fixture.model, fixture.player,
        failure: const SubtitleSelectionFailure(
            SubtitleSelectionFailureReason.unavailable));
    await _open(tester, fixture);
    expect(tester.widget<ListTile>(_row('Off')).tileColor, isNull);
    expect(tester.widget<ListTile>(_row('Synthetic 2')).tileColor, isNull);
    expect(tester.widget<ListTile>(_row('Synthetic 2')).onTap, isNotNull);
    await tester.tap(_row('Synthetic 2'));
    await tester.pump();
    fixture.player.pending.single.complete(2);
    await tester.pumpAndSettle();
    expect(tester.widget<ListTile>(_row('Synthetic 2')).tileColor, isNotNull);
    expect(fixture.selection.error, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('disposing the container cannot publish a pending result', () async {
    final fixture = _Fixture();
    final pending = fixture.controller.select(_track(3));
    fixture.container.dispose();
    fixture.player.pending.single.complete(3);
    expect((await pending).applied, isFalse);
    expect(fixture.reload.models, isEmpty);
    fixture.player.secondary.dispose();
  });

  test(
      'initial token blocks selection and ignores superseded initial completion',
      () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final oldToken =
        fixture.controller.beginInitial(fixture.model, fixture.player);
    expect(fixture.selection.pending, isTrue);
    expect((await fixture.controller.select(_track(3))).applied, isFalse);
    expect(fixture.player.choices, isEmpty);
    final currentToken =
        fixture.controller.beginInitial(fixture.model, fixture.player);
    fixture.controller.recordInitial(fixture.model, fixture.player,
        token: currentToken, appliedIndex: 2);
    fixture.controller.recordInitial(fixture.model, fixture.player,
        token: oldToken,
        failure: const SubtitleSelectionFailure(
            SubtitleSelectionFailureReason.unavailable));
    expect(fixture.selection.appliedIndex, 2);
    expect(fixture.selection.error, isNull);
    expect(fixture.selection.pending, isFalse);
  });

  test(
      'initial stop cancellation releases pending without confirming Off and permits retry',
      () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final token =
        fixture.controller.beginInitial(fixture.model, fixture.player);
    fixture.player.stopEpoch++;
    fixture.controller.recordInitial(fixture.model, fixture.player,
        token: token, appliedIndex: 2);
    fixture.controller.cancelInitial(token);
    expect(fixture.selection.pending, isFalse);
    expect(fixture.selection.appliedIndex, isNull);
    expect(fixture.selection.error?.reason,
        SubtitleSelectionFailureReason.unavailable);
    final currentToken =
        fixture.controller.beginInitial(fixture.model, fixture.player);
    fixture.controller.cancelInitial(token);
    expect(fixture.selection.pending, isTrue);
    fixture.controller.recordInitial(fixture.model, fixture.player,
        token: currentToken,
        failure: const SubtitleSelectionFailure(
            SubtitleSelectionFailureReason.unavailable));
    final retry = fixture.controller.select(_track(2));
    fixture.player.pending.single.complete(2);
    expect((await retry).applied, isTrue);
    expect(fixture.selection.appliedIndex, 2);
    expect(fixture.player.playing, isTrue);
  });

  test('malformed negative choice cannot become explicit Off', () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    expect((await fixture.controller.select(_track(-2))).applied, isFalse);
    expect(fixture.player.choices, isEmpty);
    expect(fixture.selected, 2);
  });

  test(
      'authorized reload startup owns final confirmation after old selection completes',
      () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    fixture.reload.onReload = (selected) async {
      final replacement = _model(index: 3);
      final token =
          fixture.controller.beginInitial(replacement, fixture.player);
      fixture.container.read(playBackModel.notifier).state = replacement;
      fixture.controller.recordInitial(replacement, fixture.player,
          token: token, appliedIndex: 3);
    };
    final choice = fixture.controller.select(_track(3));
    fixture.player.pending.single.complete(3);
    await choice;
    expect(fixture.selected, 3);
    expect(fixture.selection.appliedIndex, 3);
    expect(fixture.selection.pending, isFalse);
    expect(fixture.selection.error, isNull);
  });

  test('unconfirmed startup failure survives an unrelated same-session clone',
      () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    const failure = SubtitleSelectionFailure(
        SubtitleSelectionFailureReason.requiresServerReload);
    fixture.controller
        .recordInitial(fixture.model, fixture.player, failure: failure);
    final clone = fixture.model.copyWith();
    fixture.container.read(playBackModel.notifier).state = clone;
    expect(fixture.selection.isFor(clone, fixture.player), isTrue);
    expect(fixture.selection.appliedIndex, isNull);
    expect(fixture.selection.error, same(failure));
    expect(fixture.selection.requested?.index, 2);
  });

  testWidgets('old menu row cannot apply into a new item before rebuild',
      (tester) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    await _open(tester, fixture);
    final oldTap = tester.widget<ListTile>(_row('Synthetic 3')).onTap!;
    final replacement = _model(id: 'different-item');
    fixture.container.read(playBackModel.notifier).state = replacement;
    oldTap();
    await tester.pumpAndSettle();
    expect(fixture.player.choices, isEmpty);
    expect(fixture.container.read(playBackModel), same(replacement));
    expect(fixture.reload.models, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
