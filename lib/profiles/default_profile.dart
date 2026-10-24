import 'package:flutter/foundation.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/models/settings/video_player_settings.dart';
import 'package:fladder/profiles/web_profile.dart';
import 'package:fladder/providers/settings/video_player_settings_provider.dart';

final videoProfileProvider = StateProvider.autoDispose<DeviceProfile>(
    (ref) => defaultProfile(ref.watch(videoPlayerSettingsProvider.select((value) => value.wantedPlayer))));

/// Selects the profile sent with a playback request, including live TV.
DeviceProfile? playbackDeviceProfile({
  required DeviceProfile profile,
  required PlayerOptions player,
  required bool liveTv,
}) =>
    liveTv && player != PlayerOptions.nativePlayer ? null : profile;

DeviceProfile defaultProfile(PlayerOptions player) => kIsWeb
    ? webProfile
    : player == PlayerOptions.nativePlayer
        ? _nativeSdrProfile
        : _defaultNonWebProfile;

// Keep the existing MPV/MDK negotiation unchanged. Native/TV has no verified
// display/tone-mapping contract, so it advertises a required SDR input range.
// A server accepting this profile still does not prove that its output is SDR.
final _nativeSdrProfile = _defaultNonWebProfile.copyWith(codecProfiles: const [
  CodecProfile(
    type: CodecType.video,
    conditions: [
      ProfileCondition(
        condition: ProfileConditionType.equalsany,
        property: ProfileConditionValue.videorangetype,
        $Value: 'SDR',
        isRequired: true,
      ),
    ],
  ),
]);

const _defaultNonWebProfile = DeviceProfile(
  maxStreamingBitrate: 120000000,
  maxStaticBitrate: 120000000,
  musicStreamingTranscodingBitrate: 384000,
  directPlayProfiles: [
    DirectPlayProfile(
      type: DlnaProfileType.video,
    ),
    DirectPlayProfile(
      type: DlnaProfileType.audio,
    )
  ],
  transcodingProfiles: [
    TranscodingProfile(
      audioCodec: 'aac,mp3,mp2',
      container: 'ts',
      maxAudioChannels: '2',
      protocol: MediaStreamProtocol.hls,
      type: DlnaProfileType.video,
      videoCodec: 'h264',
    ),
  ],
  containerProfiles: [],
  subtitleProfiles: [
    SubtitleProfile(format: 'vtt', method: SubtitleDeliveryMethod.$external),
    SubtitleProfile(format: 'ass', method: SubtitleDeliveryMethod.$external),
    SubtitleProfile(format: 'ssa', method: SubtitleDeliveryMethod.$external),
    SubtitleProfile(format: 'pgssub', method: SubtitleDeliveryMethod.$external),
  ],
);
