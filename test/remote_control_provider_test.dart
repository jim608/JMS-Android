import 'dart:async';
import 'dart:convert';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart' as jellyfin;
import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/credentials_model.dart';
import 'package:fladder/providers/jellyfin_session_socket_provider.dart';
import 'package:fladder/providers/remote_control_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/services/jellyfin_session_socket.dart';
import 'package:fladder/services/remote_control/remote_control_models.dart';
import 'package:fladder/services/remote_control/remote_receiver.dart';
import 'package:fladder/util/application_info.dart';
import 'package:fladder/util/brand.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _userA = '11111111111111111111111111111111';
const _userB = '22222222222222222222222222222222';
const _item = '33333333333333333333333333333333';
const _policy = jellyfin.UserPolicy(
    authenticationProviderId: 'fixture',
    passwordResetProviderId: 'fixture',
    enableMediaPlayback: true);

AccountModel _account({String id = _userA, bool knownPolicy = true}) =>
    AccountModel(
      name: 'Fixture $id',
      id: id,
      avatar: '',
      lastUsed: DateTime.utc(2026),
      credentials: CredentialsModel.internal(
          url: 'https://fixture.example.invalid/jellyfin',
          token: 'synthetic-$id',
          serverId: 'fixture-server',
          deviceId: 'device-$id'),
      policy: knownPolicy ? _policy : null,
    );

http.Response _json(Object? body) => http.Response(jsonEncode(body), 200,
    headers: {'content-type': 'application/json'});

Future<void> _turns([int count = 4]) async {
  for (var i = 0; i < count; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 80; i++) {
    if (condition()) return;
    await _turns(1);
  }
  expect(condition(), true,
      reason: 'The expected local async state did not settle.');
}

class _User extends User {
  _User(this.initial);
  final AccountModel? initial;
  @override
  AccountModel? build() => initial;
  void replace(AccountModel? account) => state = account;
}

class _Socket implements JellyfinSessionSocket {
  _Socket({bool ready = true}) {
    if (ready) opening.complete();
  }
  final opening = Completer<void>();
  final incoming = StreamController<Object?>.broadcast(sync: true);
  final sent = <String>[];
  int closes = 0;
  bool _closed = false;
  @override
  Future<void> get ready => opening.future;
  @override
  Stream<Object?> get messages => incoming.stream;
  @override
  void send(String value) => sent.add(value);
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    closes++;
    if (!opening.isCompleted) opening.complete();
    await incoming.close();
  }
}

class _Player implements RemotePlaybackPort {
  @override
  bool blockedBySyncPlay = false;
  @override
  RemotePlaybackSnapshot? snapshot = const RemotePlaybackSnapshot(
    binding: RemotePlaybackBinding(
        itemId: _item,
        mediaSourceId: 'source',
        playbackId: 'jms-remote-occurrence'),
    positionTicks: 10000000,
    durationTicks: 6000000000,
    paused: false,
    canSeek: true,
    subtitleIndex: 8,
  );
  @override
  Future<void> play(RemotePlaybackBinding binding) async {}
  @override
  Future<void> pause(RemotePlaybackBinding binding) async {}
  @override
  Future<void> seek(Duration position, RemotePlaybackBinding binding) async {}
  @override
  Future<void> setSubtitle(int index, RemotePlaybackBinding binding) async {}
}

class _Client extends MockClient {
  _Client(super.fn);
  int closes = 0;
  @override
  void close() {
    closes++;
    super.close();
  }
}

typedef _Handler = Future<http.Response?> Function(
    _ApiRecord api, http.Request request);

class _ApiRecord {
  _ApiRecord(this.account, this.handler) {
    client = _Client((request) async {
      requests.add(request);
      final capability =
          request.url.path.endsWith('/Sessions/Capabilities/Full');
      bool? enabled;
      if (capability) {
        enabled =
            (jsonDecode(request.body) as Map)['SupportsMediaControl'] == true;
        capabilityStarted.add(enabled);
      }
      final override = await handler?.call(this, request);
      final response = override ?? _response(request);
      if (enabled != null) capabilityCompleted.add(enabled);
      return response;
    });
    api = jellyfin.JellyfinOpenApi.create(
        baseUrl: Uri.parse(account.credentials.url), httpClient: client);
  }
  final AccountModel account;
  final _Handler? handler;
  final requests = <http.Request>[];
  final capabilityStarted = <bool>[];
  final capabilityCompleted = <bool>[];
  late final _Client client;
  late final jellyfin.JellyfinOpenApi api;

