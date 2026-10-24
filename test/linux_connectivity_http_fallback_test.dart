import 'dart:async';
import 'dart:convert';

// Supplied by the locked connectivity_plus dependency.
// ignore: depend_on_referenced_packages
import 'package:connectivity_plus_platform_interface/connectivity_plus_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/credentials_model.dart';
import 'package:fladder/providers/connectivity_provider.dart';
import 'package:fladder/providers/service_provider.dart';
import 'package:fladder/providers/user_provider.dart';

const fixtureUrl = 'https://jellyfin.example.invalid';

AccountModel fixtureAccount([String url = fixtureUrl]) => AccountModel(
      name: 'Synthetic account',
      id: 'fixture-user',
      avatar: '',
      lastUsed: DateTime.utc(2026),
      credentials: CredentialsModel.internal(
        url: url,
        serverId: 'fixture-server',
        deviceId: 'fixture-device',
      ),
    );

class FixtureUser extends User {
  @override
  AccountModel? build() => fixtureAccount();

  void replace(String url) => state = fixtureAccount(url);
  void signOut() => state = null;
}

class ProbeBackend extends ConnectivityPlatform {
  ProbeBackend({this.results, this.detachedError = false}) {
    events = StreamController<List<ConnectivityResult>>.broadcast(
      onListen: () {
        if (detachedError) {
          Future<void>.microtask(
              () => throw StateError('synthetic missing bus'));
        }
      },
    );
  }

  late final StreamController<List<ConnectivityResult>> events;
  List<ConnectivityResult>? results;
  final bool detachedError;

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => events.stream;

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async {
    if (results case final results?) return results;
    throw StateError('synthetic NetworkManager unavailable');
  }
}

class LiveDetailService extends JellyService {
  LiveDetailService(Ref ref, this.fixtureApi) : super(ref, fixtureApi);
  final JellyfinOpenApi fixtureApi;

  @override
  JellyfinOpenApi get api => fixtureApi;
}

http.Response healthy() => http.Response(
    jsonEncode({'Id': 'fixture-server', 'ServerName': 'Synthetic server'}), 200,
    headers: {'content-type': 'application/json'});

Future<void> pumpEvents() => Future<void>.delayed(Duration.zero);

Future<void> waitForProbe(ProviderContainer container) async {
  await pumpEvents();
  await container
      .read(connectivityStatusProvider.notifier)
      .waitForProbe()
      .timeout(const Duration(seconds: 4));
  await pumpEvents();
}

