import 'dart:async';
import 'dart:convert';

import 'package:chopper/chopper.dart' as chopper;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/credentials_model.dart';
import 'package:fladder/models/items/media_streams_model.dart';
import 'package:fladder/models/items/movie_model.dart';
import 'package:fladder/models/playback/direct_playback_model.dart';
import 'package:fladder/providers/captured_playback_reporting_provider.dart';
import 'package:fladder/providers/incognito_mode_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/services/playback_reporting_scope.dart';

const _policy = UserPolicy(
    authenticationProviderId: 'fixture',
    passwordResetProviderId: 'fixture',
    enableMediaPlayback: true);
const _denied = UserPolicy(
    authenticationProviderId: 'fixture',
    passwordResetProviderId: 'fixture',
    enableMediaPlayback: false);
final _privacy = StateProvider<bool>((ref) => false);

AccountModel _account(
        {String id = 'A',
        String token = 'token-A-old',
        String host = 'a-old.example.invalid',
        String server = 'server-A'}) =>
    AccountModel(
        name: id,
        id: id,
        avatar: '',
        lastUsed: DateTime.utc(2026),
        credentials: CredentialsModel.internal(
            token: token,
            url: 'https://$host/jellyfin',
            serverId: server,
            deviceId: 'same-browser-device'),
        policy: _policy);

class _User extends User {
  _User(this.initial);
  final AccountModel initial;
  @override
  AccountModel? build() => initial;
  void replace(AccountModel? account) => state = account;
}

class _CapturedAuthorization implements chopper.Interceptor {
  _CapturedAuthorization(String token) : value = 'MediaBrowser Token="$token"';
  final String value;
  @override
  FutureOr<chopper.Response<BodyType>> intercept<BodyType>(
          chopper.Chain<BodyType> chain) =>
      chain.proceed(
          chopper.applyHeaders(chain.request, {'authorization': value}));
}

class _Client extends MockClient {
  _Client(super.handler);
  int closes = 0;
  @override
  void close() {
    closes++;
    super.close();
  }
}

class _Counter {
  int active = 0;
  int maximum = 0;
}

class _Request {
  _Request(this.account, this.request);
  final AccountModel account;
  final http.Request request;
  Map<String, dynamic> get body =>
      Map<String, dynamic>.from(jsonDecode(request.body) as Map);
}

class _ApiRecord {
  _ApiRecord(this.account, this.ledger, this.counter) {
    client = _Client((request) async {
      final gate = nextGate;
      nextGate = null;
      requests.add(request);
      ledger.add(_Request(account, request));
      counter.active++;
      if (counter.active > counter.maximum) counter.maximum = counter.active;
      try {
        await gate?.future;
        return http.Response('', 204);
      } finally {
        counter.active--;
      }
    });
    api = JellyfinOpenApi.create(
        baseUrl: Uri.parse(account.credentials.url),
        httpClient: client,
        interceptors: [_CapturedAuthorization(account.credentials.token)]);
  }
  final AccountModel account;
  final List<_Request> ledger;
  final _Counter counter;
  final requests = <http.Request>[];
  Completer<void>? nextGate;
  late final _Client client;
  late final JellyfinOpenApi api;
}

class _Fixture {
  _Fixture() {
    container = ProviderContainer(overrides: [
      userProvider.overrideWith(() => _User(_account())),
      incognitoProvider.overrideWith((ref) => ref.watch(_privacy)),
      capturedPlaybackApiFactoryProvider.overrideWithValue((account) {
        final key = (
          account.credentials.serverId,
          account.credentials.deviceId,
          account.id
        );
        final record = _ApiRecord(
            account, ledger, counters.putIfAbsent(key, _Counter.new));
        records.add(record);
        return record.api;
      }),
    ]);
    reporting = container.read(capturedPlaybackReportingProvider);
  }
  final records = <_ApiRecord>[];
  final ledger = <_Request>[];
  final counters = <(String, String, String), _Counter>{};
  late final ProviderContainer container;
  late final CapturedPlaybackReporting reporting;
  _User get user => container.read(userProvider.notifier) as _User;

  PlaybackReportingScope activate(
      PlaybackReportingCapture capture, String session) {
    final scope = capture.bind(
        itemId: 'item',
        mediaSourceId: 'source',
        playSessionId: session,
        playlistItemId: 'jms-remote-$session');
    final model = DirectPlaybackModel(
        reportingScope: scope,
        item: MovieModel.fromBaseDto(
            const BaseItemDto(
                id: 'item',
                name: 'Fixture',
                type: BaseItemKind.movie,
                mediaType: MediaType.video),
            null),
        media: null,
        playbackInfo: PlaybackInfoResponse(playSessionId: session),
        mediaStreams: MediaStreamsModel(versionStreams: [
          VersionStreamModel(
              name: 'Source',
              index: 0,
              id: 'source',
              defaultAudioStreamIndex: 2,
              defaultSubStreamIndex: 8,
              videoStreams: [],
              audioStreams: [],
              subStreams: []),
        ]));
    container.read(playBackModel.notifier).state = model;
    expect(scope.activate(), isTrue);
    return scope;
  }
}

