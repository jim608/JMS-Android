import 'package:fladder/util/brand.dart';

import 'dart:async';
import 'dart:developer';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:audio_session/audio_session.dart';
import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart' as mpv;
import 'package:media_kit_video/media_kit_video.dart';

import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/items/audio_model.dart';
import 'package:fladder/models/items/media_streams_model.dart';
import 'package:fladder/models/playback/playback_model.dart';
import 'package:fladder/models/settings/subtitle_settings_model.dart';
import 'package:fladder/models/settings/video_player_settings.dart';
import 'package:fladder/providers/settings/subtitle_settings_provider.dart';
import 'package:fladder/services/playback_diagnostics.dart';
import 'package:fladder/screens/video_player/video_player.dart' as video_screen;
import 'package:fladder/util/subtitle_position_calculator.dart';
import 'package:fladder/util/mpv_subtitle_route.dart';
import 'package:fladder/util/dual_subtitle.dart';
import 'package:fladder/util/subtitle_offset.dart';
import 'package:fladder/util/web_subtitle_timing.dart';
import 'package:fladder/widgets/dual_subtitle_text.dart';
import 'package:fladder/util/mpv_subtitle_selection.dart';
import 'package:fladder/util/mpv_video_configuration.dart';
import 'package:fladder/util/mpv_native_diagnostics.dart';
import 'package:fladder/util/mpv_pending_load_monitor.dart';
import 'package:fladder/util/mpv_render_capabilities.dart';
import 'package:fladder/util/mpv_hdr_tonemap.dart';
import 'package:fladder/services/syncplay/syncplay_prebuffer.dart';
import 'package:fladder/util/syncplay_buffer_probe.dart';
import 'package:fladder/util/web_syncplay_buffer_probe.dart';
import 'package:fladder/util/ambient_frame_capture.dart';
import 'package:fladder/wrappers/players/base_player.dart';
import 'package:fladder/wrappers/players/player_states.dart';

class LibMPV extends BasePlayer {
  mpv.Player? _player;
  Object _ambientFrameSource = Object();
  @override
  Object get ambientFrameSource => _ambientFrameSource;
  VideoController? _controller;
  MpvHdrToneMapper? _hdrToneMapper;
  final _renderCapabilityOwner = MpvRenderCapabilityOwner();
  MpvRenderCapabilities get _renderCapabilities => _renderCapabilityOwner.value;
  MpvHdrSource _nextHdrSource = const MpvHdrSource();
  final _hdrSurfaceReady = ValueNotifier(true);
  Future<void> _hdrPreparation = Future.value();
  int _mediaLoadGeneration = 0;
  bool _hdrPreparing = false;
  bool _desiredPlaying = false;
  MpvLoadReadiness? _loadReadiness;
  MpvSyncPlayBufferProbe? _syncPlayBufferProbe;
  mpv.Player? _syncPlayBufferPlayer;
  int _syncPlaySeekEpoch = 0;
  bool _softwareDecodeFallback = false;
  PlaybackAttemptRef? _activeDiagnosticAttempt;
  PlaybackSourceKind _diagnosticSourceKind = PlaybackSourceKind.unknown;
  bool _diagnosticOpening = false;
  // Fixed labels only: never retain a native exception message or stack.
  String _initializationPhase = 'not_started';
  final Set<String> _nativeDiagnosticFailures = {};
  MpvPlaybackTransitions _diagnosticTransitions = MpvPlaybackTransitions();

  void _recordPlaybackTransition(mpv.Player player) {
    if (player != _player || _activeDiagnosticAttempt == null) return;
    final transition = _diagnosticTransitions.sample(
      playing: player.state.playing,
      buffering: _hdrPreparing || player.state.buffering,
      buffer: player.state.buffer,
      position: player.state.position,
    );
    if (transition == null) return;
    _recordDiagnostic(
      _activeDiagnosticAttempt,
      PlaybackStage.buffering,
      detail: transition,
    );
  }

  void _recordDiagnostic(
    PlaybackAttemptRef? attempt,
    PlaybackStage stage, {
    PlaybackEvent event = PlaybackEvent.note,
    String? errorClass,
    int? httpStatus,
    bool timedOut = false,
    bool cancelled = false,
    String? hwdecActual,
    PlaybackSourceKind? sourceKind,
    String? detail,
  }) {
    if (attempt == null) return;
    PlaybackDiagnostics.instance.record(
      attempt,
      stage,
      event: event,
      backend: kIsWeb ? PlaybackBackend.webVideo : PlaybackBackend.mediaKit,
      errorClass: errorClass,
      httpStatus: httpStatus,
      timedOut: timedOut,
      cancelled: cancelled,
      sourceKind: sourceKind ?? _diagnosticSourceKind,
      hardwareRequested: _settings.hardwareAccel,
      hwdecActual: hwdecActual,
      softwareFallback: actualMpvSoftwareDecodeFallback(
        hardwareRequested: _settings.hardwareAccel,
        currentDecoder: hwdecActual,
      ),
      rendererKind: switch (_renderCapabilities.apiType) {
        'sw' => PlaybackRendererKind.software,
        'opengl' => PlaybackRendererKind.gpu,
        _ => PlaybackRendererKind.unknown,
      },
      detail: detail,
    );
  }

  void _recordNativeFailure(
    mpv.Player player,
    String message, {
    String prefix = '',
  }) {
    if (player != _player || _activeDiagnosticAttempt == null) return;
    final failure = MpvNativeFailure.classify(message, prefix: prefix);
    final source = safeMpvNativeSource(prefix);
    final key = '${failure.errorClass}:${failure.httpStatus}:$source';
    if (_nativeDiagnosticFailures.length >= 8 ||
        !_nativeDiagnosticFailures.add(key)) {
      return;
    }
    _recordDiagnostic(
      _activeDiagnosticAttempt ?? diagnosticAttempt,
      _diagnosticOpening || _loadReadiness != null
          ? PlaybackStage.mediaOpen
          : PlaybackStage.lifecycle,
      // mpv's public log/error stream has no media generation identifier.
      // A queued event can belong to the previous file on this same player.
      // Record context, never claim that this event failed the current load.
      event: PlaybackEvent.note,
      errorClass: failure.errorClass,
      httpStatus: failure.httpStatus,
      timedOut: failure.timedOut,
      cancelled: failure.cancelled,
      detail: 'native source: $source; attribution=player_context_only',
    );
  }

  Future<void> _recordDecodeStatus(
    mpv.Player player,
    int generation,
    PlaybackAttemptRef? attempt,
  ) async {
    try {
      final properties = await Future.wait([
        _readProperty(player, 'hwdec-current'),
        _readProperty(player, 'video-format'),
        _readProperty(player, 'audio-codec-name'),
      ]).timeout(const Duration(seconds: 2));
      if (player != _player || generation != _mediaLoadGeneration) return;
      _recordDiagnostic(
        attempt,
        PlaybackStage.mediaOpen,
        hwdecActual: safeMpvHwdec(properties[0]),
        detail: 'video_codec=${safeMpvCodec(properties[1])};'
            'audio_codec=${safeMpvCodec(properties[2])}',
      );
    } catch (_) {
      // Diagnostic property queries must never delay or change playback.
    }
  }

  MpvSyncPlayBufferProbe _nativeSyncPlayProbe(mpv.Player player) {
    if (_syncPlayBufferPlayer != player) {
      _syncPlayBufferProbe?.dispose();
      _syncPlayBufferPlayer = player;
      _syncPlayBufferProbe = MpvSyncPlayBufferProbe(
        read: (name) => _readProperty(player, name),
        write: (name, value) async {
          if (player != _player) {
            throw StateError('Native buffer backend was replaced');
          }
          await (player.platform as dynamic)
              .setProperty(name, value, waitForInitialization: false);
        },
        isCurrent: () => player == _player,
        generation: () => (_mediaLoadGeneration, _syncPlaySeekEpoch),
        buffering: () => player.state.buffering,
        preparing: () => _hdrPreparing,
      );
    }
    return _syncPlayBufferProbe!;
  }

  Future<int?> configureSyncPlayBufferBudget() async {
    final player = _player;
    if (player == null || kIsWeb || player.platform is! mpv.NativePlayer) {
      return null;
    }
    return _nativeSyncPlayProbe(player).configureBudget();
  }

  Future<SyncPlayBufferSample> readSyncPlayBufferSample() async {
    final player = _player;
    if (player == null) return unknownSyncPlayBufferSample();
    if (kIsWeb) {
      return readWebSyncPlayBufferSample(player.platform) ??
          unknownSyncPlayBufferSample();
    }
    if (player.platform is! mpv.NativePlayer) {
      return unknownSyncPlayBufferSample();
    }
    return _nativeSyncPlayProbe(player).sample();
  }

