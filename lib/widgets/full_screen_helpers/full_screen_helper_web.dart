import 'dart:js_interop';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web/web.dart' as web;

import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/widgets/full_screen_helpers/full_screen_wrapper.dart';

class FullScreenHelper implements FullScreenWrapper {
  const FullScreenHelper._();
  factory FullScreenHelper.instantiate() => const FullScreenHelper._();

  @override
  Future<void> closeFullScreen(WidgetRef ref) async {
    try {
      if (web.document.fullscreenElement != null) {
        await web.document.exitFullscreen().toDart;
      }
    } catch (_) {
      // Unsupported APIs and browser-denied transitions leave the page usable.
    } finally {
      _syncFullScreen(ref);
    }
  }

  @override
  Future<void> toggleFullScreen(WidgetRef ref) async {
    try {
      if (web.document.fullscreenElement != null) {
        await web.document.exitFullscreen().toDart;
      } else if (web.document.fullscreenEnabled) {
        await web.document.documentElement?.requestFullscreen().toDart;
      }
    } catch (_) {
      // iPhone Safari may not support document fullscreen. A rejected request
      // must not escape the button callback or change the actual player state.
    } finally {
      _syncFullScreen(ref);
    }
  }

  void _syncFullScreen(WidgetRef ref) {
    if (!ref.context.mounted) return;
    ref
        .read(mediaPlaybackProvider.notifier)
        .update((state) => state.copyWith(fullScreen: web.document.fullscreenElement != null));
  }
}
