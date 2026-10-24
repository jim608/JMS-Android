/// Native media-kit buffer timestamps are absolute media endpoints.
Duration mpvSyncPlayBufferAhead({required Duration position, required Duration bufferEnd}) =>
    bufferEnd > position ? bufferEnd - position : Duration.zero;

/// Optional demuxer-cache-state/fw-bytes readback; absent/malformed is unknown.
int? mpvSyncPlayForwardBytes(String? raw) {
  final bytes = int.tryParse(raw?.trim() ?? '');
  return bytes != null && bytes >= 0 ? bytes : null;
}

enum MpvSyncPlayBufferSettingStatus { verified, unverified, failed }

class MpvSyncPlayBufferSetting {
  const MpvSyncPlayBufferSetting(this.status, this.requestedBytes, this.actualBytes);
  final MpvSyncPlayBufferSettingStatus status;
  final int requestedBytes;
  final int? actualBytes;
}

/// Verifies the option, not available memory, cache activity or throughput.
/// NativePlayer.setProperty currently discards mpv's return code: a completed
/// Future is insufficient. Unknown/unsupported readback stays unverified.
Future<MpvSyncPlayBufferSetting> capMpvSyncPlayForwardBuffer({
  required Future<String?> Function(String property) read,
  required Future<void> Function(String property, String value) write,
  int requestedBytes = maximumMpvSyncPlayForwardBytes,
  Duration timeout = const Duration(seconds: 2),
}) async {
  if (requestedBytes <= 0) throw ArgumentError.value(requestedBytes, 'requestedBytes');
  var target = requestedBytes.clamp(1, maximumMpvSyncPlayForwardBytes);
  try {
    final existing = int.tryParse((await read('demuxer-max-bytes').timeout(timeout))?.trim() ?? '');
    // Respect an already smaller forward-cache limit rather than raising it.
    if (existing != null && existing > 0 && existing < target) target = existing;
    await write('demuxer-max-bytes', '$target').timeout(timeout);
    final actual = int.tryParse((await read('demuxer-max-bytes').timeout(timeout))?.trim() ?? '');
    return MpvSyncPlayBufferSetting(
      actual == target ? MpvSyncPlayBufferSettingStatus.verified : MpvSyncPlayBufferSettingStatus.unverified,
      target,
      actual,
    );
  } catch (_) {
    return MpvSyncPlayBufferSetting(MpvSyncPlayBufferSettingStatus.failed, target, null);
  }
}

const maximumMpvSyncPlayForwardBytes = 150 * 1024 * 1024;
