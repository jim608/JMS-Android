import 'dart:async';

import 'package:fladder/widgets/shared/ambient_blur.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> waitForCapture(WidgetTester tester, AmbientBlurDiagnostics diagnostics, int count) async {
    for (var attempt = 0; attempt < 10 && diagnostics.captures < count; attempt++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    expect(diagnostics.captures, count);
    await tester.pump();
  }

  test('ambient cadence remains bounded even for invalid widget intervals', () {
    const child = SizedBox();
    expect(const AmbientBlur(child: child).effectiveDuration, const Duration(seconds: 4));
    expect(const AmbientBlur(duration: Duration.zero, child: child).effectiveDuration, const Duration(seconds: 4));
    expect(const AmbientBlur(duration: Duration(seconds: 90), child: child).effectiveDuration,
        const Duration(seconds: 60));
    expect(
        const AmbientBlur(duration: Duration(seconds: 10), synchronizeToPlayback: true, child: child).effectiveDuration,
        const Duration(seconds: 10));
    expect(const AmbientBlur(duration: Duration(milliseconds: 1), child: child).effectiveDuration,
        const Duration(milliseconds: 1));
  });

  testWidgets('changing a fixed interval restarts cadence without rebuilding video content', (tester) async {
    final diagnostics = AmbientBlurDiagnostics();
    var videoBuilds = 0;
    final child = Builder(builder: (context) {
      videoBuilds++;
      return const SizedBox.expand(child: ColoredBox(color: Colors.blue));
    });
    Widget scene(Duration duration) =>
        MaterialApp(home: AmbientBlur(diagnostics: diagnostics, duration: duration, child: child));
    await tester.pumpWidget(scene(const Duration(seconds: 4)));
    await waitForCapture(tester, diagnostics, 1);
    final builds = videoBuilds;
    await tester.pump(const Duration(seconds: 1));
    expect(diagnostics.captures, 1);
    await tester.pumpWidget(scene(const Duration(milliseconds: 750)));
    await tester.pump(const Duration(milliseconds: 749));
    expect(diagnostics.captures, 1);
    await tester.pump(const Duration(milliseconds: 2));
    await waitForCapture(tester, diagnostics, 2);
    expect(videoBuilds, builds);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(diagnostics.allocated, diagnostics.released);
    expect(tester.takeException(), isNull);
  });

  testWidgets('presentation synchronization exceeds 2Hz and invalidates old mode and source callbacks', (tester) async {
    final diagnostics = AmbientBlurDiagnostics();
    final first = Object();
    final second = Object();
    Widget scene(Object source, {bool playing = true, bool synchronized = true, bool enabled = true}) => MaterialApp(
            home: AmbientBlur(
          diagnostics: diagnostics,
          synchronizeToPlayback: synchronized,
          frameSource: source,
          duration: const Duration(milliseconds: 100),
          playing: playing,
          enabled: enabled,
          child: const SizedBox.expand(child: ColoredBox(color: Colors.green)),
        ));
    await tester.pumpWidget(scene(first));
    await waitForCapture(tester, diagnostics, 1);
    await tester.pump(const Duration(milliseconds: 99));
    expect(diagnostics.captures, 1);
    await tester.pump(const Duration(milliseconds: 1));
    await waitForCapture(tester, diagnostics, 2);
    await tester.pump(const Duration(milliseconds: 100));
    await waitForCapture(tester, diagnostics, 3);
    await tester.pump(const Duration(milliseconds: 100));
    await waitForCapture(tester, diagnostics, 4);
    // Four actual captures over 300 ms of Vsync time, with no position stream.
    // The old ticker queues a post-frame callback before this source change builds.
    await tester.pumpWidget(scene(second), duration: const Duration(milliseconds: 100));
    expect(diagnostics.captures, 4);
    await tester.pump(const Duration(milliseconds: 16));
    await waitForCapture(tester, diagnostics, 5);
    await tester.pumpWidget(scene(second, synchronized: false), duration: const Duration(milliseconds: 100));
    await waitForCapture(tester, diagnostics, 6); // Only the new fixed-mode callback is valid.
    await tester.pumpWidget(scene(second, playing: false));
    await tester.pump(const Duration(seconds: 30));
    expect(diagnostics.captures, 6);
    expect(diagnostics.running, isFalse);
    await tester.pumpWidget(scene(second));
    await waitForCapture(tester, diagnostics, 7);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    await tester.pump(const Duration(seconds: 30));
    expect(diagnostics.captures, 7);
    expect(diagnostics.running, isFalse);
    expect(diagnostics.retainedBytes, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await waitForCapture(tester, diagnostics, 8);
    await tester.pumpWidget(scene(second, enabled: false));
    await tester.pump(const Duration(seconds: 30));
    expect(diagnostics.captures, 8);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(diagnostics.allocated, diagnostics.released);
    expect(tester.takeException(), isNull);
  });

  testWidgets('millisecond synchronization never overlaps an in-flight image capture', (tester) async {
    final diagnostics = AmbientBlurDiagnostics();
    final gate = Completer<void>();
    var attempts = 0;
    diagnostics.beforeCapture = () {
      attempts++;
      return gate.future;
    };
    Widget scene(bool ticking, {bool playing = true}) => MaterialApp(
        home: TickerMode(
            enabled: ticking,
            child: AmbientBlur(
              duration: const Duration(milliseconds: 1),
              synchronizeToPlayback: true,
              playing: playing,
              diagnostics: diagnostics,
              child: const SizedBox.expand(child: ColoredBox(color: Colors.blue)),
            )));
    await tester.pumpWidget(scene(true));
    await tester.pump();
    expect(diagnostics.inFlight, isTrue);
    for (var frame = 0; frame < 5; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(diagnostics.captures, 0);
      expect(diagnostics.inFlight, isTrue);
    }
    expect(attempts, 1);
    // Mute presentation ticks while resolving the image future, so a legitimately
    // eligible later frame cannot race the exact capture-count assertion.
    await tester.pumpWidget(scene(false));
    diagnostics.beforeCapture = null;
    gate.complete();
    await waitForCapture(tester, diagnostics, 1);
    final allocations = diagnostics.allocated;
    final cancellationGate = Completer<void>();
    diagnostics.beforeCapture = () => cancellationGate.future;
    await tester.pumpWidget(scene(true));
    await tester.pump(const Duration(milliseconds: 16));
    expect(diagnostics.inFlight, isTrue);
    await tester.pumpWidget(scene(false, playing: false));
    cancellationGate.complete();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(diagnostics.captures, 1);
    expect(diagnostics.allocated, allocations); // Revoked work never reaches the GPU capture.
    expect(diagnostics.inFlight, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(diagnostics.allocated, diagnostics.released);
    expect(tester.takeException(), isNull);
  });
  testWidgets('disposing the first ambient frame releases its image only once', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: AmbientBlur(
        composition: AmbientComposition.legacy,
        child: SizedBox.expand(child: ColoredBox(color: Colors.blue)),
      ),
    ));
    for (var attempt = 0; attempt < 10 && find.byType(RawImage).evaluate().isEmpty; attempt++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    expect(find.byType(RawImage), findsWidgets);
    final image = tester.widgetList<RawImage>(find.byType(RawImage)).first.image!;
    expect(image.width, lessThanOrEqualTo(192));
    expect(image.height, lessThanOrEqualTo(192));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(image.debugDisposed, isTrue);
  });

  testWidgets('direct composition captures bounded frames without full-screen opacity layers', (tester) async {
    final diagnostics = AmbientBlurDiagnostics()..enabled = true;
    var videoBuilds = 0;
    final child = Builder(builder: (context) {
      videoBuilds++;
      return const SizedBox.expand(child: ColoredBox(color: Colors.blue));
    });
    Widget scene({bool playing = true, bool enabled = true}) => MaterialApp(
          home: AmbientBlur(diagnostics: diagnostics, playing: playing, enabled: enabled, child: child),
        );
    await tester.pumpWidget(scene());
    for (var attempt = 0; attempt < 10 && diagnostics.captures == 0; attempt++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    expect(diagnostics.captures, 1);
    await tester.pump();
    final painter = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((widget) => widget.painter)
        .whereType<AmbientFramePainter>()
        .single;
    expect(painter.image.width, lessThanOrEqualTo(192));
    expect(painter.image.height, lessThanOrEqualTo(192));
    expect(find.byType(Opacity), findsNothing);
    expect(find.byType(FadeTransition), findsNothing);
    final buildsAfterCapture = videoBuilds;
    await tester.pump(const Duration(seconds: 1));
    expect(videoBuilds, buildsAfterCapture);
    await tester.pumpWidget(scene(playing: false));
    await tester.pump(const Duration(seconds: 20));
    expect(diagnostics.captures, 1);
    expect(diagnostics.running, isFalse);
    await tester.pumpWidget(scene(enabled: false));
    await tester.pump();
    expect(painter.image.debugDisposed, isTrue);
    expect(diagnostics.retainedBytes, 0);
    expect(diagnostics.allocated, diagnostics.released);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('disabled and initially paused ambient never starts capturing', (tester) async {
    final diagnostics = AmbientBlurDiagnostics();
    await tester.pumpWidget(MaterialApp(
        home: AmbientBlur(
      playing: false,
      diagnostics: diagnostics,
      child: const SizedBox.expand(),
    )));
    await tester.pump(const Duration(seconds: 20));
    expect(diagnostics.captures, 0);
    expect(diagnostics.allocated, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('background suspends capture, releases frames, and resumes without queued work', (tester) async {
    final diagnostics = AmbientBlurDiagnostics();
    await tester.pumpWidget(MaterialApp(
        home: AmbientBlur(
      diagnostics: diagnostics,
      child: const SizedBox.expand(child: ColoredBox(color: Colors.green)),
    )));
    for (var attempt = 0; attempt < 10 && diagnostics.captures == 0; attempt++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    await tester.pump();
    expect(diagnostics.captures, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    await tester.pump(const Duration(seconds: 30));
    expect(diagnostics.running, isFalse);
    expect(diagnostics.captures, 1);
    expect(diagnostics.allocated, diagnostics.released);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    for (var attempt = 0; attempt < 10 && diagnostics.captures < 2; attempt++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    expect(diagnostics.captures, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(diagnostics.allocated, diagnostics.released);
    expect(diagnostics.inFlight, isFalse);
    expect(tester.takeException(), isNull);
  });
}
