import 'dart:async';

import 'package:fladder/util/jms_smooth_scroll.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _viewport = ValueKey('wheel-viewport');
const _innerViewport = ValueKey('inner-wheel-viewport');

void main() {
  _desktopTestWidgets('one wheel notch animates and stops within 180ms',
      (tester) async {
    final controller = JmsSmoothScrollController();
    addTearDown(controller.dispose);
    await _mount(tester, controller);

    _wheel(tester);
    expect(controller.offset, 0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(controller.offset, greaterThan(0));
    expect(controller.offset, lessThan(120));
    await tester.pump(const Duration(milliseconds: 120));
    expect(controller.offset, closeTo(120, 0.001));
    await tester.pump(const Duration(seconds: 1));
    expect(controller.offset, closeTo(120, 0.001));
  });

  _desktopTestWidgets('unfinished same direction notches retain all distance',
      (tester) async {
    final controller = JmsSmoothScrollController();
    addTearDown(controller.dispose);
    await _mount(tester, controller);
    _wheel(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final beforeRetarget = controller.offset;

    _wheel(tester);
    expect(controller.offset, beforeRetarget);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(controller.offset, greaterThan(beforeRetarget));
    expect(controller.offset, lessThan(240));
    await tester.pump(const Duration(milliseconds: 160));
    expect(controller.offset, closeTo(240, 0.001));
  });

  _desktopTestWidgets('a notch moves across frames without a first-frame lurch',
      (tester) async {
    final controller = JmsSmoothScrollController();
    addTearDown(controller.dispose);
    await _mount(tester, controller);
    _wheel(tester);
    expect(controller.offset, 0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    final firstFrame = controller.offset;
    expect(firstFrame, inExclusiveRange(0, 24));
    await tester.pump(const Duration(milliseconds: 16));
    expect(controller.offset, greaterThan(firstFrame));
    expect(controller.offset, lessThan(60));
    await tester.pump(const Duration(milliseconds: 140));
    expect(controller.offset, closeTo(120, 0.001));
  });

  _desktopTestWidgets(
      'focus visibility scrolling interrupts wheel motion without a stale target',
      (tester) async {
    final controller = JmsSmoothScrollController();
    addTearDown(controller.dispose);
    const focusTarget = ValueKey('focus-target');
    await tester.pumpWidget(_host(SingleChildScrollView(
      key: _viewport,
      controller: controller,
      child: const Column(children: [
        SizedBox(height: 1000),
        SizedBox(key: focusTarget, height: 80, width: 300),
        SizedBox(height: 2000),
      ]),
    )));
    _wheel(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    unawaited(Scrollable.ensureVisible(
      tester.element(find.byKey(focusTarget)),
      duration: const Duration(milliseconds: 80),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final focusedPosition = controller.offset;
    expect(focusedPosition, closeTo(1000, 0.001));
    await tester.pump(const Duration(milliseconds: 180));
    expect(controller.offset, focusedPosition);
    _wheel(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    expect(controller.offset, closeTo(focusedPosition + 120, 0.001));
  });

  _desktopTestWidgets(
      'reversal discards the old target and reverses from visible pixels',
      (tester) async {
    final controller = JmsSmoothScrollController(initialScrollOffset: 300);
    addTearDown(controller.dispose);
    await _mount(tester, controller);
    _wheel(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final beforeReverse = controller.offset;

    _wheel(tester, dy: -120);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(controller.offset, lessThan(beforeReverse));
    await tester.pump(const Duration(milliseconds: 160));
    expect(controller.offset, closeTo(beforeReverse - 120, 0.001));
  });

  _desktopTestWidgets(
      'wheel target clamps at the lower extent without overshooting',
      (tester) async {
    final controller = JmsSmoothScrollController();
    addTearDown(controller.dispose);
    await _mount(tester, controller);
    final end = controller.position.maxScrollExtent;
    controller.jumpTo(end - 30);
    _wheel(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(controller.offset, lessThanOrEqualTo(end));
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.offset, end);
  });

  _desktopTestWidgets(
      'nested scrollable keeps the native innermost resolver winner',
      (tester) async {
    final outer = JmsSmoothScrollController();
    final inner = JmsSmoothScrollController();
    addTearDown(outer.dispose);
    addTearDown(inner.dispose);
    await _mountNested(tester, outer, inner);
    _wheel(tester, target: _innerViewport);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    expect(inner.offset, closeTo(120, 0.001));
    expect(outer.offset, 0);
  });

  _desktopTestWidgets(
      'nested wheel bubbles at both extents through native arbitration',
      (tester) async {
    final outer = JmsSmoothScrollController();
    final inner = JmsSmoothScrollController();
    addTearDown(outer.dispose);
    addTearDown(inner.dispose);
    await _mountNested(tester, outer, inner);

    inner.jumpTo(inner.position.maxScrollExtent);
    _wheel(tester, target: _innerViewport);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    expect(outer.offset, closeTo(120, 0.001));
    expect(inner.offset, inner.position.maxScrollExtent);

    inner.jumpTo(0);
    _wheel(tester, dy: -120, target: _innerViewport);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    expect(outer.offset, closeTo(0, 0.001));
    expect(inner.offset, 0);
  });

  _desktopTestWidgets('horizontal and Shift wheel keep native axis mapping',
      (tester) async {
    final controller = JmsSmoothScrollController();
    addTearDown(controller.dispose);
    await _mount(tester, controller, axis: Axis.horizontal);
    _wheel(tester, dx: 120, dy: 0);
    expect(controller.offset, closeTo(120, 0.001));
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    _wheel(tester);
    expect(controller.offset, closeTo(240, 0.001));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump(const Duration(milliseconds: 180));
    expect(controller.offset, closeTo(240, 0.001));
  });

  _desktopTestWidgets('reversed vertical views keep native direction mapping',
      (tester) async {
    final controller = JmsSmoothScrollController();
    addTearDown(controller.dispose);
    await _mount(tester, controller, reverse: true);
    _wheel(tester, dy: -120);
    expect(controller.offset, 0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    expect(controller.offset, closeTo(120, 0.001));
  });

  _desktopTestWidgets(
      'fine fractional diagonal and trackpad signals stay immediate',
      (tester) async {
    final controller = JmsSmoothScrollController();
    addTearDown(controller.dispose);
    await _mount(tester, controller);
    for (final input in [
      (dx: 0.0, dy: 3.0, kind: PointerDeviceKind.mouse),
      (dx: 0.0, dy: 40.5, kind: PointerDeviceKind.mouse),
      (dx: 1.0, dy: 120.0, kind: PointerDeviceKind.mouse),
      (dx: 0.0, dy: 120.0, kind: PointerDeviceKind.trackpad),
    ]) {
      final before = controller.offset;
      _wheel(tester, dx: input.dx, dy: input.dy, kind: input.kind);
      expect(controller.offset, closeTo(before + input.dy, 0.001));
      await tester.pump();
    }
  });

  _desktopTestWidgets(
      'trackpad pan zoom matches the native controller without a wheel tail',
      (tester) async {
    Future<double> stroke(ScrollController controller) async {
      final position = tester.getCenter(find.byKey(_viewport));
      tester.binding.handlePointerEvent(
          PointerPanZoomStartEvent(pointer: 9, position: position));
      tester.binding.handlePointerEvent(PointerPanZoomUpdateEvent(
        pointer: 9,
        position: position,
        pan: const Offset(0, -100),
        panDelta: const Offset(0, -100),
      ));
      // Native dragStartBehavior.start consumes the update that starts dragging.
      tester.binding.handlePointerEvent(PointerPanZoomUpdateEvent(
        pointer: 9,
        position: position,
        pan: const Offset(0, -160),
        panDelta: const Offset(0, -60),
      ));
      await tester.pump();
      final held = controller.offset;
      await tester.pump(const Duration(milliseconds: 200));
      expect(controller.offset, closeTo(held, 0.001));
      tester.binding.handlePointerEvent(
          PointerPanZoomEndEvent(pointer: 9, position: position));
      await tester.pumpAndSettle();
      return held;
    }

    final native = ScrollController();
    addTearDown(native.dispose);
    await _mount(tester, native);
    final nativeOffset = await stroke(native);
    expect(nativeOffset, greaterThan(0));
    await tester.pumpWidget(const SizedBox());

    final smooth = JmsSmoothScrollController();
    addTearDown(smooth.dispose);
    await _mount(tester, smooth);
    expect(await stroke(smooth), closeTo(nativeOffset, 0.001));
  });

  _desktopTestWidgets('reduced motion bypasses smoothing', (tester) async {
    final controller = JmsSmoothScrollController();
    addTearDown(controller.dispose);
    await _mount(tester, controller, disableAnimations: true);
    _wheel(tester);
    expect(controller.offset, closeTo(120, 0.001));
    await tester.pump(const Duration(milliseconds: 180));
    expect(controller.offset, closeTo(120, 0.001));
  });

  _desktopTestWidgets(
      'an external jump cancels the target and the next notch starts there',
      (tester) async {
    final controller = JmsSmoothScrollController();
    addTearDown(controller.dispose);
    await _mount(tester, controller);
    _wheel(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    controller.jumpTo(30);
    await tester.pump(const Duration(milliseconds: 200));
    expect(controller.offset, 30);

    _wheel(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    expect(controller.offset, closeTo(150, 0.001));
  });

  _desktopTestWidgets(
      'a touch drag interrupts the wheel animation without a ghost target',
      (tester) async {
    final controller = JmsSmoothScrollController();
    addTearDown(controller.dispose);
    await _mount(tester, controller);
    _wheel(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final gesture =
        await tester.startGesture(tester.getCenter(find.byKey(_viewport)));
    await gesture.moveBy(const Offset(0, -60));
    await tester.pump();
    final held = controller.offset;
    await tester.pump(const Duration(milliseconds: 200));
    expect(controller.offset, closeTo(held, 0.001));
    await gesture.up();
    await tester.pumpAndSettle();
  });

  _desktopTestWidgets('input observation expires after its dispatch microtask',
      (tester) async {
    final controller = JmsSmoothScrollController();
    addTearDown(controller.dispose);
    await _mount(tester, controller);
    _wheel(tester);
    await tester.pump();
    controller.position.pointerScroll(120);
    expect(controller.offset, closeTo(120, 0.001));
    await tester.pump(const Duration(milliseconds: 200));
    expect(controller.offset, closeTo(120, 0.001));
  });

  _desktopTestWidgets(
      'disposing during a wheel animation leaves no pending error',
      (tester) async {
    final controller = JmsSmoothScrollController();
    await _mount(tester, controller);
    _wheel(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);
  });
  _desktopTestWidgets(
      'single child scope switches controllers without transferring a wheel tail',
      (tester) async {
    final external = ScrollController();
    addTearDown(external.dispose);
    late ScrollController adopted;
    Future<void> mount(ScrollController? controller) => tester.pumpWidget(_host(
          JmsScrollControllerScope(
            key: const ValueKey('single-child-controller-scope'),
            controller: controller,
            builder: (context, effective) {
              adopted = effective;
              return SingleChildScrollView(
                key: _viewport,
                controller: effective,
                child: const SizedBox(height: 3000),
              );
            },
          ),
        ));

    await mount(null);
    final owned = adopted;
    expect(owned, isA<JmsSmoothScrollController>());
    _wheel(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final visible = owned.offset;
    expect(visible, inExclusiveRange(0, 120));

    await mount(external);
    expect(adopted, same(external));
    expect(owned.hasClients, isFalse);
    await tester.pump(const Duration(milliseconds: 200));
    expect(external.offset, closeTo(visible, 0.001));
    _wheel(tester);
    expect(external.offset, closeTo(visible + 120, 0.001));

    await mount(null);
    expect(adopted, same(owned));
    expect(external.hasClients, isFalse);
    expect(owned.hasClients, isTrue);
    await tester.pumpWidget(const SizedBox());
    expect(() => owned.addListener(_listener), throwsAssertionError);
    external.addListener(_listener);
    external.removeListener(_listener);
    expect(tester.takeException(), isNull);
  });

  _desktopTestWidgets(
      'sliver scope preserves external ownership through replacement and disposal',
      (tester) async {
    final first = ScrollController();
    final second = ScrollController();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    late ScrollController adopted;
    Future<void> mount(ScrollController? controller) => tester.pumpWidget(_host(
          JmsScrollControllerScope(
            key: const ValueKey('sliver-controller-scope'),
            controller: controller,
            builder: (context, effective) {
              adopted = effective;
              return CustomScrollView(
                key: _viewport,
                controller: effective,
                slivers: const [
                  SliverToBoxAdapter(child: SizedBox(height: 3000))
                ],
              );
            },
          ),
        ));

    await mount(first);
    _wheel(tester);
    expect(first.offset, 120);
    await mount(second);
    expect(adopted, same(second));
    expect(first.hasClients, isFalse);
    expect(second.hasClients, isTrue);
    first.addListener(_listener);
    first.removeListener(_listener);

    await mount(null);
    final owned = adopted;
    expect(owned, isA<JmsSmoothScrollController>());
    expect(second.hasClients, isFalse);
    _wheel(tester);
    final beforeFrame = owned.offset;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(owned.offset, greaterThan(beforeFrame));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 200));
    expect(() => owned.addListener(_listener), throwsAssertionError);
    second.addListener(_listener);
    second.removeListener(_listener);
    expect(tester.takeException(), isNull);
  });
  _desktopTestWidgets(
      'near-boundary bursts do not restart the tail or delay native bubbling',
      (tester) async {
    final outer = JmsSmoothScrollController();
    final inner = JmsSmoothScrollController();
    addTearDown(outer.dispose);
    addTearDown(inner.dispose);
    await _mountNested(tester, outer, inner);

    for (final dy in [120.0, -120.0]) {
      final bottom = dy > 0;
      outer.jumpTo(bottom ? 0 : 120);
      inner.jumpTo(bottom ? inner.position.maxScrollExtent - 60 : 60);
      _wheel(tester, dy: dy, target: _innerViewport);
      await tester.pump();
      for (var i = 0; i < 7; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        _wheel(tester, dy: dy, target: _innerViewport);
      }
      // The original 160ms tail must finish despite same-target bursts.
      await tester.pump(const Duration(milliseconds: 30));
      expect(inner.offset, bottom ? inner.position.maxScrollExtent : 0);
      expect(outer.offset, bottom ? 0 : 120);

      _wheel(tester, dy: dy, target: _innerViewport);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 180));
      expect(outer.offset, bottom ? 120 : 0);
    }
  });
}

void _listener() {}

void _desktopTestWidgets(String description, WidgetTesterCallback callback) =>
    testWidgets(
      description,
      callback,
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

Widget _host(Widget child, {bool disableAnimations = false}) => MaterialApp(
      home: Builder(builder: (context) {
        return MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(disableAnimations: disableAnimations),
          child: Builder(builder: (context) {
            return Listener(
              onPointerSignal: (event) => JmsWheelInputObserver.observe(
                event,
                enabled: !MediaQuery.disableAnimationsOf(context),
              ),
              child: Scaffold(
                  body: Center(
                      child: SizedBox(width: 350, height: 400, child: child))),
            );
          }),
        );
      }),
    );

Future<void> _mount(WidgetTester tester, ScrollController controller,
    {Axis axis = Axis.vertical,
    bool reverse = false,
    bool disableAnimations = false}) async {
  await tester.pumpWidget(_host(
    SingleChildScrollView(
      key: _viewport,
      controller: controller,
      scrollDirection: axis,
      reverse: reverse,
      child: SizedBox(
          width: axis == Axis.horizontal ? 3000 : 300,
          height: axis == Axis.vertical ? 3000 : 300),
    ),
    disableAnimations: disableAnimations,
  ));
}

Future<void> _mountNested(
    WidgetTester tester, ScrollController outer, ScrollController inner) async {
  await tester.pumpWidget(_host(SingleChildScrollView(
    controller: outer,
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 100),
      SizedBox(
        height: 200,
        child: SingleChildScrollView(
          key: _innerViewport,
          controller: inner,
          child: const SizedBox(height: 1500),
        ),
      ),
      const SizedBox(height: 1800),
    ]),
  )));
}

void _wheel(WidgetTester tester,
    {double dx = 0,
    double dy = 120,
    PointerDeviceKind kind = PointerDeviceKind.mouse,
    Key target = _viewport}) {
  tester.binding.handlePointerEvent(PointerScrollEvent(
    kind: kind,
    position: tester.getCenter(find.byKey(target)),
    scrollDelta: Offset(dx, dy),
  ));
}
