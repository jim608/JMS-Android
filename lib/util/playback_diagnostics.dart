import 'dart:ui';

String safeDiagnosticValue(String value) {
  if (RegExp(r'https?://|[?&]|token|api[_-]?key|authorization|password', caseSensitive: false).hasMatch(value)) {
    return '[redacted]';
  }
  return value.replaceAll(RegExp(r'[\r\n\x00-\x1f]'), ' ').substring(0, value.length.clamp(0, 100));
}

class PlaybackFrameSamples {
  final List<FrameTiming> _frames = [];
  static const capacity = 600;

  void add(List<FrameTiming> timings) {
    _frames.addAll(timings);
    if (_frames.length > capacity) _frames.removeRange(0, _frames.length - capacity);
  }

  void clear() => _frames.clear();

  String summary(double refreshRate) {
    if (_frames.isEmpty || refreshRate <= 0) return 'unknown';
    final ui = _frames.map((frame) => frame.buildDuration.inMicroseconds).toList()..sort();
    final raster = _frames.map((frame) => frame.rasterDuration.inMicroseconds).toList()..sort();
    final budget = 1000000 / refreshRate;
    final slow = _frames
        .where((frame) => frame.buildDuration.inMicroseconds > budget || frame.rasterDuration.inMicroseconds > budget)
        .length;
    final percentile = (_frames.length * 0.95).ceil() - 1;
    return 'n=${_frames.length}  UI ${(ui[percentile] / 1000).toStringAsFixed(1)} ms / '
        'raster ${(raster[percentile] / 1000).toStringAsFixed(1)} ms p95; '
        'slow ${(slow * 100 / _frames.length).toStringAsFixed(1)}%';
  }
}
