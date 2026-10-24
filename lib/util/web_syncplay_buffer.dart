class SyncPlayBufferedRange {
  const SyncPlayBufferedRange(this.start, this.end);
  final double start, end;
}

/// Copy HTMLMediaElement.buffered into ranges before calling. A null API result
/// is unknown; an empty/holed buffer has zero ahead at the current position.
/// Never borrow the last range's end across an unbuffered seek gap.
Duration? webSyncPlayContiguousBufferEnd({required Duration position, required List<SyncPlayBufferedRange>? ranges}) {
  if (ranges == null || position < Duration.zero) return null;
  final sorted = List<SyncPlayBufferedRange>.of(ranges);
  if (sorted.any(
    (range) => !range.start.isFinite || !range.end.isFinite || range.start < 0 || range.end < range.start,
  )) {
    return null;
  }
  sorted.sort((a, b) => a.start.compareTo(b.start));
  final seconds = position.inMicroseconds / 1000000;
  double? end;
  for (final range in sorted) {
    if (end == null) {
      if (range.start <= seconds && range.end >= seconds) end = range.end;
    } else if (range.start <= end) {
      if (range.end > end) end = range.end;
    } else {
      break;
    }
  }
  return end == null ? position : Duration(microseconds: (end * 1000000).floor());
}
