@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart' as jellyfin;
import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/credentials_model.dart';
import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/items/movie_model.dart';
import 'package:fladder/models/playback/playback_model.dart';
import 'package:fladder/profiles/default_profile.dart';
import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/providers/sleep_timer_provider.dart';
import 'package:fladder/providers/syncplay_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/services/syncplay/syncplay_models.dart';
import 'package:fladder/util/application_info.dart';
import 'package:fladder/util/sleep_timer.dart';
import 'package:fladder/wrappers/media_control_wrapper.dart';
import 'package:fladder/wrappers/players/player_states.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _group = '11111111111111111111111111111111';
const _media = '22222222222222222222222222222222';
const _queueEntry = '33333333333333333333333333333333';
const _item = jellyfin.BaseItemDto(
    id: _media,
    name: 'Provider lifecycle fixture',
    type: jellyfin.BaseItemKind.movie,
    mediaType: jellyfin.MediaType.video);

/// Only the asynchronous protocol boundaries needed to exercise the real
/// provider are implemented. This is not an actual Jellyfin server acceptance.
class _Server {
  late final HttpServer _server;
  StreamSubscription<HttpRequest>? _subscription;
  final sockets = <WebSocket>[];
  final requests = <String>[];
  final newStarted = Completer<void>();
  final socketStarted = Completer<void>();
  Completer<void>? newGate;
  Completer<void>? upgradeGate;
  String? name;
  Map<String, dynamic>? queue;
  bool leaveFails = false;
  int closedSockets = 0;
  final createdAt = DateTime.now().toUtc();

  Uri get uri => Uri.parse('http://127.0.0.1:${_server.port}/demo');
  Map<String, dynamic> get group => {
        'GroupId': _group,
        'GroupName': name,
        'State': 'Paused',
        'Participants': ['Fixture'],
        'LastUpdatedAt': createdAt.toIso8601String(),
      };

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _subscription = _server.listen((request) => unawaited(_handle(request)));
  }

  void emit(String type, Object? data) {
    for (final socket
        in sockets.where((socket) => socket.readyState == WebSocket.open)) {
      socket.add(jsonEncode({
        'MessageType': 'SyncPlayGroupUpdate',
        'Data': {'GroupId': _group, 'Type': type, 'Data': data},
      }));
    }
  }

  void unpause() {
    final emitted = DateTime.now().toUtc();
    for (final socket
        in sockets.where((socket) => socket.readyState == WebSocket.open)) {
      socket.add(jsonEncode({
        'MessageType': 'SyncPlayCommand',
        'Data': {
          'GroupId': _group,
          'PlaylistItemId': _queueEntry,
          'Command': 'Unpause',
          'PositionTicks': 30000000,
          'When':
              emitted.add(const Duration(milliseconds: 30)).toIso8601String(),
          'EmittedAt': emitted.toIso8601String(),
        },
      }));
    }
  }

  Future<void> _reply(HttpRequest request, Object? body,
      [int status = 200]) async {
    request.response.statusCode = status;
    if (status != 204) {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(body));
    }
    await request.response.close();
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.uri.path.endsWith('/socket')) {
        if (!socketStarted.isCompleted) socketStarted.complete();
        await upgradeGate?.future;
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.listen((_) {}, onDone: () => closedSockets++);
        return;
      }
      final endpoint = request.uri.path.split('/').last;
      requests.add(endpoint);
      final text = await utf8.decoder.bind(request).join();
      final body =
          text.isEmpty ? <String, dynamic>{} : syncPlayMap(jsonDecode(text));
      switch (endpoint) {
        case 'List':
          await _reply(request, name == null ? [] : [group]);
        case 'New':
          name = body['GroupName'] as String;
          if (!newStarted.isCompleted) newStarted.complete();
          await newGate?.future;
          requests.add('New-completed');
          emit('GroupJoined', group);
          await _reply(request, group);
        case 'Join':
          emit('GroupJoined', group);
          if (queue != null) emit('PlayQueue', queue);
          await _reply(request, null, 204);
        case 'Leave':
          if (leaveFails) {
            await _reply(request, {'error': 'synthetic failure'}, 503);
          } else {
            emit('GroupLeft', _group);
            await _reply(request, null, 204);
          }
        case 'GetUtcTime':
          final time = DateTime.now().toUtc().toIso8601String();
          await _reply(request,
              {'RequestReceptionTime': time, 'ResponseTransmissionTime': time});
        case 'SetNewQueue':
          queue = {
            'Reason': 'NewPlaylist',
            'LastUpdate': DateTime.now().toUtc().toIso8601String(),
            'Playlist': [
              {'ItemId': _media, 'PlaylistItemId': _queueEntry}
            ],
            'PlayingItemIndex': 0,
            'StartPositionTicks': body['StartPositionTicks'],
            'IsPlaying': false,
            'ShuffleMode': 'Sorted',
            'RepeatMode': 'RepeatNone',
          };
          emit('PlayQueue', queue);
          await _reply(request, null, 204);
        case _media:
          await _reply(request, _item.toJson());
        case 'PlaybackInfo':
          await _reply(request, {
            'PlaySessionId': 'synthetic-play-session',
            'MediaSources': [
              {'Id': _media, 'SupportsDirectPlay': true, 'MediaStreams': []}
            ],
          });
        case 'Ping':
        case 'Ready':
        case 'Buffering':
        case 'Pause':
        case 'Unpause':
        case 'Seek':
          await _reply(request, null, 204);
        default:
          await _reply(request, {'error': 'unsupported fixture endpoint'}, 404);
      }
    } on SocketException {
      // A captured client is intentionally closed during logout/disposal races.
    } on HttpException {
      // The old HTTP response is no longer deliverable after client disposal.
    }
  }

  Future<void> close() async {
    if (newGate != null && !newGate!.isCompleted) newGate!.complete();
    if (upgradeGate != null && !upgradeGate!.isCompleted) {
      upgradeGate!.complete();
    }
    for (final socket in sockets) {
      await socket.close(1000);
    }
    await _subscription?.cancel();
    await _server.close(force: true);
  }
}

