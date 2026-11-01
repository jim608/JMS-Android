import 'package:fladder/models/items/media_streams_model.dart';
import 'package:fladder/models/playback/playback_model.dart';
import 'package:fladder/util/subtitle_selection_failure.dart';
import 'package:fladder/wrappers/media_control_wrapper.dart';

/// A completed track operation must not publish into a different item/player.
/// Unsupported room operations preserve the existing model and stream session.
Future<PlaybackModel?> trySelectLocalSubtitle({
  required PlaybackModel model,
  required SubStreamModel? track,
  required MediaControlsWrapper player,
  required bool Function() isCurrent,
  required void Function(SubtitleSelectionFailure) onUnavailable,
}) async {
  if (!isCurrent()) return null;
  try {
    final selected = await model.setSubtitle(track, player);
    return isCurrent() ? selected : null;
  } on SubtitleSelectionFailure catch (failure) {
    if (isCurrent()) onUnavailable(failure);
    return null;
  }
}
