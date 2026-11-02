enum RemoteActionType { play, pause, seek, subtitle }

class RemoteAction {
  const RemoteAction.play()
      : type = RemoteActionType.play,
        position = null,
        subtitleIndex = null;
  const RemoteAction.pause()
      : type = RemoteActionType.pause,
        position = null,
        subtitleIndex = null;
  const RemoteAction.seek(Duration value)
      : type = RemoteActionType.seek,
        position = value,
        subtitleIndex = null;
  const RemoteAction.subtitle(int value)
      : type = RemoteActionType.subtitle,
        subtitleIndex = value,
        position = null;

  final RemoteActionType type;
  final Duration? position;
  final int? subtitleIndex;

  @override
  bool operator ==(Object other) =>
      other is RemoteAction &&
      other.type == type &&
      other.position == position &&
      other.subtitleIndex == subtitleIndex;
  @override
  int get hashCode => Object.hash(type, position, subtitleIndex);
}

class RemotePlaybackBinding {
  const RemotePlaybackBinding({
    required this.itemId,
    required this.mediaSourceId,
    required this.playbackId,
  });
  final String itemId;
  final String mediaSourceId;
  final String playbackId;

  bool get isComplete =>
      itemId.isNotEmpty &&
      mediaSourceId.isNotEmpty &&
      playbackId.startsWith('jms-remote-') &&
      playbackId.length > 'jms-remote-'.length;

  @override
  bool operator ==(Object other) =>
      other is RemotePlaybackBinding &&
      other.itemId == itemId &&
      other.mediaSourceId == mediaSourceId &&
      other.playbackId == playbackId;
  @override
  int get hashCode => Object.hash(itemId, mediaSourceId, playbackId);
}

class RemoteTarget {
  const RemoteTarget({
    required this.id,
    required this.deviceId,
    required this.name,
    required this.userId,
    this.serverId,
    this.binding,
    this.positionTicks,
    this.durationTicks,
    this.paused,
    this.canSeek = false,
    this.subtitleIndex,
    this.lastPlaybackCheckIn,
  });
  final String id;
  final String deviceId;
  final String name;
  final String userId;
  final String? serverId;
  final RemotePlaybackBinding? binding;
  final int? positionTicks;
  final int? durationTicks;
  final bool? paused;
  final bool canSeek;
  final int? subtitleIndex;
  final DateTime? lastPlaybackCheckIn;

  RemotePlaybackBinding? get currentBinding => binding;
  bool get canControl => binding?.isComplete == true;
  bool sameEndpoint(RemoteTarget other) =>
      id == other.id &&
      deviceId == other.deviceId &&
      userId == other.userId &&
      serverId == other.serverId;
  bool samePlayback(RemoteTarget other) =>
      sameEndpoint(other) && binding != null && binding == other.binding;
}

class RemoteSubtitle {
  const RemoteSubtitle({
    required this.sourceId,
    required this.index,
    required this.label,
    this.language,
  });
  final String sourceId;
  final int index;
  final String label;
  final String? language;
}

enum RemoteFailureCode {
  denied,
  stale,
  invalidTarget,
  invalidAction,
  unsupported,
  protocol,
  server,
  timeoutUnknown,
  closed,
}

/// Contains only a safe category, never HTTP bodies, credentials or URLs.
class RemoteControlFailure implements Exception {
  const RemoteControlFailure(this.code);
  final RemoteFailureCode code;
  @override
  String toString() => 'RemoteControlFailure(${code.name})';
}

abstract interface class RemoteControlApi {
  Future<List<RemoteTarget>> discover();
  Future<List<RemoteSubtitle>> subtitles(RemoteTarget target);

  /// Successful return means accepted by the server, not applied by the player.
  Future<void> send(RemoteTarget target, RemoteAction action);
  Future<void> close();
}

/// Invalidates a sender's asynchronous preflight without closing its receiver.
abstract interface class RemoteControlCancellation {
  void invalidatePending();
}

/// The final server snapshot obtained immediately before an accepted write.
abstract interface class RemoteControlSendObservation {
  RemoteTarget? get lastAcceptedBaseline;
}

enum RemoteCommandStatus { idle, pending, accepted, confirmed, unknown, failed }

class RemoteControlState {
  const RemoteControlState({
    this.targets = const [],
    this.target,
    this.subtitles = const [],
    this.status = RemoteCommandStatus.idle,
    this.failure,
    this.refreshing = false,
  });
  final List<RemoteTarget> targets;
  final RemoteTarget? target;
  final List<RemoteSubtitle> subtitles;
  final RemoteCommandStatus status;
  final RemoteControlFailure? failure;
  final bool refreshing;
  bool get canControl => target?.canControl == true;
  bool get busy => status == RemoteCommandStatus.pending;
}
