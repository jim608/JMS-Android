import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart'
    hide SyncPlayQueueItem;
import 'package:fladder/models/items/movie_model.dart';
import 'package:fladder/models/playback/direct_playback_model.dart';
import 'package:fladder/models/playback/playback_model.dart';
import 'package:fladder/models/playback/transcode_playback_model.dart';
import 'package:fladder/services/syncplay/syncplay_models.dart';
import 'package:fladder/services/syncplay/syncplay_player.dart';
import 'package:fladder/util/mpv_hdr_tonemap.dart';
import 'package:fladder/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _UnusedApi extends Fake implements JellyfinOpenApi {}

void main() {
  final item = MovieModel.fromBaseDto(
      const BaseItemDto(
          id: '11111111111111111111111111111111',
          name: 'Synthetic HDR classification fixture',
          type: BaseItemKind.movie,
          mediaType: MediaType.video),
      null);
  const media = Media(url: 'https://media.example.invalid/synthetic');

  SyncPlayPlaybackModel roomModel(PlayMethod method) => SyncPlayPlaybackModel(
        item: item,
        media: media,
        playbackInfo: null,
        mediaStreams: null,
        api: _UnusedApi(),
        isCurrent: () => true,
        queueItem: const SyncPlayQueueItem(
            mediaId: '11111111111111111111111111111111',
            playlistItemId: '22222222222222222222222222222222'),
        playMethod: method,
      );

  final cases = <String, (PlaybackModel, bool)>{
    'ordinary direct stream': (
      DirectPlaybackModel(item: item, media: media),
      false,
    ),
    'ordinary transcode': (
      TranscodePlaybackModel(item: item, media: media, playbackInfo: null),
      true,
    ),
    'SyncPlay direct stream': (roomModel(PlayMethod.directstream), false),
    'SyncPlay transcode': (roomModel(PlayMethod.transcode), true),
  };

  for (final entry in cases.entries) {
    test('${entry.key} preserves the output classification at the HDR gate',
        () async {
      final (model, transcoded) = entry.value;
      expect(model.isServerTranscoded, transcoded);
      final source =
          MpvHdrSource(range: 'HDR10', transcoded: model.isServerTranscoded);
      if (transcoded) {
        expect(source.skipReason, contains('Transcoded output'));
        var reads = 0;
        final commands = <List<String>>[];
        final mapper = MpvHdrToneMapper(
          softwareRenderer: true,
          read: (_) async {
            reads++;
            return '';
          },
          command: (arguments) async => commands.add(arguments),
        );
        final decision = await mapper.prepare(mapper.begin(), source);
        expect(decision.applied, isFalse);
        expect(reads, 0);
        expect(commands, isEmpty);
      } else {
        // Direct output remains eligible for the existing decoded metadata,
        // renderer, peak and filter gates; this does not claim HDR acceptance.
        expect(source.skipReason, isNull);
      }
    });
    if (entry.key.startsWith('SyncPlay')) {
      testWidgets('${entry.key} shows its known playback source label',
          (tester) async {
        final (model, transcoded) = entry.value;
        late String expected;
        await tester.pumpWidget(MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(builder: (context) {
            final baseline = transcoded
                ? TranscodePlaybackModel(
                    item: item, media: media, playbackInfo: null)
                : DirectPlaybackModel(item: item, media: media);
            expected = baseline.label(context)!;
            return Text(model.label(context)!);
          }),
        ));
        await tester.pumpAndSettle();
        expect(expected, isNot('Unknown'));
        expect(find.text(expected), findsOneWidget);
        expect(find.text('Unknown'), findsNothing);
      });
    }
  }
}