Future<void> withFixture(
  ProbeBackend backend,
  FutureOr<http.Response> Function(http.Request) handler,
  Future<void> Function(ProviderContainer) body,
) {
  return http.runWithClient(() async {
    final original = ConnectivityPlatform.instance;
    final originalPlatform = debugDefaultTargetPlatformOverride;
    ConnectivityPlatform.instance = backend;
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final container = ProviderContainer(overrides: [
      userProvider.overrideWith(FixtureUser.new),
    ]);
    try {
      container.read(connectivityStatusProvider);
      await body(container);
    } finally {
      container.dispose();
      await backend.events.close();
      ConnectivityPlatform.instance = original;
      debugDefaultTargetPlatformOverride = originalPlatform;
    }
  }, () => MockClient((request) async => handler(request)));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('missing bus plus successful HTTP enables the live item-detail route',
      () async {
    var publicCalls = 0;
    var detailCalls = 0;
    Future<http.Response> handler(http.Request request) async {
      if (request.url.path.endsWith('/System/Info/Public')) {
        publicCalls++;
        return healthy();
      }
      if (request.url.path.endsWith('/Items/fixture-item')) {
        detailCalls++;
        return http.Response(
            jsonEncode({
              'Id': 'fixture-item',
              'Name': 'Synthetic item',
              'Type': 'Movie'
            }),
            200,
            headers: {'content-type': 'application/json'});
      }
      fail('Unexpected synthetic request path');
    }

    await withFixture(ProbeBackend(detachedError: true), handler,
        (container) async {
      await waitForProbe(container);
      expect(container.read(offlineStateProvider), isFalse);
      expect(
          container.read(connectivityStatusProvider), ConnectionState.mobile);
      expect(container.read(connectivityStatusProvider).homeInternet, isFalse);
      expect(publicCalls, 1,
          reason: 'Stream/check errors share one pending probe');
      final api = JellyfinOpenApi.create(
          baseUrl: Uri.parse(fixtureUrl), httpClient: MockClient(handler));
      final detailProvider = Provider((ref) => LiveDetailService(ref, api));
      try {
        final response = await container
            .read(detailProvider)
            .usersUserIdItemsItemIdGetBaseItem(itemId: 'fixture-item');
        expect(response.statusCode, 200);
        expect(response.body?.id, 'fixture-item');
        expect(detailCalls, 1);
      } finally {
        api.client.dispose();
      }
    });
  });

  test('Linux none still verifies the signed-in server with bounded HTTP',
      () async {
    var calls = 0;
    await withFixture(ProbeBackend(results: const [ConnectivityResult.none]),
        (request) {
      calls++;
      return healthy();
    }, (container) async {
      await waitForProbe(container);
      expect(calls, 1);
      expect(container.read(offlineStateProvider), isFalse);
    });
  });

  for (final kind in ['HTTP failure', 'HTTP timeout']) {
    test('unavailable backend plus $kind remains offline', () async {
      await withFixture(ProbeBackend(), (request) {
        if (kind == 'HTTP timeout') return Completer<http.Response>().future;
        return http.Response('synthetic service unavailable', 503);
      }, (container) async {
        await waitForProbe(container);
        expect(container.read(connectivityStatusProvider),
            ConnectionState.offline);
        expect(container.read(offlineStateProvider), isTrue);
      });
    });
  }

  test('transient backend errors retain HTTP-confirmed state and share a probe',
      () async {
    var calls = 0;
    final held = Completer<http.Response>();
    final backend = ProbeBackend();
    await withFixture(backend, (request) {
      calls++;
      if (calls == 1) return healthy();
      return held.future;
    }, (container) async {
      await waitForProbe(container);
      final notifier = container.read(connectivityStatusProvider.notifier);
      await notifier.checkConnectivity();
      await pumpEvents();
      expect(calls, 2);
      expect(container.read(offlineStateProvider), isFalse);
      for (var i = 0; i < 8; i++) {
        await notifier.checkConnectivity();
      }
      backend.events.addError(StateError('synthetic transient bus failure'));
      await pumpEvents();
      expect(calls, 2);
      expect(container.read(offlineStateProvider), isFalse);
      held.complete(healthy());
      await waitForProbe(container);
      expect(container.read(offlineStateProvider), isFalse);
    });
  });

  test('a stale previous-server response cannot overwrite the new server',
      () async {
    final oldResponse = Completer<http.Response>();
    var calls = 0;
    await withFixture(ProbeBackend(), (request) {
      calls++;
      if (request.url.host == 'jellyfin.example.invalid') {
        return oldResponse.future;
      }
      return healthy();
    }, (container) async {
      await pumpEvents();
      expect(calls, 1);
      (container.read(userProvider.notifier) as FixtureUser)
          .replace('https://second.example.invalid');
      await waitForProbe(container);
      expect(calls, 2);
      expect(container.read(offlineStateProvider), isFalse);
      oldResponse.complete(http.Response('synthetic old failure', 503));
      await pumpEvents();
      expect(container.read(offlineStateProvider), isFalse);
    });
  });

  test('disposal ignores an HTTP probe result without an uncaught error',
      () async {
    final held = Completer<http.Response>();
    final backend = ProbeBackend();
    await http.runWithClient(() async {
      final original = ConnectivityPlatform.instance;
      final originalPlatform = debugDefaultTargetPlatformOverride;
      ConnectivityPlatform.instance = backend;
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final container = ProviderContainer(overrides: [
        userProvider.overrideWith(FixtureUser.new),
      ]);
      var disposed = false;
      try {
        container.read(connectivityStatusProvider);
        await pumpEvents();
        container.dispose();
        disposed = true;
        held.complete(healthy());
        await pumpEvents();
      } finally {
        if (!disposed) container.dispose();
        await backend.events.close();
        ConnectivityPlatform.instance = original;
        debugDefaultTargetPlatformOverride = originalPlatform;
      }
    }, () => MockClient((request) => held.future));
  });

  test('signing out invalidates the pending previous-account HTTP result',
      () async {
    final held = Completer<http.Response>();
    await withFixture(ProbeBackend(), (request) => held.future,
        (container) async {
      await pumpEvents();
      (container.read(userProvider.notifier) as FixtureUser).signOut();
      await pumpEvents();
      expect(
          container.read(connectivityStatusProvider), ConnectionState.offline);
      held.complete(healthy());
      await pumpEvents();
      expect(
          container.read(connectivityStatusProvider), ConnectionState.offline);
    });
  });

  test('direct retry waits for HTTP before returning to the live detail route',
      () async {
    var recovering = false;
    var detailCalls = 0;
    final held = Completer<http.Response>();
    Future<http.Response> handler(http.Request request) async {
      if (request.url.path.endsWith('/System/Info/Public')) {
        if (!recovering) return http.Response('synthetic offline', 503);
        return held.future;
      }
      if (request.url.path.endsWith('/Items/fixture-item')) {
        detailCalls++;
        return http.Response(jsonEncode({'Id': 'fixture-item'}), 200,
            headers: {'content-type': 'application/json'});
      }
      fail('Unexpected synthetic request path');
    }

    await withFixture(ProbeBackend(), handler, (container) async {
      await waitForProbe(container);
      expect(container.read(offlineStateProvider), isTrue);
      recovering = true;
      final completion = Timer(const Duration(milliseconds: 20), () {
        if (!held.isCompleted) held.complete(healthy());
      });
      try {
        final notifier = container.read(connectivityStatusProvider.notifier);
        // No pumping between these awaits: checkConnectivity must publish the
        // pending probe before completing its caller-zone Future.
        await notifier.checkConnectivity(immediate: true);
        await notifier.waitForProbe();
        expect(container.read(offlineStateProvider), isFalse);
        final api = JellyfinOpenApi.create(
            baseUrl: Uri.parse(fixtureUrl), httpClient: MockClient(handler));
        final detailProvider = Provider((ref) => LiveDetailService(ref, api));
        try {
          final response = await container
              .read(detailProvider)
              .usersUserIdItemsItemIdGetBaseItem(itemId: 'fixture-item');
          expect(response.body?.id, 'fixture-item');
          expect(detailCalls, 1);
        } finally {
          api.client.dispose();
        }
      } finally {
        completion.cancel();
        if (!held.isCompleted) held.complete(http.Response('cleanup', 503));
        await pumpEvents();
      }
    });
  });
}
