import 'package:media_kit/media_kit.dart' as mpv;
import 'package:web/web.dart' as web;

import 'package:fladder/services/syncplay/syncplay_prebuffer.dart';
import 'package:fladder/util/syncplay_buffer_probe.dart';
import 'package:fladder/util/web_syncplay_buffer.dart';

SyncPlayBufferSample? readWebSyncPlayBufferSample(Object? platform, {DateTime Function()? now}) {
  try {
    if (platform is! mpv.WebPlayer) return null;
    final player = platform as dynamic;
    if (player.disposed as bool) return null;
    return readWebSyncPlayElement(player.element as web.HTMLVideoElement, now: now);
  } catch (_) {
    return null;
  }
}

/// Synchronous scalar/TimeRanges copy; never reads src/currentSrc or other
/// identifying metadata, and never substitutes media-kit's last range end.
SyncPlayBufferSample readWebSyncPlayElement(web.HTMLVideoElement element, {DateTime Function()? now}) {
  final clock = now ?? DateTime.now;
  final started = clock();
  try {
    final position = syncPlayMeasuredMediaTime('${element.currentTime}');
    if (position == null) return unknownSyncPlayBufferSample(now: clock);
    List<SyncPlayBufferedRange>? ranges;
    try {
      final buffered = element.buffered;
      if (buffered.length <= 1024) {
        ranges = [for (var i = 0; i < buffered.length; i++) SyncPlayBufferedRange(buffered.start(i), buffered.end(i))];
      }
    } catch (_) {
      // A missing/throwing browser range API is unknown, not a fabricated zero.
    }
    return SyncPlayBufferSample(
      position: position,
      bufferEnd: webSyncPlayContiguousBufferEnd(position: position, ranges: ranges),
      duration: syncPlayMeasuredMediaTime('${element.duration}'),
      buffering: element.readyState < 3,
      preparing: element.seeking,
      observedAt: started,
    );
  } catch (_) {
    return unknownSyncPlayBufferSample(now: clock);
  }
}
