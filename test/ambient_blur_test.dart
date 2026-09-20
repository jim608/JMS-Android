import 'package:fladder/widgets/shared/ambient_blur.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
