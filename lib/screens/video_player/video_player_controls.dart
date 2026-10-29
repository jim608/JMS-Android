import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:async/async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_plus/iconsax_plus.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:volume_controller/volume_controller.dart';

import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/items/media_segments_model.dart';
import 'package:fladder/models/items/media_streams_model.dart';
import 'package:fladder/models/media_playback_model.dart';
import 'package:fladder/models/playback/playback_model.dart';
import 'package:fladder/models/settings/video_player_settings.dart';
import 'package:fladder/providers/pip_provider.dart';
import 'package:fladder/providers/settings/client_settings_provider.dart';
import 'package:fladder/providers/settings/video_player_settings_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/screens/shared/default_title_bar.dart';
import 'package:fladder/screens/shared/media/components/item_logo.dart';
import 'package:fladder/screens/video_player/components/video_playback_information.dart';
import 'package:fladder/screens/video_player/components/player_controller_navigation.dart';
import 'package:fladder/screens/video_player/components/chapter_navigation_controls.dart';
import 'package:fladder/screens/video_player/components/segment_skip_overlay.dart';
import 'package:fladder/providers/segment_skip_provider.dart';
import 'package:fladder/providers/syncplay_provider.dart';
import 'package:fladder/services/playback/segment_skip_policy.dart';
import 'package:fladder/screens/video_player/components/video_player_brightness_indicator.dart';
import 'package:fladder/screens/video_player/components/video_player_options_sheet.dart';
import 'package:fladder/screens/video_player/components/subtitle_offset_dialog.dart';
import 'package:fladder/screens/video_player/components/syncplay_dialog.dart';
import 'package:fladder/screens/video_player/components/video_player_quality_controls.dart';
import 'package:fladder/screens/video_player/components/video_player_screenshot_indicator.dart';
import 'package:fladder/screens/video_player/components/video_player_seek_indicator.dart';
import 'package:fladder/screens/video_player/components/video_player_speed_indicator.dart';
import 'package:fladder/screens/video_player/components/video_player_volume_indicator.dart';
import 'package:fladder/screens/video_player/components/video_progress_bar.dart';
import 'package:fladder/screens/video_player/components/video_volume_slider.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/duration_extensions.dart';
import 'package:fladder/util/input_handler.dart';
import 'package:fladder/util/list_padding.dart';
import 'package:fladder/util/localization_helper.dart';
import 'package:fladder/util/local_subtitle_selection.dart';
import 'package:fladder/util/string_extensions.dart';
import 'package:fladder/widgets/full_screen_helpers/full_screen_wrapper.dart';
import 'package:fladder/wrappers/pip_manager.dart';