class _User extends User {
  _User(this.account);
  final AccountModel account;
  @override
  AccountModel? build() => account;
  void replace(AccountModel next) => state = next;
}

class _InitialModel extends Fake implements PlaybackModel {
  @override
  ItemBaseModel get item => MovieModel.fromBaseDto(_item, null);
  @override
  bool get isAudioPlayback => false;
}

class _SleepTimer extends Fake implements SleepTimerController {
  @override
  void endSession() {}
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
  @override
  void dispose() {}
}

class _Wrapper extends MediaControlsWrapper {
  _Wrapper(Ref ref) : super(ref: ref);
  final snapshots = StreamController<PlayerState>.broadcast();
  final raw = PlayerState(playing: false);
  int pauses = 0, plays = 0;
  Completer<void>? playGate;
  Completer<void>? playStarted;
  @override
  bool get supportsSyncPlay => true;
  @override
  PlayerState get lastState => raw;
  @override
  Stream<PlayerState> get stateStream => snapshots.stream;
  @override
  Future<void> pauseFromSyncPlay() async {
    pauses++;
    raw.playing = false;
  }

  @override
  Future<void> seekFromSyncPlay(Duration position) async {
    raw.position = position;
  }

  @override
  Future<void> playFromSyncPlay() async {
    plays++;
    raw.playing = true;
    if (playStarted != null && !playStarted!.isCompleted) {
      playStarted!.complete();
    }
    await playGate?.future;
  }
}

class _Video extends VideoPlayerNotifier {
  _Video(super.ref) {
    state = _Wrapper(ref);
  }
  final loaded = <PlaybackModel>[];
  @override
  Future<bool> waitUntilReady() async => true;
  @override
  Future<bool> loadPlaybackItem(PlaybackModel model, Duration startPosition,
      {bool playWhenReady = true, bool Function()? isCurrent}) async {
    if (isCurrent != null && !isCurrent()) return false;
    loaded.add(model);
    ref.read(playBackModel.notifier).state = model;
    return true;
  }
}

