import 'dart:io';
import 'dart:ui' as ui;

import 'package:fladder/widgets/shared/ambient_blur.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

class SyntheticVideoTexture extends LeafRenderObjectWidget {
  final Color color;
  final Color? secondColor;
  const SyntheticVideoTexture({super.key, required this.color, this.secondColor});

  @override
  TextureBox createRenderObject(BuildContext context) => SyntheticTextureBox(color, secondColor);

  @override
  void updateRenderObject(BuildContext context, covariant SyntheticTextureBox renderObject) {
    renderObject.color = color;
    renderObject.secondColor = secondColor;
    renderObject.markNeedsPaint();
  }
}

class SyntheticTextureBox extends TextureBox {
  Color color;
  Color? secondColor;
  SyntheticTextureBox(this.color, this.secondColor) : super(textureId: 42);

  @override
  void paint(PaintingContext context, Offset offset) {
    context.canvas.drawRect(offset & size, Paint()..color = color);
    if (secondColor != null) {
      context.canvas.drawRect(Rect.fromLTWH(offset.dx + size.width / 2, offset.dy, size.width / 2, size.height),
          Paint()..color = secondColor!);
    }
  }
}

void portraitSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget scene(GlobalKey key, AmbientBlurDiagnostics diagnostics,
        {Color color = const Color(0xffff6428),
        Color? secondColor,
        bool enabled = true,
        bool fullScreen = false,
        double intensity = 0.8,
        double spread = 0.9,
        AmbientComposition composition = AmbientComposition.direct,
        Widget? video}) =>
    Directionality(
      textDirection: TextDirection.ltr,
      child: RepaintBoundary(
          key: key,
          child: ColoredBox(
              color: Colors.black,
              child: AmbientBlur(
                diagnostics: diagnostics,
                enabled: enabled,
                opacity: intensity,
                spread: spread,
                composition: composition,
                child: Center(
                    child: SizedBox(
                        width: 400,
                        height: fullScreen ? 800 : 225,
                        child: video ?? SyntheticVideoTexture(color: color, secondColor: secondColor))),
              ))),
    );

Future<void> waitForCapture(WidgetTester tester, AmbientBlurDiagnostics diagnostics, int count) async {
  for (var attempt = 0; attempt < 20 && diagnostics.captures < count; attempt++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }
  await tester.pump();
  expect(diagnostics.captures, count,
      reason: 'failures ${diagnostics.failures}; allocated ${diagnostics.allocated}; inFlight ${diagnostics.inFlight}');
}

