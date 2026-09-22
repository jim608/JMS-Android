import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/providers/seerr_link_provider.dart';
import 'package:fladder/providers/seerr_api_provider.dart';
import 'package:fladder/providers/seerr_service_provider.dart';
import 'package:fladder/providers/seerr/seerr_request_provider.dart';
import 'package:fladder/providers/connectivity_provider.dart' show offlineStateProvider;
import 'package:fladder/seerr/seerr_models.dart';
import 'package:fladder/models/api_result.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/seerr/seerr_session_store.dart';
import 'package:fladder/seerr/seerr_connection.dart';
import 'fixtures/seerr_test_scope.dart';

void main() {
  late SeerrFixture fixture;
  late ProviderContainer container;
  setUp(() {
    fixture = SeerrFixture();
    container = ProviderContainer(overrides: fixture.overrides());
  });
  tearDown(() {
    container.dispose();
    fixture.dispose();
  });

  test('single password login task, correct owner, no stored password or JSON cookie', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    fixture.beforeLogin = () {
      started.complete();
      return release.future;
    };
    final link = container.read(seerrLinkProvider.notifier);
    final pending = link.ensure(username: 'fixture', password: 'TEST_ONLY');
    await started.future;
    final duplicate = link.ensure(username: 'fixture', password: 'TEST_ONLY');
    release.complete();
    await Future.wait([pending, duplicate]);
    expect(container.read(seerrLinkProvider), 'connected');
    expect(fixture.calls.where((call) => call.method == 'POST').length, 1);
    final account = container.read(userProvider)!;
    expect(jsonEncode(account.toJson()), isNot(contains('TEST_ONLY')));
    expect(fixture.store.values[SeerrSessionStore.key(account)], 'connect.sid=TEST_ONLY');
    await link.ensure();
    expect(fixture.calls.where((call) => call.method == 'POST').length, 1);
  });

  test('unbound server never receives passwords or background authentication', () async {
    container.read(userProvider.notifier).updateUser(seerrFixtureAccount(bound: false));
    await container.read(seerrLinkProvider.notifier).ensure(username: 'fixture', password: 'TEST_ONLY');
    expect(container.read(seerrLinkProvider), 'binding_required');
    expect(fixture.calls, isEmpty);
  });

  test('existing token-only account restores and validates its own session', () async {
    final account = container.read(userProvider)!;
    await fixture.store.write(account, 'connect.sid=TEST_ONLY');
    await container.read(seerrLinkProvider.notifier).ensure();
    expect(container.read(seerrLinkProvider), 'connected');
    expect(fixture.calls.map((call) => call.url.path), ['/api/v1/auth/me']);
    expect(fixture.calls.where((call) => call.method == 'POST'), isEmpty);
  });

  test('expired session without Quick Connect requests native re-verification, preserves Jellyfin', () async {
    await fixture.store.write(container.read(userProvider)!, 'connect.sid=EXPIRED');
    fixture.authStatus = 401;
    await container.read(seerrLinkProvider.notifier).ensure();
    expect(container.read(seerrLinkProvider), 'needs_auth');
    expect(container.read(userProvider)?.id, 'aabbcc');
    expect(fixture.store.values, isEmpty);
    expect(fixture.calls.where((call) => call.method == 'POST'), isEmpty);
  });

  test('Seerr JSON 403 on restored auth/me expires only its own session', () async {
    await fixture.store.write(container.read(userProvider)!, 'connect.sid=EXPIRED');
    fixture.authStatus = 403;
    await container.read(seerrLinkProvider.notifier).ensure();
    expect(container.read(seerrLinkProvider), 'needs_auth');
    expect(fixture.store.values, isEmpty);
    expect(container.read(userProvider)?.id, 'aabbcc');
    expect(fixture.calls.where((call) => call.method == 'POST'), isEmpty);
    expect(container.read(seerrDiagnosticProvider)?.stage, 'identity_check');
  });

  test('403 does not produce a password retry storm', () async {
    fixture.authStatus = 403;
    final link = container.read(seerrLinkProvider.notifier);
    await link.ensure(username: 'fixture', password: 'TEST_ONLY');
    await link.ensure(username: 'fixture', password: 'TEST_ONLY');
    expect(container.read(seerrLinkProvider), 'login_policy_denied');
    expect(fixture.calls.where((call) => call.method == 'POST').length, 1);
    expect(container.read(userProvider)?.id, 'aabbcc');
  });

  test('status probe is first and denied public API never receives password', () async {
    fixture.statusStatus = 403;
    await container.read(seerrLinkProvider.notifier).ensure(username: 'fixture', password: 'TEST_ONLY');
    expect(container.read(seerrLinkProvider), 'request_rejected_unknown');
    expect(fixture.calls.map((call) => call.url.path), ['/api/v1/status']);
    expect(fixture.calls.where((call) => call.method == 'POST'), isEmpty);
    final diagnostic = container.read(seerrDiagnosticProvider);
    expect(diagnostic?.stage, 'status_probe');
    expect(diagnostic?.status, 403);
    expect(diagnostic?.hasCookie, isFalse);
    fixture.statusStatus = 200;
    await container.read(seerrLinkProvider.notifier).ensure(
        username: 'fixture', password: 'TEST_ONLY', manual: true);
    expect(container.read(seerrLinkProvider), 'connected');
    expect(container.read(seerrDiagnosticProvider), isNull);
  });

  test('specific operation 403 after verified auth/me remains permission denied', () async {
    await container.read(seerrLinkProvider.notifier).ensure(username: 'fixture', password: 'TEST_ONLY');
    fixture.issueStatus = 403;
    await expectLater(container.read(seerrApiProvider).issues(),
        throwsA(predicate((error) => error is SeerrFailure && error.code == 'permission_denied')));
    expect(fixture.calls.last.url.path, '/api/v1/issue');
    expect(container.read(seerrDiagnosticProvider)?.stage, 'records');
  });

  test('switching accounts during authentication never attaches old cookie to new user', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    fixture.beforeLogin = () {
      started.complete();
      return release.future;
    };
    final pending = container.read(seerrLinkProvider.notifier).ensure(username: 'fixture', password: 'TEST_ONLY');
    await started.future;
    container.read(userProvider.notifier).updateUser(seerrFixtureAccount(id: 'another-user'));
    container.read(seerrLinkProvider);
    release.complete();
    await pending;
    expect(container.read(userProvider)?.seerrCredentials?.sessionCookie, isEmpty);
    expect(fixture.store.values, isEmpty);
  });

  test('source changes isolate session and remove legacy API key/header authority', () {
    final user = container.read(userProvider)!;
    container.read(userProvider.notifier).updateUser(user.copyWith(
        seerrCredentials: user.seerrCredentials!.copyWith(
            apiKey: 'TEST_ONLY', sessionCookie: 'connect.sid=OLD', customHeaders: {'Authorization': 'TEST_ONLY'})));
    container.read(userProvider.notifier).bindSeerrAccount(jmsSeerrSource);
    final credentials = container.read(userProvider)!.seerrCredentials!;
    expect(credentials.apiKey, isEmpty);
    expect(credentials.customHeaders, isEmpty);
    expect(credentials.sessionCookie, isEmpty);
    container.read(userProvider.notifier).setSeerrServerUrl('https://other.invalid');
    expect(container.read(userProvider)!.seerrCredentials!.linkedServerId, isEmpty);
  });

  test('Quick Connect code stays inside this flow and token stays at Jellyfin', () async {
    fixture.version = '3.4.1';
    container.dispose();
    final jellyfinCalls = <http.Request>[];
    container = ProviderContainer(overrides: [
      ...fixture.overrides(),
      seerrJellyfinLinkFactoryProvider.overrideWithValue((account, {anonymous = false}) => JellyfinOpenApi.create(
          baseUrl: Uri.parse('https://example.invalid'),
          httpClient: MockClient((call) async {
            jellyfinCalls.add(call);
            Object body = true;
            if (call.url.path == '/System/Info/Public') body = {'Id': 'fixture-server'};
            if (call.url.path == '/QuickConnect/Authorize') expect(call.url.queryParameters['code'], '123456');
            return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
          })))
    ]);
    await container.read(seerrLinkProvider.notifier).ensure();
    expect(container.read(seerrLinkProvider), 'connected');
    expect(jellyfinCalls.map((call) => call.url.path),
        ['/System/Info/Public', '/QuickConnect/Enabled', '/QuickConnect/Authorize']);
    expect(fixture.calls.where((call) => call.url.path == '/api/v1/auth/jellyfin'), isEmpty);
    expect(
        fixture.calls.every((call) => !call.headers.keys.any((key) => key.toLowerCase() == 'authorization')), isTrue);
  });

  test('different advertised Jellyfin server blocks password before any login POST', () async {
    fixture.advertisedJellyfin = 'https://different.invalid/jellyfin';
    container.dispose();
    container = ProviderContainer(overrides: [
      ...fixture.overrides(),
      seerrJellyfinLinkFactoryProvider.overrideWithValue((account, {anonymous = false}) {
        expect(anonymous, isTrue);
        expect(account.credentials.token, isEmpty);
        return JellyfinOpenApi.create(
            baseUrl: Uri.parse(account.credentials.url),
            httpClient: MockClient((call) async => fixture.json({'Id': 'different-server'})));
      })
    ]);
    await container.read(seerrLinkProvider.notifier).ensure(username: 'fixture', password: 'TEST_ONLY');
    expect(container.read(seerrLinkProvider), 'identity_mismatch');
    expect(fixture.calls.where((call) => call.method == 'POST'), isEmpty);
    expect(fixture.store.values, isEmpty);
  });

  test('login as a different Seerr owner never saves that session', () async {
    fixture.userId = 'other-person';
    await container.read(seerrLinkProvider.notifier).ensure(username: 'fixture', password: 'TEST_ONLY');
    expect(container.read(seerrLinkProvider), 'identity_mismatch');
    expect(fixture.store.values, isEmpty);
    expect(container.read(userProvider)?.seerrCredentials?.sessionCookie, isEmpty);
  });

  test('cookie renewal does not erase completed side-effect protection', () async {
    await container.read(seerrLinkProvider.notifier).ensure(username: 'fixture', password: 'TEST_ONLY');
    await container.read(seerrApiProvider).requestMovie(tmdbId: 42);
    fixture.requested = false;
    await container.read(userProvider.notifier).setSeerrSessionCookie('connect.sid=RENEWED');
    await container.read(seerrApiProvider).requestMovie(tmdbId: 42);
    expect(fixture.calls.where((call) => call.method == 'POST' && call.url.path == '/api/v1/request').length, 1);
  });

  test('native request provider returns confirmed request data after selecting a season', () async {
    container.dispose();
    container = ProviderContainer(overrides: [...fixture.overrides(), offlineStateProvider.overrideWithValue(false)]);
    await container.read(seerrLinkProvider.notifier).ensure(username: 'fixture', password: 'TEST_ONLY');
    final poster = await container
        .read(seerrApiProvider)
        .fetchDashboardPosterFromIds(tmdbId: 42, mediaType: SeerrMediaType.tvshow);
    final subscription = container.listen(seerrRequestProvider, (_, __) {});
    addTearDown(subscription.close);
    final notifier = container.read(seerrRequestProvider.notifier);
    await notifier.initialize(poster!);
    notifier.toggleSeason(1, true);
    final direct = await container.read(seerrApiProvider).requestSeries(tmdbId: 42, seasons: [1]);
    expect(direct.body?.id, 10);
    expect(direct.apiResult.data?.id, 10);
    final result = await notifier.submitRequest();
    expect(result?.data?.id, 10, reason: '${result.runtimeType}, ${result?.data.runtimeType}, ${result?.errorMessage}');
  });
}