  /// Called with the selected playback stream, never inferred from a title or
  /// from PQ alone. Transcode outputs need their own classification later.
  void prepareVideoColor(PlaybackModel model) {
    final videos =
        model.mediaStreams?.videoStreams ?? const <VideoStreamModel>[];
    final stream = videos.length == 1
        ? videos.single
        : videos.where((video) => video.isDefault).singleOrNull;
    _nextHdrSource = MpvHdrSource(
      range: stream?.videoRangeType?.value ?? '',
      dolbyVision: stream?.videoDoViTitle?.trim().isNotEmpty ?? false,
      transcoded: model.isServerTranscoded,
    );
  }

  SubStreamModel? _primarySubtitle;
  bool _subtitleTextReady = false;
  final _subtitleTexts = ValueNotifier(const SubtitleTextPair());
  final _subtitleSeekRefresh = SubtitleSeekRefresh();
  bool _subtitleOffsetSupported = false;
  @override
  bool get supportsSecondarySubtitles =>
      !kIsWeb && _player?.platform is mpv.NativePlayer;
  late final WebSubtitleTiming _webSubtitleTiming = WebSubtitleTiming(
    onText: (text) => _subtitleTexts.value = SubtitleTextPair(primary: text),
    onAvailable: (available) => _subtitleOffsets.setAvailable(
      primary: _primarySubtitle != null && available,
      secondary: false,
    ),
  );
  late final SubtitleOffsetController _subtitleOffsets =
      SubtitleOffsetController(
    supportsSecondary: !kIsWeb,
    write: (property, value) async {
      if (kIsWeb) return _webSubtitleTiming.write(property, value);
      final player = _player;
      if (player?.platform is! mpv.NativePlayer) {
        throw StateError('Subtitle timing is unavailable');
      }
      await (player!.platform as dynamic).setProperty(property, value);
    },
    read: (property) async {
      if (kIsWeb) return _webSubtitleTiming.read(property);
      final player = _player;
      return player == null ? '' : await _readProperty(player, property);
    },
    refresh: () async {
      if (kIsWeb) {
        _webSubtitleTiming.refresh();
        return;
      }
      final player = _player;
      if (player != null) await _refreshSubtitleTexts(player);
    },
  );
  @override
  SubtitleOffsetController? get subtitleOffsets =>
      _subtitleOffsetSupported ? _subtitleOffsets : null;
  String _currentSubtitleCodec = '';
  String _subtitleDelivery = 'unknown';
  int _subtitleGeneration = 0;
  Future<void> _subtitleTask = Future.value();
  final ValueNotifier<MpvSubtitleRoute> _subtitleRoute =
      ValueNotifier(const MpvSubtitleRoute());
  SubtitleEncoding _externalEncoding = SubtitleEncoding.automatic;

  final StreamController<PlayerState> _stateController =
      StreamController.broadcast();
  @override
  Stream<PlayerState> get stateStream => _stateController.stream;

  StreamSubscription<bool>? _onCompleted;

  bool _replayGainFallbackLogged = false;
  VideoPlayerSettingsModel _settings = VideoPlayerSettingsModel();

  MpvPendingLoadMonitor? _retryTimer;
  DateTime _firstLoadAttempt = DateTime.now();
  final Duration _maxRetryDuration = const Duration(minutes: 1);
  final Duration _currentRetryDuration = const Duration(seconds: 5);
  Completer<void>? _loadCompleter;
  final List<StreamSubscription> _playerStreamSubs = [];
  double _preferredVolume = 100;
  int _crossfadeGeneration = 0;
  Timer? _fadeTimer;
  Duration get playPauseFadeDuration => const Duration(milliseconds: 175);
  AudioSession? _audioSession;

  bool _musicPaused = false;
  bool _musicPlaybackMode = false;

  void setMusicPlaybackMode(bool enabled) {
    _musicPlaybackMode = enabled;
    if (!enabled) _musicPaused = false;
    setState(lastState);
  }

  Future<void> setupAudioSession() async {
    _audioSession = await AudioSession.instance;
    await _audioSession?.configure(const AudioSessionConfiguration.music());
  }

  Future<void> updateSettings(VideoPlayerSettingsModel settings) async {
    _settings = settings;
  }

  @override
  Future<void> init(VideoPlayerSettingsModel settings) async {
    _settings = settings;
    _recordDiagnostic(
      diagnosticAttempt,
      PlaybackStage.playerInit,
      event: PlaybackEvent.started,
      detail: 'renderer initialization requested',
      sourceKind: PlaybackSourceKind.unknown,
    );
    try {
      await _initializePlayer(settings);
      _recordDiagnostic(
        diagnosticAttempt,
        PlaybackStage.playerInit,
        event: PlaybackEvent.succeeded,
        detail: 'render_api=${_renderCapabilities.apiType};'
            'software_override_requested=$_softwareDecodeFallback',
      );
    } catch (error) {
      final attempt = diagnosticAttempt ??
          PlaybackDiagnostics.instance.startAttempt(
            backend: kIsWeb
                ? PlaybackBackend.webVideo
                : PlaybackBackend.mediaKit,
          );
      _recordDiagnostic(
        attempt,
        PlaybackStage.playerInit,
        event: PlaybackEvent.failed,
        errorClass: safeMpvErrorClass(error),
        timedOut: error is TimeoutException,
        detail: 'init_$_initializationPhase',
      );
      rethrow;
    }
  }

  Future<void> _initializePlayer(VideoPlayerSettingsModel settings) async {
    _settings = settings;
    _initializationPhase = 'previous_cleanup';
    await dispose();
    _ambientFrameSource = Object();
    _softwareDecodeFallback = false;
    _nativeDiagnosticFailures.clear();

    _initializationPhase = 'player_construct';
    mpv.MediaKit.ensureInitialized();

    _player = mpv.Player(
      configuration: mpv.PlayerConfiguration(
        title: Brand.name,
        libassAndroidFont: libassFallbackFont,
        libassAndroidFontName: libassFallbackFontName,
        libass: !kIsWeb,
        bufferSize:
            settings.bufferSize * 1024 * 1024, // MPV uses buffer size in bytes
      ),
    );

    if (_player != null) {
      configureAmbientVideoCapture(_player!.platform);
      if (kIsWeb) {
        _webSubtitleTiming.attach(_player!.platform);
        _subtitleOffsetSupported = _webSubtitleTiming.supported;
      }
      _initializationPhase = 'video_controller';
      _controller = VideoController(
        _player!,
        configuration:
            mpvVideoConfiguration(hardwareAcceleration: settings.hardwareAccel),
      );
      final player = _player!;
      final controller = _controller!;
      bool currentController() =>
          player == _player && controller == _controller;
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
        // Apply the fixed decoder policy and create the texture before open().
        _initializationPhase = 'texture_ready';
        WidgetsBinding.instance.ensureVisualUpdate();
        await controller.platform.future.timeout(const Duration(seconds: 10));
        if (!currentController()) return;
        _renderCapabilityOwner.reset(MpvRenderCapabilities.configuredWindows);
      } else if (!kIsWeb && defaultTargetPlatform == TargetPlatform.linux) {
        _initializationPhase = 'texture_ready';
        final resolved = await _renderCapabilityOwner.resolve(() async {
          try {
            // The native constructor has now selected GL or its SW fallback.
            // The saved acceleration preference alone cannot identify that API.
            WidgetsBinding.instance.ensureVisualUpdate();
            await controller.platform.future
                .timeout(const Duration(seconds: 10));
            if (!currentController()) return const MpvRenderCapabilities();
            return queryMpvRenderCapabilities(
                playerHandle: () => player.handle);
          } catch (_) {
            return const MpvRenderCapabilities(
                reason: 'Linux texture initialization was not confirmed');
          }
        }, isCurrent: currentController);
        if (!resolved || !currentController()) return;
      }
      _setupPlayerStreams(_player!);
    }

