import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/models/settings/video_player_settings.dart';

void main() {
  testWidgets('Android retains MPV and Native, but never selects MDK', (tester) async {
    expect(PlayerOptions.available, {PlayerOptions.libMPV, PlayerOptions.nativePlayer});
    final saved = VideoPlayerSettingsModel(playerOptions: PlayerOptions.libMDK);
    expect(saved.wantedPlayer, PlayerOptions.libMPV);
    expect(saved.androidMdkUnavailable, isTrue);
    expect(saved.playerOptions, PlayerOptions.libMDK);
    expect(VideoPlayerSettingsModel.fromJson(saved.toJson()).playerOptions, PlayerOptions.libMDK);
    expect(VideoPlayerSettingsModel().wantedPlayer, PlayerOptions.libMPV);
    expect(VideoPlayerSettingsModel(playerOptions: PlayerOptions.nativePlayer).wantedPlayer, PlayerOptions.nativePlayer);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('Desktop MDK preference remains available and unchanged', (tester) async {
    expect(PlayerOptions.available, contains(PlayerOptions.libMDK));
    final saved = VideoPlayerSettingsModel(playerOptions: PlayerOptions.libMDK);
    expect(saved.wantedPlayer, PlayerOptions.libMDK);
    expect(saved.androidMdkUnavailable, isFalse);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
}
