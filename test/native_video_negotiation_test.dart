import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show BuildContext;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/items/channel_model.dart';
import 'package:fladder/models/media_playback_model.dart';
import 'package:fladder/models/playback/playback_model.dart';
import 'package:fladder/models/playback/tv_playback_model.dart';
import 'package:fladder/models/settings/arguments_model.dart';
import 'package:fladder/models/settings/video_player_settings.dart';
import 'package:fladder/models/syncing/sync_item.dart';
import 'package:fladder/models/video_stream_model.dart';
import 'package:fladder/profiles/default_profile.dart';
import 'package:fladder/providers/settings/video_player_settings_provider.dart';
import 'package:fladder/providers/sync_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/services/playback_diagnostics.dart';
import 'package:fladder/wrappers/media_control_wrapper.dart';

class _Ref extends Fake implements Ref {
  final values = <Object, Object?>{};
  final reads = <Object>[];

  @override
  T read<T>(ProviderListenable<T> provider) {
    reads.add(provider);
    return values[provider] as T;
  }
}

class _PausedPlayer extends Fake implements MediaControlsWrapper {
  var pauses = 0;

  @override
  Future<void> pause() async {
    pauses++;
  }
}

class _NoOfflineItem extends Fake implements SyncNotifier {
  @override
  Future<SyncedItem?> getSyncedItem(String? id) async => null;
}

class _Channel extends Fake implements ChannelModel {
  @override
  String get id => 'synthetic-channel';
}

class _TvModel extends Fake implements TvPlaybackModel {
  _TvModel({this.native = true});

  final bool native;

  @override
  bool get serverManagedQueue => false;

  @override
  bool get isNativePlayerBackend => native;

  @override
  ItemBaseModel get item => throw StateError('Generic VOD reload path entered');
}

class _RejectedTvRequest extends PlaybackModelHelper {
  const _RejectedTvRequest({required super.ref});

  @override
  Future<PlaybackModel?> createPlaybackModel(
    BuildContext? context,
    ItemBaseModel? item, {
    PlaybackModel? oldModel,
    List<ItemBaseModel>? libraryQueue,
    PlaybackQueueSource? queueSource,
    bool showPlaybackOptions = false,
    PlaybackType? forcedPlaybackType,
    Duration? startPosition,
    PlaybackAttemptRef? diagnosticAttempt,
  }) async =>
      null;
}

ProfileCondition? rangeCondition(DeviceProfile profile) {
  final ranges = (profile.codecProfiles ?? const <CodecProfile>[])
      .where((codec) => codec.type == CodecType.video)
      .expand((codec) => codec.conditions ?? const <ProfileCondition>[])
      .where((condition) => condition.property == ProfileConditionValue.videorangetype);
  return ranges.isEmpty ? null : ranges.single;
}

