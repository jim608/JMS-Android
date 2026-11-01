import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/util/selected_media_source.dart';
import 'package:flutter_test/flutter_test.dart';

const _simplified = MediaStream(
  type: MediaStreamType.subtitle,
  index: 7,
  language: 'zh-Hans',
  codec: 'srt',
  title: '简体中文',
  displayTitle: 'Chinese Simplified',
);

const _traditional = MediaStream(
  type: MediaStreamType.subtitle,
  index: 47,
  language: 'zh-Hant',
  codec: 'ass',
  title: '繁體中文',
  displayTitle: 'Chinese Traditional',
);

void main() {
  group('PlaybackInfo media source binding', () {
    const sourceA = MediaSourceInfo(
      id: 'source-a',
      mediaStreams: [_simplified],
    );
    const sourceB = MediaSourceInfo(
      id: 'source-b',
      mediaStreams: [_simplified, _traditional],
    );

    test('retains the requested source when response order changes', () {
      for (final sources in [
        [sourceA, sourceB],
        [sourceB, sourceA],
      ]) {
        final binding = resolvePlaybackMediaSource(
          sources,
          requestedMediaSourceId: 'source-b',
          subtitleStreamIndex: 47,
        );

        expect(binding.isAvailable, isTrue);
        expect(binding.issue, isNull);
        expect(binding.selection!.source, sourceB);
        expect(binding.selection!.responseIndex, sources.indexOf(sourceB));
        expect(binding.selection!.subtitleStreamIndex, 47);
      }
    });

    test('retains the requested source when other sources are filtered out',
        () {
      final binding = resolvePlaybackMediaSource(
        [sourceB],
        requestedMediaSourceId: 'source-b',
        subtitleStreamIndex: 47,
      );

      expect(binding.selection!.source, sourceB);
      expect(binding.selection!.responseIndex, 0);
      expect(binding.selection!.subtitleStreamIndex, 47);
    });

    test('uses the server subtitle index rather than subtitle list position',
        () {
      final binding = resolvePlaybackMediaSource(
        [sourceB],
        requestedMediaSourceId: 'source-b',
        subtitleStreamIndex: 47,
      );

      expect(binding.selection!.subtitleStreamIndex, _traditional.index);
      expect(binding.selection!.source.mediaStreams, contains(_traditional));
      expect(binding.selection!.subtitleStreamIndex, isNot(1));
    });

    test(
        'equal subtitle indexes in other sources cannot change source identity',
        () {
      const otherSource = MediaSourceInfo(
        id: 'other-source',
        mediaStreams: [
          MediaStream(
            type: MediaStreamType.subtitle,
            index: 47,
            language: 'zh-Hans',
            displayTitle: 'Chinese',
          ),
        ],
      );
      final binding = resolvePlaybackMediaSource(
        [otherSource, sourceB],
        requestedMediaSourceId: 'source-b',
        subtitleStreamIndex: 47,
      );

      expect(binding.selection!.source, sourceB);
      expect(binding.selection!.source.mediaStreams!.last.language, 'zh-Hant');
    });

    test('a missing requested source cannot fall back to the only response',
        () {
      final binding = resolvePlaybackMediaSource(
        [sourceA],
        requestedMediaSourceId: 'source-b',
        subtitleStreamIndex: 7,
      );

      expect(binding.isAvailable, isFalse);
      expect(binding.selection, isNull);
      expect(binding.issue, PlaybackSourceBindingIssue.missingRequestedSource);
    });

    test('media source IDs match exactly', () {
      for (final requestedId in ['SOURCE-B', ' source-b', 'source-b ']) {
        final binding = resolvePlaybackMediaSource(
          [sourceB],
          requestedMediaSourceId: requestedId,
          subtitleStreamIndex: 47,
        );

        expect(binding.selection, isNull);
        expect(
            binding.issue, PlaybackSourceBindingIssue.missingRequestedSource);
      }
    });

    test('an empty requested ID cannot be treated as an initial source request',
        () {
      for (final requestedId in ['', '   ']) {
        final binding = resolvePlaybackMediaSource(
          [sourceB],
          requestedMediaSourceId: requestedId,
          subtitleStreamIndex: 47,
        );

        expect(binding.selection, isNull);
        expect(binding.issue, PlaybackSourceBindingIssue.missingSourceId);
      }
    });

    test('duplicate requested source IDs are rejected', () {
      final binding = resolvePlaybackMediaSource(
        [sourceB, sourceB],
        requestedMediaSourceId: 'source-b',
        subtitleStreamIndex: 47,
      );

      expect(binding.isAvailable, isFalse);
      expect(binding.selection, isNull);
      expect(binding.issue, PlaybackSourceBindingIssue.ambiguousSourceId);
    });

    test('an initial request can bind a single source with a usable ID', () {
      final binding = resolvePlaybackMediaSource(
        [sourceB],
        requestedMediaSourceId: null,
        subtitleStreamIndex: 47,
      );

      expect(binding.isAvailable, isTrue);
      expect(binding.issue, isNull);
      expect(binding.selection!.source, sourceB);
      expect(binding.selection!.responseIndex, 0);
    });

    test('an initial request cannot choose between multiple response sources',
        () {
      final binding = resolvePlaybackMediaSource(
        [sourceA, sourceB],
        requestedMediaSourceId: null,
        subtitleStreamIndex: 47,
      );

      expect(binding.selection, isNull);
      expect(binding.issue, PlaybackSourceBindingIssue.ambiguousSources);
    });

    test('null and empty response lists are unavailable', () {
      for (final sources in <List<MediaSourceInfo>?>[null, []]) {
        final binding = resolvePlaybackMediaSource(
          sources,
          requestedMediaSourceId: 'source-b',
          subtitleStreamIndex: 47,
        );

        expect(binding.selection, isNull);
        expect(binding.issue, PlaybackSourceBindingIssue.missingSources);
      }
    });

    test('a single source without an ID cannot become a playback source', () {
      for (final id in <String?>[null, '', '   ']) {
        final binding = resolvePlaybackMediaSource(
          [
            MediaSourceInfo(id: id, mediaStreams: [_traditional])
          ],
          requestedMediaSourceId: null,
          subtitleStreamIndex: 47,
        );

        expect(binding.selection, isNull);
        expect(binding.issue, PlaybackSourceBindingIssue.missingSourceId);
      }
    });

    test('subtitle identity survives source response reordering', () {
      final keys = [
        [sourceA, sourceB],
        [sourceB, sourceA],
      ].map((sources) {
        final binding = resolvePlaybackMediaSource(
          sources,
          requestedMediaSourceId: 'source-b',
          subtitleStreamIndex: 47,
        );
        return binding.selection!.subtitleKey(47);
      }).toList();

      expect(keys.first, keys.last);
      expect(keys.first, playbackSubtitleKey('source-b', 47));
      expect(keys.first, isNot(playbackSubtitleKey('source-a', 47)));
      expect(keys.first, isNot(playbackSubtitleKey('source-b', 48)));
    });

    test('source separators and percent signs keep subtitle keys distinct', () {
      const sourceId = 'source:/:?%#';
      final key = playbackSubtitleKey(sourceId, 47);
      final parts = key.split(':');

      expect(parts, hasLength(2));
      expect(Uri.decodeComponent(parts.first), sourceId);
      expect(parts.last, '47');
      expect(
        playbackSubtitleKey('source:a', 47),
        isNot(playbackSubtitleKey('source%3Aa', 47)),
      );
    });
  });

  group('selected subtitle validation', () {
    test('null and Off do not require a subtitle stream', () {
      const source = MediaSourceInfo(id: 'source-without-subtitles');
      for (final index in <int?>[null, -1]) {
        final binding = resolvePlaybackMediaSource(
          [source],
          requestedMediaSourceId: source.id,
          subtitleStreamIndex: index,
        );

        expect(binding.isAvailable, isTrue);
        expect(binding.issue, isNull);
        expect(binding.selection!.source, source);
        expect(binding.selection!.subtitleStreamIndex, index);
      }
    });

    test('null accepts an existing server default and retains its metadata',
        () {
      const source = MediaSourceInfo(
        id: 'source-a',
        defaultSubtitleStreamIndex: 47,
        mediaStreams: [_simplified, _traditional],
      );
      final binding = resolvePlaybackMediaSource(
        [source],
        requestedMediaSourceId: source.id,
        subtitleStreamIndex: null,
      );

      expect(binding.isAvailable, isTrue);
      expect(binding.issue, isNull);
      expect(binding.selection!.subtitleStreamIndex, isNull);
      expect(binding.selection!.source.defaultSubtitleStreamIndex, 47);
      final defaultSubtitle =
          binding.selection!.source.mediaStreams!.singleWhere(
        (stream) => stream.index == 47,
      );
      expect(defaultSubtitle.language, 'zh-Hant');
      expect(defaultSubtitle.title, '繁體中文');
    });

    test('null cannot fall back from a missing server default to Simplified',
        () {
      const source = MediaSourceInfo(
        id: 'source-a',
        defaultSubtitleStreamIndex: 47,
        mediaStreams: [
          MediaStream(
            type: MediaStreamType.subtitle,
            index: 2,
            language: 'zh-Hans',
            displayTitle: 'Chinese Simplified',
          ),
        ],
      );
      final binding = resolvePlaybackMediaSource(
        [source],
        requestedMediaSourceId: source.id,
        subtitleStreamIndex: null,
      );

      expect(binding.isAvailable, isFalse);
      expect(binding.selection, isNull);
      expect(binding.issue, PlaybackSourceBindingIssue.missingSubtitle);
    });

    test('null rejects an ambiguous server default subtitle', () {
      const source = MediaSourceInfo(
        id: 'source-a',
        defaultSubtitleStreamIndex: 47,
        mediaStreams: [_traditional, _traditional],
      );
      final binding = resolvePlaybackMediaSource(
        [source],
        requestedMediaSourceId: source.id,
        subtitleStreamIndex: null,
      );

      expect(binding.isAvailable, isFalse);
      expect(binding.selection, isNull);
      expect(binding.issue, PlaybackSourceBindingIssue.ambiguousSubtitle);
    });

    test('explicit Off remains Off despite an invalid server default', () {
      for (final streams in [
        [_simplified],
        [_traditional, _traditional],
      ]) {
        final source = MediaSourceInfo(
          id: 'source-a',
          defaultSubtitleStreamIndex: 47,
          mediaStreams: streams,
        );
        final binding = resolvePlaybackMediaSource(
          [source],
          requestedMediaSourceId: source.id,
          subtitleStreamIndex: -1,
        );

        expect(binding.isAvailable, isTrue);
        expect(binding.issue, isNull);
        expect(binding.selection!.subtitleStreamIndex, -1);
      }
    });

    test('server subtitle index zero is a valid explicit selection', () {
      const source = MediaSourceInfo(
        id: 'source-a',
        mediaStreams: [
          MediaStream(type: MediaStreamType.subtitle, index: 0),
        ],
      );
      final binding = resolvePlaybackMediaSource(
        [source],
        requestedMediaSourceId: source.id,
        subtitleStreamIndex: 0,
      );

      expect(binding.isAvailable, isTrue);
      expect(binding.issue, isNull);
      expect(binding.selection!.subtitleStreamIndex, 0);
    });

    test('a missing selected subtitle cannot fall back to another subtitle',
        () {
      const source = MediaSourceInfo(
        id: 'source-a',
        mediaStreams: [_simplified],
      );
      final binding = resolvePlaybackMediaSource(
        [source],
        requestedMediaSourceId: source.id,
        subtitleStreamIndex: 47,
      );

      expect(binding.selection, isNull);
      expect(binding.issue, PlaybackSourceBindingIssue.missingSubtitle);
    });

    test('a selected subtitle is unavailable when stream metadata is absent',
        () {
      for (final streams in <List<MediaStream>?>[null, []]) {
        final binding = resolvePlaybackMediaSource(
          [MediaSourceInfo(id: 'source-a', mediaStreams: streams)],
          requestedMediaSourceId: 'source-a',
          subtitleStreamIndex: 47,
        );

        expect(binding.selection, isNull);
        expect(binding.issue, PlaybackSourceBindingIssue.missingSubtitle);
      }
    });

    test('duplicate selected subtitle indexes are rejected', () {
      const source = MediaSourceInfo(
        id: 'source-a',
        mediaStreams: [_traditional, _traditional],
      );
      final binding = resolvePlaybackMediaSource(
        [source],
        requestedMediaSourceId: source.id,
        subtitleStreamIndex: 47,
      );

      expect(binding.selection, isNull);
      expect(binding.issue, PlaybackSourceBindingIssue.ambiguousSubtitle);
    });

    test(
        'a non-subtitle stream with the selected index cannot satisfy selection',
        () {
      const source = MediaSourceInfo(
        id: 'source-a',
        mediaStreams: [MediaStream(type: MediaStreamType.audio, index: 47)],
      );
      final binding = resolvePlaybackMediaSource(
        [source],
        requestedMediaSourceId: source.id,
        subtitleStreamIndex: 47,
      );

      expect(binding.selection, isNull);
      expect(binding.issue, PlaybackSourceBindingIssue.missingSubtitle);
    });

    test('a non-subtitle index collision does not make a subtitle ambiguous',
        () {
      const source = MediaSourceInfo(
        id: 'source-a',
        mediaStreams: [
          MediaStream(type: MediaStreamType.audio, index: 47),
          _traditional,
        ],
      );
      final binding = resolvePlaybackMediaSource(
        [source],
        requestedMediaSourceId: source.id,
        subtitleStreamIndex: 47,
      );

      expect(binding.isAvailable, isTrue);
      expect(binding.issue, isNull);
      expect(binding.selection!.subtitleStreamIndex, 47);
    });

    test('only -1 represents an explicit Off selection', () {
      final binding = resolvePlaybackMediaSource(
        [const MediaSourceInfo(id: 'source-a')],
        requestedMediaSourceId: 'source-a',
        subtitleStreamIndex: -2,
      );

      expect(binding.selection, isNull);
      expect(binding.issue, PlaybackSourceBindingIssue.missingSubtitle);
    });

    test('Chinese language aliases and scripts do not replace explicit indexes',
        () {
      for (final language in ['zh', 'zho', 'chi', 'zh-Hant', 'zh-Hans']) {
        final selected = MediaStream(
          type: MediaStreamType.subtitle,
          index: 47,
          language: language,
          codec: 'srt',
          title: '繁體中文',
          displayTitle: 'Chinese',
        );
        final source = MediaSourceInfo(
          id: 'source-a',
          mediaStreams: [
            MediaStream(
              type: MediaStreamType.subtitle,
              index: 7,
              language: language,
              codec: 'srt',
              title: '简体中文',
              displayTitle: 'Chinese',
            ),
            selected,
          ],
        );
        final binding = resolvePlaybackMediaSource(
          [source],
          requestedMediaSourceId: source.id,
          subtitleStreamIndex: 47,
        );

        expect(binding.selection!.source, source);
        expect(binding.selection!.subtitleStreamIndex, 47);
        final returnedSubtitle = binding.selection!.source.mediaStreams!.last;
        expect(returnedSubtitle, selected);
        expect(returnedSubtitle.language, language);
        expect(returnedSubtitle.title, '繁體中文');
      }
    });
  });
}
