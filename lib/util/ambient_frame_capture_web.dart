import 'dart:convert';
import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:media_kit/media_kit.dart' as mpv;
import 'package:web/web.dart' as web;

/// Configure the exact player's video before its first media source is opened.
void configureAmbientVideoCapture(Object? platform) {
  if (platform is! mpv.WebPlayer) return;
  final player = platform as dynamic;
  if (player.disposed as bool) return;
  final element = player.element as web.HTMLVideoElement;
  if (!element.hasAttribute('crossorigin')) {
    element.crossOrigin = 'anonymous';
  }
}

/// Returns an owned frame for the caller to dispose; no media source is changed.
Future<ui.Image?> captureAmbientVideoFrame(
    Object? platform, double maxDimension) async {
  if (platform is! mpv.WebPlayer) return null;
  // The public VM stub has no element getters; the Web export owns these fields.
  final player = platform as dynamic;
  if (player.disposed as bool) return null;
  if (!maxDimension.isFinite || maxDimension <= 0) {
    throw ArgumentError.value(maxDimension, 'maxDimension');
  }
  final element = player.element as web.HTMLVideoElement;
  final source = element.currentSrc;
  final sourceObject = element.srcObject;
  final videoWidth = element.videoWidth;
  final videoHeight = element.videoHeight;
  if (element.readyState < web.HTMLMediaElement.HAVE_CURRENT_DATA ||
      videoWidth <= 0 ||
      videoHeight <= 0) {
    return null;
  }

  final scale = math.min(1.0, maxDimension / math.max(videoWidth, videoHeight));
  final width = math.max(1, (videoWidth * scale).floor());
  final height = math.max(1, (videoHeight * scale).floor());
  final canvas = web.HTMLCanvasElement()
    ..width = width
    ..height = height;
  late final String encoded;
  try {
    canvas.context2D.drawImage(element, 0, 0, width, height);
    encoded = canvas.toDataURL('image/png');
  } catch (error) {
    // A browser can reject canvas access for cross-origin or unavailable media.
    // Dart programmer errors remain visible to the existing capture diagnostics.
    if (error is Error || error is Exception) rethrow;
    final jsError = JSObject.fromInteropObject(error);
    if (jsError.instanceOfString('DOMException')) {
      final name = (jsError as web.DOMException).name;
      if (name == 'SecurityError' || name == 'InvalidStateError') return null;
    }
    rethrow;
  } finally {
    canvas
      ..width = 0
      ..height = 0
      ..remove();
  }
  if (encoded == 'data:,') return null;

  final codec = await ui.instantiateImageCodec(
      base64.decode(encoded.substring(encoded.indexOf(',') + 1)));
  try {
    final frame = (await codec.getNextFrame()).image;
    if (player.disposed as bool ||
        !identical(player.element, element) ||
        element.currentSrc != source ||
        !identical(element.srcObject, sourceObject)) {
      frame.dispose();
      return null;
    }
    return frame;
  } finally {
    codec.dispose();
  }
}
