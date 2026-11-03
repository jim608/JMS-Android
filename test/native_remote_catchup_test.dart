import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/models/items/media_streams_model.dart';
import 'package:fladder/models/items/movie_model.dart';
import 'package:fladder/models/playback/direct_playback_model.dart';
import 'package:fladder/models/playback/playback_model.dart';
import 'package:fladder/providers/primary_subtitle_selection_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/util/dual_subtitle.dart';
import 'package:fladder/wrappers/media_control_wrapper.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

SubStreamModel _track(int index) => SubStreamModel(
  id: 'synthetic:$index',
  name: 'Track $index',
  title: 'Track $index',
  displayTitle: 'Track $index',
  language: 'zh-Hant',
  codec: 'srt',
  index: index,
  isDefault: index == 2,
  isExternal: false,
);

DirectPlaybackModel _model() => DirectPlaybackModel(
  item: MovieModel.fromBaseDto(
    const BaseItemDto(id: 'synthetic-item', name: 'Synthetic'),
    null,
  ),
  media: const Media(url: 'https://synthetic.invalid/video'),
  playbackInfo: const PlaybackInfoResponse(playSessionId: 'synthetic-session'),
  mediaStreams: MediaStreamsModel(
    defaultSubStreamIndex: 2,
    versionStreams: [
      VersionStreamModel(
        name: 'Synthetic',
        index: 0,
        id: 'synthetic-source',
        defaultAudioStreamIndex: null,
        defaultSubStreamIndex: 2,
        videoStreams: [],
        audioStreams: [],
        subStreams: [_track(2), _track(8)],
      ),
    ],
  ),
);

// Reuse the startup fixture boundary without initializing a platform renderer.
class _Player extends MediaControlsWrapper {
  _Player({required super.ref, required this.initialResult});
  final int initialResult;
  final secondary = ValueNotifier(const SecondarySubtitleState());
  final requests = <int?>[];
  int plays = 0;

  @override
  bool get hasPlayer => true;
  @override
  ValueNotifier<SecondarySubtitleState> get secondarySubtitleState => secondary;
  @override
  Future<void> stop({bool preserveSleepTimer = false}) async {}
  @override
  Future<void> dispose() async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<int> setAudioTrack(
    AudioStreamModel? model,
    PlaybackModel playbackModel,
  ) async => -1;
  @override
  Future<void> loadVideo(
    PlaybackModel model,
    Duration position,
    bool play, {
    bool Function()? isCurrent,
  }) async {}
  @override
  Future<int> setSubtitleTrack(
    SubStreamModel? track,
    PlaybackModel model,
  ) async {
    requests.add(track?.index);
    return track?.index ?? initialResult;
  }

  @override
  Future<void> play({bool userInitiated = true}) async {
    plays++;
  }
}

class _Notifier extends VideoPlayerNotifier {
  _Notifier(super.ref, _Player player) {
    state = player;
  }
  // Keep the production native initial-subtitle policy.
}

class _NoReload extends Fake implements PlaybackModelHelper {
  @override
  Future<void> shouldReload(PlaybackModel model) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final initialResult in [-1, 0, 2]) {
    test(
      'native startup result $initialResult stays unknown until an explicit subtitle choice',
      () async {
        late _Player player;
        late _Notifier notifier;
        final container = ProviderContainer(
          overrides: [
            videoPlayerProvider.overrideWith((ref) {
              player = _Player(ref: ref, initialResult: initialResult);
              return notifier = _Notifier(ref, player);
            }),
            playbackModelHelper.overrideWithValue(_NoReload()),
          ],
        );
        addTearDown(() {
          container.dispose();
          player.secondary.dispose();
        });
        container.read(videoPlayerProvider);
        // Observe startup so a future accidental confirmation cannot be hidden by
        // creating the subtitle controller only after the load has completed.
        container.read(primarySubtitleSelectionProvider);

        expect(
          await notifier.loadPlaybackItem(_model(), Duration.zero),
          isTrue,
        );
        final startup = container.read(primarySubtitleSelectionProvider);
        expect(startup.appliedIndex, isNull);
        expect(startup.pending, isFalse);
        expect(startup.error, isNull);
        expect(player.requests, [null]);
        expect(player.plays, 1);

        final selection = container.read(
          primarySubtitleSelectionProvider.notifier,
        );
        for (final index in [2, -1, 8]) {
          final result = await selection.select(
            index == -1 ? SubStreamModel.no() : _track(index),
          );
          expect(result.applied, isTrue);
          expect(
            container.read(primarySubtitleSelectionProvider).appliedIndex,
            index,
          );
          expect(
            container.read(playBackModel)?.mediaStreams?.defaultSubStreamIndex,
            index,
          );
        }
        expect(player.requests, [null, 2, -1, 8]);
        expect(player.plays, 1);
      },
      skip: kIsWeb,
    );
  }
}
