import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fladder/screens/video_player/components/centered_video_viewport.dart';

void main() {
  testWidgets(
      'centers before first frame and after rotation with either cutout',
      (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    for (final size in [
      const Size(1280, 591),
      const Size(591, 1280),
      const Size(1280, 591)
    ]) {
      tester.view.physicalSize = size;
      for (final padding in [
        const EdgeInsets.only(left: 52),
        const EdgeInsets.only(right: 52),
        EdgeInsets.zero
      ]) {
        for (final fill in [false, true]) {
          await tester.pumpWidget(Directionality(
            textDirection: TextDirection.ltr,
            child: MediaQuery(
              data: MediaQueryData(size: size, padding: padding),
              child: CenteredVideoViewport(
                fillScreen: fill,
                child: const SizedBox.expand(key: Key('video')),
              ),
            ),
          ));
          final rect = tester.getRect(find.byKey(const Key('video')));
          expect(rect.center, Offset(size.width / 2, size.height / 2));
          expect(rect.width,
              size.width - (fill ? 0 : 2 * (padding.left + padding.right)));
          expect(tester.takeException(), isNull);
        }
      }
    }
  });
}
