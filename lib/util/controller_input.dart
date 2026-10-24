import 'package:flutter/services.dart';

final directionalKeys = {
  LogicalKeyboardKey.arrowUp,
  LogicalKeyboardKey.arrowDown,
  LogicalKeyboardKey.arrowLeft,
  LogicalKeyboardKey.arrowRight,
};

/// Flutter's gamepad button range, including unlabelled generic controllers.
bool isControllerKey(LogicalKeyboardKey key) =>
    key.keyId >= LogicalKeyboardKey.gameButton1.keyId &&
    key.keyId <= LogicalKeyboardKey.gameButtonZ.keyId;

bool isDirectionalInputKey(LogicalKeyboardKey key) =>
    directionalKeys.contains(key) ||
    key == LogicalKeyboardKey.select ||
    isControllerKey(key);