void main() {
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    leanBackMode = false;
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    leanBackMode = false;
  });

  test('Native advertises required SDR range while MPV and MDK keep their profiles', () {
    final native = rangeCondition(defaultProfile(PlayerOptions.nativePlayer));
    expect(native?.$Value, 'SDR');
    expect(native?.isRequired, isTrue);
    expect(rangeCondition(defaultProfile(PlayerOptions.libMPV)), isNull);
    expect(rangeCondition(defaultProfile(PlayerOptions.libMDK)), isNull);
  });

  test('Native profile is selected before any backend initialization', () {
    final container = ProviderContainer(overrides: [
      videoPlayerProvider.overrideWith((ref) => throw StateError('Profile lookup must not initialize a backend')),
    ]);
    addTearDown(container.dispose);
    container.read(videoPlayerSettingsProvider.notifier).applyRestoredSettings(
          VideoPlayerSettingsModel(playerOptions: PlayerOptions.nativePlayer),
        );
    expect(rangeCondition(container.read(videoProfileProvider))?.$Value, 'SDR');
  });

  test('profile follows a switch from Native back to MPV without constructing a player', () async {
    final container = ProviderContainer(overrides: [
      videoPlayerProvider.overrideWith((ref) => throw StateError('Profile lookup must not initialize a backend')),
    ]);
    addTearDown(container.dispose);
    final settings = container.read(videoPlayerSettingsProvider.notifier);
    settings.applyRestoredSettings(VideoPlayerSettingsModel(playerOptions: PlayerOptions.nativePlayer));
    final subscription = container.listen(videoProfileProvider, (_, __) {});
    addTearDown(subscription.close);
    expect(rangeCondition(container.read(videoProfileProvider))?.$Value, 'SDR');
    settings.applyRestoredSettings(VideoPlayerSettingsModel(playerOptions: PlayerOptions.libMPV));
    await container.pump();
    expect(rangeCondition(container.read(videoProfileProvider)), isNull);
  });

  test('Native TV sends its negotiated profile; MPV TV retains the existing null profile', () {
    final native = defaultProfile(PlayerOptions.nativePlayer);
    final request = PlaybackInfoDto(
      deviceProfile: playbackDeviceProfile(profile: native, player: PlayerOptions.nativePlayer, liveTv: true),
    );
    expect(rangeCondition(request.deviceProfile!)?.$Value, 'SDR');
    expect(
      playbackDeviceProfile(profile: defaultProfile(PlayerOptions.libMPV), player: PlayerOptions.libMPV, liveTv: true),
      isNull,
    );
    expect(
      playbackDeviceProfile(profile: native, player: PlayerOptions.nativePlayer, liveTv: false),
      same(native),
    );
  });

  test('Native TV fails closed when server rejects direct playback even with a transcode URL', () {
    const source = MediaSourceInfo(
      supportsDirectPlay: false,
      supportsDirectStream: false,
      supportsTranscoding: true,
      transcodingUrl: 'Videos/synthetic/master.m3u8',
      mediaStreams: [MediaStream(type: MediaStreamType.video, videoRangeType: VideoRangeType.hdr10)],
    );
    expect(nativeTvServerAllowsDirectPlayback(nativePlayer: true, liveTv: true, source: source), isFalse);
    expect(source.mediaStreams!.single.videoRangeType, VideoRangeType.hdr10);
    expect(source.transcodingUrl, 'Videos/synthetic/master.m3u8');
  });

  test('Native TV also rejects unknown server direct permission', () {
    expect(
      nativeTvServerAllowsDirectPlayback(nativePlayer: true, liveTv: true, source: const MediaSourceInfo()),
      isFalse,
    );
  });

  test('either server direct permission allows the existing Native TV path', () {
    for (final source in [
      const MediaSourceInfo(supportsDirectPlay: true),
      const MediaSourceInfo(supportsDirectStream: true),
    ]) {
      expect(nativeTvServerAllowsDirectPlayback(nativePlayer: true, liveTv: true, source: source), isTrue);
    }
  });

  test('MPV TV and non-TV negotiation are unaffected by the Native TV guard', () {
    const source = MediaSourceInfo(supportsDirectPlay: false, supportsDirectStream: false);
    expect(nativeTvServerAllowsDirectPlayback(nativePlayer: false, liveTv: true, source: source), isTrue);
    expect(nativeTvServerAllowsDirectPlayback(nativePlayer: true, liveTv: false, source: source), isTrue);
  });

  test('rejected TV request clears buffering without loading another player', () async {
    final ref = _Ref();
    final player = _PausedPlayer();
    final mediaState = StateController(MediaPlaybackModel());
    addTearDown(mediaState.dispose);
    ref.values[videoPlayerProvider] = player;
    ref.values[mediaPlaybackProvider.notifier] = mediaState;
    ref.values[playBackModel] = null;
    ref.values[syncProvider.notifier] = _NoOfflineItem();

    await _RejectedTvRequest(ref: ref).loadTVChannel(_Channel());

    expect(player.pauses, 1);
    expect(mediaState.state.buffering, isFalse);
    expect(ref.reads, isNot(contains(videoPlayerProvider.notifier)));
  });

  test('Native TV local track changes do not enter generic VOD renegotiation', () async {
    final ref = _Ref();
    ref.values[videoPlayerSettingsProvider] = VideoPlayerSettingsModel(playerOptions: PlayerOptions.libMPV);

    await PlaybackModelHelper(ref: ref).shouldReload(_TvModel());

    expect(ref.reads, isEmpty);
  });

  test('MPV TV keeps its existing reload path even after settings change to Native', () async {
    final ref = _Ref();
    ref.values[videoPlayerSettingsProvider] = VideoPlayerSettingsModel(playerOptions: PlayerOptions.nativePlayer);

    await expectLater(
      PlaybackModelHelper(ref: ref).shouldReload(_TvModel(native: false)),
      throwsA(isA<StateError>().having((error) => error.message, 'message', 'Generic VOD reload path entered')),
    );
  });
}
