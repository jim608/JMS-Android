import 'package:fladder/models/items/media_streams_model.dart';

bool isPlainTextSubtitle(String codec) =>
    const {'srt', 'subrip', 'webvtt', 'vtt', 'text'}.contains(codec.trim().toLowerCase());

enum SecondarySubtitleIssue {
  unsupportedBackend,
  primaryOff,
  primaryFormat,
  secondaryFormat,
  sameTrack,
  unavailable,
  selectionFailed,
  mediaChanged,
}

class SecondarySubtitleState {
  final SubStreamModel? selected;
  final SecondarySubtitleIssue? issue;
  const SecondarySubtitleState({this.selected, this.issue});
}

SecondarySubtitleIssue? secondarySubtitleIssue({
  required bool supportedBackend,
  required SubStreamModel? primary,
  required SubStreamModel candidate,
}) {
  if (candidate.index < 0) return null;
  if (!supportedBackend) return SecondarySubtitleIssue.unsupportedBackend;
  if (primary == null || primary.index < 0) return SecondarySubtitleIssue.primaryOff;
  if (!isPlainTextSubtitle(primary.codec)) return SecondarySubtitleIssue.primaryFormat;
  if (!isPlainTextSubtitle(candidate.codec)) return SecondarySubtitleIssue.secondaryFormat;
  if (candidate.index == primary.index) return SecondarySubtitleIssue.sameTrack;
  return null;
}

class SubtitleTextPair {
  final String primary;
  final String secondary;
  const SubtitleTextPair({this.primary = '', this.secondary = ''});

  factory SubtitleTextPair.fromSlots(List<String> slots, {required bool secondaryEnabled}) => SubtitleTextPair(
        primary: slots.isEmpty ? '' : slots[0].trim(),
        secondary: secondaryEnabled && slots.length > 1 ? slots[1].trim() : '',
      );
}

// media_kit's observed SubtitleTrack.uri is false for both container and added
// external tracks. Read mpv's explicit external flag before positional mapping.
Future<List<String>> internalMpvSubtitleIds(Future<String> Function(String) read) async {
  final count = (int.tryParse(await read('track-list/count')) ?? 0).clamp(0, 128);
  final ids = <String>[];
  for (var index = 0; index < count; index++) {
    if (await read('track-list/$index/type') != 'sub') continue;
    final external = await read('track-list/$index/external');
    if (!const {'no', 'false', '0'}.contains(external)) continue;
    final id = await read('track-list/$index/id');
    if (id.isNotEmpty && id != 'no' && id != 'auto') ids.add(id);
  }
  return ids;
}

/// mpv re-sends identical cue text across seeks, but media_kit's distinct
/// subtitle stream can suppress it. Refresh on seek completion without polling.
class SubtitleSeekRefresh {
  int _generation = 0;
  bool _pending = false;

  void begin() {
    _generation++;
    _pending = true;
  }

  void cancel() {
    _generation++;
    _pending = false;
  }

  Future<void> onSeekingChanged(
    String value,
    Future<SubtitleTextPair> Function() read,
    void Function(SubtitleTextPair) apply,
  ) async {
    if (value != 'no' || !_pending) return;
    final generation = _generation;
    _pending = false;
    final text = await read();
    if (generation == _generation) apply(text);
  }
}
