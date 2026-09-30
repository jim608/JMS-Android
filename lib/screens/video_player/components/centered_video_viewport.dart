import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Re-evaluates the usable viewport on every layout, including rotation.
/// Symmetric insets keep the video centered on the display with a side cutout.
class CenteredVideoViewport extends StatelessWidget {
  const CenteredVideoViewport(
      {super.key, required this.child, required this.fillScreen});

  final Widget? child;
  final bool fillScreen;

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    return LayoutBuilder(builder: (context, constraints) {
      final inset = fillScreen
          ? 0.0
          : math.min(
              math.max(padding.left, padding.right), constraints.maxWidth / 2);
      return SizedBox(
        width: constraints.maxWidth,
        height: constraints.maxHeight,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: inset),
          child: Center(child: child),
        ),
      );
    });
  }
}
