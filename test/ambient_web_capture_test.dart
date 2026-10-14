import 'dart:async';
import 'dart:ui' as ui;

import 'package:fladder/widgets/shared/ambient_blur.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// The DOM video is black in Flutter's scene. Its actual frame is supplied
// separately, just as a browser video element lives outside the Flutter canvas.
class _DomVideo extends LeafRenderObjectWidget {
  const _DomVideo();

  @override
  PlatformViewRenderBox createRenderObject(BuildContext context) =>
      _DomVideoRenderBox();
}

class _DomVideoController extends PlatformViewController {
  @override
  int get viewId => 42;

  @override
  Future<void> dispatchPointerEvent(PointerEvent event) async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<void> clearFocus() async {}
}

class _DomVideoRenderBox extends PlatformViewRenderBox {
  _DomVideoRenderBox()
      : super(
          controller: _DomVideoController(),
          hitTestBehavior: PlatformViewHitTestBehavior.opaque,
          gestureRecognizers: const {},
        );

  @override
  void paint(PaintingContext context, Offset offset) {
    context.canvas.drawRect(offset & size, Paint()..color = Colors.black);
  }
}

void _portraitSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _scene(
  GlobalKey sceneKey,
  AmbientBlurDiagnostics diagnostics,
  Future<ui.Image?> Function(double) captureFrame, {
  Object? frameSource,
  bool playing = true,
  bool ticking = true,
  bool synchronized = false,
  Duration duration = const Duration(seconds: 4),
  double maxCaptureDimension = 192,
}) =>
    Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: const MediaQueryData(size: Size(400, 800)),
        child: TickerMode(
          enabled: ticking,
          child: RepaintBoundary(
            key: sceneKey,
            child: ColoredBox(
              color: Colors.black,
              child: AmbientBlur(
                diagnostics: diagnostics,
                captureFrame: captureFrame,
                frameSource: frameSource,
                playing: playing,
                synchronizeToPlayback: synchronized,
                duration: duration,
                maxCaptureDimension: maxCaptureDimension,
                child: const Center(
                  child: SizedBox(
                    width: 400,
                    height: 225,
                    child: _DomVideo(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

Future<ui.Image> _frame(WidgetTester tester, Color color) async =>
    (await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
          const Rect.fromLTWH(0, 0, 144, 81), Paint()..color = color);
      final picture = recorder.endRecording();
      try {
        return await picture.toImage(144, 81);
      } finally {
        picture.dispose();
      }
    }))!;

Future<void> _waitFor(
    WidgetTester tester, bool Function() done, String description) async {
  for (var attempt = 0; attempt < 20 && !done(); attempt++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }
  await tester.pump();
  expect(done(), isTrue, reason: description);
}

Future<List<int>> _pixel(
        WidgetTester tester, GlobalKey key, int x, int y) async =>
    (await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      try {
        final bytes =
            await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        final offset = (y * image.width + x) * 4;
        return List.generate(4, (channel) => bytes!.getUint8(offset + channel));
      } finally {
        image.dispose();
      }
    }))!;

Future<void> _disposeScene(
    WidgetTester tester, AmbientBlurDiagnostics diagnostics) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  expect(diagnostics.inFlight, isFalse);
  expect(diagnostics.allocated, diagnostics.released);
  expect(tester.takeException(), isNull);
}

void main() {
  testWidgets(
      'external video frame colors the letterbox while platform video remains protected',
      (tester) async {
    _portraitSurface(tester);
    final diagnostics = AmbientBlurDiagnostics();
    final key = GlobalKey();
    final image = await _frame(tester, const Color(0xffff6428));
    final requestedDimensions = <double>[];
    Future<ui.Image?> capture(double dimension) async {
      requestedDimensions.add(dimension);
      return image;
    }

    await tester.pumpWidget(
        _scene(key, diagnostics, capture, maxCaptureDimension: 144));
    await _waitFor(
        tester, () => diagnostics.captures == 1, 'first actual frame');
    expect(requestedDimensions, [144]);
    expect(diagnostics.size, '144 × 81',
        reason:
            'The returned video frame must not be cropped as a viewport screenshot.');
    expect(diagnostics.videoRect, const Rect.fromLTWH(0, 287.5, 400, 225));
    expect(diagnostics.viewport, const Size(400, 800));
    final glow = await _pixel(tester, key, 200, 160);
    expect(glow[0], greaterThan(60),
        reason:
            'The Flutter boundary is black; only the external frame has color.');
    expect(glow[0], greaterThan(glow[1] * 1.5));
    expect(await _pixel(tester, key, 200, 400), [0, 0, 0, 255],
        reason: 'Ambient composition must leave the platform video untouched.');
    expect(image.debugDisposed, isTrue);
    await _disposeScene(tester, diagnostics);
  });

  for (final failure in ['no frame', 'capture error']) {
    testWidgets('$failure clears stale light and retries on the next interval',
        (tester) async {
      _portraitSurface(tester);
      final diagnostics = AmbientBlurDiagnostics();
      final key = GlobalKey();
      final first = await _frame(tester, const Color(0xffff6428));
      final retry = await _frame(tester, Colors.blue);
      var requests = 0;
      Future<ui.Image?> capture(double _) async {
        requests++;
        if (requests == 1) return first;
        if (requests == 2) {
          if (failure == 'capture error') throw StateError('video unavailable');
          return null;
        }
        return retry;
      }

      await tester.pumpWidget(_scene(key, diagnostics, capture,
          duration: const Duration(milliseconds: 100)));
      await _waitFor(tester, () => diagnostics.captures == 1, 'first frame');
      expect((await _pixel(tester, key, 200, 160))[0], greaterThan(60));
      await tester.pump(const Duration(milliseconds: 101));
      await _waitFor(tester, () => requests == 2 && !diagnostics.inFlight,
          'unavailable external frame');
      expect(diagnostics.captures, 1);
      expect(diagnostics.retainedBytes, 0);
      expect(await _pixel(tester, key, 200, 160), [0, 0, 0, 255]);
      await tester.pump(const Duration(milliseconds: 101));
      await _waitFor(
          tester, () => diagnostics.captures == 2, 'recovered frame');
      expect((await _pixel(tester, key, 200, 160))[2], greaterThan(60));
      expect(first.debugDisposed, isTrue);
      expect(retry.debugDisposed, isTrue);
      await _disposeScene(tester, diagnostics);
    });
  }

  testWidgets('presentation ticks never overlap an external frame request',
      (tester) async {
    _portraitSurface(tester);
    final diagnostics = AmbientBlurDiagnostics();
    final key = GlobalKey();
    final pending = Completer<ui.Image?>();
    final image = await _frame(tester, Colors.blue);
    var requests = 0;
    Future<ui.Image?> capture(double _) {
      requests++;
      return pending.future;
    }

    await tester.pumpWidget(_scene(key, diagnostics, capture,
        synchronized: true, duration: const Duration(milliseconds: 1)));
    await tester.pump();
    for (var tick = 0; tick < 5; tick++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(requests, 1);
    expect(diagnostics.captures, 0);
    expect(diagnostics.inFlight, isTrue);
    await tester.pumpWidget(_scene(key, diagnostics, capture,
        ticking: false,
        synchronized: true,
        duration: const Duration(milliseconds: 1)));
    pending.complete(image);
    await _waitFor(tester, () => diagnostics.captures == 1, 'pending frame');
    expect(requests, 1);
    expect(image.debugDisposed, isTrue);
    await _disposeScene(tester, diagnostics);
  });

  testWidgets('source change rejects and disposes the old asynchronous frame',
      (tester) async {
    _portraitSurface(tester);
    final diagnostics = AmbientBlurDiagnostics();
    final key = GlobalKey();
    final oldSource = Object();
    final newSource = Object();
    final oldFrame = await _frame(tester, const Color(0xffff6428));
    final newFrame = await _frame(tester, const Color(0xff0000ff));
    final pending = Completer<ui.Image?>();
    var requests = 0;
    Future<ui.Image?> capture(double _) {
      requests++;
      return requests == 1 ? pending.future : Future.value(newFrame);
    }

    await tester
        .pumpWidget(_scene(key, diagnostics, capture, frameSource: oldSource));
    expect(diagnostics.inFlight, isTrue);
    await tester
        .pumpWidget(_scene(key, diagnostics, capture, frameSource: newSource));
    expect(requests, 1);
    pending.complete(oldFrame);
    await _waitFor(tester, () => diagnostics.captures == 1, 'new source frame');
    expect(requests, 2);
    expect(oldFrame.debugDisposed, isTrue);
    final glow = await _pixel(tester, key, 200, 160);
    expect(glow[2], greaterThan(60));
    expect(glow[0], lessThan(10),
        reason: 'Old-source orange must not reappear.');
    await _disposeScene(tester, diagnostics);
  });

  for (final cancellation in ['paused', 'background', 'disposed']) {
    testWidgets(
        '$cancellation releases an external frame completed after cancellation',
        (tester) async {
      _portraitSurface(tester);
      final diagnostics = AmbientBlurDiagnostics();
      final key = GlobalKey();
      final source = Object();
      final image = await _frame(tester, Colors.blue);
      final pending = Completer<ui.Image?>();
      var requests = 0;
      Future<ui.Image?> capture(double _) {
        requests++;
        return pending.future;
      }

      await tester
          .pumpWidget(_scene(key, diagnostics, capture, frameSource: source));
      expect(diagnostics.inFlight, isTrue);
      if (cancellation == 'paused') {
        await tester.pumpWidget(_scene(key, diagnostics, capture,
            frameSource: source, playing: false));
      } else if (cancellation == 'background') {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
      } else {
        await tester.pumpWidget(const SizedBox.shrink());
      }
      pending.complete(image);
      await _waitFor(
          tester, () => !diagnostics.inFlight, 'cancelled frame cleanup');
      await tester.pump(const Duration(seconds: 30));
      expect(requests, 1);
      expect(diagnostics.captures, 0);
      expect(diagnostics.retainedBytes, 0);
      expect(image.debugDisposed, isTrue);
      await _disposeScene(tester, diagnostics);
      if (cancellation == 'background') {
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pump();
      }
    });
  }
}
