import 'dart:async';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart' as jellyfin;
import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/credentials_model.dart';
import 'package:fladder/providers/syncplay_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/screens/video_player/components/syncplay_dialog.dart';
import 'package:fladder/services/syncplay/syncplay_models.dart';
import 'package:fladder/widgets/shared/controller_navigation.dart';
import 'package:fladder/widgets/shared/syncplay_home_entry.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _account = AccountModel(
  name: 'Synthetic home fixture',
  id: '44444444444444444444444444444444',
  avatar: '',
  lastUsed: DateTime.utc(2026),
  credentials: CredentialsModel.internal(
    url: 'https://fixture.example.invalid',
    token: 'synthetic-only',
    serverId: '55555555555555555555555555555555',
    deviceId: 'synthetic-device',
  ),
  policy: const jellyfin.UserPolicy(
    authenticationProviderId: 'fixture',
    passwordResetProviderId: 'fixture',
    syncPlayAccess: jellyfin.SyncPlayUserAccessType.joingroups,
  ),
);

SyncPlayGroup get _group => SyncPlayGroup(
      groupId: '11111111111111111111111111111111',
      groupName: 'JMS-123456',
      participants: const ['Fixture'],
      lastUpdatedAt: DateTime.utc(2026),
    );

class _User extends User {
  _User([this.fixture]);
  final AccountModel? fixture;
  @override
  AccountModel? build() => fixture ?? _account;
}

class _Room extends SyncPlayNotifier {
  _Room(super.ref);
  int joins = 0, cancels = 0, consumes = 0;
  int? ticket;
  Completer<void>? cancelGate;
  @override
  bool get canJoinFromHome => true;
  @override
  bool get canJoin => true;
  @override
  bool get canCreate => false;
  @override
  bool get permissionKnown => true;
  @override
  Future<void> refreshPermission() async {}
  @override
  int? beginHomeJoin(String code) {
    joins++;
    ticket = joins;
    state = const SyncPlayViewState(busy: true, preparingPlayback: true);
    return ticket;
  }

  @override
  Future<void> cancelHomeJoin(int expected) async {
    if (ticket != expected) return;
    cancels++;
    // Revocation precedes the asynchronous departure acknowledgement.
    ticket = null;
    await cancelGate?.future;
    state = const SyncPlayViewState();
  }

  @override
  bool consumeHomeJoin(int expected) {
    if (ticket != expected || state.readyHomeJoin != expected) return false;
    consumes++;
    ticket = null;
    return true;
  }

  void ready(int expected) {
    state = SyncPlayViewState(
      readyHomeJoin: expected,
      room:
          SyncPlayControllerState(status: SyncPlayStatus.joined, group: _group),
    );
  }
}

class _Video extends VideoPlayerNotifier {
  _Video(super.ref);
  int opens = 0;
  @override
  Future<void> openPlayer(BuildContext context) async {
    opens++;
  }
}