class _Scope {
  _Scope(this.server, SharedPreferences preferences) {
    account = AccountModel(
      name: 'Fixture',
      id: '44444444444444444444444444444444',
      avatar: '',
      lastUsed: DateTime.utc(2026),
      credentials: CredentialsModel.internal(
          url: server.uri.toString(),
          token: 'synthetic-user-a',
          serverId: '55555555555555555555555555555555',
          deviceId: 'synthetic-device-a'),
      policy: const jellyfin.UserPolicy(
          authenticationProviderId: 'fixture',
          passwordResetProviderId: 'fixture',
          syncPlayAccess: jellyfin.SyncPlayUserAccessType.createandjoingroups),
    );
    container = ProviderContainer(overrides: [
      userProvider.overrideWith(() => _User(account)),
      sharedPreferencesProvider.overrideWithValue(preferences),
      applicationInfoProvider.overrideWith((_) => ApplicationInfo(
          name: 'JMS-test',
          version: '0.0.0',
          buildNumber: '0',
          platform: TargetPlatform.windows)),
      videoProfileProvider.overrideWith((_) => const jellyfin.DeviceProfile()),
      sleepTimerProvider.overrideWith((_) => _SleepTimer()),
      playBackModel.overrideWith((_) => _InitialModel()),
      videoPlayerProvider.overrideWith((ref) => _Video(ref)),
    ]);
    notifier = container.read(syncPlayProvider.notifier);
    video = container.read(videoPlayerProvider.notifier) as _Video;
    wrapper = container.read(videoPlayerProvider) as _Wrapper;
  }
  final _Server server;
  late final AccountModel account;
  late final ProviderContainer container;
  late final SyncPlayNotifier notifier;
  late final _Video video;
  late final _Wrapper wrapper;
  bool disposed = false;
  SyncPlayViewState get state => container.read(syncPlayProvider);

  void dispose() {
    if (disposed) return;
    disposed = true;
    container.dispose();
    for (final model in video.loaded) {
      model.dispose();
    }
    unawaited(wrapper.snapshots.close());
  }
}

