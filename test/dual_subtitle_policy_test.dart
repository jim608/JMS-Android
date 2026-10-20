import 'package:fladder/models/items/media_streams_model.dart';
import 'package:fladder/util/dual_subtitle.dart';
import 'package:flutter_test/flutter_test.dart';

SubStreamModel _subtitle({
  int index = 1,
  String codec = 'srt',
  String language = 'eng',
  String id = 'track',
}) =>
    SubStreamModel(
      name: 'Test subtitle',
      id: id,
      title: 'Test subtitle',
      displayTitle: 'Test subtitle',
      language: language,
      codec: codec,
      isDefault: false,
      isExternal: false,
      index: index,
    );

void main() {
  group('secondary subtitle eligibility', () {
    test('plain text codec aliases ignore case and surrounding whitespace', () {
      for (final codec in ['srt', 'subrip', 'webvtt', 'vtt', 'text']) {
        expect(isPlainTextSubtitle(codec), isTrue, reason: codec);
        expect(isPlainTextSubtitle('  $codec\n'.toUpperCase()), isTrue,
            reason: codec);
      }
    });

    test('styled, bitmap, missing, and unknown formats are not flattened', () {
      for (final codec in [
        'ass',
        'SSA',
        'hdmv_pgs_subtitle',
        'dvd_subtitle',
        'dvb_subtitle',
        '',
        'unknown'
      ]) {
        expect(isPlainTextSubtitle(codec), isFalse, reason: codec);
      }
    });

    test('turning secondary subtitles off is always available', () {
      expect(
        secondarySubtitleIssue(
          supportedBackend: false,
          primary: null,
          candidate: SubStreamModel.no(),
        ),
        isNull,
      );
    });

    test('requires an available backend and an enabled primary track', () {
      final primary = _subtitle();
      final secondary = _subtitle(index: 7);
      expect(
        secondarySubtitleIssue(
            supportedBackend: false, primary: primary, candidate: secondary),
        SecondarySubtitleIssue.unsupportedBackend,
      );
      for (final primary in <SubStreamModel?>[null, SubStreamModel.no()]) {
        expect(
          secondarySubtitleIssue(
              supportedBackend: true, primary: primary, candidate: secondary),
          SecondarySubtitleIssue.primaryOff,
        );
      }
    });

    test('protects primary ASS effects and bitmap rendering', () {
      for (final codec in [
        'ass',
        'ssa',
        'hdmv_pgs_subtitle',
        'dvd_subtitle',
        ''
      ]) {
        expect(
          secondarySubtitleIssue(
            supportedBackend: true,
            primary: _subtitle(codec: codec),
            candidate: _subtitle(index: 7),
          ),
          SecondarySubtitleIssue.primaryFormat,
          reason: codec,
        );
      }
    });

    test('rejects secondary formats that cannot use the text overlay', () {
      for (final codec in [
        'ass',
        'ssa',
        'hdmv_pgs_subtitle',
        'dvd_subtitle',
        ''
      ]) {
        expect(
          secondarySubtitleIssue(
            supportedBackend: true,
            primary: _subtitle(),
            candidate: _subtitle(index: 7, codec: codec),
          ),
          SecondarySubtitleIssue.secondaryFormat,
          reason: codec,
        );
      }
    });

    test('same track is identified by stream index even when model ids differ',
        () {
      expect(
        secondarySubtitleIssue(
          supportedBackend: true,
          primary: _subtitle(index: 4, id: 'original'),
          candidate: _subtitle(index: 4, id: 'reconstructed'),
        ),
        SecondarySubtitleIssue.sameTrack,
      );
    });

    test('different tracks in the same language remain selectable', () {
      expect(
        secondarySubtitleIssue(
          supportedBackend: true,
          primary: _subtitle(index: 4, language: 'eng'),
          candidate: _subtitle(index: 9, language: 'eng', codec: ' WEBVTT '),
        ),
        isNull,
      );
    });
  });

  group('subtitle stream slots', () {
    test('trims cue boundaries while preserving line breaks and input slots',
        () {
      final slots = [
        '  Primary first\nPrimary second  ',
        '\n Secondary first\nSecondary second \n',
        'ignored'
      ];
      final original = List<String>.of(slots);
      final pair = SubtitleTextPair.fromSlots(slots, secondaryEnabled: true);
      expect(pair.primary, 'Primary first\nPrimary second');
      expect(pair.secondary, 'Secondary first\nSecondary second');
      expect(slots, original);
    });

    test('a secondary-only cue never moves into the primary slot', () {
      final pair = SubtitleTextPair.fromSlots([' \n ', 'Secondary only'],
          secondaryEnabled: true);
      expect(pair.primary, isEmpty);
      expect(pair.secondary, 'Secondary only');
    });

    test('missing or empty secondary cues leave the primary slot unchanged',
        () {
      for (final slots in [
        ['Primary only'],
        ['Primary only', ' \n '],
      ]) {
        final pair = SubtitleTextPair.fromSlots(slots, secondaryEnabled: true);
        expect(pair.primary, 'Primary only');
        expect(pair.secondary, isEmpty);
      }
      final empty = SubtitleTextPair.fromSlots([], secondaryEnabled: true);
      expect(empty.primary, isEmpty);
      expect(empty.secondary, isEmpty);
    });

    test(
        'disabling secondary suppresses its stale cue without affecting primary',
        () {
      final pair = SubtitleTextPair.fromSlots(['Primary', 'Stale secondary'],
          secondaryEnabled: false);
      expect(pair.primary, 'Primary');
      expect(pair.secondary, isEmpty);
    });
  });
}