    _initializationPhase = 'native_config';
    if (_player?.platform is mpv.NativePlayer) {
      final nativePlayer = _player!.platform as dynamic;
      if (useLinuxFlatpakSoftwareDecodeFallback(
        linux: !kIsWeb && defaultTargetPlatform == TargetPlatform.linux,
        flatpak: !kIsWeb &&
            defaultTargetPlatform == TargetPlatform.linux &&
            (Platform.environment['FLATPAK_ID']?.isNotEmpty ?? false),
        hardwareRequested: settings.hardwareAccel,
        softwareRenderConfirmed: _renderCapabilities.softwareSdr,
      )) {
        // The native plugin already tried GL and selected its SW texture.
        // Keep decoding on that compatible per-instance path before open.
        await nativePlayer.setProperty('hwdec', 'no');
        _softwareDecodeFallback = true;
        _recordDiagnostic(
          diagnosticAttempt,
          PlaybackStage.playerInit,
          detail:
              'Linux Flatpak software texture confirmed; decoder fallback requested',
        );
      }
      await nativePlayer.setProperty('force-seekable', 'yes');
      await nativePlayer.setProperty('gapless-audio', 'yes');
      await nativePlayer.setProperty('cache', 'yes');
      await nativePlayer.setProperty('demuxer-max-bytes', '150M');
      await nativePlayer.setProperty('network-timeout', '60');
      await nativePlayer.setProperty('stream-buffer-size', '4M');
      await nativePlayer.setProperty('prefetch-playlist', 'yes');
      await nativePlayer.setProperty('sub-ass-override', 'no');
      await nativePlayer.setProperty('embeddedfonts', 'yes');
      // Pinned Android libmpv supports primary delay but predates independent
      // secondary delay. Probe each channel without disabling primary timing.
      _subtitleOffsetSupported =
          double.tryParse(await _readProperty(_player!, 'sub-delay')) != null;
      _subtitleOffsets.setSecondarySupported(double.tryParse(
              await _readProperty(_player!, 'secondary-sub-delay')) !=
          null);
      final observedPlayer = _player!;
      _hdrToneMapper = _createHdrToneMapper(observedPlayer);
      await nativePlayer.observeProperty('seeking', (String value) async {
        final generation = _subtitleGeneration;
        await _subtitleSeekRefresh.onSeekingChanged(
          value,
          () => _readSubtitleTexts(observedPlayer),
          (text) {
            if (observedPlayer == _player &&
                generation == _subtitleGeneration &&
                _subtitleTextReady) {
              _subtitleTexts.value = text;
            }
          },
        );
      });

      if (defaultTargetPlatform == TargetPlatform.android) {
        await nativePlayer.setProperty('ao', 'audiotrack');
      }

      setupAudioSession();
    }

