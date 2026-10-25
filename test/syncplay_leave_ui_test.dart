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
  Future<void>? leaveCompletion;
  bool throwAfterDetach = false;
  bool allowJoin = false;
  int homeCancels = 0;
  bool get pendingLeave => state.leavePending;
  void view(SyncPlayViewState value) => state = value;
  @override
  bool get supported => true;
  @override
  Future<void> leaveRoom() {
    if (!mounted) return Future<void>.value();
    leaves++;
    state = const SyncPlayViewState(
      leavePending: true,
      room: SyncPlayControllerState(status: SyncPlayStatus.leaving),
    );
    if (throwAfterDetach) {
      throw StateError('Synthetic cleanup invocation failure');
    }
    return leaveCompletion ?? Future<void>.value();
  }

  @override
  bool get canJoin => allowJoin;
  @override
  bool get canJoinFromHome => allowJoin;
  @override
  int? beginHomeJoin(String code) {
    state = const SyncPlayViewState(
      busy: true,
      preparingPlayback: true,
      room: SyncPlayControllerState(status: SyncPlayStatus.joining),
    );
    return 1;
  }

  @override
  Future<void> cancelHomeJoin(int ticket) {
    homeCancels++;
    return leaveRoom();
  }

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
      {bool fromHome = true, bool allowJoin = false}) async {
    late _LeaveRoom room;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        userProvider.overrideWith(_FixtureUser.new),
        syncPlayProvider.overrideWith((ref) {
          room = _LeaveRoom(ref);
          room.allowJoin = allowJoin;
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

  for (final status in [SyncPlayStatus.leaving, SyncPlayStatus.unknown]) {
    testWidgets(
        'background leave ${status.name} has no visible cleanup workflow',
        (tester) async {
      await panel(
          tester,
          SyncPlayViewState(
            leavePending: true,
            busy: true,
            room: SyncPlayControllerState(
              status: status,
              group: joined.room.group,
              failure:
                  const SyncPlayFailure(SyncPlayFailureCode.timeoutUnknown),
            ),
          ));
      expect(find.text('Retry leave'), findsNothing);
      expect(find.text('Confirm leave'), findsNothing);
      expect(find.textContaining('Server departure'), findsNothing);
      expect(find.textContaining('Notifying the server'), findsNothing);
      expect(find.text('Reconnect and check'), findsNothing);
      expect(find.text('Reset'), findsNothing);
      expect(find.text('Playing solo'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      expect(
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, 'Close'))
              .onPressed,
          isNotNull);
      expect(tester.takeException(), isNull);
      await panel(tester, const SyncPlayViewState());
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
      expect(
          tester
              .widget<FilledButton>(
                  find.byWidgetPredicate((w) => w is FilledButton))
              .onPressed,
          isNotNull);
    });
  }

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
    expect(find.text('Playing solo'), findsNothing);
    expect(find.byType(SelectableText), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty);
    expect(find.text('1 participants'), findsNothing);
    expect(find.byType(SyncPlayLocalBufferPanel), findsNothing);
    expect(find.byType(SyncPlayDiagnosticsPanel), findsNothing);
  });

  testWidgets('local leave clears a previously typed room code',
      (tester) async {
    await panel(tester, const SyncPlayViewState());
    await tester.enterText(find.byType(TextField), '654321');
    await tester.pump();
    await panel(tester, leavingUnknown);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty);
    expect(find.text('654321'), findsNothing);
    expect(find.byType(SelectableText), findsNothing);
    expect(tester.takeException(), isNull);
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
    expect(
        tester.widget<IconButton>(find.byType(IconButton)).onPressed, isNull);
    room.view(const SyncPlayViewState());
    await tester.pump();
    expect(tester.widget<IconButton>(find.byType(IconButton)).onPressed,
        isNotNull);
    expect(tester.takeException(), isNull);
  });

  for (final completion in ['pending', 'failed', 'throws']) {
    testWidgets(
        'one leave action dismisses immediately with $completion cleanup',
        (tester) async {
      final room = await openDialog(tester, joined);
      final gate = Completer<void>();
      room.leaveCompletion = gate.future;
      room.throwAfterDetach = completion == 'throws';
      await tester.ensureVisible(find.text('Leave room'));
      await tester.tap(find.text('Leave room'));
      await tester.pump();
      expect(room.leaves, 1);
      expect(room.pendingLeave, isTrue);
      expect(find.byType(SyncPlayDialog), findsNothing);
      expect(find.text('Playing solo'), findsOneWidget);
      if (completion == 'failed') {
        gate.completeError(StateError('Synthetic server cleanup failure'));
        await tester.pump();
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'unconfirmed creation offers one Leave without reconnect or retry',
      (tester) async {
    final room = await openDialog(
        tester,
        SyncPlayViewState(
          room: SyncPlayControllerState(
            status: SyncPlayStatus.disconnected,
            group: joined.room.group,
            failure:
                const SyncPlayFailure(SyncPlayFailureCode.creationUnconfirmed),
          ),
        ));
    expect(
        find.text(
            'Room creation is unconfirmed. Leave the room to return to solo playback.'),
        findsOneWidget);
    expect(find.text('Reconnect and check'), findsNothing);
    expect(find.text('Retry'), findsNothing);
    expect(find.textContaining('Reconnecting'), findsNothing);
    final leave = find.widgetWithText(TextButton, 'Leave room');
    expect(tester.widget<TextButton>(leave).onPressed, isNotNull);
    await tester.ensureVisible(leave);
    await tester.tap(leave);
    await tester.pump();
    expect(room.leaves, 1);
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

  testWidgets('leaving an owned home join never waits for cancellation cleanup',
      (tester) async {
    final room =
        await openDialog(tester, const SyncPlayViewState(), allowJoin: true);
    await tester.enterText(find.byType(TextField), '123456');
    await tester.pump();
    await tester.tap(find.text('Join room'));
    await tester.pump();
    room.leaveCompletion = Completer<void>().future;
    await tester.tap(find.text('Leave room'));
    await tester.pump();
    expect(room.homeCancels, 1);
    expect(room.leaves, 1);
    expect(find.byType(SyncPlayDialog), findsNothing);
    expect(tester.takeException(), isNull);
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

  testWidgets(
      'reopening after leave never offers a confirmation or retry workflow',
      (tester) async {
    final room = await openDialog(tester, joined);
    room.leaveCompletion = Completer<void>().future;
    await tester.tap(find.text('Leave room'));
    await tester.pump();
    expect(find.byType(SyncPlayDialog), findsNothing);
    await tester.tap(find.text('Open room'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(SyncPlayDialog), findsOneWidget);
    expect(find.text('Retry leave'), findsNothing);
    expect(find.text('Confirm leave'), findsNothing);
    expect(find.text('Reconnect and check'), findsNothing);
    expect(find.text('Reset'), findsNothing);
    expect(find.textContaining('Notifying the server'), findsNothing);
    expect(find.textContaining('Server departure'), findsNothing);
    expect(find.byType(SyncPlayLocalBufferPanel), findsNothing);
    expect(find.byType(SyncPlayDiagnosticsPanel), findsNothing);
    expect(room.confirmations, 0);
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