  http.Response me() => _json({'Id': account.id, 'Policy': _policy.toJson()});

  Map<String, dynamic> _session({required bool own}) => {
        'Id': own ? 'receiver-${account.id}' : 'tesla-${account.id}',
        'UserId': account.id,
        'ServerId': account.credentials.serverId,
        'DeviceId': own ? account.credentials.deviceId : 'tesla',
        'DeviceName': own ? 'Local receiver' : 'Tesla',
        'Client': Brand.name,
        'IsActive': true,
        'LastActivityDate': DateTime.now().toUtc().toIso8601String(),
        'SupportsMediaControl': true,
        'SupportsRemoteControl': true,
        'SupportedCommands': ['PlayState', 'SetSubtitleStreamIndex'],
        'PlaylistItemId': 'jms-remote-occurrence',
        'NowPlayingItem': {'Id': _item, 'RunTimeTicks': 6000000000},
        'PlayState': {
          'MediaSourceId': 'source',
          'PositionTicks': 10000000,
          'IsPaused': false,
          'CanSeek': true,
          'SubtitleStreamIndex': 8
        },
      };

  http.Response _response(http.Request request) {
    if (request.url.path.endsWith('/Users/Me')) return me();
    if (request.url.path.endsWith('/Sessions') && request.method == 'GET') {
      return _json(
          [_session(own: request.url.queryParameters.containsKey('deviceId'))]);
    }
    return http.Response('', 204);
  }
}

class _Fixture {
  _Fixture({AccountModel? account, this.handler, this.pendingSockets = false}) {
    initial = account ?? _account();
    container = ProviderContainer(overrides: [
      userProvider.overrideWith(() => _User(initial)),
      applicationInfoProvider.overrideWith((ref) => ApplicationInfo(
          name: Brand.name,
          version: '0.0.0',
          buildNumber: '0',
          platform: TargetPlatform.windows)),
      remotePlaybackPortProvider.overrideWithValue(player),
      remoteAccountApiFactoryProvider.overrideWithValue((account) {
        final record = _ApiRecord(account, handler);
        apis.add(record);
        return record.api;
      }),
      jellyfinSessionSocketHubProvider.overrideWith((ref) {
        final hub = JellyfinSessionSocketHub(connector: (uri, headers) {
          socketUris.add(uri);
          socketHeaders.add(Map.unmodifiable(headers));
          final socket = _Socket(ready: !pendingSockets);
          sockets.add(socket);
          return socket;
        });
        hubs.add(hub);
        ref.onDispose(() => unawaited(hub.dispose()));
        return hub;
      }),
    ]);
    notifier = container.read(remoteControlProvider.notifier);
  }
  final _Handler? handler;
  final bool pendingSockets;
  final player = _Player();
  final apis = <_ApiRecord>[];
  final sockets = <_Socket>[];
  final socketUris = <Uri>[];
  final socketHeaders = <Map<String, String>>[];
  final hubs = <JellyfinSessionSocketHub>[];
  late final AccountModel initial;
  late final ProviderContainer container;
  late final RemoteControlNotifier notifier;
  bool disposed = false;
  RemoteControlViewState get state => container.read(remoteControlProvider);
  void replace(AccountModel? account) =>
      (container.read(userProvider.notifier) as _User).replace(account);
  Future<void> dispose() async {
    if (!disposed) {
      disposed = true;
      container.dispose();
    }
    await _turns();
    for (final hub in hubs) {
      await hub.dispose();
    }
    await _turns();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('reading the provider opens no API, socket or capability advertisement',
      () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    expect(fixture.state.controllerOpen, false);
    expect(fixture.state.receivingEnabled, false);
    expect(fixture.apis, isEmpty);
    expect(fixture.sockets, isEmpty);
  });