Future<void> _until(bool Function() condition, String label) async {
  final clock = Stopwatch()..start();
  while (!condition()) {
    if (clock.elapsed > const Duration(seconds: 3)) fail('Timed out: $label');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late SharedPreferences preferences;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
  });

  test(
      'stop bypasses busy New, waits for its outcome, and late create continuation cannot queue media',
      () async {
    final server = _Server()..newGate = Completer<void>();
    await server.start();
    final scope = _Scope(server, preferences);
    addTearDown(() async {
      scope.dispose();
      await server.close();
    });
    final creating = scope.notifier.createRoom();
    await server.newStarted.future;
    expect(scope.state.busy, true);
    final stopping = scope.notifier.stop();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(server.requests.where((item) => item == 'Leave'), isEmpty);
    server.newGate!.complete();
    await Future.wait([creating, stopping]);
    await _until(() => !scope.state.busy && !scope.notifier.active,
        'stopped provider detaches');
    expect(server.requests.indexOf('New-completed'),
        lessThan(server.requests.indexOf('Leave')));
    expect(server.requests.where((item) => item == 'New'), hasLength(1));
    expect(server.requests.where((item) => item == 'SetNewQueue'), isEmpty);
    expect(scope.video.loaded, isEmpty);
    expect(scope.wrapper.syncPlayCommands, isNull);
    expect(scope.state.room.status, SyncPlayStatus.idle);
  }, timeout: const Timeout(Duration(seconds: 10)));

  test(
      'failed Leave retains unknown membership and reconnect reuses a functional adapter',
      () async {
    final server = _Server();
    await server.start();
    final scope = _Scope(server, preferences);
    addTearDown(() async {
      scope.dispose();
      await server.close();
    });
    await scope.notifier.createRoom();
    await _until(
        () => scope.video.loaded.length == 1 && scope.state.room.canControl,
        'initial real adapter load');
    server.leaveFails = true;
    await scope.notifier.leaveRoom();
    expect(scope.state.room.status, SyncPlayStatus.unknown);
    expect(scope.notifier.active, true);
    expect(scope.wrapper.syncPlayCommands, same(scope.notifier));
    await scope.notifier.reconnect();
    await _until(() => scope.state.room.canControl, 'same adapter reconnected');
    server.unpause();
    await _until(() => scope.wrapper.plays == 1,
        'reconnected adapter applies remote Unpause');
    expect(scope.wrapper.raw.position,
        greaterThanOrEqualTo(const Duration(seconds: 3)));
    expect(server.requests.where((item) => item == 'New'), hasLength(1));
    server.leaveFails = false;
    await scope.notifier.leaveRoom();
    expect(scope.wrapper.syncPlayCommands, isNull);
  }, timeout: const Timeout(Duration(seconds: 10)));

  test('account switch during New revokes old UI, player and socket callbacks',
      () async {
    final server = _Server()..newGate = Completer<void>();
    await server.start();
    final scope = _Scope(server, preferences);
    addTearDown(() async {
      scope.dispose();
      await server.close();
    });
    final creating = scope.notifier.createRoom();
    await server.newStarted.future;
    final other = scope.account.copyWith(
        id: '66666666666666666666666666666666',
        credentials: scope.account.credentials.copyWith(
            token: 'synthetic-user-b', deviceId: 'synthetic-device-b'));
    (scope.container.read(userProvider.notifier) as _User).replace(other);
    server.newGate!.complete();
    await creating;
    await _until(() => server.closedSockets == 1, 'old account socket closed');
    expect(scope.state.busy, false);
    expect(scope.notifier.active, false);
    expect(scope.wrapper.syncPlayCommands, isNull);
    expect(scope.video.loaded, isEmpty);
    expect(server.requests.where((item) => item == 'SetNewQueue'), isEmpty);
  }, timeout: const Timeout(Duration(seconds: 10)));

  test(
      'wrapper manual controls send exactly once while a remote play future is pending',
      () async {
    final server = _Server();
    await server.start();
    final scope = _Scope(server, preferences);
    final gate = Completer<void>();
    addTearDown(() async {
      if (!gate.isCompleted) gate.complete();
      scope.dispose();
      await server.close();
    });
    await scope.notifier.createRoom();
    await _until(
        () => scope.video.loaded.length == 1 && scope.state.room.canControl,
        'joined and loaded');
    scope.wrapper.playGate = gate;
    scope.wrapper.playStarted = Completer<void>();
    server.unpause();
    await scope.wrapper.playStarted!.future;
    expect(gate.isCompleted, false);
    final pauses = scope.wrapper.pauses;
    await scope.wrapper.pause();
    await scope.wrapper.play();
    await scope.wrapper.seek(const Duration(seconds: 37));
    for (final endpoint in ['Pause', 'Unpause', 'Seek']) {
      expect(server.requests.where((request) => request == endpoint),
          hasLength(1));
    }
    expect(scope.wrapper.plays, 1,
        reason:
            'manual controls wait for server commands instead of changing local playback');
    expect(scope.wrapper.pauses, pauses);
    gate.complete();
  }, timeout: const Timeout(Duration(seconds: 10)));

  test(
      'provider disposal during New cancels pending work without reading a disposed ref',
      () async {
    final server = _Server()..newGate = Completer<void>();
    await server.start();
    final scope = _Scope(server, preferences);
    addTearDown(() async {
      scope.dispose();
      await server.close();
    });
    final creating = scope.notifier.createRoom();
    await server.newStarted.future;
    scope.dispose();
    server.newGate!.complete();
    await creating;
    await _until(
        () => server.closedSockets == 1, 'disposed provider socket closed');
    expect(scope.wrapper.syncPlayCommands, isNull);
    expect(scope.video.loaded, isEmpty);
    expect(server.requests.where((item) => item == 'SetNewQueue'), isEmpty);
  }, timeout: const Timeout(Duration(seconds: 10)));

  test(
      'wrapper stop during initial WS handshake revokes late opening before New',
      () async {
    final server = _Server()..upgradeGate = Completer<void>();
    await server.start();
    final scope = _Scope(server, preferences);
    addTearDown(() async {
      scope.dispose();
      await server.close();
    });
    final creating = scope.notifier.createRoom();
    await server.socketStarted.future;
    expect(scope.state.room.status, SyncPlayStatus.idle);
    expect(scope.state.busy, true);
    expect(scope.wrapper.syncPlayCommands?.active, true,
        reason: 'the wrapper must delegate Stop while connect is pending');
    // The player UI has closed its local model. Exercise the production Stop
    // routing without starting native video, wakelock or window-title services.
    scope.container.read(playBackModel.notifier).state = null;
    await scope.wrapper.stop();
    expect(scope.wrapper.syncPlayCommands, isNull);
    // Reopening the same item cannot make the revoked handshake current again.
    scope.container.read(playBackModel.notifier).state = _InitialModel();
    server.upgradeGate!.complete();
    await creating;
    await _until(
        () => server.closedSockets == 1, 'late upgraded socket retired');
    expect(scope.state.busy, false);
    expect(scope.notifier.active, false);
    expect(server.requests.where((item) => item == 'New'), isEmpty);
    expect(server.requests.where((item) => item == 'SetNewQueue'), isEmpty);
    expect(scope.video.loaded, isEmpty);
  }, timeout: const Timeout(Duration(seconds: 10)));
}
