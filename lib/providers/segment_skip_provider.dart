import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/services/playback/segment_skip_policy.dart';
import 'package:fladder/services/syncplay/syncplay_models.dart';

final segmentSkipSessionProvider = Provider((ref) => SegmentSkipSession());

/// Shared with the seek wrapper so deliberate seeks also reach the policy when
/// the prompt is hidden or a different player control initiates them.
class SegmentSkipSession {
  final policy = SegmentSkipPolicy();
  Object playbackId = Object();
  String? _itemId;
  bool _completed = false;

  void bindItem(String itemId) {
    if (_itemId == itemId && !_completed) return;
    reset();
    _itemId = itemId;
  }

  void reset() {
    _itemId = null;
    _completed = false;
    playbackId = Object();
    policy.reset(playbackId);
  }

  void markCompleted() => _completed = true;

  void manualSeek(Duration from, Duration to) {
    // Seeking back is a deliberate replay inside this occurrence. A later
    // renderer reload must preserve that choice rather than re-arm auto skip.
    _completed = false;
    policy.manualSeek(from, to);
  }
}

/// Jellyfin's current room model has no authoritative leader identity. Until it
/// does, automatic skips are limited to solo playback. Manual skips still use
/// the room's ordinary authorized seek request.
bool segmentSkipCanAuto(SyncPlayControllerState room, {required bool wrapperActive, bool busy = false}) =>
    !wrapperActive && !busy && room.status == SyncPlayStatus.idle;

bool segmentSkipCanSeek(SyncPlayControllerState room, {required bool wrapperActive, bool busy = false}) =>
    !busy && (room.status == SyncPlayStatus.idle ? !wrapperActive : wrapperActive && room.canControl);
