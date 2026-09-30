import 'package:flutter/material.dart';

/// Re-evaluates the usable viewport on every layout, including rotation.
/// Video uses the whole viewport; only the separate controls need safe insets.
class CenteredVideoViewport extends StatelessWidget {
  const CenteredVideoViewport({super.key, required this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      return SizedBox(
        width: constraints.maxWidth,
        height: constraints.maxHeight,
        child: Center(child: child),
      );
    });
  }
}
