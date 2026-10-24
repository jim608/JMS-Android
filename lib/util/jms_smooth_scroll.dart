import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/widgets.dart';

/// Observes input without competing with Flutter's pointer signal resolver.
///
/// The application root calls [observe] while the original signal is bubbling,
/// before the resolver delivers it to the innermost eligible scroll position.
abstract final class JmsWheelInputObserver {
  static PointerScrollEvent? _currentEvent;

  static void observe(PointerSignalEvent event, {bool enabled = true}) {
    final current = enabled && event is PointerScrollEvent ? event : null;
    _currentEvent = current;
    if (current == null) return;
    scheduleMicrotask(() {
      if (identical(_currentEvent, current)) _currentEvent = null;
    });
  }

  static bool _smoothVerticalWheel(AxisDirection direction) {
    final event = _currentEvent;
    if (kIsWeb ||
        event == null ||
        !{TargetPlatform.windows, TargetPlatform.linux, TargetPlatform.macOS}.contains(defaultTargetPlatform) ||
        event.kind != PointerDeviceKind.mouse ||
        axisDirectionToAxis(direction) != Axis.vertical ||
        event.scrollDelta.dx != 0) {
      return false;
    }
    final delta = event.scrollDelta.dy;
    // Flutter cannot distinguish every touchpad reported as a mouse wheel.
    // Keep fine/fractional, diagonal, horizontal and pan/zoom input native.
    return delta.isFinite && delta.abs() >= 20 && delta == delta.roundToDouble();
  }
}

/// Keeps native drag, touchpad, axis mapping and nested scroll arbitration.
class JmsSmoothScrollController extends ScrollController {
  JmsSmoothScrollController({
    super.initialScrollOffset,
    super.keepScrollOffset,
    super.debugLabel,
    super.onAttach,
    super.onDetach,
  });

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return _JmsSmoothScrollPosition(
      physics: physics,
      context: context,
      initialPixels: initialScrollOffset,
      keepScrollOffset: keepScrollOffset,
      oldPosition: oldPosition,
      debugLabel: debugLabel,
    );
  }
}

/// Owns a fallback controller while leaving supplied controllers with callers.
///
/// Keeping one fallback for this widget's lifetime also supports switching an
/// existing scroll view between owned and external controllers without leaks.
class JmsScrollControllerScope extends StatefulWidget {
  const JmsScrollControllerScope({
    this.controller,
    required this.builder,
    super.key,
  });

  final ScrollController? controller;
  final Widget Function(BuildContext context, ScrollController controller) builder;

  @override
  State<JmsScrollControllerScope> createState() => _JmsScrollControllerScopeState();
}

class _JmsScrollControllerScopeState extends State<JmsScrollControllerScope> {
  final _ownedController = JmsSmoothScrollController();

  @override
  void didUpdateWidget(covariant JmsScrollControllerScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == null && widget.controller != null) {
      // Do not transfer a pending wheel animation into the caller's controller.
      for (final position in _ownedController.positions) {
        if (position is _JmsSmoothScrollPosition) {
          position._cancelWheelAnimation();
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, widget.controller ?? _ownedController);

  @override
  void dispose() {
    _ownedController.dispose();
    super.dispose();
  }
}

class _JmsSmoothScrollPosition extends ScrollPositionWithSingleContext {
  _JmsSmoothScrollPosition({
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  static const _duration = Duration(milliseconds: 160);
  // A new notch should travel across several frames rather than spending most
  // of its distance at the start. Retargeted notches still retain their speed.
  static const _initialWheelSlope = 1.5;
  double? _wheelTarget;
  double? _wheelDirection;
  ScrollActivity? _wheelActivity;
  int _generation = 0;

  void _clearWheelTarget() {
    _wheelTarget = null;
    _wheelDirection = null;
    _wheelActivity = null;
  }

  void _cancelWheelAnimation() {
    final wheelActivity = _wheelActivity;
    _generation++;
    _clearWheelTarget();
    if (wheelActivity != null && identical(activity, wheelActivity)) goIdle();
  }

  @override
  void pointerScroll(double delta) {
    if (!delta.isFinite) return;
    if (delta == 0 || !hasContentDimensions || !JmsWheelInputObserver._smoothVerticalWheel(axisDirection)) {
      _generation++;
      _clearWheelTarget();
      super.pointerScroll(delta);
      return;
    }

    final continuing = identical(activity, _wheelActivity) && _wheelTarget != null && _wheelDirection == delta.sign;
    // A reversal or interrupted animation starts at the visible position.
    final base = continuing ? _wheelTarget! : pixels;
    final target = (base + delta).clamp(minScrollExtent, maxScrollExtent).toDouble();
    // A clamped target has no additional distance: keep its original deadline.
    if (continuing && target == _wheelTarget) return;
    final distance = target - pixels;
    if (distance == 0) {
      _generation++;
      _clearWheelTarget();
      super.pointerScroll(delta);
      return;
    }

    final velocity = continuing ? activity?.velocity ?? 0.0 : 0.0;
    final initialSlope = continuing && velocity.sign == distance.sign
        ? (velocity * _duration.inMicroseconds / Duration.microsecondsPerSecond / distance).clamp(0.0, 3.0).toDouble()
        : _initialWheelSlope;
    _wheelTarget = target;
    _wheelDirection = delta.sign;
    final generation = ++_generation;
    updateUserScrollDirection(delta < 0 ? ScrollDirection.forward : ScrollDirection.reverse);
    final completion = super.animateTo(
      target,
      duration: _duration,
      curve: _WheelRetargetCurve(initialSlope),
    );
    _wheelActivity = activity;
    unawaited(completion.then((_) {
      if (_generation == generation) _clearWheelTarget();
    }));
  }

  @override
  void dispose() {
    _generation++;
    _clearWheelTarget();
    super.dispose();
  }
}

/// Cubic Hermite interpolation with the previous velocity and a resting end.
/// Bounding the start slope to [0, 3] keeps the curve monotone without overshoot.
class _WheelRetargetCurve extends Curve {
  const _WheelRetargetCurve(this.initialSlope);

  final double initialSlope;

  @override
  double transformInternal(double t) => ((initialSlope - 2) * t + (3 - 2 * initialSlope)) * t * t + initialSlope * t;
}
