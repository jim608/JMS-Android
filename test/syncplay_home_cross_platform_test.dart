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

// Self-contained and browser-compatible: no dart:io, HTTP server, socket,
// persistent preferences, native player, or real account/profile is used.
final _fixtureAccount = AccountModel(
  name: 'Cross-platform fixture',
  id: '44444444444444444444444444444444',
  avatar: '',
  lastUsed: DateTime.utc(2026),
  credentials: CredentialsModel.internal(
    url: 'https://cross-platform.example.invalid',
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

final _fixtureGroup = SyncPlayGroup(
  groupId: '11111111111111111111111111111111',
  groupName: 'JMS-123456',
  participants: const ['Fixture'],
  lastUpdatedAt: DateTime.utc(2026),
);

class _FixtureUser extends User {
  @override
  AccountModel? build() => _fixtureAccount;
}

class _FixtureRoom extends SyncPlayNotifier {
  _FixtureRoom(super.ref);

  int refreshes = 0, joins = 0, cancellations = 0, leaves = 0, consumes = 0;
  int? _ticket;
  Completer<void>? departure;

  @override
  bool get supported => throw StateError('Home must not inspect a live player');
  @override
  bool get canJoinFromHome => true;
  @override
  bool get canJoin => true;
  @override
  bool get canCreate => false;
  @override
  bool get permissionKnown => true;
  @override
  Future<void> refreshPermission() async {
    refreshes++;
  }

  @override
  int? beginHomeJoin(String _) {
    _ticket = ++joins;
    state = const SyncPlayViewState(busy: true, preparingPlayback: true);
    return _ticket;
  }

  @override
  Future<void> cancelHomeJoin(int ticket) async {
    if (ticket != _ticket) return;
    _ticket = null;
    cancellations++;
    await departure?.future;
    state = const SyncPlayViewState();
  }

  @override
  Future<void> leaveRoom() async {
    leaves++;
  }

  @override
  bool consumeHomeJoin(int ticket) {
    if (_ticket != ticket || state.readyHomeJoin != ticket) return false;
    consumes++;
    _ticket = null;
    return true;
  }

  void showExistingRoom() {
    state = SyncPlayViewState(
        room: SyncPlayControllerState(
      status: SyncPlayStatus.joined,
      group: _fixtureGroup,
      connected: true,
      clockSynchronized: true,
    ));
  }

  void emitLateReady(int ticket) {
    state = SyncPlayViewState(
      readyHomeJoin: ticket,
      room: SyncPlayControllerState(
          status: SyncPlayStatus.joined, group: _fixtureGroup),
    );
  }
}

class _Harness {
  _Harness(this.container, this.room);
  final ProviderContainer container;
  final _FixtureRoom room;
  int playerInitializations = 0;
}

Future<_Harness> _mount(
  WidgetTester tester,
  TargetPlatform platform, {
  Size size = const Size(1280, 800),
  double textScale = 1,
  bool alreadyJoined = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  late _Harness harness;
  late _FixtureRoom room;
  final container = ProviderContainer(overrides: [
    userProvider.overrideWith(_FixtureUser.new),
    syncPlayProvider.overrideWith((ref) => room = _FixtureRoom(ref)),
    playBackModel.overrideWith((_) => null),
    videoPlayerProvider.overrideWith((_) {
      harness.playerInitializations++;
      throw StateError('This fixture must never initialize a player');
    }),
  ]);
  container.read(syncPlayProvider);
  harness = _Harness(container, room);
  addTearDown(container.dispose);
  if (alreadyJoined) room.showExistingRoom();
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      navigatorKey: navigator,
      navigatorObservers: [ControllerFocusObserver(enabled: () => true)],
      theme: ThemeData(platform: platform),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
          body: ControllerNavigation(
        onBack: () => navigator.currentState!.maybePop(),
        child: const Column(children: [
          SyncPlayHomeEntry(),
          Expanded(child: Center(child: Text('Fixture library'))),
        ]),
      )),
    ),
  ));
  await tester.pumpAndSettle();
  return harness;
}

Future<void> _openByTouch(WidgetTester tester) async {
  await tester.tap(find.text('Watch together'));
  await tester.pumpAndSettle();
  expect(find.byType(SyncPlayDialog), findsOneWidget);
}

Future<void> _joinByKeyboard(WidgetTester tester) async {
  for (var step = 0; step < 6; step++) {
    if (tester
        .widget<EditableText>(find.byType(EditableText))
        .focusNode
        .hasFocus) {
      break;
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
  }
  expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isTrue,
      reason: 'Tab traversal must reach the PIN input');
  await tester.enterText(find.byType(TextField), '123456');
  await tester.pump();
  await _tabTo(tester, 'Join room');
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pump();
  await tester.pump();
}

Future<void> _tabTo(WidgetTester tester, String label) async {
  final focusTrail = <String?>[];
  for (var step = 0; step < 6; step++) {
    if (Focus.of(tester.element(find.text(label))).hasFocus) return;
    focusTrail.add(FocusManager.instance.primaryFocus?.debugLabel);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
  }
  expect(Focus.of(tester.element(find.text(label))).hasFocus, isTrue,
      reason: 'Tab traversal must reach $label; focus labels: $focusTrail');
}