Future<List<int>> readPixel(WidgetTester tester, GlobalKey key, String name, int horizontal, int vertical) async {
  return (await tester.runAsync(() async {
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    try {
      const directory = String.fromEnvironment('JMS_AMBIENT_EVIDENCE');
      if (directory.isNotEmpty) {
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('$directory/$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(png!.buffer.asUint8List());
      }
      final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final offset = (vertical * image.width + horizontal) * 4;
      return List.generate(4, (channel) => rgba!.getUint8(offset + channel));
    } finally {
      image.dispose();
    }
  }))!;
}

void main() {
  testWidgets('bright video illuminates available letterbox without changing the main image', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final diagnostics = AmbientBlurDiagnostics();
    final sceneKey = GlobalKey();
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: RepaintBoundary(
          key: sceneKey,
          child: ColoredBox(
            color: Colors.black,
            child: AmbientBlur(
              diagnostics: diagnostics,
              child: const Center(
                  child: SizedBox(
                width: 400,
                height: 225,
                child: SyntheticVideoTexture(color: Color(0xffff6428)),
              )),
            ),
          )),
    ));
    await waitForCapture(tester, diagnostics, 1);
    final glow = await readPixel(tester, sceneKey, 'bright-default', 200, 160);
    final main = await readPixel(tester, sceneKey, 'bright-main', 200, 400);
    expect(main.take(3), [255, 100, 40]);
    expect(glow[0], greaterThan(60), reason: 'Bright red video must visibly reach the unused background');
    expect(glow[0], greaterThan(glow[1] * 1.5));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(diagnostics.allocated, diagnostics.released);
  });

  testWidgets('off, .3 baseline, default and stronger settings keep the same capture budget', (tester) async {
    portraitSurface(tester);
    final measurements = <String, List<int>>{};
    for (final mode in ['off', 'previous', 'default', 'strong']) {
      final key = GlobalKey();
      final diagnostics = AmbientBlurDiagnostics();
      await tester.pumpWidget(scene(key, diagnostics,
          enabled: mode != 'off',
          intensity: mode == 'strong' ? 1 : 0.8,
          composition: mode == 'previous' ? AmbientComposition.previous : AmbientComposition.direct));
      if (mode != 'off') await waitForCapture(tester, diagnostics, 1);
      measurements[mode] = await readPixel(tester, key, 'compare-$mode', 200, 160);
      expect(await readPixel(tester, key, 'main-$mode', 200, 400), [255, 100, 40, 255]);
      expect(diagnostics.allocated, mode == 'off' ? 0 : 2);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(diagnostics.allocated, diagnostics.released);
    }
    expect(measurements['off']!.take(3), [0, 0, 0]);
    expect(measurements['previous']![0], lessThan(10));
    expect(measurements['default']![0], greaterThan(60));
    expect(measurements['strong']![0], greaterThan(measurements['default']![0]));
    const directory = String.fromEnvironment('JMS_AMBIENT_EVIDENCE');
    if (directory.isNotEmpty) {
      await tester.runAsync(() => File('$directory/comparison-rgba.txt').writeAsString('$measurements'));
    }
  });

  testWidgets('strength and spread preview reuse images, leave source pixels unchanged, and do not recapture',
      (tester) async {
    portraitSurface(tester);
    final key = GlobalKey();
    final diagnostics = AmbientBlurDiagnostics();
    await tester.pumpWidget(scene(key, diagnostics));
    await waitForCapture(tester, diagnostics, 1);
    final defaultGlow = await readPixel(tester, key, 'reuse-default', 200, 160);
    await tester.pumpWidget(scene(key, diagnostics, intensity: 1));
    final stronger = await readPixel(tester, key, 'reuse-strong', 200, 160);
    await tester.pumpWidget(scene(key, diagnostics, intensity: 1, spread: 0.2));
    final narrow = await readPixel(tester, key, 'reuse-narrow', 200, 160);
    expect(stronger[0], greaterThan(defaultGlow[0]));
    expect(narrow.take(3), [0, 0, 0]);
    expect(diagnostics.captures, 1);
    expect(diagnostics.allocated, 2);
    expect(await readPixel(tester, key, 'reuse-main', 200, 400), [255, 100, 40, 255]);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(diagnostics.allocated, diagnostics.released);
  });

  testWidgets('black scenes stay black; preview distinguishes transparent capture from a dark scene', (tester) async {
    portraitSurface(tester);
    for (final color in [Colors.black, Colors.transparent]) {
      final key = GlobalKey();
      final diagnostics = AmbientBlurDiagnostics()..enabled = true;
      await tester.pumpWidget(scene(key, diagnostics, color: color, intensity: 1));
      await waitForCapture(tester, diagnostics, 1);
      for (var attempt = 0; attempt < 20 && diagnostics.preview.value == null; attempt++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      expect(diagnostics.preview.value, isNotNull);
      final previewImage = diagnostics.preview.value!.image;
      final name = color == Colors.black ? 'dark' : 'transparent';
      expect(await readPixel(tester, key, name, 200, 160), [0, 0, 0, 255]);
      expect(diagnostics.sampleStatus, color == Colors.black ? contains('dark / black') : contains('transparent'));
      expect(diagnostics.source, 'visible video texture');
      diagnostics.enabled = false;
      await tester.pump();
      expect(previewImage.debugDisposed, isTrue);
      expect(diagnostics.preview.value, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  testWidgets('full-frame video has no halo space and is never resized or tinted', (tester) async {
    portraitSurface(tester);
    final key = GlobalKey();
    final diagnostics = AmbientBlurDiagnostics();
    await tester.pumpWidget(scene(key, diagnostics, fullScreen: true, intensity: 1));
    await waitForCapture(tester, diagnostics, 1);
    expect(diagnostics.backgroundFraction, 0);
    expect(await readPixel(tester, key, 'full-frame', 200, 160), [255, 100, 40, 255]);
    expect(diagnostics.videoRect, const Rect.fromLTWH(0, 0, 400, 800));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('dim colored scenes stay naturally dim without a brightness floor', (tester) async {
    portraitSurface(tester);
    final key = GlobalKey();
    final diagnostics = AmbientBlurDiagnostics();
    await tester.pumpWidget(scene(key, diagnostics, color: const Color(0xff100408)));
    await waitForCapture(tester, diagnostics, 1);
    final glow = await readPixel(tester, key, 'dim-color', 200, 160);
    expect(glow[0], inInclusiveRange(1, 9));
    expect(glow[0], greaterThan(glow[1]));
    expect(await readPixel(tester, key, 'dim-main', 200, 400), [16, 4, 8, 255]);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(diagnostics.allocated, diagnostics.released);
  });

  testWidgets('spatial colors remain distinct instead of averaging to gray', (tester) async {
    portraitSurface(tester);
    final key = GlobalKey();
    final diagnostics = AmbientBlurDiagnostics();
    await tester.pumpWidget(scene(key, diagnostics, color: Colors.red, secondColor: Colors.cyan));
    await waitForCapture(tester, diagnostics, 1);
    final left = await readPixel(tester, key, 'spatial-colors', 60, 160);
    final right = await readPixel(tester, key, 'spatial-colors', 340, 160);
    expect(left[0], greaterThan(left[1]));
    expect(right[1], greaterThan(right[0]));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('a changing video produces a smooth dynamic halo with no extra sampling', (tester) async {
    portraitSurface(tester);
    final key = GlobalKey();
    final diagnostics = AmbientBlurDiagnostics();
    final color = ValueNotifier(const Color(0xffff6428));
    final video = ValueListenableBuilder<Color>(
        valueListenable: color, builder: (context, value, child) => SyntheticVideoTexture(color: value));
    await tester.pumpWidget(scene(key, diagnostics, video: video));
    await waitForCapture(tester, diagnostics, 1);
    color.value = const Color(0xff2864ff);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 4001));
    expect(diagnostics.failures, 0);
    await waitForCapture(tester, diagnostics, 2);
    final frames = <List<int>>[];
    for (var frame = 0; frame < 16; frame++) {
      if (frame > 0) await tester.pump(const Duration(milliseconds: 250));
      frames.add(await readPixel(tester, key, 'transition-${frame.toString().padLeft(2, '0')}', 200, 160));
    }
    expect(frames.first[0], greaterThan(frames[8][0]));
    expect(frames[8][0], greaterThan(frames.last[0]));
    expect(frames.first[2], lessThan(frames[8][2]));
    expect(frames[8][2], lessThan(frames.last[2]));
    expect(frames[8][0], greaterThan(15));
    expect(frames[8][2], greaterThan(15));
    expect(diagnostics.captures, 2);
    expect(diagnostics.allocated, 4);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(diagnostics.allocated, diagnostics.released);
    color.dispose();
  });
}
