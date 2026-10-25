import 'package:flutter/foundation.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// This is the renderer requested by configuration, not a guess from current-vo
/// (both libmpv OpenGL and software report the same VO name).
bool mpvUsesWindowsSoftwareTexture({TargetPlatform? platform, bool web = kIsWeb}) =>
    !web && (platform ?? defaultTargetPlatform) == TargetPlatform.windows;

/// Windows uses the software texture transfer path to avoid ANGLE shared
/// surface failures. Hardware decoding remains enabled through copyback.
/// The pinned Windows software renderer limits output to 1920x1080.
VideoControllerConfiguration mpvVideoConfiguration({
  required bool hardwareAcceleration,
  TargetPlatform? platform,
  bool web = kIsWeb,
}) {
  final windows = mpvUsesWindowsSoftwareTexture(platform: platform, web: web);
  final linux =
      !web && (platform ?? defaultTargetPlatform) == TargetPlatform.linux;
  return VideoControllerConfiguration(
    enableHardwareAcceleration: windows ? false : hardwareAcceleration,
    // The native controller defaults a null hwdec to auto, independently of
    // enableHardwareAcceleration. Linux's disabled preference must disable
    // decoding as well as selecting a software texture.
    hwdec: windows
        ? (hardwareAcceleration ? 'auto-copy' : 'no')
        : linux && !hardwareAcceleration
            ? 'no'
            : null,
  );
}

Map<String, String> windowsMpvDecodeDiagnostics({
  required bool hardwareAcceleration,
  required String currentDecoder,
}) =>
    {
      'Windows hardware acceleration (saved)': '$hardwareAcceleration',
      'Windows decoder (requested)': hardwareAcceleration ? 'auto-copy' : 'no',
      'Windows renderer (requested)': 'software texture / libmpv (Windows compatibility)',
      'Windows renderer output limit': '1920x1080 (pinned software texture renderer)',
      'Windows decoder fallback': !hardwareAcceleration
          ? 'software requested'
          : currentDecoder == 'no'
              ? 'software active after auto-copy request'
              : currentDecoder.isEmpty || currentDecoder == 'unknown'
                  ? 'not determined'
                  : 'hardware active ($currentDecoder)',
    };
