import 'dart:async';
import 'dart:convert';

import 'package:chopper/chopper.dart';
import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart' as jellyfin;
import 'package:fladder/services/remote_control/remote_control_models.dart';
import 'package:fladder/services/remote_control/remote_control_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final clock = DateTime.utc(2026, 11, 2, 12);
const itemId = '11111111111111111111111111111111';
const userId = '22222222222222222222222222222222';
const targetId = '33333333333333333333333333333333';

http.Response jsonBody(Object? body, [int status = 200]) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json'});

Map<String, dynamic> session([Map<String, dynamic> changes = const {}]) => {
      'Id': targetId,
      'UserId': userId,
      'ServerId': 'server-one',
      'DeviceId': 'tesla',
      'DeviceName': 'Tesla',
      'Client': 'JMS',
      'IsActive': true,
      'LastActivityDate': clock.toIso8601String(),
      'LastPlaybackCheckIn':
          clock.subtract(const Duration(seconds: 1)).toIso8601String(),
      'SupportsMediaControl': true,
      'SupportsRemoteControl': true,
      'SupportedCommands': ['PlayState', 'SetSubtitleStreamIndex'],
      'PlaylistItemId': 'jms-remote-occurrence-one',
      'NowPlayingItem': {'Id': itemId, 'RunTimeTicks': 6000000000},
      'PlayState': {
        'MediaSourceId': 'version-one',
        'PositionTicks': 100000000,
        'IsPaused': false,
        'CanSeek': true,
        'SubtitleStreamIndex': 8
      },
      ...changes,
    };

Map<String, dynamic> metadata() => {
      'Items': [
        {
          'Id': itemId,
          'MediaSources': [
            {
              'Id': 'version-other',
              'MediaStreams': [
                {
                  'Type': 'Subtitle',
                  'Index': 6,
                  'DisplayTitle': 'Other version'
                }
              ]
            },
            {
              'Id': 'version-one',
              'MediaStreams': [
                {'Type': 'Audio', 'Index': 1},
                {
                  'Type': 'Subtitle',
                  'Index': 8,
                  'DisplayTitle': 'English CC',
                  'Language': 'eng'
                },
                {
                  'Type': 'Subtitle',
                  'Index': 16,
                  'Title': '原文',
                  'Language': 'zho'
                }
              ]
            },
          ],
        }
      ]
    };

Matcher failure(RemoteFailureCode code) => isA<RemoteControlFailure>()
    .having((error) => error.code, 'safe failure code', code);

class Fixture {
  Fixture({this.handler, Duration timeout = const Duration(seconds: 1)}) {
    api = jellyfin.JellyfinOpenApi.create(
      baseUrl: Uri.parse('https://captured.example.invalid/jellyfin'),
      interceptors: [
        const HeadersInterceptor({
          'authorization':
              'MediaBrowser Token="synthetic-private-token", DeviceId="phone"',
        })
      ],
      httpClient: MockClient((request) async {
        requests.add(request);
        if (handler != null) return handler!(request);
        if (request.method == 'GET' && request.url.path.endsWith('/Sessions')) {
          return jsonBody([session()]);
        }
        if (request.method == 'GET' && request.url.path.endsWith('/Items')) {
          return jsonBody(metadata());
        }
        return http.Response('', 204);
      }),
    );
    transport = RemoteControlTransport(
        api: api,
        userId: userId,
        deviceId: 'phone',
        serverId: 'server-one',
        client: 'JMS',
        isCurrent: () => current,
        now: () => clock,
        requestTimeout: timeout);
  }
  final Future<http.Response> Function(http.Request)? handler;
  final requests = <http.Request>[];
  late final jellyfin.JellyfinOpenApi api;
  late final RemoteControlTransport transport;
  bool current = true;
  List<http.Request> get posts =>
      requests.where((request) => request.method == 'POST').toList();
}

