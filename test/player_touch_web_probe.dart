import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_plus/iconsax_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/l10n/generated/app_localizations.dart';
import 'package:fladder/models/items/movie_model.dart';
import 'package:fladder/models/media_playback_model.dart';
import 'package:fladder/models/playback/playback_model.dart';
import 'package:fladder/models/settings/video_player_settings.dart';
import 'package:fladder/providers/pip_provider.dart';
import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/screens/video_player/video_player_controls.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout_model.dart';
import 'package:fladder/util/input_detector.dart';
import 'package:fladder/util/poster_defaults.dart';
import 'package:fladder/wrappers/media_control_wrapper.dart';
import 'package:fladder/wrappers/players/lib_mpv.dart';
import 'package:fladder/wrappers/players/player_states.dart';

// Test-only browser entrypoint. The actual player surface and controls use only
// generated loopback media; account, server and playback-reporting paths are
// replaced by the in-memory adapter below.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final item = MovieModel.fromBaseDto(
    const BaseItemDto(id: 'touch-browser-fixture', name: 'Synthetic touch video'),
    null,
  );
  runApp(ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      sharedUtilityProvider.overrideWith(
        (ref) => SharedUtility(ref: ref, sharedPreferences: preferences),
      ),
      videoPlayerProvider.overrideWith((ref) => _FixtureNotifier(ref)),
      playBackModel.overrideWith((ref) => PlaybackModel(
            item: item,
            media: null,
            playbackInfo: null,
            mediaStreams: item.mediaStreams,
          )),
      mediaPlaybackProvider.overrideWith((ref) => MediaPlaybackModel(
            state: VideoPlayerState.fullScreen,
            duration: const Duration(seconds: 12),
          )),
      pipStateProvider.overrideWith((ref) => Stream.value(false)),
    ],
    child: MaterialApp(
      title: 'Local touch player probe',
      theme: ThemeData.dark(useMaterial3: true),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      locale: const Locale('en'),
      builder: (context, child) {
        final size = MediaQuery.sizeOf(context);
        return InputDetector(
          isDesktop: false,
          htpcMode: false,
          child: (input) => AdaptiveLayout(
            data: AdaptiveLayoutModel(
              viewSize: size.width < 600 ? ViewSize.phone : ViewSize.tablet,
              layoutMode: LayoutMode.single,
              inputDevice: input,
              controllerMode: false,
              platform: Theme.of(context).platform,
              isDesktop: false,
              posterDefaults: const PosterDefaults(size: 280, ratio: 0.55),
              controller: const {},
              sideBarWidth: 0,
              topBarHeight: 0,
              statusBarHeight: 0,
            ),
            child: child!,
          ),
        );
      },
      home: const _TouchProbe(),
    ),
  ));
}

Uri? _fixtureMedia() {
  final input = Uri.base.queryParameters['media'];
  final uri = input == null ? Uri.base.resolve('/touch-fixture.mp4') : Uri.tryParse(input);
  if (uri == null ||
      uri.scheme != 'http' ||
      !{'127.0.0.1', 'localhost', '::1'}.contains(uri.host) ||
      uri.userInfo.isNotEmpty ||
      uri.port < 1 ||
      uri.port > 65535 ||
      uri.path != '/touch-fixture.mp4' ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  return uri;
}

class _FixtureNotifier extends VideoPlayerNotifier {
  _FixtureNotifier(super.ref) {
    state = _FixturePlayer(ref);
  }

  @override
  Future<void> init() => state.init();
}

class _FixturePlayer extends MediaControlsWrapper {
  _FixturePlayer(Ref ref) : super(ref: ref);

  final engine = LibMPV();
  StreamSubscription<PlayerState>? _subscription;
  bool initialized = false;
  bool _closed = false;

  @override
  bool get hasPlayer => initialized;

  @override
  PlayerOptions? get backend => PlayerOptions.libMPV;

  @override
  PlayerState get lastState => engine.lastState;

  @override
  Stream<PlayerState> get stateStream => engine.stateStream;

  @override
  Future<void> init({PlayerOptions? overridePlayer}) async {
    if (initialized || _closed) return;
    _subscription = engine.stateStream.listen((value) {
      if (_closed) return;
      ref.read(mediaPlaybackProvider.notifier).update((state) => state.copyWith(
            playing: value.playing,
            buffering: value.buffering,
            position: value.position,
            duration: value.duration,
            buffer: value.buffer,
            completed: value.completed,
          ));
    });
    await engine.init(VideoPlayerSettingsModel(ambientBlur: false));
    initialized = true;
  }

  Future<void> start(Uri uri, VoidCallback initializedSurface) async {
    await init();
    initializedSurface();
    await engine.loadVideo(uri.toString(), true);
    await engine.loop(true);
  }

  @override
  Widget? videoWidget(Key key, BoxFit fit) => engine.videoWidget(key, fit);

  @override
  Widget? subtitleWidget(bool showOverlay, {GlobalKey? controlsKey}) =>
      engine.subtitles(showOverlay, controlsKey: controlsKey);

  @override
  Future<void> play({bool userInitiated = true}) => engine.play();

  @override
  Future<void> pause() => engine.pause();

  @override
  Future<void> playOrPause() => engine.playOrPause();

  @override
  Future<void> seek(Duration position) => engine.seek(position);

  @override
  Future<void> setVolume(double volume) => engine.setVolume(volume);

  @override
  Future<void> setSpeed(double speed) => engine.setSpeed(speed);

  @override
  Future<void> stop({bool preserveSleepTimer = false}) => engine.stop();

  @override
  Future<Map<String, String>> playbackDiagnostics() => engine.playbackDiagnostics();

  @override
  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    await _subscription?.cancel();
    await engine.dispose();
  }
}

