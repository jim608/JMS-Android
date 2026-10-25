import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:fladder/models/settings/subtitle_settings_model.dart';

/// Independent bottom-anchored slots keep asynchronous cue changes from moving
/// the other language. Each slot scales down only its own unusually long cue.
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
          final scale = math.sqrt(
              ((constraints.maxWidth * constraints.maxHeight) / (1920 * 1080))
                  .clamp(0.0, 1.0));
          final fontSize = settings.fontSize * scale;
          final secondaryFontSize = fontSize * 0.60;
          final bottom = constraints.maxHeight * bottomOffset.clamp(0.0, 0.85);
          final textScaler = MediaQuery.textScalerOf(context);
          final lineHeight = settings.style.height ?? 1.4;
          final primaryHeight = textScaler.scale(fontSize) * lineHeight * 3;
          final secondaryHeight =
              textScaler.scale(secondaryFontSize) * lineHeight * 2;
          final gap = textScaler.scale(fontSize) * 0.12;
          final desiredHeight = primaryHeight + secondaryHeight + gap;
          if (desiredHeight <= 0 || constraints.maxWidth <= 0) {
            return const SizedBox.shrink();
          }
          final slotScale = math.min(1.0,
              math.max(0.0, constraints.maxHeight - bottom) / desiredHeight);
          Widget cue(String text, double size, Key key) => Container(
                decoration: BoxDecoration(
                    color: settings.backGroundColor,
                    borderRadius: BorderRadius.circular(4)),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Text(text,
                        style:
                            settings.copyWith(fontSize: size).backGroundStyle,
                        textAlign: TextAlign.center),
                    Text(text,
                        key: key,
                        style: settings.style.copyWith(fontSize: size),
                        textAlign: TextAlign.center),
                  ],
                ),
              );
          Widget slot(String text, double size, double height, Key key) =>
              SizedBox(
                height: height * slotScale,
                width: constraints.maxWidth,
                child: text.isEmpty
                    ? null
                    : FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.bottomCenter,
                        child: SizedBox(
                          width: constraints.maxWidth,
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: cue(text, size, key),
                          ),
                        ),
                      ),
              );
          return Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.only(bottom: bottom),
              child: SizedBox(
                width: constraints.maxWidth,
                child: Column(
                  key: const Key('dual-subtitle-slots'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    slot(primary, fontSize, primaryHeight,
                        const Key('primary-subtitle')),
                    SizedBox(height: gap * slotScale),
                    slot(secondary, secondaryFontSize, secondaryHeight,
                        const Key('secondary-subtitle')),
                  ],
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}
