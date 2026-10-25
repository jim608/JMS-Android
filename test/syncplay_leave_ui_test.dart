import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart' as jellyfin;
import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/credentials_model.dart';
import 'package:fladder/providers/syncplay_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/screens/video_player/components/syncplay_dialog.dart';
import 'package:fladder/services/syncplay/syncplay_models.dart';

class _FixtureUser extends User {
  @override
  AccountModel? build() => AccountModel(
        name: 'Synthetic leave fixture',
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
          syncPlayAccess: jellyfin.SyncPlayUserAccessType.none,
        ),
      );
}

class _LeaveRoom extends SyncPlayNotifier {
  _LeaveRoom(super.ref) {
    state = const SyncPlayViewState(
      leavePending: true,
      room: SyncPlayControllerState(status: SyncPlayStatus.unknown),
    );
  }
  int confirmations = 0;
  @override
  bool get canJoin => false;
  @override
  bool get canJoinFromHome => false;
  @override
  bool get permissionKnown => true;
  @override
  Future<void> refreshPermission() async {}
  @override
  Future<void> reconnect() async => confirmations++;
  @override
  int? beginHomeReconnect() => throw StateError('Must never begin a new join');
}

void main() {
  Future<void> panel(
    WidgetTester tester,
    SyncPlayViewState state, {
    bool supported = true,
    bool canJoin = true,
    bool closing = false,
    Future<void> Function()? confirm,
  }) =>
      tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SyncPlayRoomPanel(
            state: state,
            supported: supported,
            canJoin: canJoin,
            canCreate: true,
            closing: closing,
            createRoom: () async {},
            joinRoom: (_) async {},
            leaveRoom: () async {},
            reconnect: confirm ?? () async {},
            close: () async {},
          ),
        ),
      ));

  const leavingUnknown = SyncPlayViewState(
    leavePending: true,
    room: SyncPlayControllerState(
      status: SyncPlayStatus.unknown,
      failure: SyncPlayFailure(SyncPlayFailureCode.timeoutUnknown),
    ),
  );

  testWidgets('pending leave exposes settlement even without a playback model',
      (tester) async {
    var calls = 0;
    await panel(tester, leavingUnknown,
        supported: false, canJoin: false, confirm: () async => calls++);
    expect(find.text('Leave not yet confirmed'), findsOneWidget);
    expect(find.text('Reconnect and check'), findsNothing);
    expect(find.text('Create room with this video'), findsNothing);
    expect(find.textContaining('Confirmation timed out'), findsNothing);
    expect(find.textContaining('administrator'), findsNothing);
    await tester.ensureVisible(find.text('Confirm leave'));
    await tester.tap(find.text('Confirm leave'));
    expect(calls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending leave coalesces clicks while settlement is running',
      (tester) async {
    await panel(
        tester,
        const SyncPlayViewState(
          leavePending: true,
          busy: true,
          room: SyncPlayControllerState(status: SyncPlayStatus.leaving),
        ));
    expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Confirm leave'),
            )
            .onPressed,
        isNull);
    expect(
        tester
            .widget<TextButton>(
              find.widgetWithText(TextButton, 'Close'),
            )
            .onPressed,
        isNotNull);
    expect(find.text('Leave room'), findsNothing);
  });

  testWidgets('room privacy remains reachable without persistent help prose',
      (tester) async {
    await panel(tester, const SyncPlayViewState());
    expect(find.textContaining('not a password'), findsNothing);
    expect(find.textContaining('Sign in to the same Jellyfin'), findsNothing);
    await tester.tap(find.byTooltip('Room information'));
    await tester.pumpAndSettle();
    expect(find.textContaining('not a password'), findsOneWidget);
    expect(find.textContaining('Each participant needs their own permission'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('media load failure does not diagnose a permission denial',
      (tester) async {
    await panel(
        tester,
        const SyncPlayViewState(
          failure: SyncPlayFailure(SyncPlayFailureCode.player),
        ));
    expect(find.text('Room video could not be loaded.'), findsOneWidget);
    expect(find.textContaining('Check media permission'), findsNothing);
  });

  testWidgets('home dialog confirms Leave without opening a home join ticket',
      (tester) async {
    late _LeaveRoom room;
    await tester.pumpWidget(ProviderScope(
        overrides: [
          userProvider.overrideWith(_FixtureUser.new),
          syncPlayProvider.overrideWith((ref) => room = _LeaveRoom(ref)),
          videoPlayerProvider.overrideWith(
              (_) => throw StateError('No player may be initialized')),
        ],
        child: const MaterialApp(
          home: Scaffold(body: SyncPlayDialog(joinFromHome: true)),
        )));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Confirm leave'));
    await tester.tap(find.text('Confirm leave'));
    await tester.pump();
    expect(room.confirmations, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing prevents a nested information route from stealing pop',
      (tester) async {
    await panel(tester, leavingUnknown, closing: true);
    final info = find.byTooltip('Room information');
    expect(
        tester
            .widget<IconButton>(find.byWidgetPredicate(
                (w) => w is IconButton && w.tooltip == 'Room information'))
            .onPressed,
        isNull);
    await tester.tap(info);
    await tester.pump();
    expect(find.textContaining('not a password'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