class _TouchProbe extends ConsumerStatefulWidget {
  const _TouchProbe();

  @override
  ConsumerState<_TouchProbe> createState() => _TouchProbeState();
}

class _TouchProbeState extends ConsumerState<_TouchProbe> {
  final _controlsKey = GlobalKey();
  final _videoKey = const ValueKey('touch-fixture-video');
  SemanticsHandle? _semantics;
  Timer? _refresh;
  late final Uri? _media = _fixtureMedia();
  bool _busy = false;
  bool _loaded = false;
  String _visibility = 'unmounted';
  String? _error;

  @override
  void initState() {
    super.initState();
    _semantics = WidgetsBinding.instance.ensureSemantics();
    _refresh = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted) {
        // Inspect the completed tree between builds, never during build.
        _visibility = _controlsVisibility();
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _refresh?.cancel();
    _semantics?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final uri = _media;
    if (_busy || _loaded || uri == null) return;
    setState(() => _busy = true);
    try {
      final player = ref.read(videoPlayerProvider) as _FixturePlayer;
      // Invoked only by the Start button's user gesture, never by a timer.
      await player.start(uri, () {
        if (mounted) setState(() {});
      });
      if (mounted) setState(() => _loaded = true);
    } catch (error) {
      if (mounted) setState(() => _error = error.runtimeType.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _controlsVisibility() {
    String result = 'unmounted';
    void inspect(Element element) {
      final widget = element.widget;
      if (widget is Icon && widget.icon == IconsaxPlusLinear.more) {
        element.visitAncestorElements((ancestor) {
          final widget = ancestor.widget;
          if (widget is AnimatedOpacity) {
            result = widget.opacity == 1 ? 'visible' : 'hidden';
            return false;
          }
          return true;
        });
      }
      element.visitChildElements(inspect);
    }

    _controlsKey.currentContext?.visitChildElements(inspect);
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(videoPlayerProvider) as _FixturePlayer;
    final playback = ref.watch(mediaPlaybackProvider);
    final size = MediaQuery.sizeOf(context);
    final input = AdaptiveLayout.inputDeviceOf(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          player.videoWidget(_videoKey, BoxFit.contain) ?? const ColoredBox(color: Colors.black),
          DesktopControls(key: _controlsKey),
          if (!_loaded)
            Center(
              child: FilledButton(
                onPressed: !_busy && _media != null ? _start : null,
                child: Text(_busy ? 'Loading fixture' : 'Start fixture'),
              ),
            ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Semantics(
                container: true,
                label: 'touch-probe ready=${player.initialized} '
                    'loaded=$_loaded playing=${playback.playing} '
                    'buffering=${playback.buffering} '
                    'positionMs=${playback.position.inMilliseconds} '
                    'durationMs=${playback.duration.inMilliseconds} '
                    'controls=$_visibility input=${input.name} '
                    'viewport=${size.width.toInt()}x${size.height.toInt()} '
                    'fullscreen=${playback.fullScreen} '
                    'error=${_error ?? (_media == null ? 'invalid-loopback-media' : 'none')}',
                child: ExcludeSemantics(
                  child: Text(
                    'LOCAL SYNTHETIC VIDEO | ${size.width.toInt()}x${size.height.toInt()} '
                    '| ${input.name} | $_visibility '
                    '| ${playback.playing ? 'playing' : 'paused'} '
                    '| ${_error ?? 'no error'}',
                    style: const TextStyle(fontSize: 10, color: Colors.amber),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
