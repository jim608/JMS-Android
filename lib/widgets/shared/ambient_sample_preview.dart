import 'package:flutter/material.dart';
import 'package:fladder/widgets/shared/ambient_blur.dart';

class AmbientPreviewPainter extends CustomPainter {
  final AmbientSamplePreview sample;
  AmbientPreviewPainter(this.sample);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xff303030));
    final fitted = applyBoxFit(BoxFit.contain, sample.crop.size, size);
    canvas.drawImageRect(sample.image, sample.crop, Alignment.center.inscribe(fitted.destination, Offset.zero & size),
        Paint()..filterQuality = FilterQuality.low);
  }

  @override
  bool shouldRepaint(covariant AmbientPreviewPainter oldDelegate) => oldDelegate.sample != sample;
}