PlaybackProgressInfo _progress(PlaybackReportingScope scope, int ticks) =>
    PlaybackProgressInfo(
        itemId: scope.itemId,
        mediaSourceId: scope.mediaSourceId,
        playSessionId: scope.playSessionId,
        playlistItemId: scope.playlistItemId,
        positionTicks: ticks,
        subtitleStreamIndex: 8);

Future<void> _turns([int count = 4]) async {
  for (var index = 0; index < count; index++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _until(bool Function() condition) async {
  for (var index = 0; index < 50 && !condition(); index++) {
    await _turns(1);
  }
  expect(condition(), isTrue,
      reason: 'Expected local HTTP work did not settle');
}

void main() {
  test(
      'same server and browser serialize A and B through one physical session lane',
      () async {
    final fixture = _Fixture();
    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
      fixture.container.dispose();
    });
    final oldOwner = fixture.reporting.capture()!;
    final oldScope = fixture.activate(oldOwner, 'A-old');
    final oldApi = fixture.records.single;
    oldApi.nextGate = gate;
    final oldPhysical = oldScope.progress(_progress(oldScope, 10));
    await _until(() => oldApi.requests.length == 1);
    final oldQueued = oldScope.progress(_progress(oldScope, 20));
    fixture.user.replace(_account(
        id: 'B',
        token: 'token-B-same-session',
        host: 'a-old.example.invalid',
        server: 'server-A'));
    final freshOwner = fixture.reporting.capture()!;
    final freshScope = fixture.activate(freshOwner, 'B-new');
    final freshApi = fixture.records.last;
    final freshPhysical = freshScope.progress(_progress(freshScope, 30));
    await _turns();
    expect(freshApi.requests, isEmpty);
    expect(oldApi.client.closes, 0);
    expect(oldOwner.isCurrent, isFalse);
    expect(oldScope.activate(), isFalse);
    gate.complete();
    await Future.wait([oldPhysical, oldQueued, freshPhysical]);
    expect(fixture.ledger.map((entry) => entry.account.id), ['A', 'B']);
    expect(
        fixture.ledger.map((entry) => entry.body['PositionTicks']), [10, 30]);
    expect(fixture.ledger.last.request.url.host, 'a-old.example.invalid');
    expect(fixture.ledger.last.request.headers['authorization'],
        contains('token-B-same-session'));
    expect(fixture.ledger.last.body['PlaySessionId'], 'B-new');
  });

  test(
      'playback negotiation captures API and user id and discards response after account change',
      () async {
    final fixture = _Fixture();
    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
      fixture.container.dispose();
    });
    final owner = fixture.reporting.capture()!;
    final oldApi = fixture.records.single;
    oldApi.nextGate = gate;
    final response = owner.negotiatePlaybackInfo(
        itemId: 'item-A',
        body: const PlaybackInfoDto(userId: 'mutable-B-user'));
    await _until(() => fixture.ledger.length == 1);
    final request = fixture.ledger.single;
    expect(request.request.url.host, 'a-old.example.invalid');
    expect(request.request.headers['authorization'], contains('token-A-old'));
    expect(request.body['UserId'], 'A');
    fixture.user.replace(_account(
        id: 'B',
        token: 'token-B',
        host: 'b.example.invalid',
        server: 'server-B'));
    expect(owner.isCurrent, isFalse);
    expect(oldApi.client.closes, 0);
    expect(
        await owner.negotiatePlaybackInfo(
            itemId: 'item-A', body: const PlaybackInfoDto()),
        isNull);
    expect(fixture.ledger.length, 1);
    gate.complete();
    expect(await response, isNull);
    await _turns();
    expect(oldApi.client.closes, greaterThan(0));
    final current = fixture.reporting.capture()!;
    expect(
        await current.negotiatePlaybackInfo(
            itemId: 'item-B',
            body: const PlaybackInfoDto(userId: 'old-A-user')),
        isNotNull);
    expect(fixture.ledger.last.request.url.host, 'b.example.invalid');
    expect(fixture.ledger.last.request.headers['authorization'],
        contains('token-B'));
    expect(fixture.ledger.last.body['UserId'], 'B');
  });

  test(
      'captured provider preserves URL credentials and A physical lane across account ABA',
      () async {
    final fixture = _Fixture();
    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
      fixture.container.dispose();
    });
    final ownerA = fixture.reporting.capture()!;
    expect(identical(fixture.reporting.capture(), ownerA), isTrue);
    expect(fixture.records.length, 1);
    final scopeA = fixture.activate(ownerA, 'A-old');
    final apiA = fixture.records.single;
    apiA.nextGate = gate;
    final oldPhysical = scopeA.progress(_progress(scopeA, 100));
    await _until(() => apiA.requests.length == 1);
    final oldQueued = scopeA.progress(_progress(scopeA, 200));

    fixture.user.replace(_account(
        id: 'B',
        token: 'token-B',
        host: 'b.example.invalid',
        server: 'server-B'));
    await _turns();
    expect(ownerA.isCurrent, isFalse);
    expect(scopeA.isCurrent, isFalse);
    expect(apiA.client.closes, 0);
    final ownerB = fixture.reporting.capture()!;
    final scopeB = fixture.activate(ownerB, 'B-current');
    final apiB = fixture.records.last;
    await scopeB.progress(_progress(scopeB, 50));
    expect(apiB.requests.single.url.host, 'b.example.invalid');
    expect(apiB.requests.single.headers['authorization'],
        'MediaBrowser Token="token-B"');
    expect((jsonDecode(apiB.requests.single.body) as Map)['PlaySessionId'],
        'B-current');

    // A different URL/token for the same server/device/user is a new owner,
    // while its actual report writer remains behind A's original raw HTTP.
    fixture.user
        .replace(_account(token: 'token-A-new', host: 'a-new.example.invalid'));
    await _turns();
    final newOwnerA = fixture.reporting.capture()!;
    final newScopeA = fixture.activate(newOwnerA, 'A-new');
    final newApiA = fixture.records.last;
    final newProgress = newScopeA.progress(_progress(newScopeA, 10));
    await _turns();
    await oldQueued;
    await scopeA.progress(_progress(scopeA, 300));
    expect(scopeA.activate(), isFalse);
    expect(newApiA.requests, isEmpty);
    expect(
        fixture.ledger.map((entry) => entry.body['PositionTicks']), [100, 50]);
    expect(apiA.client.closes, 0);

    gate.complete();
    await Future.wait([oldPhysical, newProgress]);
    await _turns();
    expect(fixture.ledger.map((entry) => entry.body['PositionTicks']),
        [100, 50, 10]);
    expect(newApiA.requests.single.url.host, 'a-new.example.invalid');
    expect(newApiA.requests.single.headers['authorization'],
        'MediaBrowser Token="token-A-new"');
    for (final entry in fixture.ledger) {
      expect(entry.request.url.host,
          Uri.parse(entry.account.credentials.url).host);
      expect(entry.request.headers['authorization'],
          'MediaBrowser Token="${entry.account.credentials.token}"');
    }
    expect(apiA.counter.maximum, 1);
    expect(apiA.client.closes, greaterThan(0));
    expect(apiB.client.closes, greaterThan(0));
    expect(newApiA.client.closes, 0);
  });

  test(
      'permission revocation and provider disposal discard queue without closing raw HTTP early',
      () async {
    final fixture = _Fixture();
    final gate = Completer<void>();
    var disposed = false;
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
      if (!disposed) fixture.container.dispose();
    });
    final owner = fixture.reporting.capture()!;
    final scope = fixture.activate(owner, 'old');
    final api = fixture.records.single;
    api.nextGate = gate;
    final physical = scope.progress(_progress(scope, 100));
    await _until(() => api.requests.length == 1);
    final queued = scope.progress(_progress(scope, 200));
    fixture.user.replace(_account().copyWith(policy: _denied));
    await _turns();
    expect(owner.isCurrent, isFalse);
    expect(fixture.reporting.capture(), isNull);
    expect(api.client.closes, 0);
    await queued;
    fixture.container.dispose();
    disposed = true;
    expect(fixture.reporting.capture(), isNull);
    expect(api.client.closes, 0);
    gate.complete();
    await physical;
    await _turns();
    expect(api.requests.length, 1);
    expect(api.client.closes, greaterThan(0));
  });

  test(
      'incognito is checked again before queued physical report and blocks later writes',
      () async {
    final fixture = _Fixture();
    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
      fixture.container.dispose();
    });
    final owner = fixture.reporting.capture()!;
    final scope = fixture.activate(owner, 'private');
    final api = fixture.records.single;
    await scope.progress(_progress(scope, 1));
    api.nextGate = gate;
    final physical = scope.progress(_progress(scope, 2));
    await _until(() => api.requests.length == 2);
    final queued = scope.progress(_progress(scope, 3));
    fixture.container.read(_privacy.notifier).state = true;
    await _turns();
    gate.complete();
    await Future.wait([physical, queued]);
    await scope.progress(_progress(scope, 4));
    expect(
        api.requests.map(
            (request) => (jsonDecode(request.body) as Map)['PositionTicks']),
        [1, 2]);
    expect(owner.isCurrent, isTrue);
    expect(scope.isCurrent, isTrue);
  });
}
