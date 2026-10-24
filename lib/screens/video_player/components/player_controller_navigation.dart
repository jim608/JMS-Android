import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:fladder/util/input_handler.dart';
import 'package:fladder/util/input_detector.dart';

/// Keeps controller navigation separate from the user's playback hotkeys.
///
/// Hidden controls are woken before any action is taken. Dialog routes retain
/// their own focus scopes, so dismissing them restores the invoking control.
class PlayerControllerNavigation extends StatefulWidget {
  const PlayerControllerNavigation({
    required this.enabled,
    required this.controlsVisible,
    required this.primaryControl,
    required this.showControls,
    required this.hideControls,
    required this.exitPlayer,
    required this.child,
    this.dismissOverlay,
    super.key,
  });

  final bool enabled;
  final bool controlsVisible;
  final FocusNode primaryControl;
  final VoidCallback showControls;
  final VoidCallback hideControls;
  final VoidCallback exitPlayer;
  final bool Function()? dismissOverlay;
  final Widget child;

  @override
  State<PlayerControllerNavigation> createState() => _PlayerControllerNavigationState();
}

class _PlayerControllerNavigationState extends State<PlayerControllerNavigation> {
  final _focus = FocusNode(debugLabel: 'Player controller');
  LogicalKeyboardKey? _acceptKey;
  FocusNode? _acceptTarget;
  static final _navigationKeys = {
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.gameButtonA,
    LogicalKeyboardKey.gameButtonB,
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.escape,
    LogicalKeyboardKey.goBack,
    LogicalKeyboardKey.browserBack,
  };

  // Input mode changes synchronously before the next widget rebuild. The first
  // controller event must not also run a saved seek/volume shortcut.
  bool get _enabledNow => InputDetector.activeControllerMode ?? widget.enabled;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
    if (widget.enabled) _focusPrimaryControl();
  }

  @override
  void didUpdateWidget(PlayerControllerNavigation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) _clearAccept();
    if (widget.enabled && (!oldWidget.enabled || (!oldWidget.controlsVisible && widget.controlsVisible))) {
      _focusPrimaryControl();
    }
  }

  void _onFocusChanged() {
    if (!_focus.hasFocus) _clearAccept();
  }

  void _clearAccept() {
    _acceptKey = null;
    _acceptTarget = null;
  }

  void _focusPrimaryControl() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.enabled || !(ModalRoute.of(context)?.isCurrent ?? true)) return;
      if (widget.controlsVisible && widget.primaryControl.canRequestFocus) {
        widget.primaryControl.requestFocus();
      } else {
        _focus.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChanged);
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!_enabledNow || !(ModalRoute.of(context)?.isCurrent ?? true)) {
      _clearAccept();
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final direction = switch (key) {
      LogicalKeyboardKey.arrowLeft => TraversalDirection.left,
      LogicalKeyboardKey.arrowRight => TraversalDirection.right,
      LogicalKeyboardKey.arrowUp => TraversalDirection.up,
      LogicalKeyboardKey.arrowDown => TraversalDirection.down,
      _ => null,
    };
    final accept =
        key == LogicalKeyboardKey.gameButtonA || key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter;
    final back = key == LogicalKeyboardKey.gameButtonB ||
        key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.browserBack;
    if (direction == null && !accept && !back) return KeyEventResult.ignored;
    if (direction != null && (event is KeyDownEvent || event is KeyRepeatEvent)) {
      if (!widget.controlsVisible) {
        widget.showControls();
        _focusPrimaryControl();
      } else {
        FocusManager.instance.primaryFocus?.focusInDirection(direction);
      }
    } else if (accept && event is KeyDownEvent) {
      _acceptKey = key;
      _acceptTarget = FocusManager.instance.primaryFocus;
    } else if (accept && event is KeyUpEvent) {
      final paired = _acceptKey == key && identical(_acceptTarget, FocusManager.instance.primaryFocus);
      _clearAccept();
      // A dialog may handle the press and close before its release reaches the
      // restored player control. Only activate a press that began here, on the
      // same focused control, and survived without a focus/route change.
      if (!paired) return KeyEventResult.handled;
      if (!widget.controlsVisible) {
        widget.showControls();
        _focusPrimaryControl();
      } else {
        final target = FocusManager.instance.primaryFocus?.context;
        if (target != null) Actions.maybeInvoke(target, const ActivateIntent());
      }
    } else if (back && event is KeyDownEvent) {
      _clearAccept();
      if (widget.dismissOverlay?.call() ?? false) {
        return KeyEventResult.handled;
      } else if (widget.controlsVisible) {
        widget.hideControls();
        _focus.requestFocus();
      } else {
        widget.exitPlayer();
      }
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final content = Focus(
      focusNode: _focus,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: FocusTraversalGroup(
        policy: ReadingOrderTraversalPolicy(),
        child: widget.child,
      ),
    );
    return PlayerShortcutBoundary(keys: _navigationKeys, isEnabled: () => _enabledNow, child: content);
  }
}
