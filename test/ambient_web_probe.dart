import 'dart:async';
import 'dart:ui' as ui;

import 'package:fladder/models/settings/video_player_settings.dart';
import 'package:fladder/widgets/shared/ambient_blur.dart';
import 'package:fladder/wrappers/players/lib_mpv.dart';
import 'package:fladder/wrappers/players/player_states.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

// Browser acceptance harness only. It uses the production player and ambient
// capture path with an anonymous, generated loopback video, never an account.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(MaterialApp(
    title: 'Web ambient fixture',
    theme: ThemeData.dark(useMaterial3: true),
    home: const AmbientWebProbe(),
  ));
}

Uri? _fixtureMedia() {
  final input = Uri.base.queryParameters['media'];
  final uri = input == null
      ? Uri.base.resolve('/ambient-fixture.mp4')
      : Uri.tryParse(input);
  if (uri == null ||
      uri.scheme != 'http' ||
      !{'127.0.0.1', 'localhost', '::1'}.contains(uri.host) ||
      uri.userInfo.isNotEmpty ||
      uri.port < 1 ||
      uri.port > 65535 ||
      uri.path != '/ambient-fixture.mp4' ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  return uri;
}

class AmbientWebProbe extends StatefulWidget {
  const AmbientWebProbe({super.key});

  @override
  State<AmbientWebProbe> createState() => _AmbientWebProbeState();
}

class _AmbientWebProbeState extends State<AmbientWebProbe> {
  final _player = LibMPV();
  final _diagnostics = AmbientBlurDiagnostics()..enabled = true;
  final _videoKey = const ValueKey('ambient-fixture-video');
  late final Future<ui.Image?> Function(double) _captureFrame;
  StreamSubscription<PlayerState>? _subscription;
  Timer? _refresh;
  SemanticsHandle? _semantics;
  PlayerState _state = PlayerState();
  Uri? _media;
  bool _ready = false;
  bool _busy = false;
  bool _loaded = false;
  bool _ambientEnabled = true;
  bool _portrait = false;
  BoxFit _fit = BoxFit.contain;
  String? _error;

  @override
  void initState() {
    super.initState();
    _media = _fixtureMedia();
    _captureFrame = _player.captureAmbientFrame;
    _semantics = WidgetsBinding.instance.ensureSemantics();
    _subscription = _player.stateStream.listen((state) {
      if (mounted) setState(() => _state = state);
    });
    _refresh = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted) setState(() {});
    });
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await _player.init(VideoPlayerSettingsModel(ambientBlur: true));
      if (!mounted) {
        await _player.dispose();
        return;
      }
      setState(() {
        _ready = true;
        if (_media == null) _error = '測試影片網址必須是指定的本機合成影片。';
      });
    } catch (_) {
      if (mounted) setState(() => _error = '播放器初始化失敗。');
    }
  }

  Future<void> _load() async {
    final media = _media;
    if (!_ready || _busy || media == null) return;
    setState(() {
      _busy = true;
      _loaded = false;
      _error = null;
    });
    try {
      // The button invokes loadVideo directly in its user gesture. Playback is
      // not started by a timer, page load, or an automated production login.
      await _player.loadVideo(media.toString(), true);
      await _player.loop(true);
      if (mounted) setState(() => _loaded = true);
    } catch (_) {
      if (mounted) setState(() => _error = '合成測試影片載入失敗。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _play() async {
    try {
      await _player.play();
    } catch (_) {
      if (mounted) setState(() => _error = '測試影片無法播放。');
    }
  }

  Future<void> _pause() async {
    try {
      await _player.pause();
    } catch (_) {
      if (mounted) setState(() => _error = '測試影片無法暫停。');
    }
  }

  @override
  void dispose() {
    _refresh?.cancel();
    unawaited(_subscription?.cancel() ?? Future<void>.value());
    _diagnostics.enabled = false;
    // clearPreview may defer its notification during framework disposal.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _diagnostics.preview.dispose();
    });
    _semantics?.dispose();
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewport = _portrait ? const Size(400, 800) : const Size(800, 600);
    final status = 'ready=$_ready loaded=$_loaded '
        'playing=${_state.playing} buffering=${_state.buffering}\n'
        'position=${_state.position.inMilliseconds} '
        'duration=${_state.duration.inMilliseconds}\n'
        'captures=${_diagnostics.captures} failures=${_diagnostics.failures} '
        'inFlight=${_diagnostics.inFlight} size=${_diagnostics.size}\n'
        'source=${_diagnostics.source} sample=${_diagnostics.sampleStatus}\n'
        'change=${_diagnostics.contentChange} '
        'videoRect=${_diagnostics.videoRect} '
        'allocated=${_diagnostics.allocated} released=${_diagnostics.released}';
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Web 環境光本機驗證：匿名合成影片'),
                Wrap(
                  spacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    FilledButton(
                      onPressed:
                          _ready && !_busy && _media != null ? _load : null,
                      child: const Text('載入測試影片'),
                    ),
                    OutlinedButton(
                      onPressed: _loaded && !_busy ? _play : null,
                      child: const Text('播放'),
                    ),
                    OutlinedButton(
                      onPressed: _loaded && !_busy ? _pause : null,
                      child: const Text('暫停'),
                    ),
                    const Text('環境光'),
                    Switch(
                      value: _ambientEnabled,
                      onChanged: (value) =>
                          setState(() => _ambientEnabled = value),
                    ),
                    DropdownButton<BoxFit>(
                      value: _fit,
                      onChanged: (value) {
                        if (value != null) setState(() => _fit = value);
                      },
                      items: const [
                        DropdownMenuItem(
                            value: BoxFit.contain, child: Text('完整影片')),
                        DropdownMenuItem(
                            value: BoxFit.cover, child: Text('填滿畫面')),
                      ],
                    ),
                    ChoiceChip(
                      label: const Text('800 × 600'),
                      selected: !_portrait,
                      onSelected: (_) => setState(() => _portrait = false),
                    ),
                    ChoiceChip(
                      label: const Text('400 × 800'),
                      selected: _portrait,
                      onSelected: (_) => setState(() => _portrait = true),
                    ),
                  ],
                ),
                Semantics(
                  container: true,
                  label: status,
                  child: ExcludeSemantics(child: Text(status)),
                ),
                if (_error != null)
                  Text(_error!,
                      style: const TextStyle(color: Colors.redAccent)),
                const SizedBox(height: 8),
                SizedBox(
                  width: viewport.width,
                  height: viewport.height,
                  child: ColoredBox(
                    color: Colors.black,
                    child: AmbientBlur(
                      diagnostics: _diagnostics,
                      enabled: _ambientEnabled && _ready,
                      playing: _state.playing && !_state.buffering,
                      frameSource: _player.ambientFrameSource,
                      captureFrame: _captureFrame,
                      maxCaptureDimension: 192,
                      duration: const Duration(milliseconds: 200),
                      opacity: 1,
                      child: _player.videoWidget(_videoKey, _fit) ??
                          const SizedBox.expand(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
