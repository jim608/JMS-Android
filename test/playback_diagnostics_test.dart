import 'dart:ui';
import 'package:fladder/util/playback_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('diagnostics redact authorization data and bound values', () {
    for (final value in ['https://server/video?api_key=secret', 'token=secret', 'Authorization: Bearer secret']) {
      expect(safeDiagnosticValue(value), '[redacted]');
    }
    expect(safeDiagnosticValue('gpu / mediacodec-copy'), 'gpu / mediacodec-copy');
    expect(safeDiagnosticValue(List.filled(120, 'x').join()).length, 100);
  });

  test('frame sample window is bounded and uses measured refresh rate', () {
    final samples = PlaybackFrameSamples();
    expect(samples.summary(60), 'unknown');
    samples.add(List.generate(
        601,
        (index) => FrameTiming(
              vsyncStart: index * 20000,
              buildStart: index * 20000,
              buildFinish: index * 20000 + 10000,
              rasterStart: index * 20000 + 10000,
              rasterFinish: index * 20000 + 20000,
              rasterFinishWallTime: index * 20000 + 20000,
            )));
    expect(samples.summary(60), contains('n=600'));
    expect(samples.summary(60), contains('slow 0.0%'));
    expect(samples.summary(120), contains('slow 100.0%'));
    expect(samples.summary(0), 'unknown');
    samples.clear();
    expect(samples.summary(60), 'unknown');
  });
}