  test(
      'controller open is idempotent and stopping it leaves an enabled receiver intact',
      () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    await fixture.notifier.setReceiving(true);
    await _until(() => fixture.apis.first.capabilityCompleted.contains(true));
    final receiverApi = fixture.apis.single;
    await fixture.notifier.startController();
    await fixture.notifier.startController();
    expect(fixture.apis, hasLength(2));
    expect(fixture.state.controller.targets.single.name, 'Tesla');
    final senderApi = fixture.apis.last;
    await fixture.notifier.stopController();
    expect(fixture.state.controllerOpen, false);
    expect(fixture.state.receivingEnabled, true);
    expect(fixture.sockets.single.closes, 0);
    expect(receiverApi.client.closes, 0);
    expect(senderApi.client.closes, 1);
  });

  test(
      'closing a controller during policy verification prevents discovery or late dialog reopening',
      () async {
    final verification = Completer<http.Response>();
    final fixture = _Fixture(
        account: _account(knownPolicy: false),
        handler: (api, request) async {
          if (request.url.path.endsWith('/Users/Me')) {
            return await verification.future;
          }
          return null;
        });
    addTearDown(fixture.dispose);
    final starting = fixture.notifier.startController();
    await _until(() => fixture.apis.single.requests.isNotEmpty);
    await fixture.notifier.stopController();
    verification.complete(fixture.apis.single.me());
    await starting;
    expect(fixture.state.controllerOpen, false);
    expect(fixture.state.controller.targets, isEmpty);
    expect(
        fixture.apis.single.requests
            .where((request) => request.url.path.endsWith('/Sessions')),
        isEmpty);
    expect(fixture.apis.single.client.closes, 1);
  });

  test(
      'a closed and reopened controller ignores the older verification failure',
      () async {
    final verification = Completer<http.Response>();
    late _Fixture fixture;
    fixture = _Fixture(
        account: _account(knownPolicy: false),
        handler: (api, request) async {
          if (request.url.path.endsWith('/Users/Me') &&
              identical(api, fixture.apis.first)) {
            return await verification.future;
          }
          return null;
        });
    addTearDown(fixture.dispose);
    final oldStart = fixture.notifier.startController();
    await _until(() => fixture.apis.first.requests.isNotEmpty);
    await fixture.notifier.stopController();
    await fixture.notifier.startController();
    expect(fixture.state.controllerOpen, true);
    expect(fixture.state.controller.targets.single.userId, _userA);
    verification.complete(http.Response('', 403));
    await oldStart;
    expect(fixture.state.controllerOpen, true);
    expect(fixture.state.failure, isNull);
    expect(fixture.apis.first.client.closes, 1);
    expect(fixture.apis.last.client.closes, 0);
  });

  test('A to B to A cannot revive a pending first-login controller', () async {
    final verification = Completer<http.Response>();
    late _Fixture fixture;
    fixture = _Fixture(
        account: _account(knownPolicy: false),
        handler: (api, request) async {
          if (request.url.path.endsWith('/Users/Me') &&
              identical(api, fixture.apis.first)) {
            return await verification.future;
          }
          return null;
        });
    addTearDown(fixture.dispose);
    final oldStart = fixture.notifier.startController();
    await _until(() => fixture.apis.first.requests.isNotEmpty);
    fixture.replace(_account(id: _userB));
    fixture.replace(_account());
    await fixture.notifier.startController();
    verification.complete(fixture.apis.first.me());
    await oldStart;
    expect(fixture.state.controller.targets.single.userId, _userA);
    expect(fixture.apis, hasLength(2));
    expect(
        fixture.apis.first.requests
            .where((request) => request.url.path.endsWith('/Sessions')),
        isEmpty);
    expect(fixture.apis.first.client.closes, 1);
  });

  test(
      'disabling while socket readiness is pending cannot advertise an old receiver',
      () async {
    final fixture = _Fixture(pendingSockets: true);
    addTearDown(fixture.dispose);
    final enabling = fixture.notifier.setReceiving(true);
    await _until(() => fixture.sockets.isNotEmpty);
    await fixture.notifier.setReceiving(false);
    await enabling;
    await _turns();
    expect(fixture.state.receivingEnabled, false);
    expect(fixture.state.receiverStatus, RemoteReceiverState.disabled);
    expect(fixture.state.receiverBusy, false);
    expect(fixture.apis.single.capabilityStarted, isNot(contains(true)));
    expect(fixture.sockets.single.closes, 1);
    expect(
        fixture.apis.single.requests
            .where((request) => request.url.path.endsWith('/Sessions')),
        isEmpty);
  });

  test(
      'disabling during receiver policy verification closes its untransferred API',
      () async {
    final verification = Completer<http.Response>();
    final fixture = _Fixture(
        account: _account(knownPolicy: false),
        handler: (api, request) async {
          if (request.url.path.endsWith('/Users/Me')) {
            return await verification.future;
          }
          return null;
        });
    addTearDown(fixture.dispose);
    final enabling = fixture.notifier.setReceiving(true);
    await _until(() => fixture.apis.single.requests.isNotEmpty);
    await fixture.notifier.setReceiving(false);
    verification.complete(fixture.apis.single.me());
    await enabling;
    expect(fixture.sockets, isEmpty);
    expect(fixture.apis.single.capabilityStarted, isEmpty);
    expect(fixture.apis.single.client.closes, 1);
    expect(fixture.state.receivingEnabled, false);
    expect(fixture.state.receiverBusy, false);
  });

  test(
      'a late own-session lookup cannot enable or overwrite the replacement account receiver',
      () async {
    final ownSession = Completer<http.Response>();
    final fixture = _Fixture(handler: (api, request) async {
      if (api.account.id == _userA && request.url.path.endsWith('/Sessions')) {
        return await ownSession.future;
      }
      return null;
    });
    addTearDown(fixture.dispose);
    final oldEnable = fixture.notifier.setReceiving(true);
    await _until(() => fixture.apis.first.requests
        .any((request) => request.url.path.endsWith('/Sessions')));
    final oldApi = fixture.apis.first;
    fixture.replace(_account(id: _userB));
    await fixture.notifier.setReceiving(true);
    await _until(() => fixture.apis.last.capabilityCompleted.contains(true));
    ownSession.complete(_json([oldApi._session(own: true)]));
    await oldEnable;
    await _turns();
    expect(oldApi.capabilityStarted, isNot(contains(true)));
    expect(oldApi.client.closes, 1);
    expect(fixture.state.receivingEnabled, true);
    expect(fixture.state.receiverStatus, RemoteReceiverState.enabled);
    expect(fixture.apis.last.account.id, _userB);
    expect(fixture.apis.last.client.closes, 0);
  });

  test(
      'off then on reuses receiver transport and finishes with a true advertisement',
      () async {
    final blockedFalse = Completer<http.Response>();
    var holdFalse = true;
    final fixture = _Fixture(handler: (api, request) async {
      if (request.url.path.endsWith('/Sessions/Capabilities/Full') &&
          (jsonDecode(request.body) as Map)['SupportsMediaControl'] == false &&
          holdFalse) {
        return await blockedFalse.future;
      }
      return null;
    });
    addTearDown(fixture.dispose);
    await fixture.notifier.setReceiving(true);
    await _until(() => fixture.apis.single.capabilityCompleted.contains(true));
    final record = fixture.apis.single;
    final disabling = fixture.notifier.setReceiving(false);
    await _until(() => record.capabilityStarted.contains(false));
    await fixture.notifier.setReceiving(true);
    expect(fixture.apis, hasLength(1));
    expect(record.capabilityStarted, [true, false]);
    holdFalse = false;
    blockedFalse.complete(http.Response('', 204));
    await disabling;
    await _until(() => record.capabilityCompleted.length == 3);
    expect(record.capabilityCompleted, [true, false, true]);
    expect(fixture.state.receivingEnabled, true);
    expect(fixture.state.receiverStatus, RemoteReceiverState.enabled);
    expect(fixture.state.receiverBusy, false);
    expect(record.client.closes, 0);
  });

  test(
      'account change closes captured sender, receiver and socket without leaking old state',
      () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    await fixture.notifier.startController();
    await fixture.notifier.setReceiving(true);
    await _until(() => fixture.apis.last.capabilityCompleted.contains(true));
    final oldApis = List<_ApiRecord>.of(fixture.apis);
    fixture.replace(_account(id: _userB));
    await _until(() =>
        oldApis.every((api) => api.client.closes == 1) &&
        fixture.sockets.single.closes == 1);
    expect(fixture.state.controllerOpen, false);
    expect(fixture.state.receivingEnabled, false);
    expect(fixture.state.controller.targets, isEmpty);
    await fixture.notifier.startController();
    expect(fixture.state.controller.targets.single.userId, _userB);
    expect(fixture.apis.last.account.id, _userB);
    expect(fixture.socketUris.single.queryParameters['deviceId'],
        fixture.initial.credentials.deviceId);
    expect(fixture.socketHeaders.single.values.single,
        contains('synthetic-$_userA'));
  });

  test(
      'provider disposal releases both captured APIs and the physical receiver socket',
      () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    await fixture.notifier.startController();
    await fixture.notifier.setReceiving(true);
    await _until(() => fixture.apis.last.capabilityCompleted.contains(true));
    await fixture.dispose();
    expect(fixture.apis.map((api) => api.client.closes), [1, 1]);
    expect(fixture.sockets.single.closes, 1);
  });
}
