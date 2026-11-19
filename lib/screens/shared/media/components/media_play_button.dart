import 'package:material_ui/material_ui.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_plus/iconsax_plus.dart';

import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/items/movie_model.dart';
import 'package:fladder/providers/settings/home_settings_provider.dart';
import 'package:fladder/screens/shared/animated_fade_size.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/focus_provider.dart';
import 'package:fladder/util/position_provider.dart';
import 'package:fladder/widgets/shared/ensure_visible.dart';
import 'package:fladder/util/localization_helper.dart';

class MediaPlayButton extends ConsumerWidget {
  final ItemBaseModel? item;
  final bool forceFocusOutline;
  final bool showRestartOption;
  final bool autofocusOnDpad;
  final Function(bool restart)? onPressed;
  final Function(bool restart)? onLongPressed;

  const MediaPlayButton({
    required this.item,
    this.forceFocusOutline = false,
    this.showRestartOption = true,
    this.autofocusOnDpad = true,
    this.onPressed,
    this.onLongPressed,
    super.key,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = (item?.progress ?? 0) / 100.0;
    final showRestart = progress != 0 && showRestartOption;
    final classic = ref.watch(classicInterfaceProvider);
    final smallRadius = const Radius.circular(4);
    final theme = Theme.of(context);
    final strings = context.localized;
    final movie = item is MovieModel && !classic ? item : null;
    final label = movie == null ? item?.playButtonLabel(strings) ?? '' : (progress > 0 ? strings.resumeVideo : strings.playLabel);

    Widget buttonTitle(Color contentColor) {
      final icon = Icon(IconsaxPlusBold.play, color: contentColor);
      return Container(
        constraints: classic ? null : const BoxConstraints(minHeight: 48),
        padding: classic ? const EdgeInsets.all(10) : const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          spacing: classic ? 4 : 8,
          children: [
            if (!classic) icon,
            Flexible(
              child: Text(
                label,
                semanticsLabel: movie == null ? null : (progress > 0 ? strings.resume(movie.name) : strings.play(movie.name)),
                maxLines: 1,
                overflow: TextOverflow.fade,
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700, color: contentColor),
              ),
            ),
            if (classic) icon,
          ],
        ),
      );
    }

