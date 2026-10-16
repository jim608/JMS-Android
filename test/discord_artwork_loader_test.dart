@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/credentials_model.dart';
import 'package:fladder/providers/discord_presence_provider.dart';
import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TestUser extends User {
  _TestUser(this.initial);

  final AccountModel? initial;

  @override
  AccountModel? build() => initial;

  void changeAccount(AccountModel account) => state = account;
}

class _RecordedRequest {
  _RecordedRequest(HttpRequest request)
      : method = request.method,
        uri = request.uri,
        authorization = request.headers.value(HttpHeaders.authorizationHeader);

  final String method;
  final Uri uri;
  final String? authorization;
}

class _ArtworkServer {
  _ArtworkServer(this.server);

  final HttpServer server;
  final requests = <_RecordedRequest>[];
  final firstRequest = Completer<_RecordedRequest>();

  String get url => 'http://127.0.0.1:${server.port}';

  static Future<_ArtworkServer> start({
    required Map<String, Object?> body,
    int status = HttpStatus.ok,
    Future<void>? waitBeforeReply,
  }) async {
    final fixture =
        _ArtworkServer(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    addTearDown(() => fixture.server.close(force: true));
    fixture.server.listen((request) async {
      final recorded = _RecordedRequest(request);
      fixture.requests.add(recorded);
      if (!fixture.firstRequest.isCompleted) {
        fixture.firstRequest.complete(recorded);
      }
      if (waitBeforeReply != null) await waitBeforeReply;
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(body));
      await request.response.close();
    });
    return fixture;
  }
}

AccountModel _account(_ArtworkServer server, String suffix) => AccountModel(
      name: 'Synthetic account $suffix',
      id: 'synthetic-account-$suffix',
      avatar: '',
      lastUsed: DateTime(2026),
      credentials: CredentialsModel.internal(
        serverId: 'synthetic-server-$suffix',
        token: 'synthetic-artwork-token-$suffix',
        deviceId: 'synthetic-device-$suffix',
        url: server.url,
      ),
    );

Future<ProviderContainer> _container(AccountModel? account) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final container = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(preferences),
    userProvider.overrideWith(() => _TestUser(account)),
  ]);
  addTearDown(container.dispose);
  return container;
}

Map<String, Object?> _images(List<Map<String, Object?>> images) => {
      'Images': images,
      'TotalRecordCount': images.length,
      'Providers': ['Synthetic provider'],
    };

void main() {
  const poster = 'https://image.tmdb.org/t/p/w500/SyntheticPoster.jpg';

  test('actual loader requests bounded primary metadata and selects safe cover',
      () async {
    final server = await _ArtworkServer.start(
        body: _images([
      {
        'Type': 'Backdrop',
        'Url': 'https://image.tmdb.org/t/p/original/SyntheticBackdrop.jpg',
      },
      {
        'Type': 'Primary',
        'Url': 'https://private.example.invalid/Items/id/Images/Primary',
      },
      {
        'Type': 'Primary',
        'Url': 'https://image.tmdb.org/t/p/original/SyntheticPoster.jpg',
      },
    ]));
    final container = await _container(_account(server, 'a'));
    final loader = container.read(discordArtworkLoaderProvider);

    expect(await loader('synthetic-series'), poster);
    expect(server.requests, hasLength(1));
    final request = server.requests.single;
    expect(request.method, 'GET');
    expect(request.uri.path, '/Items/synthetic-series/RemoteImages');
    expect(request.uri.queryParameters, {
      'type': 'Primary',
      'limit': '20',
      'includeAllLanguages': 'true',
    });
    expect(
        request.authorization, contains('Token="synthetic-artwork-token-a"'));
    expect(
        request.uri.toString(), isNot(contains('synthetic-artwork-token-a')));
  });

  for (final entry in <String, Map<String, Object?>>{
    'empty metadata': _images([]),
    'unsupported and credential-bearing covers': _images([
      {
        'Type': 'Primary',
        'Url': 'https://private.example.invalid/Items/id/Images/Primary',
      },
      {
        'Type': 'Primary',
        'Url': '$poster?api_key=synthetic-secret',
      },
      {'Type': 'Backdrop', 'Url': poster},
    ]),
  }.entries) {
    test('actual loader keeps text fallback for ${entry.key}', () async {
      final server = await _ArtworkServer.start(body: entry.value);
      final container = await _container(_account(server, 'a'));

      expect(
          await container.read(discordArtworkLoaderProvider)('series'), isNull);
      expect(server.requests, hasLength(1));
    });
  }

  test('an HTTP failure returns no cover', () async {
    final server = await _ArtworkServer.start(
        body: _images([
          {'Type': 'Primary', 'Url': poster},
        ]),
        status: HttpStatus.serviceUnavailable);
    final container = await _container(_account(server, 'a'));

    expect(
        await container.read(discordArtworkLoaderProvider)('series'), isNull);
    expect(server.requests, hasLength(1));
  });

  test('without an account the loader does not make a request', () async {
    final server = await _ArtworkServer.start(body: _images([]));
    final container = await _container(null);

    expect(
        await container.read(discordArtworkLoaderProvider)('series'), isNull);
    expect(server.requests, isEmpty);
  });

  test(
      'pending requests keep the original server and headers on account switch',
      () async {
    const posterA = 'https://image.tmdb.org/t/p/w500/SyntheticPosterA.jpg';
    const posterB =
        'https://artworks.thetvdb.com/banners/posters/SyntheticB.jpg';
    final releaseA = Completer<void>();
    addTearDown(() {
      if (!releaseA.isCompleted) releaseA.complete();
    });
    final serverA = await _ArtworkServer.start(
        body: _images([
          {'Type': 'Primary', 'Url': posterA},
        ]),
        waitBeforeReply: releaseA.future);
    final serverB = await _ArtworkServer.start(
        body: _images([
      {'Type': 'Primary', 'Url': posterB},
    ]));
    final container = await _container(_account(serverA, 'a'));
    final loader = container.read(discordArtworkLoaderProvider);

    // Switch before the first request reaches its server, then hold that
    // response until the second account's lookup has independently completed.
    final pendingA = loader('synthetic-series-a');
    (container.read(userProvider.notifier) as _TestUser)
        .changeAccount(_account(serverB, 'b'));
    final pendingB = loader('synthetic-series-b');
    await serverA.firstRequest.future.timeout(const Duration(seconds: 3));
    expect(await pendingB, posterB);
    expect(releaseA.isCompleted, false);
    releaseA.complete();
    expect(await pendingA, posterA);

    expect(serverA.requests, hasLength(1));
    expect(serverB.requests, hasLength(1));
    final requestA = serverA.requests.single;
    final requestB = serverB.requests.single;
    expect(requestA.uri.path, '/Items/synthetic-series-a/RemoteImages');
    expect(requestB.uri.path, '/Items/synthetic-series-b/RemoteImages');
    expect(
        requestA.authorization, contains('Token="synthetic-artwork-token-a"'));
    expect(
        requestA.authorization, isNot(contains('synthetic-artwork-token-b')));
    expect(
        requestB.authorization, contains('Token="synthetic-artwork-token-b"'));
    expect(
        requestB.authorization, isNot(contains('synthetic-artwork-token-a')));
  });
}
