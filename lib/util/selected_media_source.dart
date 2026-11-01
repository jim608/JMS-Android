import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';

enum PlaybackSourceBindingIssue {
  missingSources,
  missingSourceId,
  missingRequestedSource,
  ambiguousSourceId,
  ambiguousSources,
  missingSubtitle,
  ambiguousSubtitle,
}

class SelectedPlaybackMediaSource {
  final MediaSourceInfo source;
  final int responseIndex;
  final int? subtitleStreamIndex;

  const SelectedPlaybackMediaSource({
    required this.source,
    required this.responseIndex,
    required this.subtitleStreamIndex,
  });

  String subtitleKey(int streamIndex) =>
      playbackSubtitleKey(source.id!, streamIndex);
}

class PlaybackSourceBinding {
  final SelectedPlaybackMediaSource? selection;
  final PlaybackSourceBindingIssue? issue;

  const PlaybackSourceBinding.available(SelectedPlaybackMediaSource selected)
      : selection = selected,
        issue = null;

  const PlaybackSourceBinding.unavailable(PlaybackSourceBindingIssue failure)
      : selection = null,
        issue = failure;

  bool get isAvailable => selection != null;
}

// The source ID and server stream Index identify a track across response order
// changes. A DTO's hashCode and a player's local track ID have other meanings.
String playbackSubtitleKey(String mediaSourceId, int streamIndex) =>
    '${Uri.encodeComponent(mediaSourceId)}:$streamIndex';

PlaybackSourceBinding resolvePlaybackMediaSource(
  List<MediaSourceInfo>? sources, {
  required String? requestedMediaSourceId,
  required int? subtitleStreamIndex,
}) {
  if (sources == null || sources.isEmpty) {
    return const PlaybackSourceBinding.unavailable(
        PlaybackSourceBindingIssue.missingSources);
  }

  int responseIndex;
  if (requestedMediaSourceId != null) {
    if (requestedMediaSourceId.trim().isEmpty) {
      return const PlaybackSourceBinding.unavailable(
          PlaybackSourceBindingIssue.missingSourceId);
    }
    final matches = <int>[
      for (var i = 0; i < sources.length; i++)
        if (sources[i].id == requestedMediaSourceId) i,
    ];
    if (matches.isEmpty) {
      return const PlaybackSourceBinding.unavailable(
          PlaybackSourceBindingIssue.missingRequestedSource);
    }
    if (matches.length != 1) {
      return const PlaybackSourceBinding.unavailable(
          PlaybackSourceBindingIssue.ambiguousSourceId);
    }
    responseIndex = matches.single;
  } else {
    // Initial Live TV has no preplay source model. Only an unambiguous response
    // may establish its source; a list position is not an identity fallback.
    if (sources.length != 1) {
      return const PlaybackSourceBinding.unavailable(
          PlaybackSourceBindingIssue.ambiguousSources);
    }
    responseIndex = 0;
  }

  final source = sources[responseIndex];
  if (source.id == null || source.id!.trim().isEmpty) {
    return const PlaybackSourceBinding.unavailable(
        PlaybackSourceBindingIssue.missingSourceId);
  }
  // null delegates the initial default to this resolved server source, which
  // still needs validation. -1 is explicit Off and overrides that default.
  final effectiveSubtitleIndex =
      subtitleStreamIndex ?? source.defaultSubtitleStreamIndex;
  if (effectiveSubtitleIndex != null && effectiveSubtitleIndex != -1) {
    final matches = source.mediaStreams?.where((stream) =>
            stream.type == MediaStreamType.subtitle &&
            stream.index == effectiveSubtitleIndex) ??
        const <MediaStream>[];
    if (effectiveSubtitleIndex < -1 || matches.isEmpty) {
      return const PlaybackSourceBinding.unavailable(
          PlaybackSourceBindingIssue.missingSubtitle);
    }
    if (matches.length != 1) {
      return const PlaybackSourceBinding.unavailable(
          PlaybackSourceBindingIssue.ambiguousSubtitle);
    }
  }
  return PlaybackSourceBinding.available(SelectedPlaybackMediaSource(
    source: source,
    responseIndex: responseIndex,
    subtitleStreamIndex: subtitleStreamIndex,
  ));
}
