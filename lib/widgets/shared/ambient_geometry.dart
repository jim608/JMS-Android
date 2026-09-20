import 'package:flutter/rendering.dart';

Rect? ambientVideoRect(RenderRepaintBoundary boundary) {
  Rect? largest;
  void visit(RenderObject object) {
    if (object is TextureBox && object.hasSize && object.size.shortestSide > 1) {
      final bounds = MatrixUtils.transformRect(object.getTransformTo(boundary), Offset.zero & object.size)
          .intersect(Offset.zero & boundary.size);
      if (!bounds.isEmpty && (largest == null || bounds.width * bounds.height > largest!.width * largest!.height)) {
        largest = bounds;
      }
    } else {
      object.visitChildren(visit);
    }
  }

  boundary.visitChildren(visit);
  return largest;
}

Rect ambientExtent(Rect video, Size viewport, double spread) => Rect.fromLTRB(
      video.left * (1 - spread),
      video.top * (1 - spread),
      video.right + (viewport.width - video.right) * spread,
      video.bottom + (viewport.height - video.bottom) * spread,
    );
