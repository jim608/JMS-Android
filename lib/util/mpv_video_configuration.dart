import 'package:flutter/foundation.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Windows libmpv renders through ANGLE. Copy decoded frames back instead of
/// sharing decoder surfaces across the decoder, ANGLE and Flutter adapters.
/// mpv still chooses a supported hardware decoder and falls back to software.
VideoControllerConfiguration mpvVideoConfiguration({
  required bool hardwareAcceleration,
  TargetPlatform? platform,
  bool web = kIsWeb,
}) {
  final windows =
      !web && (platform ?? defaultTargetPlatform) == TargetPlatform.windows;
  return VideoControllerConfiguration(
    enableHardwareAcceleration: hardwareAcceleration,
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
          hardwareAcceleration ? 'ANGLE / libmpv' : 'software / libmpv',
      'Windows decoder fallback': !hardwareAcceleration
          ? 'software requested'
          : currentDecoder == 'no'
              ? 'software active after auto-copy request'
              : currentDecoder.isEmpty || currentDecoder == 'unknown'
                  ? 'not determined'
                  : 'hardware active ($currentDecoder)',
    };