class DesktopControls extends ConsumerStatefulWidget {
  const DesktopControls({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _DesktopControlsState();
}

class _DesktopControlsState extends ConsumerState<DesktopControls> {
  final GlobalKey _bottomControlsKey = GlobalKey();
  final FocusNode _playControl = FocusNode(debugLabel: 'Player play/pause');

  InputDevice get inputDevice => AdaptiveLayout.inputDeviceOf(context);

  final Set<int> _activePointers = {};
  bool _routeIsCurrent = true;

  late RestartableTimer timer = RestartableTimer(
    const Duration(seconds: 10),
    () {
      if (!mounted) return;
      if (AdaptiveLayout.of(context).controllerMode ||
          _activePointers.isNotEmpty ||
          !_routeIsCurrent ||
          ModalRoute.of(context)?.isCurrent == false) {
        timer.cancel();
        return;
      }
      toggleOverlay(value: false);
    },
  );

  double? previousVolume;

  final fadeDuration = const Duration(milliseconds: 350);
  bool showOverlay = true;
  bool wasPlaying = false;
  SystemUiMode? _currentSystemUiMode;

  bool _speedBoostActive = false;
  double? _originalSpeed;

  Offset? _doubleTapPosition;

  final SeekIndicatorController _seekController = SeekIndicatorController();

  late final double topPadding = MediaQuery.of(context).viewPadding.top;
  late final double bottomPadding = MediaQuery.of(context).viewPadding.bottom;

  String? _vDragSide;
  double? _vDragStartValue;
  double? _vDragLastValue;

  int? _lastSelectedSubtitleIndex;

  @override
  void initState() {
    super.initState();
    timer.reset();
    _lastSelectedSubtitleIndex = null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final isCurrent = ModalRoute.isCurrentOf(context) ?? true;
    if (_routeIsCurrent == isCurrent) return;
    _routeIsCurrent = isCurrent;
    // A menu or another route owns interaction until the player is current.
    // Returning starts a full inactivity window rather than a partial one.
    resetTimer();
  }

  @override
  void dispose() {
    _deactivateSpeedBoost();
    timer.cancel();
    _playControl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isInPip = ref.watch(pipStateProvider).asData?.value ?? false;
    final player = ref.watch(videoPlayerProvider);
    if (isInPip) {
      // Keep only the subtitle widget so it's captured in the PiP frame.
      final pipSubtitleWidget = player.subtitleWidget(false, controlsKey: _bottomControlsKey);
      return Stack(
        children: [
          if (pipSubtitleWidget != null) Positioned.fill(child: pipSubtitleWidget),
        ],
      );
    }
    final subtitleWidget = player.subtitleWidget(showOverlay, controlsKey: _bottomControlsKey);
    final isDesktop = AdaptiveLayout.of(context).isDesktop || kIsWeb;
    final speedBoostEnabled = ref.watch(videoPlayerSettingsProvider.select((value) => value.enableSpeedBoost));
    final subtitleOffsetVisible = ref.watch(subtitleOffsetVisibleProvider);

    final controllerMode = AdaptiveLayout.of(context).controllerMode;
    return PlayerControllerNavigation(
      enabled: controllerMode,
      controlsVisible: showOverlay,
      primaryControl: _playControl,
      showControls: () => toggleOverlay(value: true),
      hideControls: () => toggleOverlay(value: false),
      dismissOverlay: () {
        if (!ref.read(subtitleOffsetVisibleProvider)) return false;
        ref.read(subtitleOffsetVisibleProvider.notifier).state = false;
        return true;
      },
      exitPlayer: () {
        if (ref.read(subtitleOffsetVisibleProvider)) {
          ref.read(subtitleOffsetVisibleProvider.notifier).state = false;
        } else {
          closePlayer();
        }
      },
      child: Listener(
        onPointerDown: (event) {
          _activePointers.add(event.pointer);
          timer.cancel();
        },
        onPointerUp: _endPointerInteraction,
        onPointerCancel: _endPointerInteraction,
        onPointerSignal: subtitleOffsetVisible ? null : setVolume,
        child: InputHandler(
          autoFocus: true,
          keyMap: ref.watch(videoPlayerSettingsProvider.select((value) => value.currentShortcuts)),
          keyMapResult: _onKey,
          onKeyEvent: isDesktop && speedBoostEnabled
              ? (node, event) {
                  if (event.logicalKey == LogicalKeyboardKey.space) {
                    return _handleSpacebarEvent(event);
                  }
                  return KeyEventResult.ignored;
                }
              : null,
          child: PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, result) {
              if (!didPop) {
                if (ref.read(subtitleOffsetVisibleProvider)) {
                  ref.read(subtitleOffsetVisibleProvider.notifier).state = false;
                } else {
                  closePlayer();
                }
              }
            },
            child: MouseRegion(
              cursor: showOverlay || subtitleOffsetVisible ? SystemMouseCursors.basic : SystemMouseCursors.none,
              // Touch browsers may emit enter/exit around a tap. Only an
              // actual mouse in pointer mode owns hover visibility.
              onExit: (event) {
                if (!controllerMode &&
                    _isMouseHover(event) &&
                    _activePointers.isEmpty &&
                    ModalRoute.of(context)?.isCurrent != false) {
                  toggleOverlay(value: false);
                }
              },
              onEnter: (event) {
                if (_isMouseHover(event)) toggleOverlay(value: true);
              },
              onHover: (event) {
                if (_isMouseHover(event)) toggleOverlay(value: true);
              },
              child: Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      supportedDevices: const {PointerDeviceKind.mouse, PointerDeviceKind.trackpad},
                      onDoubleTap: () => fullScreenHelper.toggleFullScreen(ref),
                      //better play/pause handling on Desktop (works with dragging on click)
                      onHorizontalDragDown: (details) => player.playOrPause(),
                      child: GestureDetector(
                        // Select recognizers from this event, including the
                        // first touch before Web's adaptive input mode rebuilds.
                        supportedDevices: const {
                          PointerDeviceKind.touch,
                          PointerDeviceKind.stylus,
                          PointerDeviceKind.invertedStylus,
                          PointerDeviceKind.unknown,
                        },
                        behavior: HitTestBehavior.opaque,
                        onTap: () => toggleOverlay(),
                        onDoubleTapDown: _handleDoubleTapDown,
                        onDoubleTap: _handleDoubleTapSeek,
                        onLongPressStart: _handleLongPressStart,
                        onLongPressEnd: _handleLongPressEnd,
                        // Native display brightness/system volume plugins
                        // have no browser implementation.
                        onVerticalDragStart: kIsWeb ? null : _handleVerticalDragStart,
                        onVerticalDragUpdate: kIsWeb ? null : _handleVerticalDragUpdate,
                        onVerticalDragEnd: kIsWeb ? null : _handleVerticalDragEnd,
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                  if (subtitleWidget != null) subtitleWidget,
                  if (AdaptiveLayout.of(context).isDesktop)
                    Consumer(builder: (context, ref, child) {
                      final playing = ref.watch(mediaPlaybackProvider.select((value) => value.playing));
                      final buffering = ref.watch(mediaPlaybackProvider.select((value) => value.buffering));
                      return playButton(playing, buffering);
                    }),
                  ExcludeFocus(
                    excluding: !showOverlay,
                    child: IgnorePointer(
                      ignoring: !showOverlay,
                      child: AnimatedOpacity(
                        duration: fadeDuration,
                        opacity: showOverlay ? 1 : 0,
                        child: Column(
                          children: [
                            topButtons(context),
                            const Spacer(),
                            bottomButtons(context),
                          ],
                        ),
                      ),
                    ),
                  ),
                  VideoPlayerSeekIndicator(controller: _seekController),
                  const VideoPlayerVolumeIndicator(),
                  const VideoPlayerBrightnessIndicator(),
                  const VideoPlayerSpeedIndicator(),
                  const VideoPlayerScreenshotIndicator(),
                  SegmentSkipOverlay(onInteraction: resetTimer),
                  const Positioned.fill(child: SubtitleOffsetOverlay()),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget playButton(bool playing, bool buffering) {
    return ExcludeFocus(
      excluding: playing || buffering || !showOverlay,
      child: IgnorePointer(
        ignoring: playing || buffering || !showOverlay,
        child: Align(
          alignment: Alignment.center,
          child: AnimatedScale(
            curve: Curves.easeInOutCubicEmphasized,
            scale: !showOverlay || playing || buffering ? 0 : 1,
            duration: const Duration(milliseconds: 250),
            child: IconButton.outlined(
              onPressed: () => ref.read(videoPlayerProvider).play(),
              isSelected: true,
              iconSize: 65,
              tooltip: "Resume video",
              icon: const Icon(IconsaxPlusBold.play),
            ),
          ),
        ),
      ),
    );
  }

  Widget topButtons(BuildContext context) {
    final currentItem = ref.watch(playBackModel.select((value) => value?.item));
    final maxHeight = 150.clamp(50, (MediaQuery.sizeOf(context).height * 0.25).clamp(51, double.maxFinite)).toDouble();
    return Container(
      decoration: BoxDecoration(
          gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.black.withValues(alpha: 0.8),
          Colors.black.withValues(alpha: 0),
        ],
      )),
      child: Padding(
        padding: MediaQuery.paddingOf(context).copyWith(bottom: 0, top: 0),
        child: Container(
          alignment: Alignment.topCenter,
          child: Column(
            children: [
              const Align(
                alignment: Alignment.topCenter,
                child: DefaultTitleBar(),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  spacing: 16,
                  mainAxisSize: MainAxisSize.max,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    IconButton(
                      onPressed: () => minimizePlayer(context),
                      icon: const Icon(
                        IconsaxPlusLinear.arrow_down_1,
                        size: 24,
                      ),
                    ),
                    if (currentItem != null)
                      Expanded(
                        child: Row(
                          children: [
                            Flexible(
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxHeight: maxHeight,
                                ),
                                child: ItemLogo(
                                  item: currentItem,
                                  imageAlignment: Alignment.topLeft,
                                  textStyle: Theme.of(context).textTheme.headlineLarge,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SyncPlayButton(),
                    if (inputDevice == InputDevice.touch)
                      Align(
                        alignment: Alignment.centerRight,
                        child: Tooltip(
                            message: context.localized.stop,
                            child: IconButton(
                                onPressed: () => closePlayer(), icon: const Icon(IconsaxPlusLinear.close_square))),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget bottomButtons(BuildContext context) {
    return Consumer(builder: (context, ref, child) {
      final playing = ref.watch(mediaPlaybackProvider.select((state) => state.playing));
      final bitRateOptions = ref.watch(playBackModel.select((value) => value?.bitRateOptions));
      return Container(
        key: _bottomControlsKey,
        decoration: BoxDecoration(
            gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            Colors.black.withValues(alpha: 0.8),
            Colors.black.withValues(alpha: 0),
          ],
        )),
        child: Padding(
          padding: MediaQuery.paddingOf(context).add(
            const EdgeInsets.symmetric(horizontal: 16).copyWith(bottom: 12),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Consumer(
                  builder: (context, ref, child) {
                    final mediaPlayback = ref.watch(mediaPlaybackProvider);
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ChapterNavigationControls(controllerMode: AdaptiveLayout.of(context).controllerMode),
                        progressBar(mediaPlayback),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
              LayoutBuilder(builder: (context, constraints) {
                final compact = constraints.maxWidth < 600 ||
                    (AdaptiveLayout.of(context).controllerMode && constraints.maxWidth < 1000);
                final leading = Row(
                  children: <Widget>[
                    IconButton(
                        onPressed: () => showVideoPlayerOptions(context, () => minimizePlayer(context)),
                        icon: const Icon(IconsaxPlusLinear.more)),
                    if (AdaptiveLayout.viewSizeOf(context) >= ViewSize.desktop) const SubtitleOffsetButton(),
                    if (pipPlatformSupported && MediaQuery.orientationOf(context) == Orientation.landscape)
                      IconButton(
                        tooltip: context.localized.pictureInPictureTitle,
                        onPressed: () async {
                          final ok = await ref.read(pipManagerProvider).enter();
                          if (!ok && context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(context.localized.pictureInPictureNotSupported)),
                            );
                          }
                        },
                        icon: const Icon(IconsaxPlusLinear.screenmirroring),
                      ),
                    if (AdaptiveLayout.layoutOf(context) == ViewSize.tablet) ...[
                      IconButton(
                        onPressed: () => showSubSelection(context),
                        icon: const Icon(IconsaxPlusLinear.subtitle),
                      ),
                      IconButton(
                        onPressed: () => showAudioSelection(context),
                        icon: const Icon(IconsaxPlusLinear.audio_square),
                      ),
                    ],
                    if (AdaptiveLayout.layoutOf(context) >= ViewSize.desktop) ...[
                      Flexible(
                        child: ElevatedButton.icon(
                          onPressed: () => showSubSelection(context),
                          icon: const Icon(IconsaxPlusLinear.subtitle),
                          label: Text(
                            ref.watch(playBackModel.select((value) {
                                  final language = value?.mediaStreams?.currentSubStream?.language;
                                  return language?.isEmpty == true ? context.localized.off : language;
                                }))?.capitalize() ??
                                "",
                            maxLines: 1,
                          ),
                        ),
                      ),
                      Flexible(
                        child: ElevatedButton.icon(
                          onPressed: () => showAudioSelection(context),
                          icon: const Icon(IconsaxPlusLinear.audio_square),
                          label: Text(
                            ref.watch(playBackModel.select((value) {
                                  final language = value?.mediaStreams?.currentAudioStream?.language;
                                  return language?.isEmpty == true ? context.localized.off : language;
                                }))?.capitalize() ??
                                "",
                            maxLines: 1,
                          ),
                        ),
                      )
                    ],
                  ].addInBetween(const SizedBox(
                    width: 4,
                  )),
                );
                final transport = Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      previousButton,
                      seekBackwardButton(ref),
                      IconButton.filledTonal(
                        focusNode: _playControl,
                        iconSize: 38,
                        onPressed: () {
                          ref.read(videoPlayerProvider).playOrPause();
                        },
                        icon: Icon(
                          playing ? IconsaxPlusBold.pause : IconsaxPlusBold.play,
                        ),
                      ),
                      seekForwardButton(ref),
                      nextVideoButton,
                    ].addInBetween(const SizedBox(width: 6)));
                final trailing = Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (inputDevice == InputDevice.pointer || AdaptiveLayout.of(context).isDesktop)
                      Tooltip(
                        message: context.localized.stop,
                        child: IconButton(
                          onPressed: () => closePlayer(),
                          icon: const Icon(IconsaxPlusLinear.close_square),
                        ),
                      ),
                    if (AdaptiveLayout.viewSizeOf(context) >= ViewSize.tablet &&
                        ref.read(videoPlayerProvider).hasPlayer) ...{
                      if (bitRateOptions?.isNotEmpty == true)
                        Tooltip(
                          message: context.localized.qualityOptionsTitle,
                          child: IconButton(
                            onPressed: () => openQualityOptions(context),
                            icon: const Icon(IconsaxPlusLinear.speedometer),
                          ),
                        ),
                    },
                    if ((inputDevice == InputDevice.pointer || AdaptiveLayout.of(context).isDesktop) &&
                        AdaptiveLayout.viewSizeOf(context) > ViewSize.phone) ...[
                      VideoVolumeSlider(
                        onChanged: () => resetTimer(),
                      ),
                    ],
                    if (kIsWeb ||
                        ((inputDevice == InputDevice.pointer || AdaptiveLayout.of(context).isDesktop) &&
                            AdaptiveLayout.viewSizeOf(context) > ViewSize.phone))
                      const FullScreenButton(),
                  ].addInBetween(const SizedBox(width: 8)),
                );
                if (compact) {
                  return Column(mainAxisSize: MainAxisSize.min, children: [
                    transport,
                    const SizedBox(height: 8),
                    Row(children: [Expanded(child: leading), const SizedBox(width: 12), trailing]),
                  ]);
                }
                return Row(
                    children: [
                  Expanded(flex: 2, child: leading),
                  transport,
                  Expanded(flex: 2, child: trailing),
                ].addInBetween(const SizedBox(width: 6)));
              }),
            ],
          ),
        ),
      );
    });
  }

  Widget progressBar(MediaPlaybackModel mediaPlayback) {
    return Consumer(
      builder: (context, ref, child) {
        final playbackModel = ref.watch(playBackModel);
        final item = playbackModel?.item;
        final List<String?> details = [
          if (AdaptiveLayout.of(context).isDesktop) item?.label(context.localized),
          context.localized.endsAt(DateTime.now().add(Duration(
            milliseconds: (mediaPlayback.duration.inMilliseconds - mediaPlayback.position.inMilliseconds) ~/
                ref.read(playbackRateProvider),
          )))
        ];
        return Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    details.nonNulls.join(' - '),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                    maxLines: 2,
                  ),
                ),
                const Spacer(),
                if (playbackModel != null)
                  InkWell(
                    onTap: () => showVideoPlaybackInformation(context),
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        child: Text(
                          playbackModel.label(context) ?? "",
                        ),
                      ),
                    ),
                  ),
                if (item != null) ...{
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      child: Text(
                        item.streamModel?.mediaInfoTag ?? "",
                      ),
                    ),
                  ),
                },
              ].addPadding(const EdgeInsets.symmetric(horizontal: 4)),
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: 25,
              child: VideoProgressBar(
                wasPlayingChanged: (value) => wasPlaying = value,
                wasPlaying: wasPlaying,
                duration: mediaPlayback.duration,
                position: mediaPlayback.position,
                buffer: mediaPlayback.buffer,
                buffering: mediaPlayback.buffering,
                timerReset: resetTimer,
                onPositionChanged: (position) => ref.read(videoPlayerProvider).seek(position),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  mediaPlayback.position.readAbleDuration,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                Text(
                  "-${(mediaPlayback.duration - mediaPlayback.position).readAbleDuration}",
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget get previousButton {
    return Consumer(
      builder: (context, ref, child) {
        final previousVideo = ref.watch(playBackModel.select((value) => value?.previousVideo));
        return Tooltip(
          message: previousVideo?.detailedName(context.localized) ?? "",
          textAlign: TextAlign.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.95),
          ),
          textStyle: Theme.of(context).textTheme.labelLarge,
          child: IconButton(
            onPressed: loadPreviousVideo(ref, video: previousVideo),
            iconSize: 30,
            icon: const Icon(
              IconsaxPlusLinear.backward,
            ),
          ),
        );
      },
    );
  }

  Function()? loadPreviousVideo(WidgetRef ref, {ItemBaseModel? video}) {
    final previousVideo = video ?? ref.read(playBackModel.select((value) => value?.previousVideo));
    final buffering = ref.read(mediaPlaybackProvider.select((value) => value.buffering));
    return previousVideo != null && !buffering ? () => ref.read(playbackModelHelper).loadNewVideo(previousVideo) : null;
  }

  Widget get nextVideoButton {
    return Consumer(
      builder: (context, ref, child) {
        final nextVideo = ref.watch(playBackModel.select((value) => value?.nextVideo));
        return Tooltip(
          message: nextVideo?.detailedName(context.localized) ?? "",
          textAlign: TextAlign.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.95),
          ),
          textStyle: Theme.of(context).textTheme.labelLarge,
          child: IconButton(
            onPressed: loadNextVideo(ref, video: nextVideo),
            iconSize: 30,
            icon: const Icon(
              IconsaxPlusLinear.forward,
            ),
          ),
        );
      },
    );
  }

  Function()? loadNextVideo(WidgetRef ref, {ItemBaseModel? video}) {
    final nextVideo = video ?? ref.read(playBackModel.select((value) => value?.nextVideo));
    final buffering = ref.read(mediaPlaybackProvider.select((value) => value.buffering));
    return nextVideo != null && !buffering ? () => ref.read(playbackModelHelper).loadNewVideo(nextVideo) : null;
  }

  Widget seekBackwardButton(WidgetRef ref) {
    final backwardSpeed =
        ref.read(userProvider.select((value) => value?.userSettings?.skipBackDuration.inSeconds ?? 30));
    return IconButton(
      onPressed: () => seekBack(ref, seconds: backwardSpeed),
      tooltip: "-$backwardSpeed",
      iconSize: 40,
      icon: Stack(
        alignment: Alignment.center,
        children: [
          const Icon(
            IconsaxPlusBroken.refresh,
            size: 45,
          ),
          Transform.translate(
            offset: const Offset(0, 1),
            child: Text(
              "-$backwardSpeed",
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget seekForwardButton(WidgetRef ref) {
    final forwardSpeed =
        ref.read(userProvider.select((value) => value?.userSettings?.skipForwardDuration.inSeconds ?? 30));
    return IconButton(
      onPressed: () => seekForward(ref, seconds: forwardSpeed),
      tooltip: forwardSpeed.toString(),
      iconSize: 40,
      icon: Stack(
        alignment: Alignment.center,
        children: [
          Transform.flip(
            flipX: true,
            child: const Icon(
              IconsaxPlusBroken.refresh,
              size: 45,
            ),
          ),
          Transform.translate(
            offset: const Offset(0, 1),
            child: Text(
              forwardSpeed.toString(),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  void skipToSegmentEnd(MediaSegment? mediaSegment, String? segmentId) {
    final playback = ref.read(mediaPlaybackProvider);
    final player = ref.read(videoPlayerProvider);
    final sync = ref.read(syncPlayProvider);
    if (mediaSegment != null &&
        mediaSegment.inRange(playback.position) &&
        SegmentSkipPolicy.validSegments(ref.read(playBackModel)?.mediaSegments?.segments ?? const [],
            duration: playback.duration).contains(mediaSegment) &&
        segmentSkipCanSeek(sync.room,
            wrapperActive: player.syncPlayActive,
            busy: sync.busy || sync.leavePending || sync.preparingPlayback || sync.recoveryActive)) {
      resetTimer();
      ref.read(segmentSkipSessionProvider).policy.markSkipped(mediaSegment);
      player.seek(mediaSegment.end);
    }
  }

  void seekBack(WidgetRef ref, {int seconds = 15}) {
    _seek(ref, -seconds);
  }

  void seekForward(WidgetRef ref, {int seconds = 15}) {
    _seek(ref, seconds);
  }

  void _seek(WidgetRef ref, int seconds) {
    final mediaPlayback = ref.read(mediaPlaybackProvider);
    resetTimer();
    final newPosition = (mediaPlayback.position.inSeconds + seconds).clamp(0, mediaPlayback.duration.inSeconds);
    ref.read(videoPlayerProvider).seek(Duration(seconds: newPosition));
  }

  void stepBack(WidgetRef ref) {
    _step(ref, -1);
  }

  void stepForward(WidgetRef ref) {
    _step(ref, 1);
  }

  void _step(WidgetRef ref, int frames) {
    final mediaPlayback = ref.read(mediaPlaybackProvider);
    final framerate = ref.read(playBackModel.select((value) => value?.mediaStreams?.videoStreams.first.frameRate));
    if (framerate == null || framerate == 0) return;

    final step = ((1000000.0 / framerate) * frames).round();
    resetTimer();
    final newPosition = (mediaPlayback.position.inMicroseconds + step).clamp(0, mediaPlayback.duration.inMicroseconds);
    ref.read(videoPlayerProvider).seek(Duration(microseconds: newPosition));
  }

  void seekBackWithIndicator() {
    _seekController.seekBack();
  }

  void seekForwardWithIndicator() {
    _seekController.seekForward();
  }

  void toggleOverlay({bool? value}) {
    final visible = value ?? !showOverlay;
    final changed = showOverlay != visible;
    if (changed) setState(() => showOverlay = visible);
    if (visible) {
      resetTimer();
    } else {
      timer.cancel();
    }
    if (!changed) return;

    final desiredMode = showOverlay ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky;

    if (_currentSystemUiMode != desiredMode) {
      _currentSystemUiMode = desiredMode;
      SystemChrome.setEnabledSystemUIMode(desiredMode, overlays: []);
    }

    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarDividerColor: Colors.transparent,
    ));
  }

  Future<void> minimizePlayer(BuildContext context) async {
    await clearOverlaySettings();
    if (!context.mounted) return;
    ref.read(mediaPlaybackProvider.notifier).update((state) => state.copyWith(state: VideoPlayerState.minimized));
    Navigator.of(context).pop();
  }

  void resetTimer() {
    if (!mounted || !showOverlay || !_routeIsCurrent || _activePointers.isNotEmpty) {
      timer.cancel();
      return;
    }
    timer.reset();
  }

  bool _isMouseHover(PointerEvent event) => event.kind == PointerDeviceKind.mouse && inputDevice == InputDevice.pointer;

  void _endPointerInteraction(PointerEvent event) {
    _activePointers.remove(event.pointer);
    if (_activePointers.isEmpty && showOverlay) resetTimer();
  }

  Future<void> closePlayer() async {
    await clearOverlaySettings();
    if (!mounted) return;
    ref.read(videoPlayerProvider).stop();
    Navigator.of(context).pop();
  }

  Future<void> clearOverlaySettings() async {
    toggleOverlay(value: true);
    timer.cancel();
    if (kIsWeb) {
      await fullScreenHelper.closeFullScreen(ref);
    } else if (inputDevice != InputDevice.pointer) {
      ScreenBrightness().resetApplicationScreenBrightness();
    } else {
      disableFullScreen();
    }

    if (!mounted) return;
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarIconBrightness: ref.read(clientSettingsProvider.select((value) => value.statusBarBrightness(context))),
    ));
    timer.cancel();
  }

  Future<void> disableFullScreen() async {
    resetTimer();
    if (kIsWeb || (AdaptiveLayout.of(context).isDesktop && defaultTargetPlatform != TargetPlatform.macOS)) {
      await fullScreenHelper.closeFullScreen(ref);
    }
  }

  void setVolume(PointerEvent event) {
    if (event is PointerScrollEvent) {
      resetTimer();
      if (event.scrollDelta.dy > 0) {
        ref.read(videoPlayerSettingsProvider.notifier).steppedVolume(-5);
      } else {
        ref.read(videoPlayerSettingsProvider.notifier).steppedVolume(5);
      }
    }
  }

  void _activateSpeedBoost() {
    if (_speedBoostActive || ref.read(videoPlayerProvider).syncPlayActive) return;

    final settings = ref.read(videoPlayerSettingsProvider);
    if (!settings.enableSpeedBoost) return;

    _originalSpeed = ref.read(playbackRateProvider);
    _speedBoostActive = true;
    ref.read(videoPlayerProvider).setSpeed(settings.speedBoostRate);
    ref.read(playbackRateProvider.notifier).state = settings.speedBoostRate;
  }

  void _deactivateSpeedBoost() {
    if (!_speedBoostActive) return;

    _speedBoostActive = false;
    if (_originalSpeed != null) {
      ref.read(videoPlayerProvider).setSpeed(_originalSpeed!);
      ref.read(playbackRateProvider.notifier).state = _originalSpeed!;
      _originalSpeed = null;
    }
  }

  // --- Keyboard Speed Boost Handler (Desktop) ---

  KeyEventResult _handleSpacebarEvent(KeyEvent event) {
    resetTimer();
    if (event is KeyDownEvent) {
      return KeyEventResult.handled;
    } else if (event is KeyRepeatEvent) {
      final isPlaying = ref.read(mediaPlaybackProvider.select((value) => value.playing));
      if (isPlaying) {
        _activateSpeedBoost();
      }
      return KeyEventResult.handled;
    } else if (event is KeyUpEvent) {
      if (_speedBoostActive) {
        _deactivateSpeedBoost();
      } else {
        ref.read(videoPlayerProvider).playOrPause();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // --- Touch Gesture Handlers (Mobile) ---

  void _handleDoubleTapDown(TapDownDetails details) {
    final doubleTapSeekEnabled = ref.read(videoPlayerSettingsProvider.select((value) => value.enableDoubleTapSeek));
    if (doubleTapSeekEnabled) {
      _doubleTapPosition = details.globalPosition;
    }
  }

  void _handleDoubleTapSeek() {
    final doubleTapSeekEnabled = ref.read(videoPlayerSettingsProvider.select((value) => value.enableDoubleTapSeek));
    if (!doubleTapSeekEnabled) return;

    final screenWidth = MediaQuery.sizeOf(context).width;
    final tapX = _doubleTapPosition?.dx ?? screenWidth / 2;
    final zoneThird = screenWidth / 3;

    if (tapX < zoneThird) {
      seekBackWithIndicator();
    } else if (tapX > zoneThird * 2) {
      seekForwardWithIndicator();
    } else {
      ref.read(videoPlayerProvider).playOrPause();
    }
    _doubleTapPosition = null;
  }

  void _handleLongPressStart(LongPressStartDetails details) {
    final settings = ref.read(videoPlayerSettingsProvider);
    final isPlaying = ref.read(mediaPlaybackProvider.select((value) => value.playing));
    if (settings.enableSpeedBoost && isPlaying) {
      _activateSpeedBoost();
    }
  }

  void _handleLongPressEnd(LongPressEndDetails details) {
    _deactivateSpeedBoost();
  }

  Future<void> _handleVerticalDragStart(DragStartDetails details) async {
    final settings = ref.read(videoPlayerSettingsProvider);
    if (!settings.enableEdgeGestures) return;

    final size = MediaQuery.sizeOf(context);
    final y = details.localPosition.dy;
    // Safety margin of 10% top/bottom to avoid accidental system gestures (notification tray, home bar)
    if (y < size.height * 0.1 || y > size.height * 0.9) {
      _vDragSide = null;
      return;
    }

    final isLeft = details.localPosition.dx < size.width / 2;
    final isBrightness = settings.reverseEdgeGestures ? !isLeft : isLeft;

    _vDragSide = isBrightness ? 'brightness' : 'volume';

    if (isBrightness) {
      _vDragStartValue = settings.screenBrightness ?? 1.0;
    } else {
      final currentVolume = ({TargetPlatform.android, TargetPlatform.iOS}.contains(defaultTargetPlatform))
          ? (await VolumeController.instance.getVolume())
          : settings.volume / 100;
      _vDragStartValue = currentVolume;
    }
    _vDragLastValue = _vDragStartValue;
  }

  void _handleVerticalDragUpdate(DragUpdateDetails details) {
    if (_vDragSide == null || _vDragStartValue == null) return;

    final screenHeight = MediaQuery.sizeOf(context).height;
    // Slide up to increase, down to decrease.
    // details.delta.dy is positive when sliding down.
    final delta = -details.primaryDelta! / (screenHeight * 0.7); // 70% of screen height for full range
    final newValue = (_vDragLastValue! + delta).clamp(0.0, 1.0);

    if (newValue == _vDragLastValue) return;
    _vDragLastValue = newValue;

    if (_vDragSide == 'brightness') {
      ref.read(videoPlayerSettingsProvider.notifier).setScreenBrightness(newValue);
    } else {
      ref.read(videoPlayerSettingsProvider.notifier).setVolume(newValue * 100);
    }
  }

  void _handleVerticalDragEnd(DragEndDetails details) {
    _vDragSide = null;
    _vDragStartValue = null;
    _vDragLastValue = null;
  }

  void _toggleSubtitles() {
    final playbackModel = ref.read(playBackModel);
    final player = ref.read(videoPlayerProvider);
    final subStreams = playbackModel?.subStreams;

    if (subStreams == null || subStreams.isEmpty) return;

    // Filter out the "off" track (index == -1)
    final availableSubtitles = subStreams.where((s) => s.index != -1).toList();
    if (availableSubtitles.isEmpty) return;

    final currentIndex = playbackModel?.mediaStreams?.defaultSubStreamIndex ?? -1;
    if (currentIndex != -1) {
      // Subtitles are ON -> Turn OFF and remember this index
      _lastSelectedSubtitleIndex = currentIndex;
      _setSubtitleTrack(SubStreamModel.no(), playbackModel, player);
    } else {
      // Subtitles are OFF -> Turn ON
      if (_lastSelectedSubtitleIndex != null) {
        // Use the last selected index
        final lastSub = subStreams.firstWhere(
          (s) => s.index == _lastSelectedSubtitleIndex,
          orElse: () => availableSubtitles.first,
        );
        _setSubtitleTrack(lastSub, playbackModel, player);
      } else if (availableSubtitles.length == 1) {
        // If only one subtitle is available, just use it
        _setSubtitleTrack(availableSubtitles.first, playbackModel, player);
      } else {
        // Multiple subtitles and no last selection -> Show selection dialog
        showSubSelection(context).then((_) {
          final newModel = ref.read(playBackModel);
          final selectedIndex = newModel?.mediaStreams?.defaultSubStreamIndex;
          if (selectedIndex != null && selectedIndex != -1) {
            _lastSelectedSubtitleIndex = selectedIndex;
          }
        });
      }
    }
  }

  void _setSubtitleTrack(SubStreamModel subModel, PlaybackModel? playbackModel, dynamic player) async {
    if (playbackModel == null) return;
    final previousSecondary = player.secondarySubtitleState.value.selected;
    final newModel = await trySelectLocalSubtitle(
      model: playbackModel,
      track: subModel,
      player: player,
      isCurrent: () =>
          mounted &&
          identical(ref.read(playBackModel), playbackModel) &&
          identical(ref.read(videoPlayerProvider), player),
      onUnavailable: (_) => ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(context.localized.jmsSecondaryUnavailable))),
    );
    if (newModel == null) return;
    if (mounted && previousSecondary != null && player.secondarySubtitleState.value.selected == null) {
      showSecondarySubtitleNotice(context, player.secondarySubtitleState.value);
    }
    ref.read(playBackModel.notifier).update((state) => newModel);
    await ref.read(playbackModelHelper).shouldReload(newModel);
  }

  bool _onKey(VideoHotKeys value) {
    resetTimer();
    final mediaSegments = ref.read(playBackModel.select((value) => value?.mediaSegments));
    final position = ref.read(mediaPlaybackProvider).position;
    final playing = ref.read(mediaPlaybackProvider.select((value) => value.playing));

    MediaSegment? segment = mediaSegments?.atPosition(position);

    final volume = ref.read(videoPlayerSettingsProvider.select((value) => value.volume));

    switch (value) {
      case VideoHotKeys.playPause:
        if (_speedBoostActive) {
          return false;
        }
        ref.read(videoPlayerProvider).playOrPause();
        return true;
      case VideoHotKeys.volumeUp:
        resetTimer();
        ref.read(videoPlayerSettingsProvider.notifier).steppedVolume(5);
        return true;
      case VideoHotKeys.volumeDown:
        resetTimer();
        ref.read(videoPlayerSettingsProvider.notifier).steppedVolume(-5);
        return true;
      case VideoHotKeys.speedUp:
        resetTimer();
        ref.read(videoPlayerSettingsProvider.notifier).steppedSpeed(0.1);
        return true;
      case VideoHotKeys.speedDown:
        resetTimer();
        ref.read(videoPlayerSettingsProvider.notifier).steppedSpeed(-0.1);
        return true;
      case VideoHotKeys.fullScreen:
        fullScreenHelper.toggleFullScreen(ref);
        return true;
      case VideoHotKeys.skipMediaSegment:
        if (segment != null) {
          skipToSegmentEnd(segment, null);
        }
        return true;
      case VideoHotKeys.exit:
        if (ref.read(subtitleOffsetVisibleProvider)) {
          ref.read(subtitleOffsetVisibleProvider.notifier).state = false;
          return true;
        }
        if (ModalRoute.of(context)?.isCurrent == true) {
          closePlayer();
          return true;
        }
        return false;

      case VideoHotKeys.mute:
        if (volume != 0) {
          previousVolume = volume;
        }
        ref.read(videoPlayerSettingsProvider.notifier).setVolume(volume == 0 ? (previousVolume ?? 100) : 0);
        return true;
      case VideoHotKeys.nextVideo:
        loadNextVideo(ref)?.call();
        return true;
      case VideoHotKeys.prevVideo:
        loadPreviousVideo(ref)?.call();
        return true;
      case VideoHotKeys.nextChapter:
        ref.read(videoPlayerSettingsProvider.notifier).nextChapter();
        return true;
      case VideoHotKeys.prevChapter:
        ref.read(videoPlayerSettingsProvider.notifier).prevChapter();
        return true;
      case VideoHotKeys.toggleSubtitles:
        _toggleSubtitles();
        return true;
      case VideoHotKeys.seekForwardInstant:
        final seekForwardSeconds =
            ref.read(userProvider.select((value) => value?.userSettings?.skipForwardDuration.inSeconds ?? 30));
        seekForward(ref, seconds: seekForwardSeconds);
        return true;
      case VideoHotKeys.seekBackInstant:
        final seekBackSeconds =
            ref.read(userProvider.select((value) => value?.userSettings?.skipBackDuration.inSeconds ?? 30));
        seekBack(ref, seconds: seekBackSeconds);
        return true;
      case VideoHotKeys.stepForward:
        playing ? ref.read(videoPlayerProvider).playOrPause() : stepForward(ref);
        return true;
      case VideoHotKeys.stepBack:
        playing ? ref.read(videoPlayerProvider).playOrPause() : stepBack(ref);
        return true;
      default:
        return false;
    }
  }
}