void main() {
  Future<void> panel(
    WidgetTester tester, {
    SyncPlayViewState state = const SyncPlayViewState(),
    bool signedIn = true,
    bool permissionKnown = true,
    bool transitioning = false,
    Future<void> Function()? close,
    Future<void> Function()? retry,
    Future<void> Function()? refresh,
    Future<void> Function(String)? join,
    TextScaler scaler = TextScaler.noScaling,
  }) =>
      tester.pumpWidget(MaterialApp(
          builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: scaler),
                child: child!,
              ),
          home: Scaffold(
              body: SyncPlayRoomPanel(
            state: state,
            supported: true,
            signedIn: signedIn,
            transitioning: transitioning,
            permissionKnown: permissionKnown,
            joinFromHome: true,
            canJoin: signedIn,
            canCreate: false,
            createRoom: () async {},
            joinRoom: join ?? (_) async {},
            leaveRoom: () async {},
            reconnect: () async {},
            close: close,
            retry: retry,
            refreshPermission: refresh,
          ))));

  testWidgets(
      'home entry has a touch target and controller activation before any player exists',
      (tester) async {
    var opens = 0;
    await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
            home: Scaffold(
      body: ControllerNavigation(
          onBack: () {}, child: SyncPlayHomeEntry(onPressed: () => opens++)),
    ))));
    final button = find.byWidgetPredicate((widget) => widget is FilledButton);
    expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
    await tester.tap(button);
    expect(opens, 1);
    Focus.of(tester.element(find.text('Watch together'))).requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.gameButtonA);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.gameButtonA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.gameButtonA);
    expect(opens, 2);
  });

  testWidgets(
      'home panel accepts PIN without presenting a disabled create action',
      (tester) async {
    var joins = 0;
    await panel(tester, join: (_) async => joins++);
    expect(find.text('Create room with this video'), findsNothing);
    expect(find.textContaining('choose a video first'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
    await tester.enterText(find.byType(TextField), '123456');
    await tester.pump();
    await tester.ensureVisible(find.text('Join room'));
    await tester.tap(find.text('Join room'));
    expect(joins, 1);
  });

  testWidgets(
      'signed out does not mislabel missing login as a permission denial',
      (tester) async {
    await panel(tester, signedIn: false, permissionKnown: false);
    expect(find.textContaining('Sign in to Jellyfin before'), findsOneWidget);
    expect(find.textContaining('administrator'), findsNothing);
    expect(find.textContaining('Unable to confirm'), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
  });

  testWidgets('permission lookup failure offers a targeted retry',
      (tester) async {
    var retries = 0;
    await panel(tester, permissionKnown: false, refresh: () async => retries++);
    await tester.ensureVisible(find.text('Check permission again'));
    await tester.tap(find.text('Check permission again'));
    expect(retries, 1);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
  });

  for (final missing in ['token', 'device']) {
    testWidgets(
        'restored account missing $missing requests sign-in without touching playback',
        (tester) async {
      final incomplete = _account.copyWith(
          credentials: _account.credentials.copyWith(
        token: missing == 'token' ? '' : 'synthetic-only',
        deviceId: missing == 'device' ? '' : 'synthetic-device',
      ));
      await tester.pumpWidget(ProviderScope(overrides: [
        userProvider.overrideWith(() => _User(incomplete)),
        syncPlayProvider.overrideWith(_Room.new),
        videoPlayerProvider
            .overrideWith((_) => throw StateError('Playback must remain lazy')),
      ], child: const MaterialApp(home: Scaffold(body: SyncPlayHomeEntry()))));
      await tester.tap(find.text('Watch together'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Sign in to Jellyfin before'), findsOneWidget);
      expect(find.textContaining('administrator'), findsNothing);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'departure before retry keeps Cancel usable without a false permission denial',
      (tester) async {
    var closes = 0;
    await panel(tester, transitioning: true, close: () async => closes++);
    expect(find.textContaining('administrator'), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    await tester.tap(find.text('Cancel'));
    expect(closes, 1);
  });

  testWidgets(
      'loading after membership confirmation stays cancellable and prevents duplicate joins',
      (tester) async {
    var closes = 0;
    await panel(tester,
        state: SyncPlayViewState(
          preparingPlayback: true,
          room: SyncPlayControllerState(
              status: SyncPlayStatus.joined, group: _group),
        ),
        close: () async => closes++);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.textContaining('Loading the room video'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('Cancel'));
    expect(closes, 1);
  });

  testWidgets(
      'joined media failure offers rejoin and reload while preserving leave',
      (tester) async {
    var retries = 0;
    await panel(tester,
        state: SyncPlayViewState(
            room: SyncPlayControllerState(
          status: SyncPlayStatus.joined,
          group: _group,
          failure: const SyncPlayFailure(SyncPlayFailureCode.player),
        )),
        retry: () async => retries++);
    await tester.ensureVisible(find.text('Rejoin and reload'));
    await tester.tap(find.text('Rejoin and reload'));
    expect(retries, 1);
    expect(find.text('Leave room'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  for (final size in [const Size(320, 568), const Size(640, 360)]) {
    testWidgets('home controls remain within a $size viewport at 200% text',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(ProviderScope(
          child: MaterialApp(
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!),
        home: Scaffold(
            body: Column(children: [
          SyncPlayHomeEntry(onPressed: () {}),
          const Expanded(child: SizedBox())
        ])),
      )));
      expect(tester.takeException(), isNull);
      await panel(tester, scaler: const TextScaler.linear(2));
      await tester.ensureVisible(find.text('Join room'));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'home opens the player exactly once after ready and does not initialize it on dialog open',
      (tester) async {
    late _Room room;
    _Video? video;
    await tester.pumpWidget(ProviderScope(overrides: [
      userProvider.overrideWith(_User.new),
      syncPlayProvider.overrideWith((ref) => room = _Room(ref)),
      videoPlayerProvider.overrideWith((ref) => video = _Video(ref)),
    ], child: const MaterialApp(home: Scaffold(body: SyncPlayHomeEntry()))));
    final activate = tester
        .widget<FilledButton>(
            find.byWidgetPredicate((widget) => widget is FilledButton))
        .onPressed!;
    activate();
    activate();
    await tester.pumpAndSettle();
    expect(find.byType(SyncPlayDialog), findsOneWidget);
    expect(video, isNull);
    await tester.enterText(find.byType(TextField), '123456');
    await tester.pump();
    await tester.ensureVisible(find.text('Join room'));
    await tester.tap(find.text('Join room'));
    await tester.pump();
    expect(room.joins, 1);
    room.ready(1);
    await tester.pumpAndSettle();
    expect(video?.opens, 1);
    expect(room.consumes, 1);
    room.ready(1);
    await tester.pump();
    expect(video?.opens, 1);
  });

  for (final dismiss in ['close', 'back', 'barrier', 'controller']) {
    testWidgets(
        '$dismiss revokes an owned home join and cannot navigate on a late ready',
        (tester) async {
      late _Room room;
      var videoCreated = false;
      await tester.pumpWidget(ProviderScope(overrides: [
        userProvider.overrideWith(_User.new),
        syncPlayProvider.overrideWith((ref) => room = _Room(ref)),
        videoPlayerProvider.overrideWith((ref) {
          videoCreated = true;
          return _Video(ref);
        }),
      ], child: const MaterialApp(home: Scaffold(body: SyncPlayHomeEntry()))));
      await tester.tap(find.text('Watch together'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '123456');
      await tester.pump();
      await tester.ensureVisible(find.text('Join room'));
      await tester.tap(find.text('Join room'));
      await tester.pump();
      room.cancelGate = Completer<void>();
      if (dismiss == 'close') {
        await tester.tap(find.text('Cancel'));
      } else if (dismiss == 'back') {
        await tester.binding.handlePopRoute();
      } else if (dismiss == 'controller') {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.gameButtonB);
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.gameButtonB);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.gameButtonB);
      } else {
        await tester.tapAt(const Offset(2, 2));
      }
      await tester.pump();
      expect(room.cancels, 1);
      room.ready(1);
      await tester.pump();
      expect(room.consumes, 0);
      expect(videoCreated, isFalse);
      room.cancelGate!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(SyncPlayDialog), findsNothing);
      expect(videoCreated, isFalse);
    });
  }
}
