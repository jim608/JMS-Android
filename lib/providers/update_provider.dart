import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/models/media_playback_model.dart';
import 'package:fladder/providers/settings/client_settings_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/util/update_checker.dart';
import 'package:fladder/util/update_controller.dart';
import 'package:fladder/util/update_source.dart';
import 'package:fladder/util/windows_update_bridge.dart';

final updateProvider = ChangeNotifierProvider<UpdateController>((ref) {
  final windows = !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
  final controller = UpdateController(
    checker: UpdateChecker(
        source: windows
            ? const UpdateSource(owner: 'jim608', repo: 'JMS-Desktop')
            : const UpdateSource()),
    bridge: windows ? createWindowsUpdateBridge() : AndroidUpdateBridge(),
    supported:
        !kIsWeb && (windows || defaultTargetPlatform == TargetPlatform.android),
  );
  controller.automatic = ref.read(clientSettingsProvider).checkForUpdates;
  controller.playback =
      ref.read(mediaPlaybackProvider).state != VideoPlayerState.disposed;
  ref.listen(mediaPlaybackProvider.select((value) => value.state),
      (previous, next) {
    controller.setPlayback(next != VideoPlayerState.disposed);
  });
  unawaited(controller.initialize());
  return controller;
});

final hasNewUpdateProvider =
    Provider<bool>((ref) => ref.watch(updateProvider).hasNewUpdate);
