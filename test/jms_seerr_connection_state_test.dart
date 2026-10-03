import 'dart:async';

import 'package:fladder/l10n/generated/app_localizations.dart';
import 'package:fladder/models/account_model.dart';
import 'package:fladder/providers/seerr_api_provider.dart';
import 'package:fladder/providers/seerr_link_provider.dart';
import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/screens/seerr/seerr_link_panel.dart';
import 'package:fladder/seerr/seerr_connection.dart';
import 'package:fladder/seerr/seerr_session_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/seerr_test_scope.dart';

AccountModel _account() {
  final account = seerrFixtureAccount();
  return account.copyWith(
      seerrCredentials: account.seerrCredentials!
          .copyWith(serverUrl: 'https://requests.example.invalid'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SeerrFixture fixture;
  late ProviderContainer container;
  late AccountModel account;
  Future<http.Response> Function(http.Request)? intercept;

  setUp(() async {
    fixture = SeerrFixture();
    await fixture.initializePreferences();
    account = _account();
    intercept = null;
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(fixture.preferences!),
      userProvider.overrideWith(() => SeerrFixtureUser(account)),
      seerrSessionStoreProvider.overrideWithValue(fixture.store),
      seerrHttpClientFactoryProvider.overrideWithValue(() => MockClient(
          (request) => intercept?.call(request) ?? fixture.handle(request))),
    ]);
  });

  tearDown(() {
    container.dispose();
    fixture.dispose();
  });

  Future<void> restore() async {
    await fixture.store.write(account, 'connect.sid=TEST_ONLY');
    await container.read(seerrLinkProvider.notifier).ensure();
    expect(container.read(seerrLinkProvider), 'connected');
  }

  Future<void> showPanel(WidgetTester tester) async {
    await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          locale: Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: SeerrLinkPanel()),
        )));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'verified secure restore hides the prompt on each native platform',
      (tester) async {
    await restore();
    await showPanel(tester);
    expect(find.byType(Card), findsNothing);
    expect(find.text('My request service'), findsNothing);
    expect(find.text('Connect'), findsNothing);
    expect(find.text('Copy connection diagnostic'), findsNothing);
    expect(fixture.calls.where((request) => request.method == 'POST'), isEmpty);
    expect(
        fixture.calls
            .where((request) => request.url.path == '/api/v1/auth/me')
            .length,
        1);
    expect(tester.takeException(), isNull);
  },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
        TargetPlatform.linux,
      }));

  testWidgets('same-account refresh stays unobtrusive and never logs in again',
      (tester) async {
    await restore();
    await showPanel(tester);
    final started = Completer<void>();
    final release = Completer<void>();
    intercept = (request) async {
      if (request.url.path == '/api/v1/auth/me') {
        started.complete();
        await release.future;
      }
      return fixture.handle(request);
    };
    final refresh =
        container.read(seerrLinkProvider.notifier).ensure(manual: true);
    await started.future;
    await tester.pump();
    expect(container.read(seerrLinkProvider), 'connected');
    expect(find.byType(Card), findsNothing);
    release.complete();
    await refresh;
    await tester.pumpAndSettle();
    expect(container.read(seerrLinkProvider), 'connected');
    expect(find.byType(Card), findsNothing);
    expect(fixture.calls.where((request) => request.method == 'POST'), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('operation 401 clears secure session and restores the prompt',
      (tester) async {
    await restore();
    await showPanel(tester);
    final restoredApi = container.read(seerrApiProvider);
    intercept = (request) async {
      if (request.url.path == '/api/v1/genres/movie') {
        fixture.calls.add(request);
        return fixture.json({'status': 401}, status: 401);
      }
      return fixture.handle(request);
    };
    await expectLater(
        restoredApi.getMovieGenres(),
        throwsA(isA<SeerrFailure>()
            .having((failure) => failure.code, 'code', 'session_expired')));
    await tester.pumpAndSettle();
    expect(container.read(seerrLinkProvider), 'needs_auth');
    expect(find.byType(Card), findsOneWidget);
    expect(find.text('Verify'), findsOneWidget);
    expect(
        container.read(userProvider)!.seerrCredentials!.sessionCookie, isEmpty);
    expect(fixture.store.values, isEmpty);
    expect(identical(container.read(seerrApiProvider), restoredApi), isFalse);
    expect(fixture.calls.where((request) => request.method == 'POST'), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('403 during restored identity check cannot remain connected',
      (tester) async {
    await restore();
    await showPanel(tester);
    fixture.nextMeStatus = 403;
    await container.read(seerrLinkProvider.notifier).ensure(manual: true);
    await tester.pumpAndSettle();
    expect(container.read(seerrLinkProvider), isNot('connected'));
    expect(find.byType(Card), findsOneWidget);
    expect(fixture.store.values, isEmpty);
    expect(fixture.calls.where((request) => request.method == 'POST'), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching account cannot keep the previous success hidden',
      (tester) async {
    await restore();
    await showPanel(tester);
    container.read(userProvider.notifier).updateUser(account.copyWith(
        id: 'different-fixture-user',
        seerrCredentials:
            account.seerrCredentials!.copyWith(sessionCookie: '')));
    await tester.pumpAndSettle();
    expect(container.read(seerrLinkProvider), isNot('connected'));
    expect(find.byType(Card), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'another Jellyfin URL with the same id must recheck its own scope',
      (tester) async {
    await restore();
    await showPanel(tester);
    container.read(userProvider.notifier).updateUser(account.copyWith(
        credentials: account.credentials
            .copyWith(url: 'https://other.example.invalid/jellyfin')));
    await tester.pumpAndSettle();
    expect(container.read(seerrLinkProvider), isNot('connected'));
    expect(find.byType(Card), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
