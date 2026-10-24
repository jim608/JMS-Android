import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:fladder/screens/shared/flat_button.dart';
import 'package:fladder/theme.dart';
import 'package:fladder/widgets/navigation_scaffold/components/navigation_body.dart';

final acceptKeys = {
  LogicalKeyboardKey.enter,
  LogicalKeyboardKey.accept,
  LogicalKeyboardKey.select,
  LogicalKeyboardKey.gameButtonA,
  LogicalKeyboardKey.space,
};

class FocusProvider extends InheritedWidget {
  final bool hasFocus;
  final bool autoFocus;

  const FocusProvider({
    super.key,
    this.hasFocus = false,
    this.autoFocus = false,
    required super.child,
  });

  static bool of(BuildContext context) {
    final widget = context.dependOnInheritedWidgetOfExactType<FocusProvider>();
    return widget?.hasFocus ?? false;
  }

  static bool autoFocusOf(BuildContext context) {
    final widget = context.dependOnInheritedWidgetOfExactType<FocusProvider>();
    return widget?.autoFocus ?? false;
  }

  @override
  bool updateShouldNotify(FocusProvider oldWidget) {
    return oldWidget.hasFocus != hasFocus;
  }
}

class FocusButton extends StatefulWidget {
  final Widget? child;
  final bool autoFocus;
  final FocusNode? focusNode;
  final List<Widget> focusedOverlays;
  final List<Widget> overlays;
  final Function(bool value)? onHover;
  final Function()? onTap;
  final Function()? onLongPress;
  final Function(TapDownDetails)? onSecondaryTapDown;
  final bool darkOverlay;
  final bool visualizeFocus;
  final bool forceFocusOutline;
  final Function(bool focus)? onFocusChanged;
  final BorderRadiusGeometry? borderRadius;
  final KeyEventResult Function(FocusNode node, KeyEvent event)? onKeyEvent;

  const FocusButton({
    this.child,
    this.autoFocus = false,
    this.focusNode,
    this.focusedOverlays = const [],
    this.overlays = const [],
    this.onHover,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTapDown,
    this.darkOverlay = true,
    this.visualizeFocus = true,
    this.forceFocusOutline = false,
    this.onFocusChanged,
    this.borderRadius,
    this.onKeyEvent,
    super.key,
  });

  @override
  State<FocusButton> createState() => FocusButtonState();
}

class FocusButtonState extends State<FocusButton> {
  late FocusNode focusNode = widget.focusNode ?? FocusNode();
  ValueNotifier<bool> onHover = ValueNotifier(false);
  Timer? _longPressTimer;
  bool _longPressTriggered = false;
  LogicalKeyboardKey? _activeAcceptKey;

  static const Duration _kLongPressTimeout = Duration(milliseconds: 500);

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (!node.hasFocus) return KeyEventResult.ignored;

    if (widget.onKeyEvent != null) {
      final result = widget.onKeyEvent!(node, event);
      if (result != KeyEventResult.ignored) return result;
    }

    if (acceptKeys.contains(event.logicalKey)) {
      if (event is KeyDownEvent) {
        if (_activeAcceptKey != null) return KeyEventResult.handled;
        _activeAcceptKey = event.logicalKey;
        if (widget.onLongPress != null) _startLongPressTimer();
      } else if (event is KeyUpEvent) {
        if (_activeAcceptKey == event.logicalKey) {
          final shouldTap = !_longPressTriggered;
          _resetKeyState();
          if (shouldTap) widget.onTap?.call();
        }
      }
      // Consume repeats and releases too: parent/player shortcuts must not
      // activate a second action for the same physical press.
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _startLongPressTimer() {
    _longPressTriggered = false;
    _longPressTimer?.cancel();
    _longPressTimer = Timer(_kLongPressTimeout, () {
      if (!mounted || !focusNode.hasFocus) return;
      _longPressTriggered = true;
      widget.onLongPress?.call();
    });
  }

  void _cancelLongPressTimer() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
  }

  void _resetKeyState() {
    _cancelLongPressTimer();
    _activeAcceptKey = null;
    _longPressTriggered = false;
  }

  @override
  void dispose() {
    _resetKeyState();
    onHover.dispose();
    if (lastMainFocus == focusNode) {
      lastMainFocus = null;
    }
    if (widget.focusNode == null) {
      focusNode.dispose();
    }
    super.dispose();
  }

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.autoFocus && !focusNode.hasFocus) {
        focusNode.requestFocus();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.onTap == null && widget.onLongPress == null && widget.onSecondaryTapDown == null) {
      return widget.child ?? const SizedBox.shrink();
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (event) => onHover.value = true,
      onExit: (event) {
        onHover.value = false;
        if (widget.onHover != null) {
          widget.onHover?.call(false);
        }
      },
      onHover: widget.onHover != null ? (event) => widget.onHover?.call(true) : null,
      child: Focus(
        focusNode: focusNode,
        autofocus: widget.autoFocus,
        canRequestFocus: widget.onTap != null || widget.onLongPress != null || widget.onSecondaryTapDown != null,
        skipTraversal: widget.onTap == null && widget.onLongPress == null && widget.onSecondaryTapDown != null,
        onFocusChange: (value) {
          if (!value) _resetKeyState();
          widget.onFocusChanged?.call(value);
          if (value) {
            lastMainFocus = focusNode;
            WidgetsBinding.instance.addPostFrameCallback((_) async {
              if (mounted && focusNode.hasFocus) {
                final duration = MediaQuery.maybeOf(context)?.disableAnimations == true
                    ? Duration.zero
                    : const Duration(milliseconds: 150);
                await Scrollable.ensureVisible(
                  context,
                  duration: duration,
                  alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
                );
                if (!mounted || !focusNode.hasFocus) return;
                // The complementary policy reveals earlier cards. Both leave
                // already visible controls at their existing scroll position.
                await Scrollable.ensureVisible(
                  context,
                  duration: duration,
                  alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
                );
              }
            });
          }
          onHover.value = value;
        },
        onKeyEvent: _handleKey,
        child: ExcludeFocus(
          child: ValueListenableBuilder(
            valueListenable: onHover,
            builder: (context, value, child) {
              final hasFocus = widget.forceFocusOutline || focusNode.hasFocus || value;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOut,
                clipBehavior: Clip.hardEdge,
                decoration: BoxDecoration(
                  borderRadius: widget.borderRadius ?? FladderTheme.smallShape.borderRadius,
                ),
                foregroundDecoration: BoxDecoration(
                  borderRadius: widget.borderRadius ?? FladderTheme.smallShape.borderRadius,
                  color: widget.darkOverlay && widget.visualizeFocus
                      ? Theme.of(context).colorScheme.primaryFixedDim.withValues(alpha: hasFocus ? 0.10 : 0.0)
                      : null,
                  border: widget.visualizeFocus
                      ? Border.all(
                          width: hasFocus ? 3.5 : 2,
                          color: Theme.of(context).colorScheme.primary.withValues(alpha: hasFocus ? 1 : 0.0),
                        )
                      : null,
                ),
                child: FlatButton(
                  onTap: widget.onTap,
                  onSecondaryTapDown: widget.onSecondaryTapDown,
                  onLongPress: widget.onLongPress,
                  child: widget.child,
                  overlays: [
                    if (widget.overlays.isNotEmpty) ...widget.overlays,
                    if (widget.focusedOverlays.isNotEmpty)
                      Positioned.fill(
                        child: AnimatedOpacity(
                          opacity: hasFocus ? 1 : 0,
                          duration: const Duration(milliseconds: 250),
                          child: Stack(
                            children: [...widget.focusedOverlays],
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
