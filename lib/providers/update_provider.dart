import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/models/media_playback_model.dart';
import 'package:fladder/providers/settings/client_settings_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/providers/syncplay_provider.dart';
import 'package:fladder/services/syncplay/syncplay_models.dart';
import 'package:fladder/services/flatpak_update_portal.dart';
import 'package:fladder/util/flatpak_update_controller.dart';
import 'package:fladder/util/update_checker.dart';
import 'package:fladder/util/update_controller.dart';
import 'package:fladder/util/update_source.dart';
import 'package:fladder/util/windows_update_bridge.dart';
import 'package:fladder/util/linux_update_bridge.dart';
import 'package:fladder/util/jms_test_profile_policy.dart';

final updateBridgeProvider = Provider<UpdateBridge>((ref) {
  final windows = !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
  final linux = !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;
  return JmsTestProfilePolicy.enabled
      ? TestProfileUpdateBridge()
      : windows
          ? createWindowsUpdateBridge()
          : linux
              ? createLinuxUpdateBridge()
              : AndroidUpdateBridge();
});

final updateProvider = ChangeNotifierProvider<UpdateController>((ref) {
  final windows = !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
  final linux = !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;
  final controller = UpdateController(
    checker: UpdateChecker(
        source: UpdateSource.forPlatform(defaultTargetPlatform.name)),
    bridge: ref.watch(updateBridgeProvider),
    supported: !kIsWeb &&
        (windows || linux || defaultTargetPlatform == TargetPlatform.android),
  );
  if (JmsTestProfilePolicy.enabled) return controller;
  if (controller.bridge.flatpakManaged) {
    var disposed = false;
    ref.onDispose(() => disposed = true);
    final flatpak = ref.read(flatpakUpdateProvider);
    // Use the existing saved app preference. No monitor is opened while it is
    // disabled, and the optional startup check never blocks the first frame.
    scheduleMicrotask(() {
      if (!disposed) {
        unawaited(flatpak
            .setAutomatic(ref.read(clientSettingsProvider).checkForUpdates));
      }
    });
    ref.listen(clientSettingsProvider.select((value) => value.checkForUpdates),
        (_, enabled) => unawaited(flatpak.setAutomatic(enabled)));
    return controller;
  }
  controller.automatic = ref.read(clientSettingsProvider).checkForUpdates;
  controller.playback =
      ref.read(mediaPlaybackProvider).state != VideoPlayerState.disposed;
  ref.listen(mediaPlaybackProvider.select((value) => value.state),
      (previous, next) {
    controller.setPlayback(next != VideoPlayerState.disposed);
  });
  // Initialization and the optional startup query never block the first frame.
  unawaited(controller.initialize().then((_) async {
    if (controller.ready) await controller.check(manual: false);
  }));
  return controller;
});

final hasNewUpdateProvider = Provider<bool>((ref) {
  if (kIsWeb) return false;
  final updates = ref.watch(updateProvider);
  return updates.bridge.flatpakManaged
      ? ref.watch(flatpakUpdateProvider).canRequestUpdate
      : updates.hasNewUpdate;
});

/// Construction is passive. A saved automatic-check preference or an explicit
/// user check opens only the app's standard portal monitor.
final flatpakUpdateProvider =
    ChangeNotifierProvider<FlatpakUpdateController>((ref) {
  final controller =
      FlatpakUpdateController(portalFactory: createFlatpakUpdatePortal);
  void refreshActivity() {
    final room = ref.read(syncPlayProvider);
    controller.setActivity(
      playback:
          ref.read(mediaPlaybackProvider).state != VideoPlayerState.disposed,
      syncPlay: room.busy ||
          room.preparingPlayback ||
          !const {SyncPlayStatus.idle, SyncPlayStatus.disposed}
              .contains(room.room.status),
    );
  }

  refreshActivity();
  ref.listen(mediaPlaybackProvider.select((value) => value.state),
      (_, __) => refreshActivity());
  ref.listen(syncPlayProvider, (_, __) => refreshActivity());
  return controller;
});
