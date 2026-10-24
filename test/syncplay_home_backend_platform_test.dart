import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/models/settings/arguments_model.dart';
import 'package:fladder/models/settings/video_player_settings.dart';
import 'package:fladder/profiles/default_profile.dart';
import 'package:fladder/profiles/web_profile.dart';
import 'package:fladder/wrappers/media_control_wrapper.dart';
import 'package:fladder/wrappers/players/lib_mdk.dart'
    if (dart.library.html) 'package:fladder/stubs/web/lib_mdk_web.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late bool initialLeanBackMode;

  setUp(() {
    initialLeanBackMode = leanBackMode;
    leanBackMode = false;
  });
  tearDown(() {
    leanBackMode = initialLeanBackMode;
    debugDefaultTargetPlatformOverride = null;
  });

  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    test(
        '$platform resolves restored backends without changing stored settings',
        () {
      debugDefaultTargetPlatformOverride = platform;
      for (final saved in <PlayerOptions?>[null, ...PlayerOptions.values]) {
        final settings = VideoPlayerSettingsModel(playerOptions: saved);
        final expected = !kIsWeb &&
                platform == TargetPlatform.android &&
                saved == PlayerOptions.nativePlayer
            ? PlayerOptions.nativePlayer
            : PlayerOptions.libMPV;
        expect(settings.wantedPlayer, expected,
            reason: 'stored choice: $saved');
        expect(settings.playerOptions, saved);
        expect(settings.toJson()['playerOptions'], saved?.name);
      }
    });

    test('$platform lean-back mode stays on an available runtime backend', () {
      debugDefaultTargetPlatformOverride = platform;
      leanBackMode = true;
      final settings =
          VideoPlayerSettingsModel(playerOptions: PlayerOptions.libMDK);
      expect(
          settings.wantedPlayer,
          !kIsWeb && platform == TargetPlatform.android
              ? PlayerOptions.nativePlayer
              : PlayerOptions.libMPV);
      expect(settings.playerOptions, PlayerOptions.libMDK);
    });
  }

  test('iOS runtime selection retains its existing deferred-platform behavior',
      () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final settings =
        VideoPlayerSettingsModel(playerOptions: PlayerOptions.libMDK);
    expect(settings.wantedPlayer,
        kIsWeb ? PlayerOptions.libMPV : PlayerOptions.libMDK);
    leanBackMode = true;
    expect(settings.wantedPlayer,
        kIsWeb ? PlayerOptions.libMPV : PlayerOptions.nativePlayer);
    expect(settings.playerOptions, PlayerOptions.libMDK);
  });

  test('actual Web execution always negotiates the Web media profile', () {
    expect(kIsWeb, isTrue);
    for (final platform in [
      TargetPlatform.android,
      TargetPlatform.windows,
      TargetPlatform.linux
    ]) {
      debugDefaultTargetPlatformOverride = platform;
      for (final saved in <PlayerOptions?>[null, ...PlayerOptions.values]) {
        final settings = VideoPlayerSettingsModel(playerOptions: saved);
        expect(settings.wantedPlayer, PlayerOptions.libMPV);
        expect(defaultProfile(settings.wantedPlayer), same(webProfile));
      }
    }
  }, skip: !kIsWeb);

  test('actual Web MDK stub cannot claim SyncPlay support', () async {
    expect(kIsWeb, isTrue);
    final provider =
        Provider<MediaControlsWrapper>((ref) => MediaControlsWrapper(ref: ref));
    final container = ProviderContainer();
    final wrapper = container.read(provider);
    try {
      // The conditional import is the no-op Web stub. Do not initialize any
      // native renderer or load media; this checks runtime capability only.
      await wrapper.setup(LibMDK());
      expect(wrapper.hasPlayer, isTrue);
      expect(wrapper.backend, PlayerOptions.libMDK);
      expect(wrapper.supportsSyncPlay, isFalse);
    } finally {
      await wrapper.dispose();
      container.dispose();
    }
  }, skip: !kIsWeb);
}