class PendingWrites {
  final requests = <http.Request>[];
  final pending = <Completer<http.Response>>[];
  final applied = <Map<String, dynamic>>[];
  int active = 0;
  int maximumActive = 0;

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    final completion = Completer<http.Response>();
    pending.add(completion);
    active++;
    if (active > maximumActive) maximumActive = active;
    try {
      final response = await completion.future;
      if (response.statusCode >= 200 && response.statusCode < 300) {
        applied.add(Map<String, dynamic>.from(jsonDecode(request.body) as Map));
      }
      return response;
    } finally {
      active--;
    }
  }
}

jellyfin.PlaybackProgressInfo progress(int occurrence) =>
    jellyfin.PlaybackProgressInfo(
      itemId: itemId,
      mediaSourceId: 'source-$occurrence',
      playlistItemId: 'jms-remote-occurrence-$occurrence',
      positionTicks: occurrence * 10000000,
      subtitleStreamIndex: occurrence,
    );

Future<void> flushWrites() => Future<void>.delayed(Duration.zero);

void main() {
  test(
      'discovery is current-user scoped and filters clients, owners, freshness and capabilities',
      () async {
    final fixture = Fixture(
        handler: (_) async => jsonBody([
              session(),
              session({'Id': 'other-owner', 'UserId': 'other'}),
              session({'Id': 'other-server', 'ServerId': 'server-two'}),
              session({'Id': 'own', 'DeviceId': 'phone'}),
              session({'Id': 'web', 'Client': 'Jellyfin Web'}),
              session({
                'Id': 'old',
                'LastActivityDate': clock
                    .subtract(const Duration(seconds: 31))
                    .toIso8601String()
              }),
              session({
                'Id': 'future',
                'LastActivityDate':
                    clock.add(const Duration(seconds: 6)).toIso8601String()
              }),
              session({
                'Id': 'no-command',
                'SupportedCommands': ['SetSubtitleStreamIndex']
              }),
              session({'Id': 'inactive', 'IsActive': false}),
              session({'Id': 'no-socket', 'SupportsRemoteControl': false}),
            ]));
    addTearDown(fixture.transport.close);
    final targets = await fixture.transport.discover();
    expect(targets.map((target) => target.id), [targetId]);
    expect(targets.single.binding?.playbackId, 'jms-remote-occurrence-one');
    expect(fixture.requests.single.url.queryParameters['controllableByUserId'],
        userId);
    expect(fixture.requests.single.url.queryParameters['activeWithinSeconds'],
        '30');
  });

  test('unscoped playback remains visible but cannot send a command', () async {
    final fixture = Fixture(
        handler: (_) async => jsonBody([
              session({'PlaylistItemId': null})
            ]));
    addTearDown(fixture.transport.close);
    final target = (await fixture.transport.discover()).single;
    expect(target.canControl, false);
    await expectLater(
        fixture.transport.send(target, const RemoteAction.pause()),
        throwsA(failure(RemoteFailureCode.invalidTarget)));
    expect(fixture.posts, isEmpty);
  });

  test(
      'subtitle metadata uses exact source and stream Index without creating PlaybackInfo',
      () async {
    final fixture = Fixture();
    addTearDown(fixture.transport.close);
    final target = (await fixture.transport.discover()).single;
    final options = await fixture.transport.subtitles(target);
    expect(options.map((option) => option.index), [8, 16]);
    expect(options.map((option) => option.label), ['English CC', '原文']);
    final request = fixture.requests.last;
    expect(request.method, 'GET');
    expect(request.url.queryParameters['ids'], itemId);
    expect(request.url.queryParametersAll['fields'],
        containsAll(['MediaSources', 'MediaStreams']));
    expect(request.url.path, isNot(contains('PlaybackInfo')));
  });

  test('send revalidates binding and writes the bounded string envelope once',
      () async {
    final fixture = Fixture();
    addTearDown(fixture.transport.close);
    final target = (await fixture.transport.discover()).single;
    await fixture.transport
        .send(target, const RemoteAction.seek(Duration(seconds: 12)));
    expect(fixture.posts, hasLength(1));
    final request = fixture.posts.single;
    expect(request.url.path, '/jellyfin/Sessions/$targetId/Command');
    final command = jsonDecode(request.body) as Map;
    expect(command['Name'], 'PlayState');
    final args = command['Arguments'] as Map;
    expect(args.values.every((value) => value is String), true);
    expect(args['Command'], 'Seek');
    expect(args['SeekPositionTicks'], '120000000');
    expect(args['JmsPlaybackId'], 'jms-remote-occurrence-one');
    expect(args['JmsRemoteVersion'], '1');
    expect(args['JmsSequence'], '1');
    expect(fixture.transport.lastAcceptedBaseline?.binding, target.binding);
    expect(fixture.requests.where((request) => request.method == 'GET'),
        hasLength(2));
  });

  test('changed occurrence and account switch abort before any POST', () async {
    var reads = 0;
    final fixture = Fixture(
        handler: (_) async => jsonBody([
              session(reads++ == 0
                  ? const {}
                  : {'PlaylistItemId': 'jms-remote-occurrence-two'})
            ]));
    addTearDown(fixture.transport.close);
    final target = (await fixture.transport.discover()).single;
    await expectLater(
        fixture.transport.send(target, const RemoteAction.pause()),
        throwsA(failure(RemoteFailureCode.stale)));
    fixture.current = false;
    await expectLater(fixture.transport.send(target, const RemoteAction.play()),
        throwsA(failure(RemoteFailureCode.stale)));
    expect(fixture.posts, isEmpty);
  });

  test('selection cancellation invalidates an already pending preflight',
      () async {
    final pending = Completer<http.Response>();
    var reads = 0;
    final fixture = Fixture(handler: (_) async {
      if (reads++ == 0) return jsonBody([session()]);
      return await pending.future;
    });
    addTearDown(fixture.transport.close);
    final target = (await fixture.transport.discover()).single;
    final send = fixture.transport.send(target, const RemoteAction.pause());
    await Future<void>.delayed(Duration.zero);
    fixture.transport.invalidatePending();
    pending.complete(jsonBody([session()]));
    await expectLater(send, throwsA(failure(RemoteFailureCode.stale)));
    expect(fixture.posts, isEmpty);
  });

  test('mutation timeout is unknown, sanitized and never retried', () async {
    final outstanding = Completer<http.Response>();
    final fixture = Fixture(
        timeout: const Duration(milliseconds: 5),
        handler: (request) async {
          if (request.method == 'GET') return jsonBody([session()]);
          return outstanding.future;
        });
    addTearDown(fixture.transport.close);
    final target = (await fixture.transport.discover()).single;
    await expectLater(
        fixture.transport.send(target, const RemoteAction.pause()),
        throwsA(failure(RemoteFailureCode.timeoutUnknown)));
    expect(fixture.posts, hasLength(1));
    await expectLater(fixture.transport.send(target, const RemoteAction.play()),
        throwsA(failure(RemoteFailureCode.timeoutUnknown)));
    expect(fixture.posts, hasLength(1));
    outstanding.complete(http.Response('', 204));
    await Future<void>.delayed(Duration.zero);
    await fixture.transport.send(target, const RemoteAction.play());
    expect(fixture.posts, hasLength(2));
  });

  test(
      'credential-bearing network exceptions stay inside the sanitizing boundary',
      () async {
    final fixture = Fixture(handler: (request) async {
      if (request.method == 'GET') return jsonBody([session()]);
      throw StateError(
          'https://private.example.invalid/socket?ApiKey=private-secret');
    });
    addTearDown(fixture.transport.close);
    final target = (await fixture.transport.discover()).single;
    await expectLater(
        fixture.transport.send(target, const RemoteAction.pause()),
        throwsA(isA<RemoteControlFailure>()
            .having((error) => error.code, 'unknown outcome',
                RemoteFailureCode.timeoutUnknown)
            .having(
                (error) => error.toString(),
                'safe message',
                allOf(isNot(contains('private-secret')),
                    isNot(contains('https://'))))));
    expect(fixture.posts, hasLength(1));
  });

  test('metadata rejects subtitle indices from a different version', () async {
    final fixture = Fixture();
    addTearDown(fixture.transport.close);
    final target = (await fixture.transport.discover()).single;
    await expectLater(
        fixture.transport.send(target, const RemoteAction.subtitle(6)),
        throwsA(failure(RemoteFailureCode.invalidAction)));
    expect(fixture.posts, isEmpty);
    await fixture.transport.send(target, const RemoteAction.subtitle(-1));
    expect((jsonDecode(fixture.posts.single.body)['Arguments'] as Map)['Index'],
        '-1');
  });

  test(
      'own session lookup is unique, account-bound and independent of receiver capabilities',
      () async {
    var duplicate = false;
    final own = session({
      'DeviceId': 'phone',
      'SupportedCommands': [],
      'SupportsRemoteControl': false
    });
    final fixture = Fixture(
        handler: (_) async => jsonBody([
              own,
              if (duplicate) {...own, 'Id': 'duplicate'}
            ]));
    addTearDown(fixture.transport.close);
    expect(await fixture.transport.ownSessionId(), targetId);
    duplicate = true;
    expect(await fixture.transport.ownSessionId(), isNull);
    expect(fixture.requests.first.url.queryParameters['deviceId'], 'phone');
  });

  test(
      'capabilities omit target id and progress cannot report to another session',
      () async {
    final fixture = Fixture();
    addTearDown(fixture.transport.close);
    await fixture.transport.capabilities(true);
    await fixture.transport.report(const jellyfin.PlaybackProgressInfo(
        sessionId: 'different-session',
        itemId: itemId,
        mediaSourceId: 'version-one',
        playlistItemId: 'jms-remote-occurrence-one',
        positionTicks: 42));
    expect(fixture.posts.first.url.queryParameters, isEmpty);
    expect(jsonDecode(fixture.posts.first.body)['SupportedCommands'],
        ['PlayState', 'SetSubtitleStreamIndex']);
    final report = jsonDecode(fixture.posts.last.body) as Map;
    expect(report.containsKey('SessionId'), false);
    expect(report['PlaylistItemId'], 'jms-remote-occurrence-one');
  });

  test('timed-out capability true cannot race past the final queued withdrawal',
      () async {
    final writes = PendingWrites();
    final fixture = Fixture(
        handler: writes.handle, timeout: const Duration(milliseconds: 20));
    addTearDown(fixture.transport.close);
    await expectLater(fixture.transport.capabilities(true),
        throwsA(failure(RemoteFailureCode.timeoutUnknown)));
    await expectLater(fixture.transport.capabilities(false),
        throwsA(failure(RemoteFailureCode.timeoutUnknown)));
    expect(writes.requests, hasLength(1));
    writes.pending[0].complete(http.Response('', 204));
    await flushWrites();
    expect(writes.requests, hasLength(2));
    expect(jsonDecode(writes.requests[1].body)['SupportsMediaControl'], false);
    writes.pending[1].complete(http.Response('', 204));
    await flushWrites();
    expect(writes.applied.map((body) => body['SupportsMediaControl']),
        [true, false]);
    expect(writes.maximumActive, 1);
  });

  test(
      'a late false is serialized before a re-enabled latest true on the same session',
      () async {
    final writes = PendingWrites();
    final fixture = Fixture(
        handler: writes.handle, timeout: const Duration(milliseconds: 20));
    addTearDown(fixture.transport.close);
    final initial = fixture.transport.capabilities(true);
    await flushWrites();
    writes.pending[0].complete(http.Response('', 204));
    await initial;
    await expectLater(fixture.transport.capabilities(false),
        throwsA(failure(RemoteFailureCode.timeoutUnknown)));
    await expectLater(fixture.transport.capabilities(true),
        throwsA(failure(RemoteFailureCode.timeoutUnknown)));
    expect(writes.requests, hasLength(2));
    writes.pending[1].complete(http.Response('', 204));
    await flushWrites();
    expect(writes.requests, hasLength(3));
    expect(jsonDecode(writes.requests[2].body)['SupportsMediaControl'], true);
    writes.pending[2].complete(http.Response('', 204));
    await flushWrites();
    expect(writes.applied.map((body) => body['SupportsMediaControl']),
        [true, false, true]);
    expect(writes.maximumActive, 1);
  });

  test(
      'timed-out progress retains one physical request and only the latest queued snapshot',
      () async {
    final writes = PendingWrites();
    final fixture = Fixture(
        handler: writes.handle, timeout: const Duration(milliseconds: 20));
    addTearDown(fixture.transport.close);
    await expectLater(fixture.transport.report(progress(1)),
        throwsA(failure(RemoteFailureCode.timeoutUnknown)));
    final superseded = expectLater(fixture.transport.report(progress(2)),
        throwsA(failure(RemoteFailureCode.stale)));
    await expectLater(fixture.transport.report(progress(3)),
        throwsA(failure(RemoteFailureCode.timeoutUnknown)));
    await superseded;
    expect(writes.requests, hasLength(1));
    writes.pending[0].complete(http.Response('', 204));
    await flushWrites();
    expect(writes.requests, hasLength(2));
    final latest = jsonDecode(writes.requests[1].body) as Map;
    expect(latest['PositionTicks'], 30000000);
    expect(latest['SubtitleStreamIndex'], 3);
    expect(latest['MediaSourceId'], 'source-3');
    expect(latest['PlaylistItemId'], 'jms-remote-occurrence-3');
    writes.pending[1].complete(http.Response('', 204));
    await flushWrites();
    expect(writes.applied.map((body) => body['PositionTicks']),
        [10000000, 30000000]);
    expect(writes.maximumActive, 1);
  });

  test('withdrawal cancels only progress that has not started its HTTP request',
      () async {
    final writes = PendingWrites();
    final fixture = Fixture(
        timeout: const Duration(milliseconds: 20),
        handler: (request) async {
          if (request.url.path.endsWith('/Capabilities/Full')) {
            return http.Response('', 204);
          }
          return writes.handle(request);
        });
    addTearDown(fixture.transport.close);
    await expectLater(fixture.transport.report(progress(1)),
        throwsA(failure(RemoteFailureCode.timeoutUnknown)));
    final queued = expectLater(fixture.transport.report(progress(2)),
        throwsA(failure(RemoteFailureCode.stale)));
    await fixture.transport.capabilities(false);
    await queued;
    writes.pending.single.complete(http.Response('', 204));
    await flushWrites();
    expect(writes.requests, hasLength(1));
    expect(writes.applied.single['PositionTicks'], 10000000);
  });

  test(
      'queued progress rechecks its playback scope at the actual HTTP boundary',
      () async {
    final writes = PendingWrites();
    final fixture = Fixture(
        handler: writes.handle, timeout: const Duration(milliseconds: 20));
    addTearDown(fixture.transport.close);
    await expectLater(fixture.transport.report(progress(1)),
        throwsA(failure(RemoteFailureCode.timeoutUnknown)));
    var current = true;
    final queued = expectLater(
        fixture.transport.report(progress(2), isCurrent: () => current),
        throwsA(failure(RemoteFailureCode.stale)));
    current = false;
    writes.pending.single.complete(http.Response('', 204));
    await queued;
    await flushWrites();
    expect(writes.requests, hasLength(1));
    final fresh = fixture.transport.report(progress(3), isCurrent: () => true);
    await flushWrites();
    expect(writes.requests, hasLength(2));
    expect(jsonDecode(writes.requests.last.body)['MediaSourceId'], 'source-3');
    writes.pending.last.complete(http.Response('', 204));
    await fresh;
  });

  test(
      'already revoked report scopes cannot replace the current queued snapshot',
      () async {
    final writes = PendingWrites();
    final fixture = Fixture(
        handler: writes.handle, timeout: const Duration(milliseconds: 20));
    addTearDown(fixture.transport.close);
    await expectLater(fixture.transport.report(progress(1)),
        throwsA(failure(RemoteFailureCode.timeoutUnknown)));
    final valid = fixture.transport.report(progress(2), isCurrent: () => true);
    for (final scope in <bool Function()>[
      () => false,
      () => throw StateError('private')
    ]) {
      await expectLater(fixture.transport.report(progress(3), isCurrent: scope),
          throwsA(failure(RemoteFailureCode.stale)));
    }
    writes.pending[0].complete(http.Response('', 204));
    await flushWrites();
    expect(writes.requests, hasLength(2));
    expect(jsonDecode(writes.requests[1].body)['PositionTicks'], 20000000);
    writes.pending[1].complete(http.Response('', 204));
    await valid;
  });

  test(
      'a failed physical capability request still drains the latest valid withdrawal',
      () async {
    final writes = PendingWrites();
    final fixture = Fixture(handler: writes.handle);
    addTearDown(fixture.transport.close);
    final failed = expectLater(fixture.transport.capabilities(true),
        throwsA(failure(RemoteFailureCode.timeoutUnknown)));
    final withdrawal = fixture.transport.capabilities(false);
    await flushWrites();
    writes.pending[0].completeError(
        StateError('https://private.invalid?ApiKey=private-secret'));
    await failed;
    await flushWrites();
    expect(writes.requests, hasLength(2));
    writes.pending[1].complete(http.Response('', 204));
    await withdrawal;
    expect(writes.applied.single['SupportsMediaControl'], false);
    expect(writes.maximumActive, 1);
  });

  for (final capability in [true, false]) {
    final endpoint = capability ? 'capabilities' : 'progress';
    test(
        'a fresh identical $endpoint intent does not join an expired caller result',
        () async {
      final writes = PendingWrites();
      final fixture = Fixture(
          handler: writes.handle, timeout: const Duration(milliseconds: 20));
      addTearDown(fixture.transport.close);
      Future<void> submit() => capability
          ? fixture.transport.capabilities(true)
          : fixture.transport.report(progress(1));
      await expectLater(
          submit(), throwsA(failure(RemoteFailureCode.timeoutUnknown)));
      await expectLater(
          submit(), throwsA(failure(RemoteFailureCode.timeoutUnknown)));
      expect(writes.requests, hasLength(1));
      writes.pending[0].complete(http.Response('', 204));
      await flushWrites();
      expect(writes.requests, hasLength(2));
      writes.pending[1].complete(http.Response('', 204));
      await flushWrites();
      expect(writes.maximumActive, 1);
      expect(writes.applied, hasLength(2));
    });

    test(
        'account switch prevents queued $endpoint from starting after the old raw response',
        () async {
      final writes = PendingWrites();
      final fixture = Fixture(
          handler: writes.handle, timeout: const Duration(milliseconds: 20));
      addTearDown(fixture.transport.close);
      Future<void> submit(int version) => capability
          ? fixture.transport.capabilities(version == 1)
          : fixture.transport.report(progress(version));
      await expectLater(
          submit(1), throwsA(failure(RemoteFailureCode.timeoutUnknown)));
      final queued =
          expectLater(submit(2), throwsA(failure(RemoteFailureCode.stale)));
      fixture.current = false;
      writes.pending.single.complete(http.Response('', 204));
      await queued;
      await flushWrites();
      expect(writes.requests, hasLength(1));
      await expectLater(submit(3), throwsA(failure(RemoteFailureCode.stale)));
      expect(writes.requests, hasLength(1));
    });

    test(
        'full close releases callers and never drains queued $endpoint after raw completion',
        () async {
      final writes = PendingWrites();
      final fixture = Fixture(handler: writes.handle);
      addTearDown(fixture.transport.close);
      Future<void> submit(int version) => capability
          ? fixture.transport.capabilities(version == 1)
          : fixture.transport.report(progress(version));
      final active =
          expectLater(submit(1), throwsA(failure(RemoteFailureCode.closed)));
      final queued =
          expectLater(submit(2), throwsA(failure(RemoteFailureCode.closed)));
      await flushWrites();
      await fixture.transport.close();
      await Future.wait([active, queued]);
      writes.pending.single.complete(http.Response('', 204));
      await flushWrites();
      expect(writes.requests, hasLength(1));
      await expectLater(submit(3), throwsA(failure(RemoteFailureCode.closed)));
      expect(writes.requests, hasLength(1));
    });
  }
}
