import 'package:flutter/material.dart';

import 'package:async/async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/models/items/media_streams_model.dart';
import 'package:fladder/models/playback/playback_model.dart';
import 'package:fladder/models/settings/video_player_settings.dart';
import 'package:fladder/providers/settings/video_player_settings_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/util/input_handler.dart';
import 'package:fladder/util/localization_helper.dart';
import 'package:fladder/util/local_subtitle_selection.dart';

class VideoPlayerScreenshotIndicator extends ConsumerStatefulWidget {
  const VideoPlayerScreenshotIndicator({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => VideoPlayerScreenshotIndicatorState();
}

class VideoPlayerScreenshotIndicatorState extends ConsumerState<VideoPlayerScreenshotIndicator> {
  RestartableTimer? timer;

  bool visible = false;
  bool screenshotTaken = false;
  bool isCleanScreenshot = false;

  void onTimerEnd() {
    setState(() {
      visible = false;
    });

    timer?.cancel();
    timer = null;
  }

  void onTakeScreenshot(bool cleanScreenshot) async {
    bool result;

    if (cleanScreenshot) {
      final playbackModel = ref.read(playBackModel);
      final player = ref.read(videoPlayerProvider);
      if (playbackModel == null) return;
      final selectedSubs = playbackModel.mediaStreams?.currentSubStream;
      final selectedSecondary = player.secondarySubtitleState.value.selected;
      bool current(PlaybackModel expected) => mounted && identical(ref.read(playBackModel), expected) &&
          identical(ref.read(videoPlayerProvider), player);
      void unavailable(Object _) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(context.localized.jmsSecondaryUnavailable)));
      if (!playbackModel.serverManagedQueue) {
        // Generic VOD reload may legitimately replace the model/player. Keep
        // its existing reload/restore path separate from room identity guards.
        final noSubsModel = await trySelectLocalSubtitle(
            model: playbackModel, track: SubStreamModel.no(), player: player,
            isCurrent: () => mounted, onUnavailable: unavailable);
        if (noSubsModel == null) return;
        ref.read(playBackModel.notifier).update((state) => noSubsModel);
        await ref.read(playbackModelHelper).shouldReload(noSubsModel);
        if (!mounted) return;
        result = await ref.read(videoPlayerProvider.notifier).takeScreenshot();
        final restoredModel = await trySelectLocalSubtitle(
            model: playbackModel, track: selectedSubs, player: player,
            isCurrent: () => mounted, onUnavailable: unavailable);
        if (restoredModel != null) {
          ref.read(playBackModel.notifier).update((state) => restoredModel);
          await ref.read(playbackModelHelper).shouldReload(restoredModel);
          if (mounted && selectedSecondary != null) {
            await player.setSecondarySubtitleTrack(selectedSecondary, restoredModel);
          }
        }
      } else {
      final noSubsModel = await trySelectLocalSubtitle(
          model: playbackModel, track: SubStreamModel.no(), player: player,
          isCurrent: () => current(playbackModel), onUnavailable: unavailable);
      if (noSubsModel == null) return;
      ref.read(playBackModel.notifier).update((state) => noSubsModel);
      try {
        await ref.read(playbackModelHelper).shouldReload(noSubsModel);
        if (!current(noSubsModel)) return;
        result = await ref.read(videoPlayerProvider.notifier).takeScreenshot();
      } finally {
        if (current(noSubsModel)) {
          final restoredModel = await trySelectLocalSubtitle(
              model: noSubsModel, track: selectedSubs, player: player,
              isCurrent: () => current(noSubsModel), onUnavailable: unavailable);
          if (restoredModel != null) {
            ref.read(playBackModel.notifier).update((state) => restoredModel);
            await ref.read(playbackModelHelper).shouldReload(restoredModel);
            if (current(restoredModel) && selectedSecondary != null) {
              await player.setSecondarySubtitleTrack(selectedSecondary, restoredModel);
            }
          }
        }
      }
      }
    } else {
      result = await ref.read(videoPlayerProvider.notifier).takeScreenshot();
    }

    if (!mounted) return;
    if (timer == null) {
      timer = RestartableTimer(const Duration(milliseconds: 500), () => onTimerEnd());
    } else {
      timer?.reset();
    }

    setState(() {
      visible = true;
      screenshotTaken = result;
      isCleanScreenshot = cleanScreenshot;
    });
  }

  @override
  Widget build(BuildContext context) {
    return InputHandler<VideoHotKeys>(
      autoFocus: false,
      listenRawKeyboard: true,
      keyMap: ref.watch(videoPlayerSettingsProvider.select((value) => value.currentShortcuts)),
      keyMapResult: (result) => _onKey(result),
      child: IgnorePointer(
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 500),
          opacity: visible ? 1 : 0,
          child: Center(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 8.0,
                  children: [
                    const Icon(Icons.image),
                    Text(
                      screenshotTaken
                          ? isCleanScreenshot
                              ? context.localized.screenshotCleanTaken
                              : context.localized.screenshotTaken
                          : context.localized.errorTakingScreenshot,
                      style: Theme.of(context).textTheme.bodyMedium,
                    )
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void takeScreenshot() {
    onTakeScreenshot(false);
  }

  void takeScreenshotClean() {
    onTakeScreenshot(true);
  }

  bool _onKey(VideoHotKeys value) {
    switch (value) {
      case VideoHotKeys.takeScreenshot:
        takeScreenshot();
        return true;
      case VideoHotKeys.takeScreenshotClean:
        takeScreenshotClean();
        return true;
      default:
        return false;
    }
  }
}