    return AnimatedFadeSize(
      duration: const Duration(milliseconds: 250),
      child: onPressed == null
          ? const SizedBox.shrink(key: ValueKey('empty'))
          : Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              spacing: 4,
              children: [
                Flexible(
                  child: PositionProvider(
                    position: PositionContext.first,
                    child: _PlayButton(
                      onPressed: onPressed,
                      onLongPressed: onLongPressed,
                      autoFocus: autofocusOnDpad && AdaptiveLayout.inputDeviceOf(context) == InputDevice.dPad,
                      forceFocusOutline: forceFocusOutline,
                      progress: progress,
                      buttonTitle: buttonTitle,
                      theme: theme,
                      classic: classic,
                      smallRadius: smallRadius,
                      showRestart: showRestart,
                    ),
                  ),
                ),
                if (showRestart)
                  PositionProvider(
                    position: PositionContext.last,
                    child: _RestartButton(
                      onPressed: onPressed,
                      onLongPressed: onLongPressed,
                      forceFocusOutline: forceFocusOutline,
                      theme: theme,
                      classic: classic,
                      smallRadius: smallRadius,
                    ),
                  ),
              ],
            ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  final Function(bool restart)? onPressed;
  final Function(bool restart)? onLongPressed;
  final bool autoFocus;
  final bool forceFocusOutline;
  final double progress;
  final Widget Function(Color) buttonTitle;
  final ThemeData theme;
  final bool classic;
  final Radius smallRadius;
  final bool showRestart;

  const _PlayButton({
    required this.onPressed,
    required this.onLongPressed,
    required this.autoFocus,
    required this.forceFocusOutline,
    required this.progress,
    required this.buttonTitle,
    required this.theme,
    required this.classic,
    required this.smallRadius,
    required this.showRestart,
  });

  @override
  Widget build(BuildContext context) {
    final position = PositionProvider.of(context);
    final borderRadius = BorderRadiusDirectional.horizontal(
      start: position == PositionContext.first ? const Radius.circular(16) : smallRadius,
      end: showRestart || position == PositionContext.last ? smallRadius : const Radius.circular(16),
    ).resolve(classic ? TextDirection.ltr : Directionality.of(context));

    return FocusButton(
      onTap: () => onPressed?.call(false),
      onLongPress: () => onLongPressed?.call(false),
      autoFocus: autoFocus,
      borderRadius: borderRadius,
      forceFocusOutline: forceFocusOutline,
      darkOverlay: false,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Progress background
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: classic ? theme.colorScheme.primaryContainer : theme.colorScheme.primary,
                borderRadius: borderRadius,
              ),
            ),
          ),
          // Button content
          buttonTitle(classic ? theme.colorScheme.onPrimaryContainer : theme.colorScheme.onPrimary),
          if (!classic && progress > 0)
            Positioned(
              bottom: 3,
              left: 12,
              right: 12,
              child: ExcludeSemantics(
                child: LinearProgressIndicator(
                  value: progress.clamp(0, 1),
                  minHeight: 2,
                  color: theme.colorScheme.onPrimary,
                  backgroundColor: theme.colorScheme.onPrimary.withValues(alpha: 0.25),
                ),
              ),
            ),
          if (classic)
            Positioned.fill(
              child: ClipRect(
                clipper: _ProgressClipper(progress),
                child: DecoratedBox(
                  decoration: BoxDecoration(color: theme.colorScheme.primary, borderRadius: borderRadius),
                  child: buttonTitle(theme.colorScheme.onPrimary),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _RestartButton extends StatelessWidget {
  final Function(bool restart)? onPressed;
  final Function(bool restart)? onLongPressed;
  final bool forceFocusOutline;
  final ThemeData theme;
  final bool classic;
  final Radius smallRadius;

  const _RestartButton({
    required this.onPressed,
    required this.onLongPressed,
    required this.forceFocusOutline,
    required this.theme,
    required this.classic,
    required this.smallRadius,
  });

  @override
  Widget build(BuildContext context) {
    final position = PositionProvider.of(context);
    final borderRadius = BorderRadiusDirectional.horizontal(
      start: position == PositionContext.first ? const Radius.circular(16) : smallRadius,
      end: position == PositionContext.last ? const Radius.circular(16) : smallRadius,
    ).resolve(classic ? TextDirection.ltr : Directionality.of(context));

    return FocusButton(
      onTap: () => onPressed?.call(true),
      onLongPress: () => onLongPressed?.call(true),
      borderRadius: borderRadius,
      forceFocusOutline: forceFocusOutline,
      onFocusChanged: (value) {
        if (value) {
          context.ensureVisible(alignment: 1.0);
        }
      },
      child: Container(
        constraints: classic ? null : const BoxConstraints(minHeight: 48, minWidth: 48),
        decoration: BoxDecoration(color: theme.colorScheme.primaryContainer, borderRadius: borderRadius),
        child: Padding(
          padding: const EdgeInsets.all(7.5),
          child: Icon(
            IconsaxPlusBold.refresh,
            size: 29,
            color: theme.colorScheme.onPrimaryContainer,
            semanticLabel: context.localized.restart,
          ),
        ),
      ),
    );
  }
}

class _ProgressClipper extends CustomClipper<Rect> {
  final double progress;
  _ProgressClipper(this.progress);

  @override
  Rect getClip(Size size) {
    final w = (progress.clamp(0.0, 1.0) * size.width);
    return Rect.fromLTWH(0, 0, w, size.height);
  }

  @override
  bool shouldReclip(covariant _ProgressClipper old) => old.progress != progress;
}
