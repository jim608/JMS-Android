/// Native Jellyfin SyncPlay wire models, independent of Flutter and networking.
///
/// Protocol reference: jellyfin-web 5ab0379f5106439aa6266ca3b8824a642059f1a2,
/// src/plugins/syncPlay/core/{Manager,QueueCore,PlaybackCore}.js.
library;

class SyncPlayIdentity {
  const SyncPlayIdentity({
    required this.sourceId,
    required this.userId,
    required this.sessionId,
  });

  final String sourceId;
  final String userId;
  final String sessionId;

  @override
  bool operator ==(Object other) =>
      other is SyncPlayIdentity &&
      sourceId == other.sourceId &&
      userId == other.userId &&
      sessionId == other.sessionId;

  @override
  int get hashCode => Object.hash(sourceId, userId, sessionId);
}

enum SyncPlayStatus {
  idle,
  creating,
  joining,
  joined,
  leaving,
  unknown,
  disconnected,
  disposed,
}

enum SyncPlayFailureCode {
  invalidCode,
  noGroup,
  ambiguousCode,
  busy,
  denied,
  server,
  timeoutUnknown,
  disconnected,
  protocol,
  player,
  clock,
  unsupported,
}

class SyncPlayFailure implements Exception {
  const SyncPlayFailure(this.code);
  final SyncPlayFailureCode code;

  @override
  String toString() => 'SyncPlayFailure(${code.name})';
}

class SyncPlayGroup {
  SyncPlayGroup({
    required this.groupId,
    required this.groupName,
    required this.lastUpdatedAt,
    this.state = 'Idle',
    List<String> participants = const [],
  }) : participants = List.unmodifiable(participants);

  factory SyncPlayGroup.fromJson(Map<String, dynamic> json) {
    final participants = json['Participants'];
    if (participants is! List || participants.any((item) => item is! String)) {
      throw const FormatException('Invalid SyncPlay participants');
    }
    final state = _string(json, 'State');
    if (!const {'Idle', 'Waiting', 'Paused', 'Playing'}.contains(state)) {
      throw const FormatException('Invalid SyncPlay group state');
    }
    return SyncPlayGroup(
      groupId: syncPlayId(json['GroupId']),
      groupName: _string(json, 'GroupName'),
      lastUpdatedAt: syncPlayDate(json['LastUpdatedAt']),
      state: state,
      participants: participants.cast<String>(),
    );
  }

  final String groupId;
  final String groupName;
  final String state;
  final List<String> participants;
  final DateTime lastUpdatedAt;

  String? get code =>
      RegExp(r'^JMS-([0-9]{6})$').firstMatch(groupName)?.group(1);
}

class SyncPlayQueueItem {
  const SyncPlayQueueItem(
      {required this.mediaId, required this.playlistItemId});
  factory SyncPlayQueueItem.fromJson(Map<String, dynamic> json) =>
      SyncPlayQueueItem(
        mediaId: syncPlayId(json['ItemId']),
        playlistItemId: syncPlayId(json['PlaylistItemId']),
      );

  /// Library item, which may appear more than once in the same queue.
  final String mediaId;

  /// Unique queue-entry ID; never substitute [mediaId] in commands/reports.
  final String playlistItemId;
}

class SyncPlayQueue {
  SyncPlayQueue({
    required this.lastUpdate,
    required List<SyncPlayQueueItem> items,
    required this.playingIndex,
    required this.position,
    required this.isPlaying,
    required this.reason,
  }) : items = List.unmodifiable(items);

  factory SyncPlayQueue.fromJson(Map<String, dynamic> json) {
    final playlist = json['Playlist'];
    if (playlist is! List || playlist.length > 10000) {
      throw const FormatException('Invalid SyncPlay playlist');
    }
    final items = playlist
        .map((value) => SyncPlayQueueItem.fromJson(syncPlayMap(value)))
        .toList();
    final index = json['PlayingItemIndex'];
    if (index is! int ||
        (items.isEmpty ? index != -1 : index < 0 || index >= items.length) ||
        items.map((item) => item.playlistItemId).toSet().length !=
            items.length ||
        json['IsPlaying'] is! bool) {
      throw const FormatException('Invalid SyncPlay queue selection');
    }
    final reason = _string(json, 'Reason');
    if (!const {
      'NewPlaylist',
      'SetCurrentItem',
      'NextItem',
      'PreviousItem',
      'RemoveItems',
      'MoveItem',
      'Queue',
      'QueueNext',
      'RepeatMode',
      'ShuffleMode',
    }.contains(reason)) {
      throw const FormatException('Invalid SyncPlay queue reason');
    }
    return SyncPlayQueue(
      lastUpdate: syncPlayDate(json['LastUpdate']),
      items: items,
      playingIndex: index,
      position: syncPlayPosition(json['StartPositionTicks']),
      isPlaying: json['IsPlaying'] as bool,
      reason: reason,
    );
  }

