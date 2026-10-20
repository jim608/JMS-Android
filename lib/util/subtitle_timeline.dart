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
