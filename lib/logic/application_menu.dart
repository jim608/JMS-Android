import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:desktop_multi_window/desktop_multi_window.dart';

import 'package:fladder/models/settings/arguments_model.dart';
import 'package:fladder/src/application_menu.g.dart';
import 'package:fladder/util/jms_test_profile_policy.dart';

class ApplicationMenuImp extends ApplicationMenu {
  ApplicationMenuImp({Future<void> Function()? newInstanceLauncher})
      : _newInstanceLauncher = newInstanceLauncher ?? _launchNewInstance;

  final Future<void> Function() _newInstanceLauncher;

  @override
  Future<void> openNewWindow() async {
    final controller = await WindowController.create(
      const WindowConfiguration(
        hiddenAtLaunch: true,
        arguments:
            '${NotificationKeys.newWindow}, ${NotificationKeys.skipNotifications}',
      ),
    );

    await controller.show();
  }

  @override
  Future<void> newInstance() async {
    // A new process without the validated root would open the normal profile.
    if (JmsTestProfilePolicy.enabled) return;
    await _newInstanceLauncher();
  }

  static Future<void> _launchNewInstance() async {
    if (kIsWeb) return;
    if (Platform.isMacOS) {
      await Process.start('open', ['-n', '-a', Platform.resolvedExecutable]);
    } else if (Platform.isWindows) {
      await Process.start(Platform.resolvedExecutable, []);
    } else if (Platform.isLinux) {
      await Process.start(Platform.resolvedExecutable, [],
          mode: ProcessStartMode.detached);
    }
  }
}
