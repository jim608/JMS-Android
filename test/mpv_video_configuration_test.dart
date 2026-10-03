import 'package:fladder/util/mpv_video_configuration.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows uses hardware copyback without disabling GPU rendering', () {
    final configuration = mpvVideoConfiguration(
        hardwareAcceleration: true, platform: TargetPlatform.windows);
    expect(configuration.hwdec, 'auto-copy');
    expect(configuration.enableHardwareAcceleration, isTrue);
    expect(configuration.vo, isNull);
  });

  test('Windows disabled preference disables decoder and renderer acceleration',
      () {
    final configuration = mpvVideoConfiguration(
        hardwareAcceleration: false, platform: TargetPlatform.windows);
    expect(configuration.hwdec, 'no');
    expect(configuration.enableHardwareAcceleration, isFalse);
  });

  test('other platforms preserve their existing controller defaults', () {
    for (final platform in TargetPlatform.values
        .where((value) => value != TargetPlatform.windows)) {
      for (final acceleration in [false, true]) {
        final configuration = mpvVideoConfiguration(
            hardwareAcceleration: acceleration, platform: platform);
        expect(configuration.hwdec, isNull, reason: platform.name);
        expect(configuration.enableHardwareAcceleration, acceleration);
        expect(configuration.vo, isNull);
      }
    }
    final browser = mpvVideoConfiguration(
        hardwareAcceleration: true,
        platform: TargetPlatform.windows,
        web: true);
    expect(browser.hwdec, isNull);
  });

  test(
      'diagnostics distinguish hardware copyback, software fallback and pending playback',
      () {
    Map<String, String> diagnostics(String current) =>
        windowsMpvDecodeDiagnostics(
            hardwareAcceleration: true, currentDecoder: current);
    expect(diagnostics('d3d11va-copy')['Windows decoder fallback'],
        'hardware active (d3d11va-copy)');
    expect(diagnostics('no')['Windows decoder fallback'],
        'software active after auto-copy request');
    expect(
        diagnostics('unknown')['Windows decoder fallback'], 'not determined');
    expect(
        windowsMpvDecodeDiagnostics(
            hardwareAcceleration: false,
            currentDecoder: 'no')['Windows decoder fallback'],
        'software requested');
  });
}