Future<void> _heldGamepad(WidgetTester tester, LogicalKeyboardKey logical,
    PhysicalKeyboardKey physical) async {
  // Android supplies Flutter's complete synthetic gamepad key map. The theme
  // and target-platform variant remain unchanged; this verifies the app's
  // logical input handling, not a real OS/driver's controller translation.
  await tester.sendKeyDownEvent(logical,
      platform: 'android', physicalKey: physical);
  await tester.sendKeyRepeatEvent(logical,
      platform: 'android', physicalKey: physical);
  await tester.sendKeyUpEvent(logical,
      platform: 'android', physicalKey: physical);
  await tester.pump();
}

void _platformTest(
        String name, TargetPlatform platform, WidgetTesterCallback callback) =>
    testWidgets(name, callback, variant: TargetPlatformVariant.only(platform));

void main() {
  const platforms = [
    TargetPlatform.android,
    TargetPlatform.windows,
    TargetPlatform.linux
  ];
  const viewports = <String, Size>{
    'narrow': Size(320, 568),
    'tablet': Size(800, 1280),
    'desktop': Size(1280, 800),
  };

  for (final platform in platforms) {
    for (final viewport in viewports.entries) {
      _platformTest(
          '${platform.name}/${viewport.key}: touch opens the home room dialog at 200% text without playback',
          platform, (tester) async {
        final fixture =
            await _mount(tester, platform, size: viewport.value, textScale: 2);
        expect(
            tester
                .getSize(
                    find.byWidgetPredicate((widget) => widget is FilledButton))
                .height,
            greaterThanOrEqualTo(48));
        await _openByTouch(tester);
        expect(
            tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
        expect(find.text('Create room with this video'), findsNothing);
        expect(fixture.container.read(playBackModel), isNull);
        expect(fixture.playerInitializations, 0);
        await tester.ensureVisible(find.text('Join room'));
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        expect(find.byType(SyncPlayDialog), findsNothing);
        expect(fixture.room.joins, 0);
      });
    }

    _platformTest(
        '${platform.name}: Tab reaches entry/PIN/Join, Enter and Space open once, Escape closes and cancels',
        platform, (tester) async {
      final fixture = await _mount(tester, platform);
      await _tabTo(tester, 'Watch together');
      expect(Focus.of(tester.element(find.text('Watch together'))).hasFocus,
          isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byType(SyncPlayDialog), findsOneWidget);
      await _tabTo(tester, 'Close');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(SyncPlayDialog), findsNothing);
      await _tabTo(tester, 'Watch together');
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(find.byType(SyncPlayDialog), findsOneWidget);
      expect(fixture.room.refreshes, 2);
      await _joinByKeyboard(tester);
      expect(fixture.room.joins, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(SyncPlayDialog), findsNothing);
      expect(fixture.playerInitializations, 0);
      expect(fixture.room.cancellations, 1);
    });

    _platformTest(
        '${platform.name}: held gamepad A opens once and held B cancels pending join before late ready',
        platform, (tester) async {
      final fixture = await _mount(tester, platform);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await _heldGamepad(tester, LogicalKeyboardKey.gameButtonA,
          PhysicalKeyboardKey.gameButtonA);
      await tester.pumpAndSettle();
      expect(find.byType(SyncPlayDialog), findsOneWidget);
      expect(fixture.room.refreshes, 1);
      await _joinByKeyboard(tester);
      expect(fixture.room.joins, 1);
      fixture.room.departure = Completer<void>();
      await _heldGamepad(tester, LogicalKeyboardKey.gameButtonB,
          PhysicalKeyboardKey.gameButtonB);
      await tester.pump();
      expect(fixture.room.cancellations, 1);
      fixture.room.emitLateReady(1);
      await tester.pump();
      expect(fixture.room.consumes, 0);
      expect(fixture.playerInitializations, 0);
      fixture.room.departure!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(SyncPlayDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });

    _platformTest(
        '${platform.name}: Escape cancels pending join with no playback or late navigation',
        platform, (tester) async {
      final fixture = await _mount(tester, platform);
      await _openByTouch(tester);
      await _joinByKeyboard(tester);
      expect(fixture.room.joins, 1);
      fixture.room.departure = Completer<void>();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(fixture.room.cancellations, 1);
      fixture.room.emitLateReady(1);
      await tester.pump();
      fixture.room.departure!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(SyncPlayDialog), findsNothing);
      expect(fixture.room.consumes, 0);
      expect(fixture.playerInitializations, 0);
    });

    _platformTest(
        '${platform.name}: closing an existing room panel neither rejoins nor leaves that room',
        platform, (tester) async {
      final fixture = await _mount(tester, platform, alreadyJoined: true);
      await _openByTouch(tester);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Leave room'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(SyncPlayDialog), findsNothing);
      expect(fixture.room.joins, 0);
      expect(fixture.room.leaves, 0);
      expect(fixture.room.cancellations, 0);
      expect(fixture.container.read(syncPlayProvider).room.isJoined, isTrue);
      expect(fixture.playerInitializations, 0);
    });
  }
}
