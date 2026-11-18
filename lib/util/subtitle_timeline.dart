import 'dart:math' as math;

/// HTML tracks require WebVTT. Keep SRT conversion local to the browser player.
String browserSubtitleVtt(String source) {
  final text = source.replaceFirst('\uFEFF', '').replaceAll('\r\n', '\n');
  if (text.startsWith('WEBVTT')) return text;
  final timestamps = RegExp(
      r'(?<start>\d{2,}:\d{2}:\d{2}),(?<sm>\d{3})(\s+-->\s+)(?<end>\d{2,}:\d{2}:\d{2}),(?<em>\d{3})');
  if (!timestamps.hasMatch(text)) {
    throw const FormatException('Subtitles must contain WebVTT or SRT cues');
  }
  return 'WEBVTT\n\n${text.replaceAllMapped(timestamps, (match) => '${match[1]}.${match[2]}${match[3]}${match[4]}.${match[5]}')}';
}

/// Positive offsets delay the subtitle, matching libmpv's sub-delay semantics.
bool subtitleCueIsActive({
  required double start,
  required double end,
  required double position,
  required double offset,
}) {
  final time = position - offset;
  return start.isFinite &&
      end.isFinite &&
      time.isFinite &&
      start <= time &&
      time < end;
}

typedef SubtitleCue = ({double start, double end, String text});

/// Indexes a track's cues in start-time order, retaining order within overlaps.
class SubtitleCueTimeline {
  SubtitleCueTimeline(this._cues)
      : _latestEnd = List.filled(_cues.length * 4, 0) {
    if (_cues.isNotEmpty) _indexEnds(1, 0, _cues.length);
  }

  final List<SubtitleCue> _cues;
  final List<double> _latestEnd;

  double _indexEnds(int node, int first, int limit) {
    if (limit - first == 1) return _latestEnd[node] = _cues[first].end;
    final middle = (first + limit) ~/ 2;
    return _latestEnd[node] = math.max(
      _indexEnds(node * 2, first, middle),
      _indexEnds(node * 2 + 1, middle, limit),
    );
  }

  String textAt(double time) {
    if (_cues.isEmpty || !time.isFinite) return '';
    final active = <String>[];
    _collect(1, 0, _cues.length, time, active);
    return active.join('\n');
  }

  void _collect(
      int node, int first, int limit, double time, List<String> active) {
    // A group can be skipped when all cues have ended or none have begun.
    if (_latestEnd[node] <= time || _cues[first].start > time) return;
    if (limit - first == 1) {
      final text = _cues[first].text;
      if (text.isNotEmpty) active.add(text);
      return;
    }
    final middle = (first + limit) ~/ 2;
    _collect(node * 2, first, middle, time, active);
    _collect(node * 2 + 1, middle, limit, time, active);
  }
}
