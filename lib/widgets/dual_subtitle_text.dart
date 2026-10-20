import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:fladder/models/settings/subtitle_settings_model.dart';

/// Both cue blocks share one layout, so wrapping never makes them overlap.
class DualSubtitleText extends StatelessWidget {
  final String primaryText;
  final String secondaryText;
  final SubtitleSettingsModel settings;
  final EdgeInsets padding;
  final double bottomOffset;
  const DualSubtitleText({
    required this.primaryText,
    required this.secondaryText,
    required this.settings,
    this.padding = EdgeInsets.zero,
    this.bottomOffset = 0.1,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final primary = primaryText.trim();
    final secondary = secondaryText.trim();
    if (primary.isEmpty && secondary.isEmpty) return const SizedBox.shrink();
    return IgnorePointer(
      child: Padding(
        padding: padding.add(const EdgeInsets.all(16)),
        child: LayoutBuilder(builder: (context, constraints) {
          final scale = math.sqrt(((constraints.maxWidth * constraints.maxHeight) / (1920 * 1080)).clamp(0.0, 1.0));
          final fontSize = settings.fontSize * scale;
          final bottom = constraints.maxHeight * bottomOffset.clamp(0.0, 0.85);
          Widget cue(String text, double size, Key key) => Container(
                decoration: BoxDecoration(color: settings.backGroundColor, borderRadius: BorderRadius.circular(4)),
                child: Stack(children: [
                  Text(text, style: settings.backGroundStyle.copyWith(fontSize: size), textAlign: TextAlign.center),
                  Text(text, key: key, style: settings.style.copyWith(fontSize: size), textAlign: TextAlign.center),
                ]),
              );
          return Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.only(bottom: bottom),
              child: SizedBox(
                width: constraints.maxWidth,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.bottomCenter,
                  child: SizedBox(
                    width: constraints.maxWidth,
                    child: Column(
                      key: const Key('dual-subtitle-column'),
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (primary.isNotEmpty) cue(primary, fontSize, const Key('primary-subtitle')),
                        if (primary.isNotEmpty && secondary.isNotEmpty) SizedBox(height: fontSize * 0.12),
                        if (secondary.isNotEmpty) cue(secondary, fontSize * 0.75, const Key('secondary-subtitle')),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}
