import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/models/items/media_segments_model.dart';
import 'package:fladder/providers/segment_skip_provider.dart';
import 'package:fladder/providers/settings/video_player_settings_provider.dart';
import 'package:fladder/providers/syncplay_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/services/playback/segment_skip_policy.dart';
import 'package:fladder/util/localization_helper.dart';

/// The prompt has its own lifetime, independent of the touch controls timer.
/// It never requests focus and only its visible card intercepts pointer input.
class SegmentSkipOverlay extends ConsumerStatefulWidget {
  const SegmentSkipOverlay({required this.onInteraction, super.key});

  final VoidCallback onInteraction;

  @override
  ConsumerState<SegmentSkipOverlay> createState() => _SegmentSkipOverlayState();
}

class _SegmentSkipOverlayState extends ConsumerState<SegmentSkipOverlay> {
  SegmentSkipDecision? _decision;
  Object? _decisionPlaybackId;
  Object? _decisionModel;
  bool _scheduled = false;
  bool _seeking = false;

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) _evaluate();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _evaluate() {
    if (_seeking) return;
    final model = ref.read(playBackModel);
    final playback = ref.read(mediaPlaybackProvider);
    final player = ref.read(videoPlayerProvider);
    final sync = ref.read(syncPlayProvider);
    final session = ref.read(segmentSkipSessionProvider);
    final currentRoute = ModalRoute.of(context)?.isCurrent ?? true;
    final decision = model == null
        ? null
        : session.policy.evaluate(
            playbackId: session.playbackId,
            segments: model.mediaSegments?.segments ?? const [],
            position: playback.position,
            duration: playback.duration,
            modes: ref.read(videoPlayerSettingsProvider).segmentSkipSettings,
            playing: playback.playing && !playback.buffering && currentRoute,
            canAutoSkip: segmentSkipCanAuto(sync.room,
                wrapperActive: player.syncPlayActive,
                busy: sync.busy || sync.leavePending || sync.preparingPlayback || sync.recoveryActive),
          );
    if (decision?.autoSkip == true) {
      setState(() => _decision = null);
      unawaited(
          _skip(decision!.segment, expectedPlaybackId: session.playbackId, expectedModel: model!, automatic: true));
    } else if (_decision?.segment != decision?.segment ||
        _decisionPlaybackId != session.playbackId ||
        !identical(_decisionModel, model)) {
      setState(() {
        _decision = decision;
        _decisionPlaybackId = session.playbackId;
        _decisionModel = model;
      });
    }
  }

  Future<void> _skip(MediaSegment segment,
      {required Object expectedPlaybackId, required Object expectedModel, bool automatic = false}) async {
    if (_seeking || !(ModalRoute.of(context)?.isCurrent ?? true)) return;
    final player = ref.read(videoPlayerProvider);
    final playback = ref.read(mediaPlaybackProvider);
    final sync = ref.read(syncPlayProvider);
    final session = ref.read(segmentSkipSessionProvider);
    final mode = ref.read(videoPlayerSettingsProvider).segmentSkipSettings[segment.type] ?? SegmentSkip.askToSkip;
    final currentSegments = SegmentSkipPolicy.validSegments(
        ref.read(playBackModel)?.mediaSegments?.segments ?? const [],
        duration: playback.duration);
    final stillPresent = currentSegments
        .any((value) => value.type == segment.type && value.start == segment.start && value.end == segment.end);
    if (session.playbackId != expectedPlaybackId ||
        !identical(ref.read(playBackModel), expectedModel) ||
        mode == SegmentSkip.none ||
        (automatic && mode != SegmentSkip.skip && mode != SegmentSkip.skipOnce) ||
        !segment.inRange(playback.position) ||
        !stillPresent ||
        !segmentSkipCanSeek(sync.room,
            wrapperActive: player.syncPlayActive,
            busy: sync.busy || sync.leavePending || sync.preparingPlayback || sync.recoveryActive) ||
        (automatic && !segmentSkipCanAuto(sync.room, wrapperActive: player.syncPlayActive, busy: sync.busy))) {
      return;
    }
    _seeking = true;
    session.policy.markSkipped(segment);
    setState(() => _decision = null);
    widget.onInteraction();
    try {
      if (automatic) {
        await player.seekSegmentAutomatically(segment.end);
      } else {
        await player.seek(segment.end);
      }
    } catch (_) {
      // An uncertain or failed request must not create a seek retry loop.
    } finally {
      _seeking = false;
      if (mounted) _schedule();
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(mediaPlaybackProvider, (_, __) => _schedule());
    ref.listen(playBackModel, (_, __) => _schedule());
    ref.listen(videoPlayerSettingsProvider.select((value) => value.segmentSkipSettings), (_, __) => _schedule());
    ref.listen(syncPlayProvider, (_, __) => _schedule());
    _schedule();
    final sync = ref.watch(syncPlayProvider);
    final active = ref.watch(videoPlayerProvider).syncPlayActive;
    final decision = _decision;
    final decisionPlaybackId = _decisionPlaybackId;
    final decisionModel = _decisionModel;
    if (decision == null || !(ModalRoute.of(context)?.isCurrent ?? true)) return const SizedBox.shrink();
    final canSeek = segmentSkipCanSeek(sync.room,
        wrapperActive: active, busy: sync.busy || sync.leavePending || sync.preparingPlayback || sync.recoveryActive);
    return SafeArea(
      child: Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SegmentSkipCard(
            segment: decision.segment,
            groupPlayback: !segmentSkipCanAuto(sync.room, wrapperActive: active, busy: sync.busy),
            onSkip: canSeek && decisionPlaybackId != null && decisionModel != null
                ? () => _skip(decision.segment, expectedPlaybackId: decisionPlaybackId, expectedModel: decisionModel)
                : null,
            onDismiss: () {
              final session = ref.read(segmentSkipSessionProvider);
              if (session.playbackId == decisionPlaybackId && identical(ref.read(playBackModel), decisionModel)) {
                session.policy.cancel(decision.segment);
              }
              setState(() => _decision = null);
              widget.onInteraction();
            },
          ),
        ),
      ),
    );
  }
}

/// A compact focusable card; no modal barrier, autofocus, fade, or tap-through.
class SegmentSkipCard extends StatelessWidget {
  const SegmentSkipCard(
      {required this.segment, required this.onSkip, required this.onDismiss, this.groupPlayback = false, super.key});

  final MediaSegment segment;
  final VoidCallback? onSkip;
  final VoidCallback onDismiss;
  final bool groupPlayback;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: Listener(
          behavior: HitTestBehavior.opaque,
          child: Material(
            color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.95),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FilledButton.icon(
                    key: const ValueKey('skip-segment'),
                    onPressed: onSkip,
                    icon: const Icon(Icons.fast_forward_rounded),
                    label: Text(context.localized.skipButtonLabel(segment.type.label(context))),
                  ),
                  if (groupPlayback)
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(context.localized.segmentGroupManualHint,
                          textAlign: TextAlign.center, style: Theme.of(context).textTheme.labelSmall),
                    ),
                  TextButton(
                      key: const ValueKey('dismiss-segment'),
                      onPressed: onDismiss,
                      child: Text(context.localized.segmentDismiss)),
                ],
              ),
            ),
          ),
        ),
      );
}
