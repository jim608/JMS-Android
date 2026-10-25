import 'dart:async';

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
  int leaves = 0;
  bool get pendingLeave => state.leavePending;
  void view(SyncPlayViewState value) => state = value;
  @override
  bool get supported => true;
  @override
  Future<void> leaveRoom() async {
    if (!mounted) return;
    leaves++;
    state = const SyncPlayViewState(
      leavePending: true,
      room: SyncPlayControllerState(status: SyncPlayStatus.leaving),
    );
  }

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

class _FixtureVideo extends VideoPlayerNotifier {
  _FixtureVideo(super.ref);
}

void main() {
  Future<void> panel(
    WidgetTester tester,
    SyncPlayViewState state, {
    bool supported = true,
    bool canJoin = true,
    bool closing = false,
    Future<void> Function()? confirm,
    Future<void> Function()? leave,
    Future<void> Function()? create,
    Future<void> Function(String)? join,
  }) =>
      tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SyncPlayRoomPanel(
            state: state,
            supported: supported,
            canJoin: canJoin,
            canCreate: true,
            closing: closing,
            createRoom: create ?? () async {},
            joinRoom: join ?? (_) async {},
            leaveRoom: leave ?? () async {},
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

  final joined = SyncPlayViewState(
    room: SyncPlayControllerState(
      status: SyncPlayStatus.joined,
      group: SyncPlayGroup(
        groupId: '11111111111111111111111111111111',
        groupName: 'JMS-123456',
        participants: const ['Synthetic member'],
        lastUpdatedAt: DateTime.utc(2026),
      ),
    ),
  );

  Future<_LeaveRoom> openDialog(WidgetTester tester, SyncPlayViewState state,
      {bool fromHome = true}) async {
    late _LeaveRoom room;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        userProvider.overrideWith(_FixtureUser.new),
        syncPlayProvider.overrideWith((ref) {
          room = _LeaveRoom(ref);
          room.view(state);
          return room;
        }),
        videoPlayerProvider.overrideWith(_FixtureVideo.new),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
              builder: (context) => TextButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => SyncPlayDialog(joinFromHome: fromHome),
                    ),
                    child: const Text('Open room'),
                  )),
        ),
      ),
    ));
    await tester.tap(find.text('Open room'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    return room;
  }

  testWidgets('pending leave exposes settlement even without a playback model',
      (tester) async {
    var calls = 0;
    await panel(tester, leavingUnknown,
        supported: false, canJoin: false, confirm: () async => calls++);
    expect(find.text('Playing solo'), findsOneWidget);
    expect(find.text('Local sync is off. Server departure is unconfirmed.'),
        findsOneWidget);
    expect(find.text('Confirm leave'), findsNothing);
    expect(find.text('Reconnect and check'), findsNothing);
    expect(find.text('Create room with this video'), findsNothing);
    expect(find.textContaining('Confirmation timed out'), findsNothing);
    expect(find.textContaining('administrator'), findsNothing);
    await tester.ensureVisible(find.text('Retry leave'));
    await tester.tap(find.text('Retry leave'));
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
    expect(find.text('Retry leave'), findsNothing);
    expect(
        find.text('Notifying the server in the background…'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(
        tester
            .widget<TextButton>(
              find.widgetWithText(TextButton, 'Close'),
            )
            .onPressed,
        isNotNull);
    expect(find.text('Leave room'), findsNothing);
  });

  testWidgets(
      'retry gives immediate feedback and coalesces without provider rebuild',
      (tester) async {
    var calls = 0;
    final gate = Completer<void>();
    await panel(tester, leavingUnknown, confirm: () async {
      calls++;
      await gate.future;
    });
    final press = tester
        .widget<TextButton>(find.widgetWithText(TextButton, 'Retry leave'))
        .onPressed!;
    press();
    press();
    await tester.pump();
    expect(calls, 1);
    expect(
        find.text('Notifying the server in the background…'), findsOneWidget);
    expect(find.text('Retry leave'), findsNothing);
    expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Close'))
            .onPressed,
        isNotNull);
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('Retry leave'), findsOneWidget);
  });

  testWidgets('local leave hides stale room members and advanced diagnostics',
      (tester) async {
    await panel(
        tester,
        SyncPlayViewState(
          leavePending: true,
          room: SyncPlayControllerState(
            status: SyncPlayStatus.unknown,
            group: joined.room.group,
          ),
        ));
    expect(find.text('Playing solo'), findsOneWidget);
    expect(find.text('123456'), findsNothing);
    expect(find.text('1 participants'), findsNothing);
    expect(find.byType(SyncPlayLocalBufferPanel), findsNothing);
    expect(find.byType(SyncPlayDiagnosticsPanel), findsNothing);
  });

  testWidgets(
      'leave remains actionable during pending join and reacts immediately',
      (tester) async {
    var leaves = 0;
    final gate = Completer<void>();
    await panel(
        tester,
        const SyncPlayViewState(
          busy: true,
          preparingPlayback: true,
          room: SyncPlayControllerState(status: SyncPlayStatus.joining),
        ), leave: () async {
      leaves++;
      await gate.future;
    });
    final press = tester
        .widget<TextButton>(find.widgetWithText(TextButton, 'Leave room'))
        .onPressed!;
    press();
    press();
    await tester.pump();
    expect(leaves, 1);
    expect(find.text('Stopping sync…'), findsOneWidget);
    expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Leave room'))
            .onPressed,
        isNull);
    gate.complete();
    await tester.pump();
  });

  for (final action in ['create', 'join']) {
    testWidgets('$action coalesces clicks before provider state changes',
        (tester) async {
      var requests = 0;
      final gate = Completer<void>();
      Future<void> request() async {
        requests++;
        await gate.future;
      }

      await panel(tester, const SyncPlayViewState(),
          create: request, join: (_) => request());
      VoidCallback press;
      if (action == 'create') {
        press = tester
            .widget<FilledButton>(
                find.byWidgetPredicate((w) => w is FilledButton))
            .onPressed!;
      } else {
        await tester.enterText(find.byType(TextField), '123456');
        await tester.pump();
        press = tester
            .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, 'Join room'))
            .onPressed!;
      }
      press();
      press();
      await tester.pump();
      expect(requests, 1);
      gate.complete();
      await tester.pumpAndSettle();
    });
  }

  testWidgets(
      'toolbar deselects local leave while retaining the server room snapshot',
      (tester) async {
    late _LeaveRoom room;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        userProvider.overrideWith(_FixtureUser.new),
        syncPlayProvider.overrideWith((ref) {
          room = _LeaveRoom(ref);
          room.view(joined);
          return room;
        }),
        videoPlayerProvider.overrideWith(
            (_) => throw StateError('Toolbar must not initialize a player')),
      ],
      child: const MaterialApp(home: Scaffold(body: SyncPlayButton())),
    ));
    expect(
        tester.widget<IconButton>(find.byType(IconButton)).isSelected, isTrue);
    room.view(SyncPlayViewState(
      leavePending: true,
      room: SyncPlayControllerState(
        status: SyncPlayStatus.unknown,
        group: joined.room.group,
      ),
    ));
    await tester.pump();
    expect(
        tester.widget<IconButton>(find.byType(IconButton)).isSelected, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'one leave action closes the dialog while server settlement continues',
      (tester) async {
    final room = await openDialog(tester, joined);
    await tester.ensureVisible(find.text('Leave room'));
    await tester.tap(find.text('Leave room'));
    await tester.pumpAndSettle();
    expect(room.leaves, 1);
    expect(room.pendingLeave, isTrue);
    expect(find.byType(SyncPlayDialog), findsNothing);
    expect(find.text('Playing solo'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing a joined dialog preserves room membership',
      (tester) async {
    final room = await openDialog(tester, joined);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(room.leaves, 0);
    expect(find.byType(SyncPlayDialog), findsNothing);
  });

  for (final phase in ['join', 'handshake']) {
    for (final dismiss in ['close', 'back', 'navigation']) {
      testWidgets(
          '$dismiss cancels pending player $phase without repeated leave',
          (tester) async {
        final room = await openDialog(
            tester,
            SyncPlayViewState(
              busy: true,
              room: SyncPlayControllerState(
                  status: phase == 'handshake'
                      ? SyncPlayStatus.idle
                      : SyncPlayStatus.joining),
            ),
            fromHome: false);
        if (dismiss == 'close') {
          await tester.tap(find.text('Cancel'));
        } else if (dismiss == 'back') {
          await tester.binding.handlePopRoute();
        } else {
          final context = tester.element(find.byType(SyncPlayDialog));
          Navigator.of(context).removeRoute(ModalRoute.of(context)!);
        }
        await tester.pumpAndSettle();
        expect(room.leaves, 1);
        expect(find.byType(SyncPlayDialog), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }

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

  testWidgets('home dialog retries leave without opening a home join ticket',
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
    await tester.ensureVisible(find.text('Retry leave'));
    await tester.tap(find.text('Retry leave'));
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
