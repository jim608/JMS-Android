import 'dart:async';

import 'package:fladder/services/syncplay/syncplay_clock.dart';
import 'package:fladder/services/syncplay/syncplay_models.dart';

String wireId(int n) => n.toRadixString(16).padLeft(32, '0');
Future<void> flushTasks() async {
  for (var i = 0; i < 80; i++) {
    await Future<void>.value();
  }
}

class ScheduledWait implements SyncPlayCancellation {
  ScheduledWait(this.when, this.callback);
  final DateTime when;
  final void Function() callback;
  bool cancelled = false;
  @override
  void cancel() => cancelled = true;
}

class WaitClock implements SyncPlayScheduler {
  DateTime now = DateTime.utc(2026, 10, 24, 12);
  final jobs = <ScheduledWait>[];
  @override
  SyncPlayCancellation schedule(Duration delay, void Function() callback) {
    final job = ScheduledWait(now.add(delay), callback);
    jobs.add(job);
    return job;
  }

  Future<void> advance(Duration delta) async {
    final end = now.add(delta);
    await flushTasks();
    var guard = 0;
    while (jobs.any((j) => !j.cancelled && !j.when.isAfter(end))) {
      if (++guard > 1000) throw StateError('Synthetic timer feedback loop');
      final j = jobs
          .where((j) => !j.cancelled && !j.when.isAfter(end))
          .reduce((a, b) => a.when.isBefore(b.when) ? a : b);
      now = j.when;
      j.cancelled = true;
      j.callback();
      await flushTasks();
    }
    now = end;
    await flushTasks();
  }
}

class WaitPlayer implements SyncPlayPlayerPort {
  WaitPlayer(this.clock);
  final WaitClock clock;
  @override
  String? mediaId;
  @override
  String? playlistItemId;
  Duration _position = Duration.zero;
  DateTime? _at;
  @override
  Duration get position =>
      _position +
      (isPlaying && _at != null ? clock.now.difference(_at!) : Duration.zero);
  set position(Duration v) {
    _position = v;
    _at = clock.now;
  }

  @override
  bool isPlaying = false;
  bool buffering = false;
  bool refuseUnpause = false;
  bool refuseSeek = false;
  int cancellations = 0;
  Future<void> Function(SyncPlayPlayerAction)? beforeApply;
  final actions = <SyncPlayPlayerAction>[];
  void cancelPending() => cancellations++;
  @override
  Future<void> applyRemote(SyncPlayPlayerAction action) async {
    final generation = cancellations;
    actions.add(action);
    await beforeApply?.call(action);
    if (generation != cancellations) return;
    if (!(refuseSeek && action.type == SyncPlayPlayerActionType.seek)) {
      position = action.position;
    }
    if (action.type == SyncPlayPlayerActionType.load) {
      mediaId = action.queueItem!.mediaId;
      playlistItemId = action.queueItem!.playlistItemId;
    }
    isPlaying =
        action.type == SyncPlayPlayerActionType.unpause && !refuseUnpause;
  }
}

class WaitMember {
  bool buffering = false;
  bool ignored = false;
}

/// Bounded executable subset of official Jellyfin 10.10.7/10.11 SyncPlay:
/// IsBuffering excludes ignored members, but Buffer still enters Waiting;
/// Ready in Playing returns an own-session command without clearing buffering.
class WaitServer {
  WaitServer(this.clock) : anchorWhen = clock.now;
  final WaitClock clock;
  final members = <WaitApi, WaitMember>{};
  final requests = <(WaitApi, SyncPlayRequest)>[];
  final applied = <SyncPlayRequestType>[];
  final groupId = wireId(100);
  String name = 'JMS-001234';
  String state = 'Paused';
  bool resumePlaying = true;
  DateTime anchorWhen;
  Duration anchorPosition = const Duration(seconds: 12);
  int revision = 0;
  int joins = 0, leaves = 0;
  bool created = false;
  List<Map<String, dynamic>> playlist = [];
  bool get waiting => members.values.any((m) => m.buffering && !m.ignored);
  SyncPlayGroup info() => SyncPlayGroup(
      groupId: groupId,
      groupName: name,
      state: state,
      lastUpdatedAt: clock.now,
      participants: members.keys.map((a) => a.name).toSet().toList());
  void update(WaitApi api, String type, Object? data) => api.events.add({
        'MessageType': 'SyncPlayGroupUpdate',
        'Data': {'GroupId': groupId, 'Type': type, 'Data': data},
      });
  void confirm(WaitApi api) {
    final i = info();
    update(api, 'GroupJoined', {
      'GroupId': groupId,
      'GroupName': name,
      'State': state,
      'LastUpdatedAt': i.lastUpdatedAt.toIso8601String(),
      'Participants': i.participants
    });
  }

  void broadcastState(String reason) {
    for (final a in members.keys.toList()) {
      update(a, 'StateUpdate', {'State': state, 'Reason': reason});
    }
  }

