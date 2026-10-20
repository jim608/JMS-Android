import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/util/localization_helper.dart';
import 'package:fladder/util/subtitle_offset.dart';

final subtitleOffsetVisibleProvider =
    StateProvider.autoDispose<bool>((ref) => false);

class SubtitleOffsetButton extends ConsumerWidget {
  const SubtitleOffsetButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(videoPlayerProvider).subtitleOffsets;
    if (controller == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: controller,
      builder: (context, child) => IconButton(
        key: const Key('subtitle-offset-open'),
        tooltip: context.localized.jmsSubtitleOffsetTitle,
        icon: const Icon(Icons.sync_alt_rounded),
        onPressed: controller.primaryAvailable
            ? () =>
                ref.read(subtitleOffsetVisibleProvider.notifier).state = true
            : null,
      ),
    );
  }
}

class SubtitleOffsetTile extends ConsumerWidget {
  const SubtitleOffsetTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(videoPlayerProvider).subtitleOffsets;
    if (controller == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: controller,
      builder: (context, child) => ListTile(
        leading: const Icon(Icons.sync_alt_rounded),
        title: Text(context.localized.jmsSubtitleOffsetTitle),
        subtitle: Text(controller.primaryAvailable
            ? context.localized
                .jmsSubtitleOffsetValue(_signedMilliseconds(controller.primary))
            : context.localized.jmsSubtitleOffsetInactive),
        onTap: controller.primaryAvailable
            ? () {
                ref.read(subtitleOffsetVisibleProvider.notifier).state = true;
                Navigator.pop(context);
              }
            : null,
      ),
    );
  }
}

/// Kept inside the player's input/overlay tree so playback and its controls stay
/// mounted while timing is adjusted. No route change or pause/resume is needed.
class SubtitleOffsetOverlay extends ConsumerWidget {
  const SubtitleOffsetOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(subtitleOffsetVisibleProvider)) {
      return const SizedBox.shrink();
    }
    final controller = ref.watch(videoPlayerProvider).subtitleOffsets;
    if (controller == null) return const SizedBox.shrink();
    void close() =>
        ref.read(subtitleOffsetVisibleProvider.notifier).state = false;
    return Focus(
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          close();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            key: const Key('subtitle-offset-dismiss'),
            behavior: HitTestBehavior.opaque,
            onTap: close,
            child: const SizedBox.expand(),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child:
                    SubtitleOffsetPanel(controller: controller, onClose: close),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SubtitleOffsetPanel extends StatelessWidget {
  const SubtitleOffsetPanel(
      {required this.controller, required this.onClose, super.key});

  final SubtitleOffsetController controller;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(
          maxWidth: 360, maxHeight: MediaQuery.sizeOf(context).height * 0.7),
      child: Material(
        key: const Key('subtitle-offset-panel'),
        color: Theme.of(context)
            .colorScheme
            .surfaceContainer
            .withValues(alpha: 0.94),
        elevation: 6,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                      child: Text(context.localized.jmsSubtitleOffsetTitle,
                          style: Theme.of(context).textTheme.titleMedium)),
                  IconButton(
                    key: const Key('subtitle-offset-close'),
                    tooltip: context.localized.close,
                    onPressed: onClose,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Flexible(
                child: SingleChildScrollView(
                  child: ListenableBuilder(
                    listenable: controller,
                    builder: (context, child) => SubtitleOffsetControls(
                      controller: controller,
                      primaryEnabled: controller.primaryAvailable,
                      secondaryEnabled: controller.secondaryAvailable,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Playback controls kept separate from player/provider lookup for accessibility
/// and interaction tests.
class SubtitleOffsetControls extends StatelessWidget {
  const SubtitleOffsetControls({
    required this.controller,
    required this.secondaryEnabled,
    this.primaryEnabled = true,
    super.key,
  });

  final SubtitleOffsetController controller;
  final bool primaryEnabled;
  final bool secondaryEnabled;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, child) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.localized.jmsSubtitleOffsetHelp),
          const SizedBox(height: 16),
          _offsetRow(context, secondary: false),
          if (secondaryEnabled) ...[
            const SizedBox(height: 20),
            _offsetRow(context, secondary: true),
          ],
          if (!primaryEnabled) ...[
            const SizedBox(height: 12),
            Text(context.localized.jmsSubtitleOffsetInactive),
          ],
          if (controller.busy) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],
          if (controller.failed) ...[
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Text(
                context.localized.jmsSubtitleOffsetFailed,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _offsetRow(BuildContext context, {required bool secondary}) {
    final value = secondary ? controller.secondary : controller.primary;
    final enabled =
        (secondary ? secondaryEnabled : primaryEnabled) && !controller.busy;
    final prefix = secondary ? 'secondary' : 'primary';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          secondary
              ? context.localized.jmsSecondarySubtitle
              : context.localized.jmsSubtitleOffsetPrimary,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        Semantics(
          liveRegion: true,
          child: Text(
            context.localized
                .jmsSubtitleOffsetValue(_signedMilliseconds(value)),
            key: Key('subtitle-offset-$prefix-value'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
              key: Key('subtitle-offset-$prefix-earlier'),
              onPressed: enabled && value > -SubtitleOffsetController.limit
                  ? () => controller.setOffset(
                      value - SubtitleOffsetController.step,
                      secondary: secondary)
                  : null,
              child: Text(context.localized.jmsSubtitleOffsetEarlier),
            ),
            OutlinedButton(
              key: Key('subtitle-offset-$prefix-later'),
              onPressed: enabled && value < SubtitleOffsetController.limit
                  ? () => controller.setOffset(
                      value + SubtitleOffsetController.step,
                      secondary: secondary)
                  : null,
              child: Text(context.localized.jmsSubtitleOffsetLater),
            ),
            TextButton(
              key: Key('subtitle-offset-$prefix-reset'),
              onPressed: enabled && value != Duration.zero
                  ? () =>
                      controller.setOffset(Duration.zero, secondary: secondary)
                  : null,
              child: Text(context.localized.jmsSubtitleOffsetReset),
            ),
          ],
        ),
      ],
    );
  }
}

String _signedMilliseconds(Duration value) =>
    '${value.isNegative || value == Duration.zero ? '' : '+'}${value.inMilliseconds}';
