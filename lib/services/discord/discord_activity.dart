import 'dart:convert';

/// Only explicitly selected display fields enter Discord activity payloads.
/// Service clients, account data, artwork URLs and credentials stay outside it.
class DiscordPlaybackSnapshot {
  const DiscordPlaybackSnapshot({
    required this.active,
    required this.title,
    required this.playing,
    this.buffering = false,
    this.audio = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.rate = 1.0,
  });

  final bool active;
  final String title;
  final bool playing;
  final bool buffering;
  final bool audio;
  final Duration position;
  final Duration duration;
  final double rate;
}

String? discordDisplayTitle(String value) {
  final clean = value.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
  if (clean.isEmpty ||
      RegExp(r'\b[a-z][a-z0-9+.-]*://|[a-zA-Z]:[\\/]|\\\\|(?:^|\s)/[^\s]|(?:token|api[_ -]?key|password|cookie)\s*[:=]',
              caseSensitive: false)
          .hasMatch(clean)) {
    return null;
  }
  // Discord text fields are bounded; preserve full Unicode code points.
  final result = StringBuffer();
  var bytes = 0;
  for (final rune in clean.runes) {
    final character = String.fromCharCode(rune);
    final length = utf8.encode(character).length;
    if (bytes + length > 128) break;
    result.write(character);
    bytes += length;
  }
  final title = result.toString();
  return title.runes.length < 2 ? '$title ' : title;
}

Map<String, Object?>? discordActivity(
  DiscordPlaybackSnapshot? playback, {
  required bool shareTitle,
  required DateTime now,
}) {
  if (playback == null || !playback.active) return null;
  final title = shareTitle ? discordDisplayTitle(playback.title) : null;
  final state =
      playback.buffering ? '正在緩衝' : (playback.playing ? '正在播放' : '已暫停');
  final activity = <String, Object?>{
    'type': playback.audio ? 2 : 3,
    'details': title ?? 'JMS 媒體播放',
    'state': state,
  };
  // Paused/buffering playback must not keep a misleading running countdown.
  if (playback.playing &&
      !playback.buffering &&
      playback.duration > Duration.zero &&
      playback.position >= Duration.zero &&
      playback.position < playback.duration &&
      playback.rate.isFinite &&
      playback.rate > 0) {
    final current = now.millisecondsSinceEpoch ~/ 1000;
    final elapsed =
        (playback.position.inMilliseconds / (1000 * playback.rate)).floor();
    final remaining = ((playback.duration - playback.position).inMilliseconds /
            (1000 * playback.rate))
        .ceil();
    activity['timestamps'] = <String, int>{
      'start': current - elapsed,
      'end': current + remaining
    };
  }
  return activity;
}