    await _applyReplayGainSettings();
    _initializationPhase = 'ready';
  }

  @override
  Future<void> dispose() async {
    _recordDiagnostic(
      _activeDiagnosticAttempt,
      PlaybackStage.lifecycle,
      detail: 'media kit player disposed',
    );
    _activeDiagnosticAttempt = null;
    _diagnosticSourceKind = PlaybackSourceKind.unknown;
    _diagnosticOpening = false;
    _syncPlayBufferProbe?.dispose();
    _syncPlayBufferProbe = null;
    _syncPlayBufferPlayer = null;
    final generation = ++_mediaLoadGeneration;
    _desiredPlaying = false;
    _loadReadiness?.cancel();
    _loadReadiness = null;
    final player = _player;
    final hdr = _hdrToneMapper;
    _hdrToneMapper = null;
    _renderCapabilityOwner.reset();
    try {
      if (hdr != null) {
        final stopVideo = hdr.applied || _hdrPreparing;
        await stopMpvWithHdr(
          mapper: hdr,
          isCurrent: () =>
              generation == _mediaLoadGeneration && player == _player,
          stop: () async {
            if (stopVideo) await player?.stop();
          },
          surfaceReady: (ready) => _hdrSurfaceReady.value = ready,
          forceCover: _hdrPreparing,
          uncover: false,
          reason: 'disposed',
        );
      }
    } catch (_) {
      // Disposing the owning native context also drops its remaining filters.
    }
    _nextHdrSource = const MpvHdrSource();
    _subtitleOffsetSupported = false;
    _subtitleOffsets.clear();
    await _subtitleOffsets.idle;
    _webSubtitleTiming.dispose();
    _subtitleGeneration++;
    _subtitleSeekRefresh.cancel();
    _primarySubtitle = null;
    _subtitleTextReady = false;
    _subtitleTexts.value = const SubtitleTextPair();
    secondarySubtitles.value = const SecondarySubtitleState();
    _currentSubtitleCodec = '';
    unawaited(_audioSession?.setActive(false));
    _fadeTimer?.cancel();
    _fadeTimer = null;
    _crossfadeGeneration++;
    _cancelPlayerStreams();
    _onCompleted?.cancel();
    _onCompleted = null;
    _player = null;
    _controller = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    await player?.dispose();
    _hdrPreparing = false;
    _hdrSurfaceReady.value = true;
  }

  MpvHdrToneMapper? _createHdrToneMapper(mpv.Player player) {
    if (!_renderCapabilities.softwareSdr ||
        player.platform is! mpv.NativePlayer) {
      return null;
    }
    return MpvHdrToneMapper(
      softwareRenderer: true,
      read: (name) => _readProperty(player, name),
      command: (arguments) async {
        if (player != _player) {
          throw StateError('The native player was replaced');
        }
        await (player.platform as dynamic).command(arguments);
      },
    );
  }

  void setState(PlayerState state) {
    final newState = state.update(
      playing: _musicPlaybackMode ? !_musicPaused : state.playing,
    );
    lastState = newState;
    _stateController.add(newState);
  }

  void _cancelPlayerStreams() {
    for (final sub in _playerStreamSubs) {
      sub.cancel();
    }
    _playerStreamSubs.clear();
  }

  void _setupPlayerStreams(mpv.Player player) {
    _playerStreamSubs.addAll([
      player.stream.error.listen(
        (message) => _recordNativeFailure(player, message),
      ),
      player.stream.log.listen((entry) {
        if (entry.level == 'error' || entry.level == 'fatal') {
          _recordNativeFailure(player, entry.text, prefix: entry.prefix);
        }
      }),
      player.stream.subtitle.listen((slots) {
        if (!kIsWeb && player == _player && _subtitleTextReady) {
          _subtitleTexts.value = SubtitleTextPair.fromSlots(
            slots,
            secondaryEnabled: secondarySubtitles.value.selected != null,
          );
        }
      }),
      player.stream.playing.listen((value) {
        _recordPlaybackTransition(player);
        if (player != _player || _hdrPreparing) return;
        setState(lastState.update(playing: value));
      }),
      player.stream.buffering.listen((value) {
        _recordPlaybackTransition(player);
        if (player == _player) {
          setState(lastState.update(buffering: _hdrPreparing || value));
        }
      }),
      player.stream.position.listen(
        (value) {
          if (player == _player) setState(lastState.update(position: value));
        },
      ),
      player.stream.duration.listen(
        (value) {
          if (player == _player) setState(lastState.update(duration: value));
        },
      ),
      player.stream.volume.listen((value) {
        if (player == _player) setState(lastState.update(volume: value));
      }),
      player.stream.rate.listen(
        (value) {
          if (player == _player) setState(lastState.update(rate: value));
        },
      ),
      player.stream.buffer.listen((value) {
        _recordPlaybackTransition(player);
        if (player == _player) setState(lastState.update(buffer: value));
      }),
      player.stream.completed.listen(
        (value) {
          if (player == _player) setState(lastState.update(completed: value));
        },
      ),
    ]);
  }

  Future<void> crossfadeToUrl(String url, Duration startPosition,
      {double? replayGainDb}) async {
    final mediaGeneration = ++_mediaLoadGeneration;
    final previous = _player;
    final hdr = _hdrToneMapper;
    _loadReadiness?.cancel();
    _loadReadiness = null;
    if (hdr != null) {
      final stopVideo = hdr.applied || _hdrPreparing;
      await stopMpvWithHdr(
        mapper: hdr,
        isCurrent: () =>
            mediaGeneration == _mediaLoadGeneration && previous == _player,
        stop: () async {
          if (stopVideo) await previous?.stop();
        },
        surfaceReady: (ready) => _hdrSurfaceReady.value = ready,
        forceCover: _hdrPreparing,
        reason: 'audio transition',
      );
    }
    if (mediaGeneration != _mediaLoadGeneration || previous != _player) return;
    _hdrPreparing = false;
    _hdrSurfaceReady.value = true;
    if (!_settings.enableCrossfade ||
        !VideoPlayerSettingsModel.crossfadeSupportedOnCurrentPlatform) {
      await _applyReplayGainSettings(trackGainDb: replayGainDb);
      await loadVideo(url, true, startPosition: startPosition);
      return;
    }

    final oldPlayer = _player;
    if (oldPlayer == null) {
      await loadVideo(url, true, startPosition: startPosition);
      return;
    }

    const stepMs = 16;
    final steps = math.max(1, _settings.crossfadeDurationMs ~/ stepMs);

    final incomingPlayer = mpv.Player(
      configuration: mpv.PlayerConfiguration(
        title: Brand.name,
        libassAndroidFont: libassFallbackFont,
        libassAndroidFontName: libassFallbackFontName,
        libass: !kIsWeb,
        bufferSize: _settings.bufferSize * 1024 * 1024,
      ),
    );

    if (incomingPlayer.platform is mpv.NativePlayer) {
      final native = incomingPlayer.platform as dynamic;
      await native.setProperty('force-seekable', 'yes');
      await native.setProperty('gapless-audio', 'weak');
      if (defaultTargetPlatform == TargetPlatform.android) {
        await native.setProperty('ao', 'audiotrack');
      }
      await native.setProperty(
          'start', '${startPosition.inMilliseconds / 1000}');
    }

    await _applyReplayGainSettings(
        trackGainDb: replayGainDb, targetPlayer: incomingPlayer);
    _fadeTimer?.cancel();
    _fadeTimer = null;
    await incomingPlayer.setVolume(0.0);
    await incomingPlayer.open(mpv.Media(url), play: true);

    final generation = ++_crossfadeGeneration;
    final fromVolume = oldPlayer.state.volume.clamp(0.0, 100.0);

    bool aborted = false;
    for (var i = 1; i <= steps; i++) {
      if (generation != _crossfadeGeneration) {
        aborted = true;
        break;
      }
      final progress = i / steps;
      await oldPlayer.setVolume(fromVolume * (1.0 - progress));
      await incomingPlayer.setVolume(_preferredVolume * progress);
      if (i < steps) await Future.delayed(const Duration(milliseconds: stepMs));
    }

    if (aborted || generation != _crossfadeGeneration) {
      incomingPlayer.stop();
      incomingPlayer.dispose();
      return;
    }

    _cancelPlayerStreams();
    _player = incomingPlayer;
    // Crossfaded audio has no video texture. Do not inherit a previous texture's
    // capability classification for a different native player handle.
    _renderCapabilityOwner.reset(const MpvRenderCapabilities(
        reason: 'Audio player has no video texture'));
    _hdrToneMapper = _createHdrToneMapper(incomingPlayer);
    _controller = null;
    _setupPlayerStreams(incomingPlayer);

    _retryTimer?.cancel();
    _retryTimer = null;
    _loadCompleter = null;

    oldPlayer.stop();
    oldPlayer.dispose();

    setState(lastState.update(
      playing: incomingPlayer.state.playing,
      buffering: incomingPlayer.state.buffering,
      position: incomingPlayer.state.position,
      duration: incomingPlayer.state.duration,
      volume: _preferredVolume,
      buffer: incomingPlayer.state.buffer,
      completed: false,
    ));
  }

  @override
  Future<void> loadVideo(
    String url,
    bool play, {
    Duration startPosition = Duration.zero,
  }) async {
    final attempt = diagnosticAttempt;
    _activeDiagnosticAttempt = attempt;
    _diagnosticSourceKind = classifyMpvDiagnosticSource(url);
    final sourceKind = _diagnosticSourceKind;
    _diagnosticOpening = true;
    _nativeDiagnosticFailures.clear();
    _diagnosticTransitions = MpvPlaybackTransitions();
    final player = _player;
    final generation = _mediaLoadGeneration + 1;
    _recordDiagnostic(
      attempt,
      PlaybackStage.mediaOpen,
      event: PlaybackEvent.started,
      detail: 'media kit open requested',
      sourceKind: sourceKind,
    );
    try {
      await _loadVideo(url, play, startPosition: startPosition);
      if (generation != _mediaLoadGeneration || player != _player) {
        _recordDiagnostic(
          attempt,
          PlaybackStage.mediaOpen,
          cancelled: true,
          detail: 'media kit open superseded',
          sourceKind: sourceKind,
        );
        return;
      }
      _recordDiagnostic(
        attempt,
        PlaybackStage.mediaOpen,
        event: PlaybackEvent.succeeded,
        detail: 'open command completed; frame not yet confirmed',
        sourceKind: sourceKind,
      );
      if (player != null) {
        unawaited(_recordDecodeStatus(player, generation, attempt));
        // The pinned plugin's first-frame future can complete for its initial
        // 1x1 placeholder. It does not prove this media was presented.
        _recordDiagnostic(
          attempt,
          PlaybackStage.firstFrame,
          detail: 'media presentation unconfirmed',
        );
      }
    } catch (error) {
      final cancelled = generation != _mediaLoadGeneration || player != _player;
      _recordDiagnostic(
        attempt,
        PlaybackStage.mediaOpen,
        event: cancelled ? PlaybackEvent.note : PlaybackEvent.failed,
        errorClass: safeMpvErrorClass(error),
        timedOut: error is TimeoutException,
        cancelled: cancelled,
        detail: 'media kit open failed',
        sourceKind: sourceKind,
      );
      rethrow;
    } finally {
      if (generation == _mediaLoadGeneration && player == _player) {
        _diagnosticOpening = false;
      }
    }
  }

  Future<void> _loadVideo(
    String url,
    bool play, {
    Duration startPosition = Duration.zero,
  }) async {
    final generation = ++_mediaLoadGeneration;
    final player = _player;
    final source = _nextHdrSource;
    final hdrGated = _hdrToneMapper != null &&
        (source.skipReason == null ||
            _hdrToneMapper!.applied ||
            !_hdrSurfaceReady.value);
    _desiredPlaying = play;
    _loadReadiness?.cancel();
    _loadReadiness = null;
    if (_loadCompleter?.isCompleted == false) _loadCompleter!.complete();
    final completion = Completer<void>();
    _loadCompleter = completion;
    _nextHdrSource = const MpvHdrSource();
    _ambientFrameSource = Object();
    _subtitleGeneration++;
    _webSubtitleTiming.clearTrack();
    _subtitleSeekRefresh.cancel();
    _primarySubtitle = null;
    _subtitleTextReady = false;
    _subtitleTexts.value = const SubtitleTextPair();
    if (subtitleOffsets != null && !await _subtitleOffsets.resetForMedia()) {
      throw StateError('Subtitle timing could not be reset');
    }
    if (generation != _mediaLoadGeneration || player != _player) return;
    await _clearSecondary(issue: SecondarySubtitleIssue.mediaChanged);
    if (generation != _mediaLoadGeneration || player != _player) return;
    _subtitleRoute.value = const MpvSubtitleRoute();
    _currentSubtitleCodec = '';
    _subtitleDelivery = 'unknown';
    _firstLoadAttempt = DateTime.now();

    await setStartPosition(startPosition);
    if (generation != _mediaLoadGeneration || player != _player) return;

    if (player != null) {
      final preparation =
          _openWithVideoColor(player, url, play, source, generation);
      _hdrPreparation = preparation;
      await preparation;
      if (generation != _mediaLoadGeneration || player != _player) return;
    }

    _retryTimer?.cancel();
    _retryTimer = null;

    void stopPendingLoad(Object error) {
      if (generation != _mediaLoadGeneration || player != _player) return;
      _recordDiagnostic(
        _activeDiagnosticAttempt,
        PlaybackStage.mediaOpen,
        event: PlaybackEvent.failed,
        errorClass: safeMpvErrorClass(error),
        timedOut: error is TimeoutException,
        detail: 'media readiness budget ended',
      );
      _loadReadiness?.cancel();
      _loadReadiness = null;
      _retryTimer?.cancel();
      _retryTimer = null;
      // Release the completion without letting timeout trigger the backup seek.
      if (identical(_loadCompleter, completion)) _loadCompleter = null;
      if (!completion.isCompleted) completion.complete();
    }

    _retryTimer = MpvPendingLoadMonitor(
      networkStream: _diagnosticSourceKind == PlaybackSourceKind.networkStream,
      interval: _currentRetryDuration,
      budget: _maxRetryDuration - DateTime.now().difference(_firstLoadAttempt),
      isCurrent: () => generation == _mediaLoadGeneration && player == _player,
      retryLocal: () async {
        await setStartPosition(startPosition);
        if (generation != _mediaLoadGeneration ||
            player != _player ||
            !identical(_loadCompleter, completion) ||
            completion.isCompleted) {
          return;
        }
        if (player != null) {
          final preparation = _openWithVideoColor(
            player,
            url,
            play,
            source,
            generation,
          );
          _hdrPreparation = preparation;
          await preparation;
        }
      },
      onTimeout: () => stopPendingLoad(TimeoutException('Media readiness')),
      onFailure: stopPendingLoad,
    )..start();

    // Wait for the player to be ready
    if (!completion.isCompleted && player != null) {
      final readiness = MpvLoadReadiness(
        isCurrent: () =>
            generation == _mediaLoadGeneration && player == _player,
        isReady: () => player.state.duration > Duration.zero,
        onReady: () => _finishedLoading(completion),
      );
      _loadReadiness = readiness;
      readiness.observe([player.stream.buffering, player.stream.duration]);
    }

    completion.future.then((value) async {
      if (generation != _mediaLoadGeneration ||
          player != _player ||
          !identical(_loadCompleter, completion)) {
        return;
      }
      // Backup seek in case property didn't work
      if (startPosition != Duration.zero &&
          (_player?.state.position.inSeconds ?? 0) <
              startPosition.inSeconds - 5) {
        await _player?.seek(startPosition);
      }
    });
    return setState(
      lastState.update(
        playing: hdrGated ? player?.state.playing : null,
        buffering: mpvInitialBuffering(
          readinessCompleted: completion.isCompleted,
          hdrGated: hdrGated,
          backendBuffering: player?.state.buffering ?? true,
        ),
      ),
    );
  }

  Future<void> _openWithVideoColor(mpv.Player player, String url, bool play,
      MpvHdrSource source, int generation) async {
    bool current() => generation == _mediaLoadGeneration && player == _player;
    if (!current()) return;
    final mapper = _hdrToneMapper;
    if (mapper == null) {
      await player.open(mpv.Media(url), play: play);
      return;
    }
    final inheritedCover = !_hdrSurfaceReady.value;
    final gate = source.skipReason == null || mapper.applied || inheritedCover;
    _hdrPreparing = gate;
    if (gate) {
      setState(lastState.update(buffering: true));
    }
    try {
      await openMpvWithHdr(
        mapper: mapper,
        source: source,
        play: play,
        shouldResume: () => _desiredPlaying,
        forceSurfaceGate: inheritedCover,
        isCurrent: current,
        surfaceReady: (ready) => _hdrSurfaceReady.value = ready,
        pause: player.pause,
        open: (play) => player.open(mpv.Media(url), play: play),
        resume: player.play,
        stop: player.stop,
        frameBarrier: () async {
          // Native output confirmation precedes this. Keep the cover during
          // texture propagation; actual display presentation still needs QA.
          for (var frame = 0; frame < 2; frame++) {
            WidgetsBinding.instance.ensureVisualUpdate();
            await WidgetsBinding.instance.endOfFrame
                .timeout(const Duration(milliseconds: 500));
            if (!current()) return;
          }
        },
      );
    } catch (_) {
      if (current()) {
        setState(lastState.update(playing: false, buffering: false));
      }
      rethrow;
    } finally {
      if (current()) _hdrPreparing = false;
    }
  }

  /// Apply ReplayGain normalization for the given [item] before loading it.
  /// Call this before [loadVideo] when starting an audio queue item.
  Future<void> applyReplayGainForItem(ItemBaseModel? item) async {
    double? gainDb;
    if (item is AudioModel) {
      final gain = item.normalizationGain;
      if (gain != null && !gain.isNaN && !gain.isInfinite) {
        gainDb = gain.clamp(-60.0, 0).toDouble();
      }
    }
    await _applyReplayGainSettings(trackGainDb: gainDb);
  }

  double get _replayGainVolumeOffsetDb {
    return _settings.replayGainVolumeLevel.replayGainOffsetDb;
  }

  Future<void> _applyReplayGainSettings(
      {double? trackGainDb, mpv.Player? targetPlayer}) async {
    final player = targetPlayer ?? _player;
    if (player?.platform is! mpv.NativePlayer) {
      return;
    }

    final nativePlayer = player!.platform as dynamic;

    if (!_settings.enableReplayGain) {
      try {
        await nativePlayer.setProperty('af', '');
      } catch (_) {
        // Best effort clear.
      }
      return;
    }

    final replayGainOffsetDb = clampReplayGainDb(_replayGainVolumeOffsetDb);
    final replayGainFallbackDb =
        _settings.replayGainVolumeLevel.adjustedReplayGainDb(trackGainDb);

    try {
      await nativePlayer.setProperty('replaygain', 'track');
      await nativePlayer.setProperty('replaygain-clip', 'yes');
      await nativePlayer.setProperty(
          'replaygain-fallback', '$replayGainFallbackDb');
      await nativePlayer.setProperty(
          'replaygain-preamp', '$replayGainOffsetDb');
      await nativePlayer.setProperty('af', '');
      _replayGainFallbackLogged = false;
    } catch (error, stackTrace) {
      if (!_replayGainFallbackLogged) {
        log('ReplayGain unsupported by current mpv backend, falling back to loudnorm. $error\n$stackTrace');
      }
      _replayGainFallbackLogged = true;

      try {
        final gainFilter = ',volume=${replayGainFallbackDb}dB';
        await nativePlayer.setProperty(
            'af', 'format=stereo,loudnorm$gainFilter');
      } catch (fallbackError, fallbackStackTrace) {
        log('Unable to set loudnorm fallback filter. $fallbackError\n$fallbackStackTrace');
      }
    }
  }

  Future<void> setStartPosition(Duration position) async {
    if (_player?.platform is mpv.NativePlayer) {
      await (_player?.platform as dynamic).setProperty(
        'start',
        '${position.inMilliseconds / 1000}',
      );
    }
  }

  void _finishedLoading(Completer<void> completion) {
    if (!identical(_loadCompleter, completion) || completion.isCompleted) {
      return;
    }
    completion.complete();
    _loadReadiness = null;
    _recordDiagnostic(
      _activeDiagnosticAttempt,
      PlaybackStage.mediaOpen,
      detail: 'duration readiness confirmed',
    );
    final player = _player;
    if (player != null) {
      unawaited(
        _recordDecodeStatus(
          player,
          _mediaLoadGeneration,
          _activeDiagnosticAttempt,
        ),
      );
    }
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  @override
  Future<void> open(BuildContext context) async =>
      Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute(
          builder: (context) => const video_screen.VideoPlayer(),
        ),
      );

  List<mpv.SubtitleTrack> get subTracks => _player?.state.tracks.subtitle ?? [];
  mpv.SubtitleTrack get subtitleTrack =>
      _player?.state.track.subtitle ?? mpv.SubtitleTrack.no();

  List<mpv.AudioTrack> get audioTracks => _player?.state.tracks.audio ?? [];
  mpv.AudioTrack get audioTrack =>
      _player?.state.track.audio ?? mpv.AudioTrack.no();

  void _startPlaybackFade(bool fadingIn) {
    final player = _player;
    if (player == null) return;

    _fadeTimer?.cancel();

    if (!_settings.enablePlayPauseFade) {
      if (fadingIn) {
        player.play();
      } else {
        player.pause();
      }
      return;
    }

    const stepMs = 16;
    final steps = playPauseFadeDuration.inMilliseconds ~/ stepMs;
    final stepSize = _preferredVolume / steps;

    if (fadingIn) player.play();

    _fadeTimer = Timer.periodic(const Duration(milliseconds: stepMs), (timer) {
      final p = _player;
      if (p == null) {
        timer.cancel();
        return;
      }
      if (fadingIn) {
        final next = (p.state.volume + stepSize).clamp(0.0, _preferredVolume);
        p.setVolume(next);
        if (next >= _preferredVolume) timer.cancel();
      } else {
        final next = (p.state.volume - stepSize).clamp(0.0, 100.0);
        p.setVolume(next);
        if (next <= 0.0) {
          timer.cancel();
          p.pause();
        }
      }
    });
  }

  @override
  Future<void> pause() async {
    _desiredPlaying = false;
    _musicPaused = true;
    setState(lastState.update(playing: false));
    unawaited(_audioSession?.setActive(false));
    _startPlaybackFade(false);
  }

  @override
  Future<void> play() async {
    _desiredPlaying = true;
    final generation = _mediaLoadGeneration;
    await _hdrPreparation;
    if (generation != _mediaLoadGeneration || !_desiredPlaying) return;
    _musicPaused = false;
    setState(lastState.update(playing: true));
    unawaited(_audioSession?.setActive(true));
    _startPlaybackFade(true);
  }

  @override
  Future<void> playOrPause() async {
    if ((_hdrPreparing
            ? _desiredPlaying
            : (_player?.state.playing ?? lastState.playing)) ==
        true) {
      await pause();
    } else {
      await play();
    }
  }

  @override
  Future<void> seek(Duration position) async {
    final player = _player;
    if (player == null) return;
    if (player.platform is mpv.NativePlayer) {
      _subtitleSeekRefresh.begin();
      _subtitleTexts.value = const SubtitleTextPair();
    }
    _syncPlaySeekEpoch++;
    try {
      await player.seek(position);
    } finally {
      _syncPlaySeekEpoch++;
    }
  }

  // mpv parses tracks asynchronously after open(); at playback start the list is still empty, so a
  // positional lookup would miss and leave mpv on its own default pick. Wait (capped) for [index].
  Future<void> _awaitTrack(int index, int Function(mpv.Tracks) count) async {
    final player = _player;
    if (player == null || index < 0 || count(player.state.tracks) > index + 2) {
      return;
    }
    await player.stream.tracks
        .firstWhere((tracks) => count(tracks) > index + 2)
        .timeout(const Duration(seconds: 5),
            onTimeout: () => player.state.tracks);
  }

  @override
  Future<int> setAudioTrack(
      AudioStreamModel? model, PlaybackModel playbackModel) async {
    final wantedAudioStream = model ?? playbackModel.defaultAudioStream;
    if (wantedAudioStream == null) return -1;
    if (wantedAudioStream.index == AudioStreamModel.no().index) {
      await _player?.setAudioTrack(mpv.AudioTrack.no());
    } else {
      final index =
          (playbackModel.audioStreams?.indexOf(wantedAudioStream) ?? -1) - 1;
      await _awaitTrack(index, (tracks) => tracks.audio.length);
      final internalTracks =
          audioTracks.getRange(2, audioTracks.length).toList();
      final audioTrack = internalTracks.elementAtOrNull(index);
      if (audioTrack != null) {
        await _player?.setAudioTrack(audioTrack);
      }
    }
    return wantedAudioStream.index;
  }

  @override
  Future<void> setSpeed(double speed) async => _player?.setRate(speed);

  @override
  Future<int> setSubtitleTrack(
      SubStreamModel? model, PlaybackModel playbackModel) async {
    final generation = ++_subtitleGeneration;
    if (kIsWeb) _webSubtitleTiming.clearTrack();
    final result = _subtitleTask.then((_) async {
      try {
        return await _selectSubtitle(model, playbackModel, generation);
      } catch (_) {
        if (generation == _subtitleGeneration) {
          _subtitleOffsets.setAvailable(primary: false, secondary: false);
        }
        if (generation == _subtitleGeneration &&
            secondarySubtitles.value.selected != null) {
          try {
            await _clearSecondary(
                issue: SecondarySubtitleIssue.selectionFailed,
                generation: generation);
          } catch (_) {
            // Preserve the original primary-selection exception for the caller.
          }
        }
        rethrow;
      }
    });
    _subtitleTask =
        result.then<void>((_) {}, onError: (Object error, StackTrace stack) {});
    return result;
  }

  Future<int> _selectSubtitle(SubStreamModel? model,
      PlaybackModel playbackModel, int generation) async {
    final player = _player;
    if (player == null || generation != _subtitleGeneration) return -1;
    _subtitleOffsets.setAvailable(primary: false, secondary: false);
    Future<int> unavailable() async {
      if (player == _player && generation == _subtitleGeneration) {
        _primarySubtitle = null;
        if (secondarySubtitles.value.selected != null) {
          await _clearSecondary(
              issue: SecondarySubtitleIssue.unavailable,
              generation: generation);
        }
      }
      return -1;
    }

    _subtitleTextReady = false;
    _subtitleTexts.value = const SubtitleTextPair();
    _subtitleRoute.value = const MpvSubtitleRoute();
    final wantedSubtitle = model ?? playbackModel.defaultSubStream;
    if (wantedSubtitle == null ||
        wantedSubtitle.index == SubStreamModel.no().index) {
      _primarySubtitle = null;
      await _clearSecondary(issue: SecondarySubtitleIssue.primaryOff);
      _currentSubtitleCodec = '';
      _subtitleDelivery = 'off';
      await player.setSubtitleTrack(mpv.SubtitleTrack.no());
      _subtitleRoute.value = const MpvSubtitleRoute(sid: 'no');
      return -1;
    }
    _primarySubtitle = wantedSubtitle;
    _currentSubtitleCodec = wantedSubtitle.codec;
    final external = kIsWeb
        ? wantedSubtitle.url != null &&
            (wantedSubtitle.isExternal || wantedSubtitle.supportsExternalStream)
        : useExternalSubtitleSource(
            isExternal: wantedSubtitle.isExternal,
            transcoded: playbackModel.isServerTranscoded,
            supportsExternalStream: wantedSubtitle.supportsExternalStream,
            codec: wantedSubtitle.codec,
            url: wantedSubtitle.url,
          );
    _subtitleDelivery = external
        ? wantedSubtitle.isExternal
            ? 'external/local subtitle'
            : 'Jellyfin extracted ASS/SSA (transcoded video)'
        : 'container track';
    if (external) {
      final url = wantedSubtitle.url;
      if (url == null || url.isEmpty) return unavailable();
      if (!kIsWeb && player.platform is mpv.NativePlayer) {
        await (player.platform as dynamic)
            .setProperty('sub-codepage', _externalEncoding.codepage);
        if (generation != _subtitleGeneration || player != _player) return -1;
      }
      final subtitleUrl = kIsWeb && isPlainTextSubtitle(wantedSubtitle.codec)
          ? await _webSubtitleTiming.prepareSubtitle(url)
          : url;
      if (generation != _subtitleGeneration || player != _player) return -1;
      await player.setSubtitleTrack(mpv.SubtitleTrack.uri(subtitleUrl));
    } else {
      final index = playbackModel.subStreams
              ?.where((element) => element.index >= 0 && !element.isExternal)
              .toList()
              .indexWhere((element) => element.id == wantedSubtitle.id) ??
          -1;
      if (index < 0) return unavailable();
      await _awaitTrack(index, (tracks) => tracks.subtitle.length);
      if (generation != _subtitleGeneration || player != _player) return -1;
      final subTrack = subTracks
          .where(
              (track) => track.id != 'no' && track.id != 'auto' && !track.uri)
          .elementAtOrNull(index);
      if (subTrack == null) return unavailable();
      await player.setSubtitleTrack(subTrack);
    }
    if (generation != _subtitleGeneration || player != _player) return -1;
    final secondary = secondarySubtitles.value.selected;
    if (secondary != null) {
      final issue = secondarySubtitleIssue(
        supportedBackend: supportsSecondarySubtitles,
        primary: wantedSubtitle,
        candidate: secondary,
      );
      if (issue != null) await _clearSecondary(issue: issue);
    }
    if (!kIsWeb && player.platform is mpv.NativePlayer) {
      final route = await MpvSubtitleRoute.configure(
        read: (name) => _readProperty(player, name),
        write: (name, value) async {
          if (generation == _subtitleGeneration && player == _player) {
            await (player.platform as dynamic).setProperty(name, value);
          }
        },
        expectedCodec: wantedSubtitle.codec,
        plainTextPreference: _settings.useLibass,
        dualText: secondarySubtitles.value.selected != null,
      );
      if (generation != _subtitleGeneration || player != _player) return -1;
      _subtitleRoute.value = route;
      if (secondarySubtitles.value.selected != null && !route.dualText) {
        await _clearSecondary(issue: SecondarySubtitleIssue.unavailable);
        await _restoreSubtitleRoute(player, generation);
      }
    } else {
      _subtitleRoute.value = const MpvSubtitleRoute(plainOverlay: true);
      if (kIsWeb) _webSubtitleTiming.selectTrack();
    }
    _subtitleTextReady = true;
    _updateSubtitleOffsetAvailability();
    await _refreshSubtitleTexts(player);
    return wantedSubtitle.index;
  }

  Future<void> _clearSecondary(
      {SecondarySubtitleIssue? issue, int? generation}) async {
    if (generation != null && generation != _subtitleGeneration) return;
    final selected = secondarySubtitles.value.selected;
    secondarySubtitles.value =
        SecondarySubtitleState(issue: selected != null ? issue : null);
    _subtitleOffsets.setAvailable(
        primary: _subtitleOffsets.primaryAvailable, secondary: false);
    _subtitleTexts.value =
        SubtitleTextPair(primary: _subtitleTexts.value.primary);
    final player = _player;
    if (player?.platform is mpv.NativePlayer) {
      await (player!.platform as dynamic).setProperty('secondary-sid', 'no');
      if (player != _player ||
          (generation != null && generation != _subtitleGeneration)) {
        return;
      }
      await (player.platform as dynamic)
          .setProperty('secondary-sub-visibility', 'no');
    }
  }

  Future<SubtitleTextPair> _readSubtitleTexts(mpv.Player player) async {
    if (kIsWeb) {
      _webSubtitleTiming.refresh();
      return _subtitleTexts.value;
    }
    if (player.platform is! mpv.NativePlayer) {
      return SubtitleTextPair.fromSlots(player.state.subtitle,
          secondaryEnabled: false);
    }
    final primary = await _readProperty(player, 'sub-text');
    final secondary = secondarySubtitles.value.selected == null
        ? ''
        : await _readProperty(player, 'secondary-sub-text');
    return SubtitleTextPair(primary: primary, secondary: secondary);
  }

  Future<void> _refreshSubtitleTexts(mpv.Player player) async {
    final generation = _subtitleGeneration;
    final text = await _readSubtitleTexts(player);
    if (player == _player &&
        generation == _subtitleGeneration &&
        _subtitleTextReady) {
      _subtitleTexts.value = text;
    }
  }

  void _updateSubtitleOffsetAvailability() {
    if (kIsWeb) {
      _subtitleOffsets.setAvailable(
          primary: _primarySubtitle != null && _webSubtitleTiming.available,
          secondary: false);
      return;
    }
    final route = _subtitleRoute.value;
    final sid = route.sid;
    final primary = supportsSecondarySubtitles &&
        _primarySubtitle != null &&
        route.codec.isNotEmpty &&
        sid.isNotEmpty &&
        sid != 'no' &&
        sid != 'auto';
    _subtitleOffsets.setAvailable(
        primary: primary,
        secondary: primary && secondarySubtitles.value.selected != null);
  }

  @override
  Future<void> setSecondarySubtitleTrack(
      SubStreamModel? model, PlaybackModel playbackModel) async {
    final generation = _subtitleGeneration;
    final result = _subtitleTask.then(
        (_) => _selectSecondarySubtitle(model, playbackModel, generation));
    _subtitleTask =
        result.then<void>((_) {}, onError: (Object error, StackTrace stack) {});
    return result;
  }

  Future<void> _selectSecondarySubtitle(SubStreamModel? model,
      PlaybackModel playbackModel, int generation) async {
    final player = _player;
    bool current() =>
        player != null &&
        player == _player &&
        generation == _subtitleGeneration;
    if (!current()) return;
    if (model == null || model.index < 0) {
      await _clearSecondary();
      if (current()) await _restoreSubtitleRoute(player!, generation);
      return;
    }
    final issue = secondarySubtitleIssue(
      supportedBackend: supportsSecondarySubtitles,
      primary: _primarySubtitle,
      candidate: model,
    );
    if (issue != null) {
      secondarySubtitles.value = SecondarySubtitleState(
          selected: secondarySubtitles.value.selected, issue: issue);
      return;
    }
    _subtitleTextReady = false;
    _subtitleTexts.value = const SubtitleTextPair();
    String primaryId = '';
    try {
      primaryId = await _readProperty(player!, 'sid');
      final primaryCodec = await MpvSubtitleRoute.selectedCodec(
          (name) => _readProperty(player, name));
      if (!current()) return;
      if (!isPlainTextSubtitle(primaryCodec)) {
        throw StateError('Primary subtitle is not decoded text');
      }
      String? id;
      final external = model.isExternal ||
          (playbackModel.isServerTranscoded &&
              model.supportsExternalStream &&
              model.url?.isNotEmpty == true);
      if (external) {
        final url = model.url;
        if (url == null || url.isEmpty) {
          throw StateError('Subtitle source unavailable');
        }
        Future<String?> existingExternalId() async {
          final count =
              (int.tryParse(await _readProperty(player, 'track-list/count')) ??
                      0)
                  .clamp(0, 128);
          for (var index = 0; index < count; index++) {
            if (await _readProperty(player, 'track-list/$index/type') ==
                    'sub' &&
                await _readProperty(
                        player, 'track-list/$index/external-filename') ==
                    url) {
              return _readProperty(player, 'track-list/$index/id');
            }
          }
          return null;
        }

        id = await existingExternalId();
        if (id == null) {
          if (!current()) return;
          await (player.platform as dynamic)
              .setProperty('sub-codepage', _externalEncoding.codepage);
          if (!current()) return;
          // Unlike setSubtitleTrack(uri), auto does not intentionally replace primary sid.
          await (player.platform as dynamic)
              .command(['sub-add', url, 'auto', model.title, model.language]);
          if (!current()) return;
          await (player.platform as dynamic).setProperty('sid', primaryId);
          id = await existingExternalId();
        }
      } else {
        final index = playbackModel.subStreams
                ?.where((entry) => entry.index >= 0 && !entry.isExternal)
                .toList()
                .indexWhere((entry) => entry.index == model.index) ??
            -1;
        if (index < 0) throw StateError('Subtitle track unavailable');
        await _awaitTrack(index, (tracks) => tracks.subtitle.length);
        if (!current()) return;
        final internalIds =
            await internalMpvSubtitleIds((name) => _readProperty(player, name));
        id = internalIds.elementAtOrNull(index);
      }
      if (!current()) return;
      if (id == null || id.isEmpty || id == primaryId) {
        throw StateError('Subtitle track unavailable');
      }
      await (player.platform as dynamic).setProperty('secondary-sid', id);
      if (!current()) return;
      if (await _readProperty(player, 'secondary-sid') != id) {
        throw StateError('Secondary subtitle not selected');
      }
      final count =
          (int.tryParse(await _readProperty(player, 'track-list/count')) ?? 0)
              .clamp(0, 128);
      String codec = '';
      for (var index = 0; index < count; index++) {
        if (await _readProperty(player, 'track-list/$index/type') == 'sub' &&
            await _readProperty(player, 'track-list/$index/id') == id) {
          codec = await _readProperty(player, 'track-list/$index/codec');
          break;
        }
      }
      if (!current()) return;
      if (!isPlainTextSubtitle(codec)) {
        throw StateError('Secondary subtitle is not decoded text');
      }
      await (player.platform as dynamic)
          .setProperty('secondary-sub-visibility', 'no');
      if (!current()) return;
      secondarySubtitles.value = SecondarySubtitleState(selected: model);
      await _restoreSubtitleRoute(player, generation);
      if (!_subtitleRoute.value.dualText) {
        throw StateError('Dual text rendering unavailable');
      }
    } catch (_) {
      if (!current()) return;
      try {
        if (primaryId.isNotEmpty) {
          await (player!.platform as dynamic).setProperty('sid', primaryId);
        }
        await _clearSecondary();
        await _restoreSubtitleRoute(player!, generation);
      } catch (_) {
        _subtitleRoute.value = const MpvSubtitleRoute();
      }
      secondarySubtitles.value = const SecondarySubtitleState(
          issue: SecondarySubtitleIssue.selectionFailed);
    }
  }

  Future<void> _restoreSubtitleRoute(mpv.Player player, int generation) async {
    if (player != _player || generation != _subtitleGeneration) return;
    final route = await MpvSubtitleRoute.configure(
      read: (name) => _readProperty(player, name),
      write: (name, value) async {
        if (player == _player && generation == _subtitleGeneration) {
          await (player.platform as dynamic).setProperty(name, value);
        }
      },
      expectedCodec: _primarySubtitle?.codec ?? '',
      plainTextPreference: _settings.useLibass,
      dualText: secondarySubtitles.value.selected != null,
    );
    if (player != _player || generation != _subtitleGeneration) return;
    _subtitleRoute.value = route;
    if (secondarySubtitles.value.selected != null && !route.dualText) {
      await _clearSecondary(issue: SecondarySubtitleIssue.unavailable);
      return _restoreSubtitleRoute(player, generation);
    }
    _subtitleTextReady = true;
    _updateSubtitleOffsetAvailability();
    await _refreshSubtitleTexts(player);
  }

  Future<String> _readProperty(mpv.Player player, String name) async {
    if (player != _player || player.platform is! mpv.NativePlayer) return '';
    try {
      return await (player.platform as dynamic)
          .getProperty(name, waitForInitialization: false) as String;
    } catch (_) {
      return '';
    }
  }

  @override
  Future<Map<String, String>> playbackDiagnostics() async {
    final player = _player;
    if (player == null) return {'backend': 'MPV (not initialized)'};
    final values = <String, String>{
      'backend': kIsWeb ? 'media_kit web' : 'media_kit / libmpv',
    };
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.linux) {
      values['Linux acceleration (saved)'] = '${_settings.hardwareAccel}';
      values['Linux decoder (requested)'] =
          !_settings.hardwareAccel || _softwareDecodeFallback ? 'no' : 'auto';
      values['Linux software decoder fallback'] = _softwareDecodeFallback
          ? 'confirmed software texture in Flatpak'
          : 'not applied';
    }
    for (final name in [
      'mpv-version',
      'libass-version',
      'current-vo',
      'hwdec-current',
      'video-codec',
      'sid',
      'secondary-sid',
      'sub-ass',
      'sub-ass-override',
      'sub-visibility',
      'secondary-sub-visibility',
      'embeddedfonts',
      'sub-font',
      'sub-font-provider',
      'sub-delay',
      'secondary-sub-delay',
      'sub-scale',
      'sub-ass-force-style',
      'decoder-frame-drop-count',
      'frame-drop-count',
      'avsync',
      'paused-for-cache',
      'cache-buffering-state',
    ]) {
      final value = await _readProperty(player, name);
      values[name] = value.isEmpty ? 'unknown' : value;
    }
    final codec = await MpvSubtitleRoute.selectedCodec(
        (name) => _readProperty(player, name));
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      values.addAll(windowsMpvDecodeDiagnostics(
        hardwareAcceleration: _settings.hardwareAccel,
        currentDecoder: values['hwdec-current'] ?? 'unknown',
      ));
    }
    values['subtitle codec (selected / requested)'] =
        '${codec.isEmpty ? 'unknown' : codec} / $_currentSubtitleCodec';
    values['subtitle delivery (requested)'] = _subtitleDelivery;
    values['subtitle renderer'] = MpvSubtitleRoute(
      codec: codec,
      expectedCodec: _currentSubtitleCodec,
      sid: values['sid'] ?? '',
      ass: values['sub-ass'] ?? '',
      override: values['sub-ass-override'] ?? '',
      visibility: values['sub-visibility'] ?? '',
      plainOverlay:
          _subtitleRoute.value.plainOverlay && values['sub-visibility'] == 'no',
    ).renderer;
    if (isStyledSubtitle(codec)) {
      values['active ASS effect tags (content hidden)'] =
          activeAssEffects(await _readProperty(player, 'sub-text-ass'));
    } else if (isStyledSubtitle(_currentSubtitleCodec) && codec.isNotEmpty) {
      values['subtitle source warning'] =
          'ASS requested, but native decoder received $codec';
    }
    values['plain subtitle preference (saved)'] =
        '${_settings.useLibass} (ASS always native)';
    values.addAll(_renderCapabilities.diagnostics);
    values.addAll(_hdrToneMapper?.diagnostics ??
        {'HDR SDR policy': _renderCapabilities.reason});
    return values;
  }

  @override
  void applySubtitleSettings(SubtitleSettingsModel settings) {
    _externalEncoding = settings.externalEncoding;
  }

  @override
  Future<void> addToPlaylist(String url) async => _player?.add(mpv.Media(url));

  @override
  Future<void> removeFromPlaylist(int index) async => _player?.remove(index);

  @override
  Future<void> playerNext() async => _player?.next();

  @override
  Future<void> playerPrevious() async => _player?.previous();

  @override
  Stream<int> get playlistIndexStream =>
      _player?.stream.playlist.map((p) => p.index) ?? const Stream<int>.empty();

  @override
  Future<void> stop() async {
    final generation = ++_mediaLoadGeneration;
    _desiredPlaying = false;
    _loadReadiness?.cancel();
    _loadReadiness = null;
    _activeDiagnosticAttempt = null;
    _diagnosticOpening = false;
    final player = _player;
    final hdr = _hdrToneMapper;
    if (hdr != null) {
      await stopMpvWithHdr(
        mapper: hdr,
        isCurrent: () =>
            generation == _mediaLoadGeneration && player == _player,
        stop: () async {
          await player?.stop();
        },
        surfaceReady: (ready) => _hdrSurfaceReady.value = ready,
        forceCover: _hdrPreparing,
      );
    } else {
      await player?.stop();
    }
    if (generation != _mediaLoadGeneration || player != _player) return;
    _nextHdrSource = const MpvHdrSource();
    _subtitleGeneration++;
    _subtitleSeekRefresh.cancel();
    _webSubtitleTiming.clearTrack();
    _subtitleOffsets.clear();
    _primarySubtitle = null;
    _subtitleTextReady = false;
    _subtitleTexts.value = const SubtitleTextPair();
    secondarySubtitles.value = const SecondarySubtitleState();
    _subtitleRoute.value = const MpvSubtitleRoute();
    _currentSubtitleCodec = '';
    _subtitleDelivery = 'off';
    await _subtitleOffsets.idle;
    unawaited(_audioSession?.setActive(false));
    if (generation == _mediaLoadGeneration && player == _player) {
      _hdrPreparing = false;
    }
  }

  @override
  Future<Uint8List?> takeScreenshot() async {
    return _player?.screenshot(
        format: "image/png", includeLibassSubtitles: true);
  }

  @override
  Future<ui.Image?> captureAmbientFrame(double maxDimension) =>
      captureAmbientVideoFrame(_player?.platform, maxDimension);

  @override
  Widget? videoWidget(
    Key key,
    BoxFit fit,
  ) =>
      _controller == null
          ? null
          : ValueListenableBuilder<bool>(
              valueListenable: _hdrSurfaceReady,
              builder: (context, ready, child) => Stack(
                fit: StackFit.passthrough,
                children: [
                  child!,
                  if (!ready)
                    const Positioned.fill(
                        child: ColoredBox(color: Colors.black))
                ],
              ),
              child: Video(
                key: key,
                controller: _controller!,
                wakelock: false,
                fill: Colors.transparent,
                fit: fit,
                subtitleViewConfiguration:
                    const SubtitleViewConfiguration(visible: false),
                controls: NoVideoControls,
              ),
            );

  @override
  Widget? subtitles(
    bool showOverlay, {
    GlobalKey? controlsKey,
  }) =>
      _controller != null
          ? ValueListenableBuilder<MpvSubtitleRoute>(
              valueListenable: _subtitleRoute,
              builder: (context, route, child) => route.plainOverlay
                  ? _VideoSubtitles(
                      texts: _subtitleTexts,
                      dualText: route.dualText,
                      showOverlay: showOverlay,
                      controlsKey: controlsKey,
                    )
                  : const SizedBox.shrink(),
            )
          : null;

  @override
  Future<void> setVolume(double volume) async {
    _fadeTimer?.cancel();
    _preferredVolume = volume.clamp(0.0, 100.0);
    await _player?.setVolume(_preferredVolume);
  }

  @override
  Future<void> loop(bool loop) async {
    if (loop && _onCompleted == null) {
      _onCompleted = _player?.stream.completed.listen((completed) {
        if (completed) {
          _player?.play();
        }
      });
    } else {
      _onCompleted?.cancel();
    }
  }
}

