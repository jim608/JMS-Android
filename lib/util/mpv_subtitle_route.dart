typedef ReadMpvProperty = Future<String> Function(String name);
typedef WriteMpvProperty = Future<void> Function(String name, String value);

bool isStyledSubtitle(String codec) => const {'ass', 'ssa'}.contains(codec.trim().toLowerCase());

String activeAssEffects(String event) {
  if (event.isEmpty) return 'unknown / no active cue';
  final tags = RegExp(r'\\(pos|move|fad|t|i?clip|p|k[fo]?)(?=[(\d])', caseSensitive: false)
      .allMatches(event)
      .map((match) => match.group(1)!.toLowerCase())
      .toSet()
      .toList()
    ..sort();
  return tags.isEmpty ? 'none in active cue (not whole track)' : tags.join(', ');
}

bool useNativeSubtitle(String codec, bool plainTextPreference) =>
    isStyledSubtitle(codec) || plainTextPreference || !const {'srt', 'subrip', 'webvtt', 'vtt', 'text'}.contains(codec);

class MpvSubtitleRoute {
  final String codec;
  final String expectedCodec;
  final String sid;
  final String ass;
  final String override;
  final String visibility;
  final bool plainOverlay;

  const MpvSubtitleRoute({
    this.codec = '',
    this.expectedCodec = '',
    this.sid = '',
    this.ass = '',
    this.override = '',
    this.visibility = '',
    this.plainOverlay = false,
  });

  String get renderer {
    if (sid == 'no') return 'off';
    if (isStyledSubtitle(expectedCodec) && codec.isNotEmpty && !isStyledSubtitle(codec)) {
      return 'ASS source format mismatch ($codec); effects unavailable';
    }
    if (plainOverlay) return 'Flutter text (native hidden)';
    if (codec.isEmpty || visibility != 'yes') return 'unknown';
    if (isStyledSubtitle(codec) && (ass != 'yes' || override != 'no')) return 'ASS configuration mismatch';
    return const {'ass', 'ssa', 'subrip', 'srt', 'text', 'webvtt', 'vtt'}.contains(codec)
        ? 'mpv native/libass'
        : 'mpv native (bitmap/other)';
  }

  static Future<String> selectedCodec(ReadMpvProperty read) async {
    final sid = await read('sid');
    if (sid.isEmpty || sid == 'no') return '';
    final count = (int.tryParse(await read('track-list/count')) ?? 0).clamp(0, 128);
    for (var index = 0; index < count; index++) {
      if (await read('track-list/$index/type') == 'sub' && await read('track-list/$index/id') == sid) {
        return (await read('track-list/$index/codec')).trim().toLowerCase();
      }
    }
    return '';
  }

  static Future<MpvSubtitleRoute> configure({
    required ReadMpvProperty read,
    required WriteMpvProperty write,
    required String expectedCodec,
    required bool plainTextPreference,
  }) async {
    final codec = await selectedCodec(read);
    final native = isStyledSubtitle(expectedCodec) ||
        useNativeSubtitle(codec.isEmpty ? expectedCodec.trim().toLowerCase() : codec, plainTextPreference);
    await write('sub-ass', 'yes');
    await write('sub-ass-override', 'no');
    await write('embeddedfonts', 'yes');
    await write('sub-visibility', native ? 'yes' : 'no');
    final visibility = await read('sub-visibility');
    return MpvSubtitleRoute(
      codec: codec,
      expectedCodec: expectedCodec,
      sid: await read('sid'),
      ass: await read('sub-ass'),
      override: await read('sub-ass-override'),
      visibility: visibility,
      plainOverlay: !native && visibility == 'no',
    );
  }
}
