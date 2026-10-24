import 'dart:ui' show KeyEventDeviceType;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/controller_input.dart';
import 'package:fladder/util/focus_helper.dart';

class InputDetector extends StatefulWidget {
  static _InputDetectorState? _activeDetector;

  /// Available during key dispatch, before the inherited layout is rebuilt.
  static InputDevice? get activeInputDevice => _activeDetector?._currentInput;

  static bool? get activeControllerMode => _activeDetector?._controllerActive;

  final bool isDesktop;
  final bool htpcMode;
  final bool controllerMode;
  final Widget Function(InputDevice input) child;

  const InputDetector({
    super.key,
    required this.isDesktop,
    required this.htpcMode,
    this.controllerMode = false,
    required this.child,
  });

  @override
  State<InputDetector> createState() => _InputDetectorState();
}

class _InputDetectorState extends State<InputDetector> {
  late InputDevice _currentInput = widget.htpcMode || widget.controllerMode
      ? InputDevice.dPad
      : (widget.isDesktop || kIsWeb)
          ? InputDevice.pointer
          : InputDevice.touch;
  late bool _controllerActive = widget.htpcMode || widget.controllerMode;

  @override
  void initState() {
    super.initState();
    InputDetector._activeDetector = this;
    _startListeningToKeyboard();
  }

  void _startListeningToKeyboard() {
    ServicesBinding.instance.keyboard.addHandler(_handleKeyPress);
  }

  @override
  void dispose() {
    if (identical(InputDetector._activeDetector, this)) {
      InputDetector._activeDetector = null;
    }
    ServicesBinding.instance.keyboard.removeHandler(_handleKeyPress);
    super.dispose();
  }

  bool _handleKeyPress(KeyEvent event) {
    if (event is KeyDownEvent) {
      final fromController = widget.htpcMode || widget.controllerMode ||
          isControllerKey(event.logicalKey) ||
          event.deviceType == KeyEventDeviceType.gamepad ||
          event.deviceType == KeyEventDeviceType.joystick ||
          event.deviceType == KeyEventDeviceType.directionalPad;
      if (isEditableTextFocused() &&
          directionalKeys.contains(event.logicalKey) && !fromController) {
        _setControllerActive(false);
        return false;
      }

      if (isDirectionalInputKey(event.logicalKey)) {
        _updateInputDevice(InputDevice.dPad, controllerActive: fromController);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_controllerActive) return;
          final focus = FocusManager.instance.primaryFocus;
          if (focus == null || focus is FocusScopeNode || focus.skipTraversal) {
            FocusScope.of(context).nextFocus();
          }
        });
      } else if (!widget.controllerMode && !widget.htpcMode) {
        _setControllerActive(false);
      }
    }
    return false;
  }

  void _handlePointerEvent(PointerEvent event) {
    if (event is PointerDownEvent) {
      if (event.kind == PointerDeviceKind.touch) {
        _updateInputDevice(InputDevice.touch);
      } else if (event.kind == PointerDeviceKind.mouse) {
        _updateInputDevice(InputDevice.pointer);
      }
    }
  }

  void _setControllerActive(bool active) {
    if (_controllerActive != active) {
      setState(() => _controllerActive = active);
    }
  }

  void _updateInputDevice(InputDevice device, {bool controllerActive = false}) {
    if (_currentInput != device || _controllerActive != controllerActive) {
      if (_currentInput != device && device != InputDevice.dPad) {
        FocusManager.instance.primaryFocus?.unfocus();
      }
      setState(() {
        _currentInput = device;
        _controllerActive = controllerActive;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _handlePointerEvent,
      behavior: HitTestBehavior.translucent,
      // Changing input mode must not swallow the first touch or mouse click.
      child: Builder(
        builder: (context) => widget.child(_currentInput),
      ),
    );
  }
}
