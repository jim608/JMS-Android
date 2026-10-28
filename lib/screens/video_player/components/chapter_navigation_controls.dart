import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/models/items/chapters_model.dart';
import 'package:fladder/providers/settings/video_player_settings_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/providers/segment_skip_provider.dart';
import 'package:fladder/providers/syncplay_provider.dart';
import 'package:fladder/util/localization_helper.dart';

/// Chapter navigation stays separate from the previous/next episode transport.
class ChapterNavigationControls extends ConsumerWidget {
  const ChapterNavigationControls({this.controllerMode = false, super.key});

  final bool controllerMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chapters = ref.watch(playBackModel.select((value) => value?.chapters ?? <Chapter>[]));
    final playback = ref.watch(mediaPlaybackProvider);
    final navigation = chapters.navigationAt(playback.position, duration: playback.duration);
    final sync = ref.watch(syncPlayProvider);
    final player = ref.watch(videoPlayerProvider);
    final canSeek = segmentSkipCanSeek(sync.room,
        wrapperActive: player.syncPlayActive,
        busy: sync.busy || sync.preparingPlayback || sync.recoveryActive || sync.leavePending);
    return ChapterNavigationButtons(
      navigation: navigation,
      controllerMode: controllerMode,
      enabled: canSeek,
      onPrevious: ref.read(videoPlayerSettingsProvider.notifier).prevChapter,
      onNext: ref.read(videoPlayerSettingsProvider.notifier).nextChapter,
    );
  }
}

/// Presentation accepts callbacks so accessibility and layout need no renderer.
class ChapterNavigationButtons extends StatelessWidget {
  const ChapterNavigationButtons({
    required this.navigation,
    required this.onPrevious,
    required this.onNext,
    this.controllerMode = false,
    this.enabled = true,
    super.key,
  });

  final ChapterNavigation navigation;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final bool controllerMode;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (navigation.chapters.isEmpty) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 4,
          children: [
            TextButton.icon(
              key: const ValueKey('previous-chapter'),
              onPressed: enabled && navigation.previous != null ? onPrevious : null,
              icon: const Icon(Icons.first_page_rounded),
              label: Text(context.localized.prevChapter),
            ),
            TextButton.icon(
              key: const ValueKey('next-chapter'),
              onPressed: enabled && navigation.next != null ? onNext : null,
              icon: const Icon(Icons.last_page_rounded),
              label: Text(context.localized.nextChapter),
            ),
          ],
        ),
        if (controllerMode)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: Text(
              context.localized.chapterControllerHint,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
      ],
    );
  }
}