  final DateTime lastUpdate;
  final List<SyncPlayQueueItem> items;
  final int playingIndex;
  final Duration position;
  final bool isPlaying;
  final String reason;
  SyncPlayQueueItem? get current => items.isEmpty ? null : items[playingIndex];
}

enum SyncPlayCommandType { pause, unpause, seek, stop }

class SyncPlayCommand {
  const SyncPlayCommand({
    required this.groupId,
    required this.playlistItemId,
    required this.type,
    required this.when,
    required this.emittedAt,
    required this.position,
  });

  factory SyncPlayCommand.fromJson(Map<String, dynamic> json) {
    final type = switch (json['Command']) {
      'Pause' => SyncPlayCommandType.pause,
      'Unpause' => SyncPlayCommandType.unpause,
      'Seek' => SyncPlayCommandType.seek,
      'Stop' => SyncPlayCommandType.stop,
      _ => throw const FormatException('Unknown SyncPlay command'),
    };
    return SyncPlayCommand(
      groupId: syncPlayId(json['GroupId']),
      playlistItemId: syncPlayId(json['PlaylistItemId']),
      type: type,
      when: syncPlayDate(json['When']),
      emittedAt: syncPlayDate(json['EmittedAt']),
      position: syncPlayPosition(json['PositionTicks']),
    );
  }

  final String groupId;
  final String playlistItemId;
  final SyncPlayCommandType type;
  final DateTime when;
  final DateTime emittedAt;
  final Duration position;

  String get fingerprint =>
      '$groupId/$playlistItemId/${type.name}/${when.microsecondsSinceEpoch}/'
      '${position.inMicroseconds}';
}

enum SyncPlayPlayerActionType { load, pause, unpause, seek, stop }

class SyncPlayPlayerAction {
  const SyncPlayPlayerAction({
    required this.type,
    this.position = Duration.zero,
    this.queueItem,
    this.queue,
  });

  final SyncPlayPlayerActionType type;
  final Duration position;
  final SyncPlayQueueItem? queueItem;
  final SyncPlayQueue? queue;
}

class SyncPlayServerTime {
  const SyncPlayServerTime({
    required this.requestReceptionTime,
    required this.responseTransmissionTime,
  });
  factory SyncPlayServerTime.fromJson(Map<String, dynamic> json) =>
      SyncPlayServerTime(
        requestReceptionTime: syncPlayDate(json['RequestReceptionTime']),
        responseTransmissionTime:
            syncPlayDate(json['ResponseTransmissionTime']),
      );
  final DateTime requestReceptionTime;
  final DateTime responseTransmissionTime;
}

enum SyncPlayRequestType {
  pause,
  unpause,
  seek,
  setNewQueue,
  buffering,
  ready,
  setIgnoreWait,
  ping
}

class SyncPlayRequest {
  SyncPlayRequest(this.type, [Map<String, dynamic> body = const {}])
      : body = Map.unmodifiable(body) {
    if (type == SyncPlayRequestType.setIgnoreWait &&
        (body.length != 1 || body['IgnoreWait'] is! bool)) {
      throw const FormatException('IgnoreWait requires one boolean');
    }
  }
  final SyncPlayRequestType type;
  final Map<String, dynamic> body;
  String get endpoint => switch (type) {
        SyncPlayRequestType.pause => 'Pause',
        SyncPlayRequestType.unpause => 'Unpause',
        SyncPlayRequestType.seek => 'Seek',
        SyncPlayRequestType.setNewQueue => 'SetNewQueue',
        SyncPlayRequestType.buffering => 'Buffering',
        SyncPlayRequestType.ready => 'Ready',
        SyncPlayRequestType.setIgnoreWait => 'SetIgnoreWait',
        SyncPlayRequestType.ping => 'Ping',
      };
}

abstract interface class SyncPlayApiPort {
  Future<List<SyncPlayGroup>> listGroups();
  Future<SyncPlayGroup?> newGroup(String groupName);
  Future<void> joinGroup(String groupId);
  Future<void> leaveGroup();
  Future<void> sendRequest(SyncPlayRequest request);
  Future<SyncPlayServerTime> getServerTime();
}

abstract interface class SyncPlayPlayerPort {
  String? get mediaId;
  String? get playlistItemId;
  Duration get position;
  bool get isPlaying;

  /// Adapter must apply without invoking the controller's local request methods.
  Future<void> applyRemote(SyncPlayPlayerAction action);
}

/// Local estimates only. Positive drift means this player is behind its target,
/// not a measured difference from a friend's device. Never persisted or uploaded.
class SyncPlayDiagnostics {
  const SyncPlayDiagnostics({
    this.networkRoundTrip,
    this.clockOffset,
    this.clockSampleAge,
    this.playbackDrift,
    this.driftSampleAge,
    this.lastCorrection,
    this.correctionCount = 0,
  });

  final Duration? networkRoundTrip;
  final Duration? clockOffset;
  final Duration? clockSampleAge;
  final Duration? playbackDrift;
  final Duration? driftSampleAge;
  final Duration? lastCorrection;
  final int correctionCount;