  void queue(WaitApi api) => update(api, 'PlayQueue', {
        'Reason': 'NewPlaylist',
        'LastUpdate':
            clock.now.add(Duration(microseconds: ++revision)).toIso8601String(),
        'Playlist': playlist,
        'PlayingItemIndex': 0,
        'StartPositionTicks': syncPlayTicks(anchorPosition),
        'IsPlaying': false,
      });
  void seedQueue([int media = 71]) {
    playlist = [
      {'ItemId': wireId(media), 'PlaylistItemId': wireId(media + 1000)}
    ];
    state = 'Waiting';
    resumePlaying = true;
    for (final m in members.values) {
      m.buffering = true;
    }
    broadcastState('Play');
    for (final a in members.keys.toList()) {
      queue(a);
    }
  }

  void command(String type, {WaitApi? only, bool allReady = false}) {
    final event = {
      'MessageType': 'SyncPlayCommand',
      'Data': {
        'GroupId': groupId,
        'PlaylistItemId': playlist.first['PlaylistItemId'],
        'Command': type,
        'When': anchorWhen.toIso8601String(),
        'EmittedAt': clock.now.toIso8601String(),
        'PositionTicks': syncPlayTicks(anchorPosition),
      }
    };
    for (final a in only == null
        ? members.keys
            .where((a) => !allReady || !members[a]!.buffering)
            .toList()
        : [only]) {
      a.events.add(event);
    }
  }

  void play(String reason) {
    state = 'Playing';
    anchorWhen = clock.now.add(const Duration(milliseconds: 50));
    command('Unpause');
    broadcastState(reason);
  }

  void pause() {
    if (state == 'Playing') {
      final elapsed = clock.now.difference(anchorWhen);
      if (!elapsed.isNegative) anchorPosition += elapsed;
    }
    state = 'Paused';
    anchorWhen = clock.now;
    resumePlaying = false;
    command('Pause');
    broadcastState('Pause');
  }

  void handle(WaitApi api, SyncPlayRequest r) {
    applied.add(r.type);
    final m = members[api]!;
    switch (r.type) {
      case SyncPlayRequestType.ping:
        break;
      case SyncPlayRequestType.setIgnoreWait:
        m.ignored = r.body['IgnoreWait'] as bool;
        if (state == 'Waiting' && !waiting) {
          if (resumePlaying) {
            play('Unpause');
          } else {
            state = 'Paused';
          }
        }
      case SyncPlayRequestType.buffering:
        if (state == 'Playing') {
          final elapsed = clock.now.difference(anchorWhen);
          if (!elapsed.isNegative) anchorPosition += elapsed;
          state = 'Waiting';
          resumePlaying = true;
          anchorWhen = clock.now;
          m.buffering = true;
          command('Pause', allReady: true);
          broadcastState('Buffer');
        } else {
          m.buffering = true;
        }
      case SyncPlayRequestType.ready:
        if (state == 'Playing') {
          command('Unpause', only: api);
          return;
        }
        if (state == 'Paused') {
          command('Pause', only: api);
          return;
        }
        if (r.body['PlaylistItemId'] != playlist.first['PlaylistItemId']) {
          m.buffering = true;
          queue(api);
          return;
        }
        final p = syncPlayPosition(r.body['PositionTicks']);
        if (!(r.body['IsPlaying'] as bool) &&
            (p - anchorPosition).abs() > const Duration(milliseconds: 500)) {
          m.buffering = true;
          command('Seek', only: api);
          return;
        }
        m.buffering = false;
        if (!waiting) {
          if (resumePlaying) {
            play('Ready');
          } else {
            state = 'Paused';
            command('Pause');
            broadcastState('Ready');
          }
        } else {
          command('Pause', only: api);
        }
      default:
        throw StateError(
            'Test must not manufacture room playback commands: ${r.type}');
    }
  }
}

class WaitApi implements SyncPlayApiPort {
  WaitApi(this.server, this.name);
  final WaitServer server;
  final String name;
  final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  Future<void> Function(SyncPlayRequest)? beforeRequest, afterRequest;
  List<SyncPlayGroup>? listOverride;
  @override
  Future<List<SyncPlayGroup>> listGroups() async =>
      listOverride ?? (server.created ? [server.info()] : []);
  @override
  Future<SyncPlayGroup> newGroup(String name) async {
    server.created = true;
    server.name = name;
    server.members[this] = WaitMember();
    server.confirm(this);
    return server.info();
  }

  @override
  Future<void> joinGroup(String groupId) async {
    server.joins++;
    server.members.putIfAbsent(this, WaitMember.new);
    server.confirm(this);
    if (server.playlist.isNotEmpty) server.queue(this);
  }

  @override
  Future<void> leaveGroup() async {
    server.leaves++;
    server.members.remove(this);
    server.update(this, 'GroupLeft', server.groupId);
  }

  @override
  Future<SyncPlayServerTime> getServerTime() async => SyncPlayServerTime(
      requestReceptionTime: server.clock.now,
      responseTransmissionTime: server.clock.now);
  @override
  Future<void> sendRequest(SyncPlayRequest r) async {
    server.requests.add((this, r));
    await beforeRequest?.call(r);
    server.handle(this, r);
    await afterRequest?.call(r);
  }
}
