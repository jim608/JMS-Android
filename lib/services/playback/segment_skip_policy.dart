import 'package:fladder/models/items/media_segments_model.dart';

/// One decision for a server supplied segment. Callers route its seek through
/// the normal player/SyncPlay seek path; this policy never seeks a player.
class SegmentSkipDecision {
  const SegmentSkipDecision({required this.segment, required this.autoSkip});

  final MediaSegment segment;
  final bool autoSkip;
}

/// Tracks skip attempts for one playback occurrence, independent of UI rebuilds.
///
/// Both legacy automatic modes are once-per-occurrence. A manual replay or a
/// setting changed while inside a segment offers a prompt instead of seeking
/// immediately. A fresh playback id resets these decisions.
class SegmentSkipPolicy {
  Object? _playbackId;
  List<MediaSegment> _segments = const [];
  Map<MediaSegmentType, SegmentSkip> _previousModes = const {};
  final Set<String> _attempted = {};
  final Set<String> _dismissed = {};
  final Set<String> _manualReplay = {};
  final List<(Duration, Duration)> _manualSeekRanges = [];

  void reset([Object? playbackId]) {
    _playbackId = playbackId;
    _segments = const [];
    _previousModes = const {};
    _attempted.clear();
    _dismissed.clear();
    _manualReplay.clear();
    _manualSeekRanges.clear();
  }

  SegmentSkipDecision? evaluate({
    required Object playbackId,
    required Iterable<MediaSegment> segments,
    required Duration position,
    required Duration duration,
    required Map<MediaSegmentType, SegmentSkip> modes,
    required bool playing,
    required bool canAutoSkip,
  }) {
    if (_playbackId == null) {
      _playbackId = playbackId;
    } else if (playbackId != _playbackId) {
      reset(playbackId);
    }
    _segments = validSegments(segments, duration: duration);
    final currentModes = {
      for (final type in MediaSegmentType.values) type: modes[type] ?? SegmentSkip.askToSkip,
    };
    for (final segment in _segments) {
      _applyManualReplay(segment);
      if (segment.inRange(position) &&
          _previousModes.containsKey(segment.type) &&
          _previousModes[segment.type] != currentModes[segment.type]) {
        _manualReplay.add(_key(segment));
      }
    }
    _previousModes = currentModes;

    for (final segment in _segments) {
      if (!segment.inRange(position)) continue;
      final key = _key(segment);
      final mode = modes[segment.type] ?? SegmentSkip.askToSkip;
      if (mode == SegmentSkip.none || _dismissed.contains(key) || _attempted.contains(key)) continue;

      final automatic = mode == SegmentSkip.skip || mode == SegmentSkip.skipOnce;
      if (automatic && !canAutoSkip) _manualReplay.add(key);
      if (automatic && playing && canAutoSkip && !_manualReplay.contains(key)) {
        // Reserve before returning, so duplicate position notifications and
        // rebuilds cannot schedule a second seek while the first is pending.
        _attempted.add(key);
        return SegmentSkipDecision(segment: segment, autoSkip: true);
      }
      return SegmentSkipDecision(segment: segment, autoSkip: false);
    }
    return null;
  }

  /// Inform the policy before an intentional user seek, including chapter taps.
  /// Rewinding across a segment means the user may be replaying that material.
  void manualSeek(Duration from, Duration to) {
    if (to < from) {
      _rememberManualReplay(to, from);
    } else {
      _rememberManualReplay(from, from);
      _rememberManualReplay(to, to);
    }
    for (final segment in _segments) {
      _applyManualReplay(segment);
    }
  }

  // Metadata and duration may arrive after a manual seek. Retain exact replay
  // intervals until this occurrence ends, merging overlaps rather than storing
  // position notifications or guessing when a user intended a replay.
  void _rememberManualReplay(Duration start, Duration end) {
    for (var i = _manualSeekRanges.length - 1; i >= 0; i--) {
      final range = _manualSeekRanges[i];
      if (range.$2 < start || range.$1 > end) continue;
      if (range.$1 < start) start = range.$1;
      if (range.$2 > end) end = range.$2;
      _manualSeekRanges.removeAt(i);
    }
    _manualSeekRanges.add((start, end));
  }

  void _applyManualReplay(MediaSegment segment) {
    for (final range in _manualSeekRanges) {
      if (range.$1 < segment.end && range.$2 >= segment.start) {
        _manualReplay.add(_key(segment));
        return;
      }
    }
  }

  void markSkipped(MediaSegment segment) => _attempted.add(_key(segment));

  /// Dismissal lasts until the next playback occurrence, including after seeks
  /// or mode changes. It must never turn into a deferred automatic skip.
  void cancel(MediaSegment segment) => _dismissed.add(_key(segment));

  static String _key(MediaSegment segment) =>
      '${segment.type.name}:${segment.start.inMicroseconds}:${segment.end.inMicroseconds}';

  /// No runtime guesses, chapter-name inference, or clamping invalid endpoints.
  /// Require a known duration and keep only explicit, positive-length bounds.
  static List<MediaSegment> validSegments(Iterable<MediaSegment> segments, {required Duration duration}) {
    if (duration <= Duration.zero) return const [];
    final unique = <String, MediaSegment>{};
    for (final segment in segments) {
      if (!segment.explicitBounds ||
          segment.type == MediaSegmentType.unknown ||
          segment.start < Duration.zero ||
          segment.end <= segment.start ||
          segment.end > duration) {
        continue;
      }
      unique.putIfAbsent(_key(segment), () => segment);
    }
    final sorted = unique.values.toList()
      ..sort((a, b) {
        final startOrder = a.start.compareTo(b.start);
        if (startOrder != 0) return startOrder;
        final endOrder = a.end.compareTo(b.end);
        return endOrder != 0 ? endOrder : a.type.index.compareTo(b.type.index);
      });
    final conflicts = <String>{};
    for (var i = 0; i < sorted.length; i++) {
      for (var j = i + 1; j < sorted.length; j++) {
        if (sorted[j].start >= sorted[i].end) break;
        conflicts.add(_key(sorted[i]));
        conflicts.add(_key(sorted[j]));
      }
    }
    return sorted.where((segment) => !conflicts.contains(_key(segment))).toList();
  }
}
