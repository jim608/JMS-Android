import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fladder/screens/video_player/components/centered_video_viewport.dart';

void main() {
  testWidgets(
      'movie uses full viewport before first frame and after rotation with either cutout',
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
        for (final aspect in [2.4, 16 / 9, 4 / 3]) {
          await tester.pumpWidget(Directionality(
            textDirection: TextDirection.ltr,
            child: MediaQuery(
              // Layout constraints win over stale metrics during rotation.
              data:
                  MediaQueryData(size: const Size(591, 1280), padding: padding),
              child: CenteredVideoViewport(
                child: AspectRatio(
                    aspectRatio: aspect,
                    child: const SizedBox(key: Key('video'))),
              ),
            ),
          ));
          final rect = tester.getRect(find.byKey(const Key('video')));
          final fitted =
              applyBoxFit(BoxFit.contain, Size(aspect, 1), size).destination;
          expect(rect.width, closeTo(fitted.width, 0.001));
          expect(rect.height, closeTo(fitted.height, 0.001));
          expect(rect.center.dx, closeTo(size.width / 2, 0.001));
          expect(rect.center.dy, closeTo(size.height / 2, 0.001));
          expect(rect.width / rect.height, closeTo(aspect, 0.001));
          if (aspect == 2.4) {
            expect(rect.left, 0);
            expect(rect.right, size.width);
          }
          expect(tester.takeException(), isNull);
        }
      }
    }
  });

  testWidgets('video fills parent while sibling controls retain safe padding',
      (tester) async {
    await tester.pumpWidget(const Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: MediaQueryData(padding: EdgeInsets.only(right: 52)),
        child: Center(
            child: SizedBox(
                width: 640,
                height: 300,
                child: Stack(children: [
                  CenteredVideoViewport(
                      child: SizedBox.expand(key: Key('video'))),
                  SafeArea(child: SizedBox.expand(key: Key('controls'))),
                ]))),
      ),
    ));
    final video = tester.getRect(find.byKey(const Key('video')));
    final controls = tester.getRect(find.byKey(const Key('controls')));
    expect(video.size, const Size(640, 300));
    expect(controls.right, video.right - 52);
    expect(controls.left, video.left);
  });
}