class _VideoSubtitles extends ConsumerStatefulWidget {
  final ValueListenable<SubtitleTextPair> texts;
  final bool dualText;
  final bool showOverlay;
  final GlobalKey? controlsKey;

  const _VideoSubtitles({
    required this.texts,
    required this.dualText,
    this.showOverlay = false,
    this.controlsKey,
  });

  @override
  _VideoSubtitlesState createState() => _VideoSubtitlesState();
}

class _VideoSubtitlesState extends ConsumerState<_VideoSubtitles> {
  double? _cachedMenuHeight;

  @override
  Widget build(BuildContext context) {
    _measureMenuHeight();

    final settings = ref.watch(subtitleSettingsProvider);
    final padding = MediaQuery.paddingOf(context);

    final offset = SubtitlePositionCalculator.calculateOffset(
      settings: settings,
      showOverlay: widget.showOverlay,
      screenHeight: MediaQuery.sizeOf(context).height,
      menuHeight: _cachedMenuHeight,
    );

    return ValueListenableBuilder<SubtitleTextPair>(
      valueListenable: widget.texts,
      builder: (context, text, child) => widget.dualText
          ? DualSubtitleText(
              primaryText: text.primary,
              secondaryText: text.secondary,
              settings: settings,
              padding: padding,
              bottomOffset: offset,
            )
          : SubtitleText(
              subModel: settings,
              padding: padding,
              offset: offset,
              text: text.primary),
    );
  }

  void _measureMenuHeight() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.controlsKey == null) return;

      final RenderBox? renderBox =
          widget.controlsKey?.currentContext?.findRenderObject() as RenderBox?;
      final newHeight = renderBox?.size.height;

      if (newHeight != _cachedMenuHeight && newHeight != null) {
        setState(() {
          _cachedMenuHeight = newHeight;
        });
      }
    });
  }
}
