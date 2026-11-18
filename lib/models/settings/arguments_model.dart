import 'package:collection/collection.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:fladder/util/jms_test_profile_policy.dart';

part 'arguments_model.freezed.dart';

/// Prefer using the arguments provider over this boolean
bool leanBackMode = false;

/// Prefer using the arguments provider over this boolean
bool lowResourceDevice = false;

class NotificationKeys {
  static const String skipNotifications = '--skipNotifications';
  static const String newWindow = '--newWindow';
  static const String htpcMode = '--htpc';
  static const String handheldMode = '--handheld';
}

@Freezed(copyWith: true)
abstract class ArgumentsModel with _$ArgumentsModel {
  const ArgumentsModel._();

  factory ArgumentsModel({
    @Default(false) bool htpcMode,
    @Default(false) bool handheldMode,
    @Default(false) bool leanBackMode,
    @Default(false) bool lowResourceDevice,
    @Default(false) bool newWindow,
    @Default(false) bool skipNotifications,
    String? launchLink,
  }) = _ArgumentsModel;

  factory ArgumentsModel.fromArguments(
      List<String> arguments, String windowArguments, bool leanBackEnabled, {bool lowResourceDetected = false}) {
    arguments = arguments.map((e) => e.trim()).toList();
    leanBackMode = leanBackEnabled;
    lowResourceDevice = lowResourceDetected;
    final parsedWindowArgs = windowArguments.split(',');
    final shouldSkipNotifications = JmsTestProfilePolicy.enabled ||
        arguments.contains(NotificationKeys.skipNotifications) ||
        parsedWindowArgs.contains(NotificationKeys.skipNotifications) ||
        parsedWindowArgs.contains(NotificationKeys.newWindow);
    return ArgumentsModel(
      htpcMode:
          arguments.contains(NotificationKeys.htpcMode) || leanBackEnabled,
      handheldMode: arguments.contains(NotificationKeys.handheldMode) ||
          parsedWindowArgs.contains(NotificationKeys.handheldMode),
      leanBackMode: leanBackEnabled,
      lowResourceDevice: lowResourceDetected,
      newWindow: parsedWindowArgs.contains(NotificationKeys.newWindow),
      skipNotifications: shouldSkipNotifications,
      launchLink: arguments.firstWhereOrNull((argument) => argument.toLowerCase().startsWith('jms:')),
    );
  }
}
