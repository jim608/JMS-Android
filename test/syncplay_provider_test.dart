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
import 'package:fladder/providers/connectivity_provider.dart' as connectivity;
import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/providers/sleep_timer_provider.dart';
import 'package:fladder/providers/syncplay_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/screens/video_player/components/syncplay_dialog.dart';
import 'package:fladder/services/syncplay/syncplay_models.dart';
import 'package:fladder/services/playback_diagnostics.dart';
import 'package:fladder/services/syncplay/syncplay_prebuffer.dart';
import 'package:fladder/util/application_info.dart';
import 'package:fladder/util/sleep_timer.dart';
import 'package:fladder/wrappers/media_control_wrapper.dart';
import 'package:fladder/wrappers/players/player_states.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _group = '11111111111111111111111111111111';
const _media = '22222222222222222222222222222222';
const _queueEntry = '33333333333333333333333333333333';
const _legacyTokenClient = 'JMS-legacy-token-client';
typedef _SessionKey = ({String client, String deviceId});
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
  // Keep only the fields that define the synthetic server session. Never
  // retain a complete Authorization header or websocket URL in test evidence.
  final identities = <({
    String endpoint,
    String? client,
    String? deviceId,
    String? queryDeviceId,
    _SessionKey session,
  })>[];
  final memberships = <_SessionKey, String>{};
  final completedLeaves = <_SessionKey>[];
  final _socketSessions = <WebSocket, _SessionKey>{};
  final newStarted = Completer<void>();
  final socketStarted = Completer<void>();
  Completer<void>? newGate;
  Completer<void>? upgradeGate;
  String? name;
  Map<String, dynamic>? queue;
  bool legacyNewNoContent = false;
  bool legacyQueueStartsPlaying = false;
  bool _resumePlaying = false;
  bool _waitingForInitialReady = false;
  Completer<void>? queueResponseGate, pauseResponseGate, unpauseResponseGate;
  final queueStarted = Completer<void>();
  final pauseStarted = Completer<void>();
  final unpauseStarted = Completer<void>();
  final readyPlayingValues = <bool>[];
  bool leaveFails = false;
  bool leftBeforeLeaveResponse = false;
  Completer<void>? leaveGate;
  final leaveStarted = Completer<void>();
  int closedSockets = 0;
  String policyAccess = 'CreateAndJoinGroups';
  int policyStatus = 200;
  Completer<void>? policyGate;
  Completer<void>? listGate, joinGate, itemGate;
  final listStarted = Completer<void>();
  final joinStarted = Completer<void>();
  final itemStarted = Completer<void>();
  int itemStatus = 200;
  final mediaUsers = <String?>[];
  final policyStarted = Completer<void>();
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

  void emit(String type, Object? data, {_SessionKey? session}) {
    for (final socket in sockets.where((socket) =>
        socket.readyState == WebSocket.open &&
        (session == null || _socketSessions[socket] == session))) {
      socket.add(jsonEncode({
        'MessageType': 'SyncPlayGroupUpdate',
        'Data': {'GroupId': _group, 'Type': type, 'Data': data},
      }));
    }
  }

  void unpause({Duration position = const Duration(seconds: 3)}) {
    final emitted = DateTime.now().toUtc();
    for (final socket
        in sockets.where((socket) => socket.readyState == WebSocket.open)) {
      socket.add(jsonEncode({
        'MessageType': 'SyncPlayCommand',
        'Data': {
          'GroupId': _group,
          'PlaylistItemId': _queueEntry,
          'Command': 'Unpause',
          'PositionTicks': syncPlayTicks(position),
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
      final endpoint = request.uri.path.split('/').last;
      final authorization =
          request.headers.value(HttpHeaders.authorizationHeader) ?? '';
      String? field(String name) =>
          RegExp('$name="([^"]*)"').firstMatch(authorization)?.group(1);
      final queryDeviceId = request.uri.queryParameters['deviceId'];
      // Jellyfin's older websocket resolver ignores header Client and takes
      // the token AppName plus query DeviceId. REST falls back to that AppName
      // only when Client is absent. Use a different token name deliberately.
      final session = (
        client: endpoint == 'socket'
            ? _legacyTokenClient
            : field('Client') ?? _legacyTokenClient,
        deviceId: endpoint == 'socket'
            ? queryDeviceId ?? ''
            : field('DeviceId') ?? '',
      );
      identities.add((
        endpoint: endpoint,
        client: field('Client'),
        deviceId: field('DeviceId') ?? queryDeviceId,
        queryDeviceId: queryDeviceId,
        session: session,
      ));
      if (request.uri.path.endsWith('/socket')) {
        if (!socketStarted.isCompleted) socketStarted.complete();
        await upgradeGate?.future;
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        _socketSessions[socket] = session;
        socket.listen((_) {}, onDone: () => closedSockets++);
        return;
      }
      requests.add(endpoint);
      final text = await utf8.decoder.bind(request).join();
      final body =
          text.isEmpty ? <String, dynamic>{} : syncPlayMap(jsonDecode(text));
      switch (endpoint) {
        case 'Me':
          if (!policyStarted.isCompleted) policyStarted.complete();
          await policyGate?.future;
          await _reply(
              request,
              {
                'Id': '44444444444444444444444444444444',
                'Name': 'Fixture',
                'Policy': {
                  'AuthenticationProviderId': 'fixture',
                  'PasswordResetProviderId': 'fixture',
                  'SyncPlayAccess': policyAccess,
                },
              },
              policyStatus);
        case 'List':
          if (!listStarted.isCompleted) listStarted.complete();
          await listGate?.future;
          await _reply(request, name == null ? [] : [group]);
        case 'New':
          name = body['GroupName'] as String;
          memberships[session] = name!;
          if (!newStarted.isCompleted) newStarted.complete();
          await newGate?.future;
          requests.add('New-completed');
          if (legacyNewNoContent) {
            emit('GroupJoined', group, session: session);
            await _reply(request, null, 204);
          } else {
            emit('GroupJoined', group);
            await _reply(request, group);
          }
        case 'Join':
          if (name != null) memberships[session] = name!;
          if (!joinStarted.isCompleted) joinStarted.complete();
          await joinGate?.future;
          emit('GroupJoined', group);
          if (queue != null) emit('PlayQueue', queue);
          await _reply(request, null, 204);
        case 'Leave':
          if (leftBeforeLeaveResponse) {
            emit('GroupLeft', _group, session: session);
          }
          if (!leaveStarted.isCompleted) leaveStarted.complete();
          await leaveGate?.future;
          if (leaveFails) {
            await _reply(request, {'error': 'synthetic failure'}, 503);
          } else {
            memberships.remove(session);
            completedLeaves.add(session);
            if (!leftBeforeLeaveResponse) {
              emit('GroupLeft', _group, session: session);
            }
            await _reply(request, null, 204);
          }
        case 'GetUtcTime':
          final time = DateTime.now().toUtc().toIso8601String();
          await _reply(request,
              {'RequestReceptionTime': time, 'ResponseTransmissionTime': time});
        case 'SetNewQueue':
          if (legacyQueueStartsPlaying) {
            _resumePlaying = true;
            _waitingForInitialReady = true;
          }
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
          if (!queueStarted.isCompleted) queueStarted.complete();
          emit('PlayQueue', queue);
          await queueResponseGate?.future;
          await _reply(request, null, 204);
        case _media:
          mediaUsers.add(request.uri.queryParameters['userId']);
          if (!itemStarted.isCompleted) itemStarted.complete();
          await itemGate?.future;
          await _reply(request, _item.toJson(), itemStatus);
        case 'PlaybackInfo':
          await _reply(request, {
            'PlaySessionId': 'synthetic-play-session',
            'MediaSources': [
              {'Id': _media, 'SupportsDirectPlay': true, 'MediaStreams': []}
            ],
          });
        case 'Ready':
          if (legacyQueueStartsPlaying) {
            readyPlayingValues.add(body['IsPlaying'] as bool);
            if (_waitingForInitialReady) {
              _waitingForInitialReady = false;
              emit('StateUpdate', {
                'State': _resumePlaying ? 'Playing' : 'Paused',
                'Reason': 'Ready',
              });
              if (_resumePlaying) {
                unpause(
                    position: syncPlayPosition(queue!['StartPositionTicks']));
              }
            }
          }
          await _reply(request, null, 204);
        case 'Ping':
        case 'Buffering':
        case 'Seek':
          await _reply(request, null, 204);
        case 'Pause':
          if (legacyQueueStartsPlaying) _resumePlaying = false;
          if (!pauseStarted.isCompleted) pauseStarted.complete();
          await pauseResponseGate?.future;
          await _reply(request, null, 204);
        case 'Unpause':
          if (legacyQueueStartsPlaying) _resumePlaying = true;
          if (!unpauseStarted.isCompleted) unpauseStarted.complete();
          await unpauseResponseGate?.future;
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
    for (final gate in [
      listGate,
      joinGate,
      itemGate,
      queueResponseGate,
      pauseResponseGate,
      unpauseResponseGate
    ]) {
      if (gate != null && !gate.isCompleted) gate.complete();
    }
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
  void replace(AccountModel? next) => state = next;
}

class _FixtureConnectivity extends connectivity.ConnectivityStatus {
  @override
  connectivity.ConnectionState build() => connectivity.ConnectionState.ethernet;
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
  final raw = PlayerState(playing: false, buffering: false);
  int pauses = 0, plays = 0;
  Completer<void>? playGate;
  Completer<void>? playStarted;
  Duration? bufferedAhead = const Duration(seconds: 10);
  @override
  Future<int?> configureSyncPlayBufferBudget() async => null;
  @override
  Future<SyncPlayBufferSample> readSyncPlayBufferSample() async =>
      SyncPlayBufferSample(
          position: raw.position,
          bufferEnd:
              bufferedAhead == null ? null : raw.position + bufferedAhead!,
          duration: raw.duration,
          buffering: raw.buffering,
          observedAt: DateTime.now());
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
  int prepares = 0;
  final preparedCurrent = <bool>[];
  Completer<void>? prepareGate;
  @override
  Future<bool> prepareSyncPlayPlayback(
      {required bool Function() isCurrent}) async {
    prepares++;
    await prepareGate?.future;
    final current = isCurrent();
    preparedCurrent.add(current);
    return current;
  }

  @override
  Future<bool> waitUntilReady() async => true;
  @override
  Future<bool> loadPlaybackItem(PlaybackModel model, Duration startPosition,
      {bool playWhenReady = true,
      bool Function()? isCurrent,
      PlaybackAttemptRef? diagnosticAttempt}) async {
    if (isCurrent != null && !isCurrent()) return false;
    loaded.add(model);
    final wrapper = state as _Wrapper;
    wrapper.raw.position = startPosition;
    wrapper.raw.buffering = false;
    ref.read(playBackModel.notifier).state = model;
    return true;
  }
}

class _Scope {
  _Scope(this.server, SharedPreferences preferences,
      {bool noMedia = false,
      TargetPlatform platform = TargetPlatform.windows}) {
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
      connectivity.connectivityStatusProvider
          .overrideWith(_FixtureConnectivity.new),
      sharedPreferencesProvider.overrideWithValue(preferences),
      applicationInfoProvider.overrideWith((_) => ApplicationInfo(
          name: 'JMS-test',
          version: '0.0.0',
          buildNumber: '0',
          platform: platform)),
      videoProfileProvider.overrideWith((_) => const jellyfin.DeviceProfile()),
      sleepTimerProvider.overrideWith((_) => _SleepTimer()),
      playBackModel.overrideWith((_) => noMedia ? null : _InitialModel()),
      videoPlayerProvider.overrideWith((ref) => _Video(ref)),
    ]);
    notifier = container.read(syncPlayProvider.notifier);
  }
  final _Server server;
  late final AccountModel account;
  late final ProviderContainer container;
  late final SyncPlayNotifier notifier;
  _Video? _video;
  _Wrapper? _wrapper;
  _Video get video =>
      _video ??= container.read(videoPlayerProvider.notifier) as _Video;
  _Wrapper get wrapper =>
      _wrapper ??= container.read(videoPlayerProvider) as _Wrapper;
  bool disposed = false;
  SyncPlayViewState get state => container.read(syncPlayProvider);

  void dispose() {
    if (disposed) return;
    disposed = true;
    final models = container.exists(videoPlayerProvider)
        ? video.loaded
        : <PlaybackModel>[];
    final snapshots =
        container.exists(videoPlayerProvider) ? wrapper.snapshots : null;
    container.dispose();
    for (final model in models) {
      model.dispose();
    }
    unawaited(snapshots?.close());
  }
}

Future<void> _until(bool Function() condition, String label,
    {Duration timeout = const Duration(seconds: 3)}) async {
  final clock = Stopwatch()..start();
  while (!condition()) {
    if (clock.elapsed > timeout) fail('Timed out: $label');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

// These protocol fixtures intentionally use an in-process loopback HTTP server.
// The standard widget binding's HTTP-400 substitute would bypass that fixture.
class _LoopbackFixtureBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

void main() {
  _LoopbackFixtureBinding();
  late SharedPreferences preferences;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
  });

  Map<String, dynamic> homeQueue() => {
        'Reason': 'NewPlaylist',
        'LastUpdate': DateTime.now().toUtc().toIso8601String(),
        'Playlist': [
          {'ItemId': _media, 'PlaylistItemId': _queueEntry}
        ],
        'PlayingItemIndex': 0,
        'StartPositionTicks': 0,
        'IsPlaying': false,
        'ShuffleMode': 'Sorted',
        'RepeatMode': 'RepeatNone',
      };

  Future<_Scope> homeScope(_Server server) async {
    await server.start();
    final scope = _Scope(server, preferences,
        noMedia: true, platform: TargetPlatform.android);
    addTearDown(() async {
      scope.dispose();
      await server.close();
    });
    return scope;
  }

  Future<_Scope> creatorScope(_Server server, {bool playing = false}) async {
    await server.start();
    final scope = _Scope(server, preferences);
    scope.wrapper.raw.position = const Duration(minutes: 9, seconds: 29);
    scope.wrapper.raw.playing = playing;
    addTearDown(() async {
      scope.dispose();
      await server.close();
    });
    return scope;
  }

  _Server legacyCreatorServer() => _Server()
    ..legacyNewNoContent = true
    ..legacyQueueStartsPlaying = true;

  test('legacy creator keeps Pause before the first Ready despite fast loading',
      () async {
    final server = legacyCreatorServer()
      ..queueResponseGate = Completer<void>()
      ..pauseResponseGate = Completer<void>();
    final scope = await creatorScope(server);
    final creating = scope.notifier.createRoom();
    await server.queueStarted.future;
    await _until(() => scope.video.loaded.length == 1, 'fast room load');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(server.requests.where((request) => request == 'Ready'), isEmpty);
    expect(server.requests.where((request) => request == 'Pause'), isEmpty);
    expect(scope.wrapper.plays, 0);
    server.queueResponseGate!.complete();
    await server.pauseStarted.future;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(server.requests.where((request) => request == 'Ready'), isEmpty);
    expect(scope.wrapper.plays, 0);
    server.pauseResponseGate!.complete();
    await creating;
    await _until(
        () => server.readyPlayingValues.isNotEmpty, 'first safe Ready');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(
        server.requests.where((request) => request == 'Pause'), hasLength(1));
    expect(server.requests.indexOf('SetNewQueue'),
        lessThan(server.requests.indexOf('Pause')));
    expect(server.requests.indexOf('Pause'),
        lessThan(server.requests.indexOf('Ready')));
    expect(server.readyPlayingValues, [false]);
    expect(scope.wrapper.plays, 0);
    expect(scope.wrapper.raw.playing, false);
    expect(scope.wrapper.raw.position, const Duration(minutes: 9, seconds: 29));
    expect(scope.video.loaded, hasLength(1));
    expect(scope.state.busy, false);
    expect(scope.state.room.failure, isNull);
  });

  test('legacy creator that was playing retains normal Ready autoplay',
      () async {
    final server = legacyCreatorServer();
    final scope = await creatorScope(server, playing: true);
    await scope.notifier.createRoom();
    await _until(() => scope.wrapper.plays == 1, 'normal server Unpause');
    expect(server.requests.where((request) => request == 'Pause'), isEmpty);
    expect(scope.wrapper.raw.playing, true);
    expect(scope.wrapper.raw.position, const Duration(minutes: 9, seconds: 29));
    expect(scope.video.loaded, hasLength(1));
  });

  test('legacy creator drains latest Play then Pause behind both intent ACKs',
      () async {
    final server = legacyCreatorServer()
      ..pauseResponseGate = Completer<void>()
      ..unpauseResponseGate = Completer<void>();
    final scope = await creatorScope(server);
    final creating = scope.notifier.createRoom();
    await server.pauseStarted.future;
    await scope.wrapper.play();
    expect(server.requests.where((request) => request == 'Unpause'), isEmpty);
    server.pauseResponseGate!.complete();
    await server.unpauseStarted.future;
    await scope.wrapper.pause();
    expect(server.requests.where((request) => request == 'Ready'), isEmpty);
    server.unpauseResponseGate!.complete();
    await creating;
    await _until(
        () => server.readyPlayingValues.isNotEmpty, 'latest paused Ready');
    expect(
        server.requests.where((request) => request == 'Pause'), hasLength(2));
    expect(
        server.requests.where((request) => request == 'Unpause'), hasLength(1));
    expect(server.requests.lastIndexOf('Pause'),
        lessThan(server.requests.indexOf('Ready')));
    expect(scope.wrapper.plays, 0);
    expect(scope.wrapper.raw.playing, false);
    expect(scope.state.busy, false);
    expect(scope.state.room.failure, isNull);
  });

  test('legacy creator records a newer Pause while New is still pending',
      () async {
    final server = legacyCreatorServer()..newGate = Completer<void>();
    final scope = await creatorScope(server, playing: true);
    final creating = scope.notifier.createRoom();
    await server.newStarted.future;
    await scope.wrapper.pause();
    expect(server.requests.where((request) => request == 'Pause'), isEmpty);
    server.newGate!.complete();
    await creating;
    await _until(
        () => server.readyPlayingValues.isNotEmpty, 'manual paused Ready');
    expect(
        server.requests.where((request) => request == 'Pause'), hasLength(1));
    expect(scope.wrapper.plays, 0);
    expect(scope.wrapper.raw.playing, false);
    expect(scope.state.room.failure, isNull);
  });

  test('legacy creator Leave revokes the late initial Pause ACK and Ready',
      () async {
    final server = legacyCreatorServer()..pauseResponseGate = Completer<void>();
    final scope = await creatorScope(server);
    final creating = scope.notifier.createRoom();
    await server.pauseStarted.future;
    await scope.notifier.leaveRoom();
    expect(scope.wrapper.syncPlayCommands, isNull);
    server.pauseResponseGate!.complete();
    await creating;
    await _until(() => !scope.state.leavePending, 'cancelled creator cleanup');
    expect(server.requests.where((request) => request == 'Ready'), isEmpty);
    expect(server.requests.where((request) => request == 'Unpause'), isEmpty);
    expect(scope.wrapper.plays, 0);
    expect(scope.wrapper.raw.playing, false);
    expect(scope.wrapper.raw.position, const Duration(minutes: 9, seconds: 29));
    expect(scope.state.busy, false);
    expect(scope.state.room.status, SyncPlayStatus.idle);
  });

  test(
      'legacy creator timed-out Pause blocks contradictory Play through late HTTP ACK',
      () async {
    final server = legacyCreatorServer()..pauseResponseGate = Completer<void>();
    final scope = await creatorScope(server);
    final creating = scope.notifier.createRoom();
    await server.pauseStarted.future;
    await creating; // The controller's 10s budget ends before HTTP's 15s budget.
    expect(scope.state.busy, false);
    expect(scope.state.room.failure?.code,
        SyncPlayFailureCode.creationUnconfirmed);
    expect(scope.state.recoveryActive, false);
    await scope.wrapper.play();
    await scope.wrapper.pause();
    await scope.notifier.reconnect();
    expect(server.sockets, hasLength(1));
    expect(server.requests.where((request) => request == 'Join'), isEmpty);
    expect(
        server.requests.where((request) => request == 'Pause'), hasLength(1));
    expect(server.requests.where((request) => request == 'Unpause'), isEmpty);
    expect(server.requests.where((request) => request == 'Ready'), isEmpty);
    server.pauseResponseGate!.complete();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await scope.wrapper.play();
    expect(server.requests.where((request) => request == 'Unpause'), isEmpty);
    expect(server.requests.where((request) => request == 'Ready'), isEmpty);
    expect(scope.wrapper.plays, 0);
    expect(scope.wrapper.raw.playing, false);
    await scope.notifier.leaveRoom();
    await _until(() => !scope.state.leavePending, 'uncertain creator left');
    expect(scope.wrapper.syncPlayCommands, isNull);
    expect(scope.state.busy, false);
    expect(scope.state.room.status, SyncPlayStatus.idle);
    expect(scope.wrapper.raw.position, const Duration(minutes: 9, seconds: 29));
  }, timeout: const Timeout(Duration(seconds: 15)));

  test(
      'Android home joins with no media, authorizes own item and becomes ready once',
      () async {
    final server = _Server()
      ..name = 'JMS-123456'
      ..queue = homeQueue();
    final scope = await homeScope(server);
    expect(scope.container.exists(videoPlayerProvider), isFalse);
    expect(scope.notifier.canJoinFromHome, isTrue);
    final ticket = scope.notifier.beginHomeJoin('123456');
    expect(ticket, isNotNull);
    await _until(
        () => scope.state.readyHomeJoin == ticket, 'home playback ready');
    expect(scope.video.prepares, 1);
    expect(scope.video.loaded, hasLength(1));
    expect(server.mediaUsers, [scope.account.id]);
    expect(server.requests.where((e) => e == 'PlaybackInfo'), hasLength(1));
    expect(scope.notifier.consumeHomeJoin(ticket!), isTrue);
    expect(scope.notifier.consumeHomeJoin(ticket), isFalse);
    expect(scope.state.readyHomeJoin, isNull);
    await scope.notifier.stop();
  });

  test('provider waits for measured media ahead while raw buffering is false',
      () async {
    final server = _Server();
    await server.start();
    final scope = _Scope(server, preferences);
    addTearDown(() async {
      scope.dispose();
      await server.close();
    });
    scope.wrapper.bufferedAhead = const Duration(milliseconds: 100);
    await scope.notifier.createRoom();
    await _until(() => scope.state.prebuffer != null, 'first measured sample');
    expect(scope.wrapper.raw.buffering, isFalse);
    expect(scope.state.prebuffer!.ready, isFalse);
    expect(server.requests.where((e) => e == 'Ready'), isEmpty);
    expect(server.requests.where((e) => e == 'Buffer'), isEmpty);
    scope.wrapper.bufferedAhead = const Duration(seconds: 10);
    await _until(
        () =>
            server.requests.contains('Ready') &&
            scope.state.room.mediaReady == true,
        'media target reached and acknowledgement reflected in state');
    expect(scope.state.room.mediaReady, isTrue);
    await scope.notifier.stop();
  });

  test('home lookup cancellation sends no Join and never initializes playback',
      () async {
    final server = _Server()
      ..name = 'JMS-123456'
      ..listGate = Completer<void>();
    final scope = await homeScope(server);
    final ticket = scope.notifier.beginHomeJoin('123456')!;
    await server.listStarted.future;
    await scope.notifier.cancelHomeJoin(ticket);
    server.listGate!.complete();
    await _until(() => !scope.state.busy, 'lookup cancelled');
    expect(server.requests.where((e) => e == 'Join'), isEmpty);
    expect(scope.container.exists(videoPlayerProvider), isFalse);
    expect(scope.state.readyHomeJoin, isNull);
  });

  test('home cancel detaches immediately then leaves late Join without media/Ready',
      () async {
    final server = _Server()
      ..name = 'JMS-123456'
      ..queue = homeQueue()
      ..joinGate = Completer<void>();
    final scope = await homeScope(server);
    final ticket = scope.notifier.beginHomeJoin('123456')!;
    await server.joinStarted.future;
    final cancelled = scope.notifier.cancelHomeJoin(ticket);
    await cancelled.timeout(const Duration(seconds: 3));
    expect(scope.state.room.status, SyncPlayStatus.idle);
    expect(scope.container.exists(videoPlayerProvider), isFalse);
    expect(server.requests.where((e) => e == 'Leave'), isEmpty);
    server.joinGate!.complete();
    await server.leaveStarted.future.timeout(const Duration(seconds: 3));
    await _until(() => server.completedLeaves.length == 1,
        'late Join membership cleanup confirmed');
    expect(server.requests.where((e) => e == 'Leave'), hasLength(1));
    expect(server.memberships, isEmpty);
    expect(server.requests.where((e) => e == 'Ready'), isEmpty);
    expect(scope.container.exists(videoPlayerProvider), isFalse);
    expect(scope.state.room.status, SyncPlayStatus.idle);
  });

  test('missing and empty rooms leave existing playback untouched', () async {
    final server = _Server();
    final scope = await homeScope(server);
    final first = scope.notifier.beginHomeJoin('123456')!;
    await _until(() => scope.state.room.failure != null, 'missing room');
    expect(scope.state.room.failure!.code, SyncPlayFailureCode.noGroup);
    expect(scope.container.exists(videoPlayerProvider), isFalse);
    await scope.notifier.cancelHomeJoin(first);
    server.name = 'JMS-123456';
    final second = scope.notifier.beginHomeJoin('123456')!;
    await _until(() => scope.state.room.isJoined, 'empty room joined');
    expect(scope.state.preparingPlayback, isTrue);
    expect(scope.state.readyHomeJoin, isNull);
    expect(scope.container.exists(videoPlayerProvider), isFalse);
    await scope.notifier.cancelHomeJoin(second);
  });

  test(
      'media denial occurs before player prepare, then explicit cleanup permits retry',
      () async {
    final server = _Server()
      ..name = 'JMS-123456'
      ..queue = homeQueue()
      ..itemStatus = 403;
    final scope = await homeScope(server);
    final first = scope.notifier.beginHomeJoin('123456')!;
    await _until(
        () => scope.state.room.failure?.code == SyncPlayFailureCode.player,
        'own media denied');
    expect(scope.container.exists(videoPlayerProvider), isFalse);
    expect(server.requests.where((e) => e == 'PlaybackInfo'), isEmpty);
    expect(scope.notifier.beginHomeJoin('123456'), isNull);
    await scope.notifier.cancelHomeJoin(first);
    await _until(() => scope.state.room.status == SyncPlayStatus.idle,
        'explicit cleanup confirmed');
    server.itemStatus = 200;
    final second = scope.notifier.beginHomeJoin('123456')!;
    await _until(() => scope.state.readyHomeJoin == second, 'retry loaded');
    await scope.notifier.cancelHomeJoin(first);
    expect(scope.state.readyHomeJoin, second);
    expect(scope.notifier.consumeHomeJoin(second), isTrue);
    await scope.notifier.stop();
  });

  test(
      'cancel during captured item fetch cannot pause existing playback or prepare',
      () async {
    final server = _Server()
      ..name = 'JMS-123456'
      ..queue = homeQueue()
      ..itemGate = Completer<void>();
    final scope = await homeScope(server);
    final wrapper = scope.wrapper..raw.playing = true;
    final ticket = scope.notifier.beginHomeJoin('123456')!;
    await server.itemStarted.future;
    expect(wrapper.pauses, 0);
    await scope.notifier.cancelHomeJoin(ticket);
    server.itemGate!.complete();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(wrapper.pauses, 0);
    expect(wrapper.raw.playing, isTrue);
    expect(scope.video.prepares, 0);
    expect(scope.video.loaded, isEmpty);
    expect(scope.state.readyHomeJoin, isNull);
  });

  test('logout revokes home load and old ready ticket', () async {
    final server = _Server()
      ..name = 'JMS-123456'
      ..queue = homeQueue()
      ..itemGate = Completer<void>();
    final scope = await homeScope(server);
    final ticket = scope.notifier.beginHomeJoin('123456')!;
    await server.itemStarted.future;
    (scope.container.read(userProvider.notifier) as _User).replace(null);
    server.itemGate!.complete();
    await _until(() => !scope.state.busy, 'logout detached');
    expect(scope.notifier.canJoinFromHome, isFalse);
    expect(scope.notifier.consumeHomeJoin(ticket), isFalse);
    expect(scope.container.exists(videoPlayerProvider), isFalse);
  });

  test(
      'failed cleanup ends local workflow and retains only a diagnostic result',
      () async {
    final server = _Server()
      ..name = 'JMS-123456'
      ..leaveFails = true;
    final scope = await homeScope(server);
    final ticket = scope.notifier.beginHomeJoin('123456')!;
    await _until(() => scope.state.room.isJoined, 'joined empty room');
    await scope.notifier.cancelHomeJoin(ticket);
    await _until(() => scope.notifier.backgroundLeaveResult != null,
        'failed background cleanup');
    expect(
        scope.notifier.backgroundLeaveResult?.status, SyncPlayStatus.unknown);
    expect(scope.state.room.status, SyncPlayStatus.idle);
    expect(scope.state.busy, false);
    expect(scope.state.leavePending, false);
    expect(scope.state.failure, isNull);
    expect(scope.notifier.consumeHomeJoin(ticket), isFalse);
    expect(scope.container.exists(videoPlayerProvider), isFalse);
    await _until(() => server.closedSockets == 1, 'cleanup session closed');
  });

  test('home cancel during handshake cannot initialize or open playback later',
      () async {
    final server = _Server()
      ..name = 'JMS-123456'
      ..queue = homeQueue()
      ..upgradeGate = Completer<void>();
    final scope = await homeScope(server);
    final ticket = scope.notifier.beginHomeJoin('123456')!;
    await server.socketStarted.future;
    await scope.notifier.cancelHomeJoin(ticket);
    server.upgradeGate!.complete();
    await _until(
        () => server.closedSockets == 1, 'cancelled home socket closed');
    expect(server.requests.where((e) => e == 'Join'), isEmpty);
    expect(scope.container.exists(videoPlayerProvider), isFalse);
    expect(scope.state.readyHomeJoin, isNull);
  });

  test('explicit cancel cannot be revived by a new reconnect ticket', () async {
    final server = _Server()
      ..name = 'JMS-123456'
      ..queue = homeQueue()
      ..leaveFails = true;
    final scope = await homeScope(server);
    scope.video.prepareGate = Completer<void>();
    final first = scope.notifier.beginHomeJoin('123456')!;
    await _until(() => scope.video.prepares == 1, 'first preparation pending');
    await scope.notifier.cancelHomeJoin(first);
    await _until(() => scope.notifier.backgroundLeaveResult != null,
        'failed background cleanup');
    expect(
        scope.notifier.backgroundLeaveResult?.status, SyncPlayStatus.unknown);
    expect(scope.state.room.status, SyncPlayStatus.idle);
    expect(scope.state.leavePending, false);
    expect(scope.notifier.beginHomeReconnect(), isNull);
    scope.video.prepareGate!.complete();
    await _until(() => scope.video.preparedCurrent.isNotEmpty,
        'cancelled preparation returns');
    expect(scope.video.preparedCurrent, [false]);
    expect(scope.video.prepares, 1);
    expect(scope.video.loaded, isEmpty);
    expect(scope.notifier.consumeHomeJoin(first), isFalse);
    expect(scope.state.readyHomeJoin, isNull);
    expect(
        server.requests.where((request) => request == 'Leave'), hasLength(1));
  });

  test('ready home ticket is revoked when the host changes its queued item',
      () async {
    final server = _Server()
      ..name = 'JMS-123456'
      ..queue = homeQueue();
    final scope = await homeScope(server);
    final ticket = scope.notifier.beginHomeJoin('123456')!;
    await _until(() => scope.state.readyHomeJoin == ticket, 'first item ready');
    server.itemGate = Completer<void>();
    server.emit('PlayQueue', {
      ...homeQueue(),
      'Playlist': [
        {'ItemId': _media, 'PlaylistItemId': '77777777777777777777777777777777'}
      ],
    });
    await _until(() => server.mediaUsers.length == 2, 'new item authorizing');
    expect(scope.state.readyHomeJoin, isNull);
    expect(scope.state.preparingPlayback, isTrue);
    expect(scope.notifier.consumeHomeJoin(ticket), isFalse);
    server.itemGate!.complete();
    await _until(
        () => scope.state.readyHomeJoin == ticket, 'replacement ready');
    expect(scope.video.loaded, hasLength(2));
    expect(scope.notifier.consumeHomeJoin(ticket), isTrue);
    await scope.notifier.stop();
  });

  test(
      'restored account refreshes runtime policy without persisting it or opening a room',
      () async {
    final server = _Server();
    await server.start();
    final scope = _Scope(server, preferences);
    addTearDown(() async {
      scope.dispose();
      await server.close();
    });
    final stored =
        jsonDecode(jsonEncode(scope.account)) as Map<String, dynamic>;
    expect(stored.containsKey('policy'), false);
    final restored = AccountModel.fromJson(stored);
    expect(restored.policy, isNull);
    (scope.container.read(userProvider.notifier) as _User).replace(restored);
    expect(scope.notifier.permissionKnown, false);
    expect(scope.notifier.canCreate, false);
    await scope.notifier.refreshPermission();
    expect(scope.notifier.permissionKnown, true);
    expect(scope.notifier.canCreate, true);
    expect(scope.notifier.canJoin, true);
    expect(scope.container.read(userProvider)!.toJson().containsKey('policy'),
        false);
    expect(server.requests, ['Me']);
    expect(server.sockets, isEmpty);
  });

  test(
      'server None is a known denial and cannot reuse the earlier allowed policy',
      () async {
    final server = _Server()..policyAccess = 'None';
    await server.start();
    final scope = _Scope(server, preferences);
    addTearDown(() async {
      scope.dispose();
      await server.close();
    });
    expect(scope.notifier.canCreate, true);
    await scope.notifier.refreshPermission();
    expect(scope.notifier.permissionKnown, true);
    expect(scope.notifier.canCreate, false);
    expect(scope.notifier.canJoin, false);
    await scope.notifier.createRoom();
    expect(server.requests, ['Me']);
    expect(server.sockets, isEmpty);
  });

  test(
      '401 refresh leaves permission unknown and blocks stale cached access without retry',
      () async {
    final server = _Server()..policyStatus = 401;
    await server.start();
    final scope = _Scope(server, preferences);
    addTearDown(() async {
      scope.dispose();
      await server.close();
    });
    await scope.notifier.refreshPermission();
    expect(scope.notifier.permissionChecking, false);
    expect(scope.notifier.permissionKnown, false);
    expect(scope.notifier.canJoin, false);
    expect(scope.notifier.canCreate, false);
    await scope.notifier.createRoom();
    expect(server.requests, ['Me']);
    expect(server.sockets, isEmpty);
  });

  test(
      'late policy response cannot cross an account/source change even after returning to the original account',
      () async {
    final server = _Server()..policyGate = Completer<void>();
    await server.start();
    final scope = _Scope(server, preferences);
    addTearDown(() async {
      scope.dispose();
      await server.close();
    });
    final restored =
        AccountModel.fromJson(jsonDecode(jsonEncode(scope.account)));
    final user = scope.container.read(userProvider.notifier) as _User;
    user.replace(restored);
    final refreshing = scope.notifier.refreshPermission();
    await server.policyStarted.future;
    expect(scope.notifier.permissionChecking, true);
    user.replace(restored.copyWith(
        id: 'another-synthetic-user',
        credentials: restored.credentials
            .copyWith(url: server.uri.resolve('/another-source').toString())));
    user.replace(restored);
    server.policyGate!.complete();
    await refreshing;
    expect(scope.container.read(userProvider)!.policy, isNull);
    expect(scope.notifier.permissionKnown, false);
    expect(scope.notifier.canJoin, false);
    expect(server.requests, ['Me']);
    expect(server.sockets, isEmpty);
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
    await _until(() => !scope.state.leavePending, 'stopped provider detaches');
    expect(server.requests.indexOf('New-completed'),
        lessThan(server.requests.indexOf('Leave')));
    expect(server.requests.where((item) => item == 'New'), hasLength(1));
    expect(server.requests.where((item) => item == 'SetNewQueue'), isEmpty);
    expect(scope.video.loaded, isEmpty);
    expect(scope.wrapper.syncPlayCommands, isNull);
    expect(scope.state.room.status, SyncPlayStatus.idle);
  }, timeout: const Timeout(Duration(seconds: 10)));

  test(
      'failed Leave ends the workflow without exposing a reconnect or retry step',
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
    expect(scope.state.busy, false);
    expect(scope.wrapper.syncPlayCommands, isNull);
    await _until(() => scope.notifier.backgroundLeaveResult != null,
        'failed background leave');
    expect(
        scope.notifier.backgroundLeaveResult?.status, SyncPlayStatus.unknown);
    expect(scope.state.room.status, SyncPlayStatus.idle);
    expect(scope.state.room.group, isNull);
    expect(scope.notifier.active, false);
    expect(scope.state.leavePending, false);
    expect(scope.state.failure, isNull);
    expect(scope.wrapper.syncPlayCommands, isNull);
    await _until(
        () => server.closedSockets == 1, 'failed Leave session closed');
    server.emit('GroupJoined', server.group);
    server.unpause();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(server.requests.where((item) => item == 'Join'), isEmpty);
    expect(server.requests.where((item) => item == 'Leave'), hasLength(1));
    expect(server.requests.where((item) => item == 'New'), hasLength(1));
    expect(scope.state.room.status, SyncPlayStatus.idle);
    expect(scope.wrapper.syncPlayCommands, isNull);
  }, timeout: const Timeout(Duration(seconds: 10)));

  test('Leave or Stop without a session does not suppress a new explicit room',
      () async {
    final server = _Server();
    await server.start();
    final scope = _Scope(server, preferences);
    addTearDown(() async {
      scope.dispose();
      await server.close();
    });
    await scope.notifier.stop();
    await scope.notifier.leaveRoom();
    expect(scope.notifier.active, false);
    await scope.notifier.createRoom();
    await _until(() => scope.state.room.canControl, 'new explicit room');
    expect(scope.notifier.active, true);
  }, timeout: const Timeout(Duration(seconds: 10)));

  test(
      'Windows control DeviceId matches legacy REST and socket sessions and isolates late Leave',
      () async {
    for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
      final server = _Server()
        ..legacyNewNoContent = platform == TargetPlatform.windows;
      await server.start();
      final scope = _Scope(server, preferences, platform: platform);
      final originalCredentials = scope.account.credentials;
      final savedCredentials = jsonEncode(originalCredentials.toJson());
      final windows = platform == TargetPlatform.windows;
      final oldLeaveGate = Completer<void>();
      try {
        await scope.notifier.createRoom();
        await _until(
            () => scope.video.loaded.length == 1 && scope.state.room.canControl,
            'first control session ready');
        final first = server.identities
            .firstWhere((identity) => identity.endpoint == 'New');
        final firstSocket = server.identities
            .singleWhere((identity) => identity.endpoint == 'socket');
        expect(first.client, windows ? isNull : 'JMS-test');
        expect(firstSocket.client, isNull);
        expect(
            first.deviceId,
            windows
                ? isNot(originalCredentials.deviceId)
                : originalCredentials.deviceId);
        expect(firstSocket.queryDeviceId, first.deviceId);
        if (windows) {
          expect(firstSocket.deviceId, first.deviceId);
          expect(first.session, firstSocket.session,
              reason:
                  'legacy REST and websocket must address the same session');
          expect(first.session.client, _legacyTokenClient);
          server.leaveGate = oldLeaveGate;
        } else {
          server.leaveFails = true;
        }
        await scope.notifier.leaveRoom();
        await _until(() => scope.notifier.backgroundLeaveResult != null,
            'first failed Leave retired',
            timeout: Duration(seconds: windows ? 11 : 3));
        expect(scope.notifier.backgroundLeaveResult?.status,
            SyncPlayStatus.unknown);
        expect(scope.state.room.status, SyncPlayStatus.idle);
        expect(scope.state.leavePending, false);
        await _until(() => server.closedSockets == 1, 'old socket closed');
        final firstLeave = server.identities
            .singleWhere((identity) => identity.endpoint == 'Leave');
        expect(firstLeave.session, first.session);
        expect(firstLeave.client, first.client);

        // The old Leave result may still be unknown, but a new explicit room
        // must capture a different Windows session rather than reuse its key.
        server.leaveFails = false;
        await scope.notifier.createRoom();
        await _until(
            () => scope.video.loaded.length == 2 && scope.state.room.canControl,
            'replacement control session ready');
        final newSessions = server.identities
            .where((identity) => identity.endpoint == 'New')
            .toList();
        expect(newSessions, hasLength(2));
        final second = newSessions.last;
        final secondSocket = server.identities
            .where((identity) => identity.endpoint == 'socket')
            .last;
        expect(second.client, windows ? isNull : 'JMS-test');
        expect(secondSocket.client, isNull);
        expect(secondSocket.queryDeviceId, second.deviceId);
        if (windows) {
          expect(second.session, secondSocket.session);
          expect(second.deviceId, isNot(first.deviceId));
          expect(second.deviceId, isNot(originalCredentials.deviceId));
          expect(second.session.client, _legacyTokenClient);
          expect(server.memberships[second.session], server.name);
          // The original HTTP handler is still live after local cleanup. Its
          // real late completion may remove only the captured old session.
          oldLeaveGate.complete();
          await _until(() => server.completedLeaves.contains(first.session),
              'old Leave completed against its captured session');
          expect(server.memberships.containsKey(first.session), isFalse);
          expect(server.memberships[second.session], server.name);
          expect(scope.state.room.isJoined, isTrue);
          expect(scope.state.failure, isNull);
          server.leaveGate = null;
        } else {
          expect(second.deviceId, originalCredentials.deviceId);
          expect(second.session, first.session);
        }
        await scope.notifier.leaveRoom();
        await _until(
            () => !scope.state.leavePending, 'replacement Leave ended');
        expect(
            server.identities
                .where((identity) => identity.endpoint == 'Leave')
                .last
                .session,
            second.session);

        for (final endpoint in [_media, 'PlaybackInfo']) {
          final playbackRequests = server.identities
              .where((identity) => identity.endpoint == endpoint);
          expect(playbackRequests, isNotEmpty);
          expect(
              playbackRequests.every((identity) =>
                  identity.client == 'JMS-test' &&
                  identity.deviceId == originalCredentials.deviceId),
              isTrue,
              reason: 'playback keeps the saved account session');
        }
        if (!windows) {
          expect(
              server.identities.every((identity) =>
                  identity.deviceId == originalCredentials.deviceId),
              isTrue);
        }
        final retainedCredentials =
            scope.container.read(userProvider)!.credentials;
        expect(identical(retainedCredentials, originalCredentials), isTrue);
        expect(jsonEncode(retainedCredentials.toJson()) == savedCredentials,
            isTrue);
      } finally {
        if (!oldLeaveGate.isCompleted) oldLeaveGate.complete();
        scope.dispose();
        await server.close();
      }
    }
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('Leave GroupLeft before HTTP response never recaptures local controls',
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
        'initial adapter load');
    server.leftBeforeLeaveResponse = true;
    server.leaveGate = gate;
    final leaving = scope.notifier.leaveRoom();
    await server.leaveStarted.future;
    expect(scope.state.room.status, SyncPlayStatus.idle);
    expect(scope.state.busy, false);
    expect(scope.notifier.active, false);
    expect(scope.wrapper.syncPlayCommands, isNull);
    gate.complete();
    await leaving;
    await _until(() => !scope.state.leavePending, 'authoritative GroupLeft');
    expect(scope.notifier.backgroundLeaveResult?.status, SyncPlayStatus.idle);
    expect(scope.wrapper.syncPlayCommands, isNull);
  }, timeout: const Timeout(Duration(seconds: 10)));

  test(
      'one Leave bypasses busy New and returns solo before any server response',
      () async {
    final server = _Server()..newGate = Completer<void>();
    await server.start();
    final scope = _Scope(server, preferences);
    addTearDown(() async {
      scope.dispose();
      await server.close();
    });
    scope.wrapper.raw.position = const Duration(seconds: 37);
    scope.wrapper.raw.playing = false;
    final creating = scope.notifier.createRoom();
    await server.newStarted.future;
    expect(scope.state.busy, true);
    final pauses = scope.wrapper.pauses;
    await scope.notifier.leaveRoom();
    expect(scope.notifier.active, false);
    expect(scope.state.busy, false);
    expect(scope.state.leavePending, true);
    expect(scope.wrapper.syncPlayCommands, isNull);
    expect(scope.wrapper.raw.position, const Duration(seconds: 37));
    expect(scope.wrapper.raw.playing, false);
    expect(scope.wrapper.pauses, pauses);
    expect(server.requests.where((e) => e == 'Leave'), isEmpty);
    await scope.notifier.createRoom();
    expect(server.requests.where((e) => e == 'New'), hasLength(1));
    server.newGate!.complete();
    await creating;
    await _until(
        () => !scope.state.leavePending, 'late New cleaned without playback');
    expect(server.requests.where((e) => e == 'Leave'), hasLength(1));
    expect(server.requests.where((e) => e == 'SetNewQueue'), isEmpty);
    expect(scope.video.loaded, isEmpty);
  });

  test('stalled Leave does not own local player or require another user action',
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
        'initial adapter ready');
    scope.wrapper.raw.position = const Duration(seconds: 24);
    scope.wrapper.raw.playing = true;
    server.leaveGate = gate;
    await scope.notifier.leaveRoom();
    await server.leaveStarted.future;
    expect(scope.state.busy, false);
    expect(scope.wrapper.syncPlayCommands, isNull);
    expect(scope.wrapper.raw.playing, true);
    expect(scope.wrapper.raw.position, const Duration(seconds: 24));
    expect(server.requests.where((e) => e == 'Leave'), hasLength(1));
    server
        .unpause(); // A late room command cannot seek or replay solo playback.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(scope.wrapper.raw.position, const Duration(seconds: 24));
    gate.complete();
    await _until(
        () => !scope.state.leavePending, 'late acknowledgement confirmed');
    expect(scope.notifier.backgroundLeaveResult?.status, SyncPlayStatus.idle);
    expect(scope.wrapper.syncPlayCommands, isNull);
    expect(server.requests.where((e) => e == 'Join'), isEmpty);
  });

  for (final initiallyPlaying in [false, true]) {
    testWidgets(
        'one real dialog Leave removes the barrier and returns clickable solo controls playing=$initiallyPlaying',
        (tester) async {
      final server = _Server();
      final gate = Completer<void>();
      late _Scope scope;
      await tester.runAsync(() async {
        await server.start();
        scope = _Scope(server, preferences);
        await scope.notifier.createRoom();
        await _until(
            () => scope.video.loaded.length == 1 && scope.state.room.canControl,
            'real provider joined and loaded');
      });
      try {
        scope.wrapper.raw.position = const Duration(seconds: 37);
        scope.wrapper.raw.playing = initiallyPlaying;
        server.leaveGate = gate;
        final pauses = scope.wrapper.pauses;
        final plays = scope.wrapper.plays;
        final loads = scope.video.loaded.length;
        final requestsBefore = server.requests.length;
        await tester.pumpWidget(UncontrolledProviderScope(
          container: scope.container,
          child: MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  const Text('Synthetic solo player'),
                  const SyncPlayButton(),
                  ElevatedButton(
                    key: const ValueKey('main-player-pause'),
                    onPressed: scope.wrapper.pause,
                    child: const Text('Pause video'),
                  ),
                  ElevatedButton(
                    key: const ValueKey('main-player-seek'),
                    onPressed: () =>
                        scope.wrapper.seek(const Duration(seconds: 42)),
                    child: const Text('Seek to 42 seconds'),
                  ),
                ],
              ),
            ),
          ),
        ));
        // The root MaterialPageRoute has its own transparent barrier. Compare
        // against that baseline so only the room route's blockers are counted.
        final barriers = find.byWidgetPredicate((widget) =>
            widget is ModalBarrier || widget is AnimatedModalBarrier);
        final baselineBarriers = barriers.evaluate().length;
        await tester.tap(find.byType(SyncPlayButton));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();
        expect(find.byType(SyncPlayDialog), findsOneWidget);
        expect(barriers.evaluate().length, greaterThan(baselineBarriers));
        await tester.ensureVisible(find.text('Leave room'));
        final leaveClock = Stopwatch()..start();
        // The real HTTP fixture must run outside the widget clock's fake I/O
        // zone. UI dismissal is still checked after exactly one pumped frame.
        await tester.runAsync(() => tester.tap(find.text('Leave room')));
        await tester.pump();

        // This checks the real Navigator route and hit testing, rather than
        // treating a provider flag as evidence that the modal has gone away.
        expect(find.byType(SyncPlayDialog), findsNothing);
        expect(barriers.evaluate().length, baselineBarriers);
        expect(find.text('Playing solo'), findsOneWidget);
        expect(scope.wrapper.raw.position, const Duration(seconds: 37));
        expect(scope.wrapper.raw.playing, initiallyPlaying);
        expect(scope.wrapper.pauses, pauses);
        expect(scope.wrapper.plays, plays);
        expect(scope.state.room.status, SyncPlayStatus.idle);
        expect(scope.state.busy, false);
        expect(scope.state.leavePending, true);
        await tester.runAsync(
            () => _until(() => server.leaveStarted.isCompleted, 'Leave sent'));
        expect(gate.isCompleted, false);

        await tester.tap(find.byKey(const ValueKey('main-player-pause')));
        await tester.pump();
        expect(scope.wrapper.pauses, pauses + 1);
        expect(scope.wrapper.raw.playing, false);
        await tester.tap(find.byKey(const ValueKey('main-player-seek')));
        await tester.pump();
        expect(scope.wrapper.raw.position, const Duration(seconds: 42));

        server.emit('GroupJoined', server.group);
        server.emit('PlayQueue', {
          ...server.queue!,
          'LastUpdate': DateTime.now().toUtc().toIso8601String(),
          'StartPositionTicks': 990000000,
        });
        server.unpause();
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 80)));
        await tester.pump();
        expect(scope.wrapper.raw.position, const Duration(seconds: 42));
        expect(scope.wrapper.raw.playing, false);
        expect(scope.wrapper.plays, plays);
        expect(scope.video.loaded.length, loads);
        expect(
            server.requests.skip(requestsBefore).where((endpoint) => const {
                  'Pause',
                  'Unpause',
                  'Seek',
                  'Join',
                  'SetNewQueue'
                }.contains(endpoint)),
            isEmpty);

        if (initiallyPlaying) {
          // Exercise the real ten-second budget once; the paused variant
          // instead checks the successful acknowledgement path.
          await tester.runAsync(() => _until(
              () => !scope.state.leavePending, 'bounded background leave',
              timeout: const Duration(seconds: 11)));
          expect(leaveClock.elapsed, lessThan(const Duration(seconds: 11)));
          expect(scope.notifier.backgroundLeaveResult?.status,
              SyncPlayStatus.unknown);
          expect(scope.notifier.backgroundLeaveResult?.failure?.code,
              SyncPlayFailureCode.timeoutUnknown);
        } else {
          gate.complete();
          await tester.runAsync(() => _until(
              () => !scope.state.leavePending, 'background leave confirmed'));
          expect(scope.notifier.backgroundLeaveResult?.status,
              SyncPlayStatus.idle);
        }
        await tester.pump();
        expect(scope.state.leavePending, false);
        expect(scope.state.room.status, SyncPlayStatus.idle);
        expect(scope.state.failure, isNull);
        expect(find.text('Retry leave'), findsNothing);
        expect(find.text('Confirm leave'), findsNothing);
        expect(find.byType(SyncPlayDialog), findsNothing);
        await tester.runAsync(() =>
            _until(() => server.closedSockets == 1, 'old session closed'));
        expect(server.requests.where((endpoint) => endpoint == 'Leave'),
            hasLength(1));
        expect(scope.wrapper.raw.position, const Duration(seconds: 42));
        expect(scope.wrapper.raw.playing, false);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          if (!gate.isCompleted) gate.complete();
          scope.dispose();
          await server.close();
        });
      }
    });
  }

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
    final requestsBeforeManualControls = server.requests.length;
    server.unpause();
    await scope.wrapper.playStarted!.future;
    expect(gate.isCompleted, false);
    final pauses = scope.wrapper.pauses;
    await scope.wrapper.pause();
    await scope.wrapper.play();
    await scope.wrapper.seek(const Duration(seconds: 37));
    for (final endpoint in ['Pause', 'Unpause', 'Seek']) {
      expect(
          server.requests
              .skip(requestsBeforeManualControls)
              .where((request) => request == endpoint),
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
