import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fladder/models/settings/client_settings_model.dart';

/// Auto mode deliberately requires both the host OS and this process's session
/// to identify Steam Deck Gaming Mode. A controller alone is not sufficient.
bool isSteamDeckGamingMode({
  required String hostOsRelease,
  required Map<String, String> environment,
}) {
  final properties = <String, String>{};
  for (final line in hostOsRelease.split('\n')) {
    final match = RegExp(r'^([A-Z0-9_]+)=(.*)$').firstMatch(line.trim());
    if (match == null) continue;
    var value = match.group(2)!.trim();
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1);
    }
    properties[match.group(1)!] = value.toLowerCase();
  }

  bool isGamescope(String? value) => value?.trim().toLowerCase() == 'gamescope';

  final currentDesktop = environment['XDG_CURRENT_DESKTOP'];
  final sessionDesktop = environment['XDG_SESSION_DESKTOP'];
  return properties['ID'] == 'steamos' &&
      properties['VARIANT_ID'] == 'steamdeck' &&
      isGamescope(currentDesktop) &&
      (sessionDesktop == null || isGamescope(sessionDesktop));
}

bool resolveHandheldMode({
  required HandheldModePreference preference,
  required bool explicitHandheldFlag,
  required bool automaticGamingMode,
}) {
  if (explicitHandheldFlag) return true;
  return switch (preference) {
    HandheldModePreference.auto => automaticGamingMode,
    HandheldModePreference.desktop => false,
    HandheldModePreference.handheld => true,
  };
}

String _hostOsRelease() {
  final path = File('/.flatpak-info').existsSync() ? '/run/host/os-release' : '/etc/os-release';
  RandomAccessFile? file;
  try {
    file = File(path).openSync();
    return String.fromCharCodes(file.readSync(4096));
  } on FileSystemException {
    return '';
  } finally {
    file?.closeSync();
  }
}

/// Cached host/session evidence. An explicit setting can still change live.
final bool automaticSteamDeckGamingMode = !kIsWeb && Platform.isLinux
    ? isSteamDeckGamingMode(
        hostOsRelease: _hostOsRelease(),
        environment: Platform.environment,
      )
    : false;
