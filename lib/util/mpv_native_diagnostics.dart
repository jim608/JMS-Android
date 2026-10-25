/// Pure policy: only a positively confirmed native software texture permits
/// this per-player override. Unknown capabilities and unrelated media errors
/// never disable acceleration. The saved preference is left intact.
bool useLinuxFlatpakSoftwareDecodeFallback({
  required bool linux,
  required bool flatpak,
  required bool hardwareRequested,
  required bool softwareRenderConfirmed,
}) =>
    linux && flatpak && hardwareRequested && softwareRenderConfirmed;

/// Bounded canonical state transitions, never a position or buffer history.
class MpvPlaybackTransitions {
  MpvPlaybackTransitions({this.limit = 16});
  final int limit;
  int _emitted = 0;
  String? _last;

  String? sample({
    required bool playing,
    required bool buffering,
    required Duration buffer,
    required Duration position,
  }) {
    if (_emitted >= limit) return null;
    final ahead = buffer - position;
    final bucket = ahead <= Duration.zero
        ? 'empty'
        : ahead < const Duration(seconds: 1)
            ? 'lt1s'
            : ahead < const Duration(seconds: 5)
                ? '1to5s'
                : ahead < const Duration(seconds: 15)
                    ? '5to15s'
                    : 'gte15s';
    final next = 'playing=$playing;buffering=$buffering;cache_ahead=$bucket';
    if (next == _last) return null;
    _last = next;
    _emitted++;
    return next;
  }
}

/// Native strings are classified in memory and then discarded. Never return
/// the message, URL, file path, arbitrary prefix, or arbitrary property value.
class MpvNativeFailure {
  const MpvNativeFailure(
    this.errorClass, {
    this.httpStatus,
    this.timedOut = false,
    this.cancelled = false,
  });

  final String errorClass;
  final int? httpStatus;
  final bool timedOut;
  final bool cancelled;

  factory MpvNativeFailure.classify(String message, {String prefix = ''}) {
    final text = message
        .substring(0, message.length > 4096 ? 4096 : message.length)
        .toLowerCase();
    final status = RegExp(
      r'(?:http(?: error)?|server returned|status(?: code)?)[\s:]+([45]\d\d)\b',
    ).firstMatch(text);
    final httpStatus = int.tryParse(status?.group(1) ?? '');
    if (httpStatus != null) {
      return MpvNativeFailure(
        'native_http',
        httpStatus: httpStatus,
        timedOut: httpStatus == 408 || httpStatus == 504,
      );
    }
    if (text.contains('timed out') || text.contains('timeout')) {
      return const MpvNativeFailure('native_timeout', timedOut: true);
    }
    if (text.contains('cancelled') ||
        text.contains('canceled') ||
        text.contains('operation aborted')) {
      return const MpvNativeFailure('native_cancelled', cancelled: true);
    }
    if (text.contains('connection') ||
        text.contains('resolve host') ||
        text.contains('network') ||
        text.contains('tls') ||
        text.contains('certificate')) {
      return const MpvNativeFailure('native_network');
    }
    if (text.contains('read error') ||
        text.contains('i/o error') ||
        text.contains('input/output error') ||
        text.contains('partial file')) {
      return const MpvNativeFailure('native_read');
    }
    final source = safeMpvNativeSource(prefix);
    if (source == 'video_output') {
      return const MpvNativeFailure('native_video_output');
    }
    if (source == 'audio_output') {
      return const MpvNativeFailure('native_audio_output');
    }
    if (source == 'decoder' ||
        text.contains('decoder') ||
        text.contains('decoding')) {
      return const MpvNativeFailure('native_decoder');
    }
    if (source == 'demuxer' ||
        text.contains('demux') ||
        text.contains('unrecognized file format')) {
      return const MpvNativeFailure('native_demuxer');
    }
    if (text.contains('failed to open') || text.contains('loading failed')) {
      return const MpvNativeFailure('native_open');
    }
    return const MpvNativeFailure('native_unknown');
  }
}

String safeMpvNativeSource(String value) {
  if (value.length > 64) return 'unknown';
  final prefix = value.toLowerCase();
  if (prefix == 'vd' || prefix.startsWith('vd/')) return 'decoder';
  if (prefix == 'vo' || prefix.startsWith('vo/')) return 'video_output';
  if (prefix == 'ao' || prefix.startsWith('ao/')) return 'audio_output';
  if (prefix == 'demux' || prefix.startsWith('demux/')) return 'demuxer';
  if (prefix == 'stream' || prefix.startsWith('stream/')) return 'network';
  if (prefix == 'cplayer') return 'player';
  return 'unknown';
}

String safeMpvCodec(String value) => const {
      'h264',
      'hevc',
      'h265',
      'vp8',
      'vp9',
      'av1',
      'mpeg1video',
      'mpeg2video',
      'mpeg4',
      'vc1',
      'theora',
      'mjpeg',
      'prores',
      'aac',
      'ac3',
      'eac3',
      'dts',
      'truehd',
      'flac',
      'mp3',
      'opus',
      'vorbis',
      'alac',
      'pcm_s16le',
      'pcm_s24le',
    }.contains(value.toLowerCase().trim())
        ? value.toLowerCase().trim()
        : 'unknown';

String safeMpvHwdec(String value) => const {
      'no',
      'auto',
      'auto-copy',
      'vaapi',
      'vaapi-copy',
      'vdpau',
      'vdpau-copy',
      'nvdec',
      'nvdec-copy',
      'videotoolbox',
      'videotoolbox-copy',
      'd3d11va',
      'd3d11va-copy',
      'dxva2',
      'dxva2-copy',
      'cuda',
      'cuda-copy',
      'mediacodec',
      'mediacodec-copy',
      'drm',
      'drm-copy',
    }.contains(value.toLowerCase().trim())
        ? value.toLowerCase().trim()
        : 'unknown';

String safeMpvErrorClass(Object error) {
  final type = error.runtimeType.toString();
  return const {
    'TimeoutException',
    'StateError',
    'ArgumentError',
    'FormatException',
    'UnsupportedError',
    'PlatformException',
    'MissingPluginException',
    'Exception',
    'NativePlayerException',
  }.contains(type)
      ? type
      : 'PlayerException';
}