  /// Explicit numeric allowlist; no arbitrary event, room, media or login data.
  Map<String, Object?> toJson() => {
        'networkRoundTripMs': networkRoundTrip == null
            ? null
            : networkRoundTrip!.inMicroseconds / 1000,
        'clockOffsetMs':
            clockOffset == null ? null : clockOffset!.inMicroseconds / 1000,
        'clockSampleAgeMs': clockSampleAge?.inMilliseconds,
        'playbackDriftMs':
            playbackDrift == null ? null : playbackDrift!.inMicroseconds / 1000,
        'driftSampleAgeMs': driftSampleAge?.inMilliseconds,
        'lastCorrectionMs': lastCorrection == null
            ? null
            : lastCorrection!.inMicroseconds / 1000,
        'correctionCount': correctionCount,
      };
}

/// Playback can recover while this session remains excluded from group wait.
/// A Playing-state Ready acknowledgement does not clear Jellyfin's buffer flag.
enum SyncPlayWaitParticipation {
  following,
  ignoring,
  ignored,
  recovering,
  ignoredRecovered,
  unsupported,
  uncertain,
}

enum SyncPlayMembershipFreshness { unverified, confirmed, stale, uncertain }

class SyncPlayControllerState {
  const SyncPlayControllerState({
    this.status = SyncPlayStatus.idle,
    this.group,
    this.queue,
    this.connected = true,
    this.clockSynchronized = false,
    this.failure,
    this.diagnostics = const SyncPlayDiagnostics(),
    this.waitParticipation = SyncPlayWaitParticipation.following,
    this.mediaReady,
    this.bufferedAhead,
    this.targetBufferedAhead,
    this.waitAge,
    this.catchupAttempts = 0,
    this.mediaBufferEpoch = 0,
    this.membershipFreshness = SyncPlayMembershipFreshness.unverified,
    this.membershipCheckAge,
  });

  final SyncPlayStatus status;
  final SyncPlayGroup? group;
  final SyncPlayQueue? queue;
  final bool connected;
  final bool clockSynchronized;
  final SyncPlayFailure? failure;
  final SyncPlayDiagnostics diagnostics;
  final SyncPlayWaitParticipation waitParticipation;
  final bool? mediaReady;
  final Duration? bufferedAhead;
  final Duration? targetBufferedAhead;
  final Duration? waitAge;
  final int catchupAttempts;
  final int mediaBufferEpoch;
  final SyncPlayMembershipFreshness membershipFreshness;
  final Duration? membershipCheckAge;
  bool get isJoined => status == SyncPlayStatus.joined && group != null;
  bool get canControl => isJoined && connected && clockSynchronized;
}

Map<String, dynamic> syncPlayMap(Object? value) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw const FormatException('Invalid SyncPlay object');
  }
  return Map<String, dynamic>.from(value);
}

String syncPlayId(Object? value) {
  if (value is! String ||
      !RegExp(r'^(?:[0-9a-fA-F]{32}|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$')
          .hasMatch(value)) {
    throw const FormatException('Invalid SyncPlay identifier');
  }
  return value.replaceAll('-', '').toLowerCase();
}

DateTime syncPlayDate(Object? value) {
  final match = value is String
      ? RegExp(
              r'^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.[0-9]{1,9})?(Z|[+-][0-9]{2}:[0-9]{2})$')
          .firstMatch(value)
      : null;
  if (match == null) {
    throw const FormatException('SyncPlay timestamp requires timezone');
  }
  final year = int.parse(match[1]!),
      month = int.parse(match[2]!),
      day = int.parse(match[3]!);
  final zone = match[7]!;
  final zoneHours = zone == 'Z' ? 0 : int.parse(zone.substring(1, 3));
  final zoneMinutes = zone == 'Z' ? 0 : int.parse(zone.substring(4, 6));
  if (year < 1 ||
      month < 1 ||
      month > 12 ||
      day < 1 ||
      day > DateTime.utc(year, month + 1, 0).day ||
      int.parse(match[4]!) > 23 ||
      int.parse(match[5]!) > 59 ||
      int.parse(match[6]!) > 59 ||
      zoneHours > 14 ||
      zoneMinutes > 59 ||
      (zoneHours == 14 && zoneMinutes != 0)) {
    throw const FormatException('Invalid SyncPlay calendar timestamp');
  }
  final parsed = DateTime.tryParse(value as String);
  if (parsed == null) throw const FormatException('Invalid SyncPlay timestamp');
  return parsed.toUtc();
}

Duration syncPlayPosition(Object? ticks) {
  if (ticks is! int || ticks < 0 || ticks > 9007199254740991) {
    throw const FormatException('Invalid SyncPlay ticks');
  }
  return Duration(microseconds: ticks ~/ 10);
}

int syncPlayTicks(Duration position) {
  final ticks = position.inMicroseconds * 10;
  if (ticks < 0 || ticks > 9007199254740991) {
    throw const FormatException('Invalid SyncPlay position');
  }
  return ticks;
}

String _string(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty || value.length > 256) {
    throw const FormatException('Invalid SyncPlay string');
  }
  return value;
}
