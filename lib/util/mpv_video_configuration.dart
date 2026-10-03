import 'package:flutter/foundation.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Windows uses the software texture transfer path to avoid ANGLE shared
/// surface failures. Hardware decoding remains enabled through copyback.
/// The pinned Windows software renderer limits output to 1920x1080.
VideoControllerConfiguration mpvVideoConfiguration({
  required bool hardwareAcceleration,
  TargetPlatform? platform,
  bool web = kIsWeb,
}) {
  final windows =
      !web && (platform ?? defaultTargetPlatform) == TargetPlatform.windows;
  return VideoControllerConfiguration(
    enableHardwareAcceleration: windows ? false : hardwareAcceleration,
    hwdec: windows ? (hardwareAcceleration ? 'auto-copy' : 'no') : null,
  );
}

Map<String, String> windowsMpvDecodeDiagnostics({
  required bool hardwareAcceleration,
  required String currentDecoder,
}) =>
    {
      'Windows hardware acceleration (saved)': '$hardwareAcceleration',
      'Windows decoder (requested)': hardwareAcceleration ? 'auto-copy' : 'no',
      'Windows renderer (requested)':
          'software texture / libmpv (Windows compatibility)',
      'Windows renderer output limit':
          '1920x1080 (pinned software texture renderer)',
      'Windows decoder fallback': !hardwareAcceleration
          ? 'software requested'
          : currentDecoder == 'no'
              ? 'software active after auto-copy request'
              : currentDecoder.isEmpty || currentDecoder == 'unknown'
                  ? 'not determined'
                  : 'hardware active ($currentDecoder)',
    };
