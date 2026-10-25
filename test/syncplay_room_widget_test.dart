import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/providers/syncplay_provider.dart';
import 'package:fladder/screens/video_player/components/syncplay_dialog.dart';
import 'package:fladder/services/syncplay/syncplay_models.dart';

void main() {
  Future<void> showPanel(
    WidgetTester tester, {
    SyncPlayViewState state = const SyncPlayViewState(),
    bool canJoin = true,
    bool canCreate = true,
    bool supported = true,
    bool checkingPermission = false,
    bool permissionKnown = true,
    Future<void> Function(String)? join,
    Future<void> Function()? create,
    Future<void> Function()? reconnect,
    TextScaler scaler = TextScaler.noScaling,
  }) =>
      tester.pumpWidget(MaterialApp(
          home: MediaQuery(
        data: MediaQueryData(textScaler: scaler),
        child: Scaffold(
            body: SyncPlayRoomPanel(
          state: state,
          supported: supported,
          checkingPermission: checkingPermission,
          permissionKnown: permissionKnown,
          canJoin: canJoin,
          canCreate: canCreate,
          createRoom: create ?? () async {},
          joinRoom: join ?? (_) async {},
          leaveRoom: () async {},
          reconnect: reconnect ?? () async {},
        )),
      )));

  testWidgets(
      'joining requires exactly six digits; input never treats code as an account credential',
      (tester) async {
    final codes = <String>[];
    await showPanel(tester, join: (code) async => codes.add(code));
    await tester.enterText(find.byType(TextField), '12');
    await tester.pump();
    expect(
        tester
            .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, 'Join room'))
            .onPressed,
        isNull);
    await tester.enterText(find.byType(TextField), 'a1234567');
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '123456');
    await tester.ensureVisible(find.text('Join room'));
    await tester.tap(find.text('Join room'));
    await tester.pump();
    expect(codes, ['123456']);
    expect(find.textContaining('not a password'), findsNothing);
    await tester.tap(find.byTooltip('Room information'));
    await tester.pumpAndSettle();
    expect(find.textContaining('not a password'), findsOneWidget);
  });

  testWidgets(
      'diagnostics are collapsed, signed and describe local estimates only',
      (tester) async {
    const d = SyncPlayDiagnostics(
      networkRoundTrip: Duration(microseconds: 81250),
      clockOffset: Duration(milliseconds: -20),
      playbackDrift: Duration(milliseconds: 750),
      correctionCount: 1,
    );
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: SyncPlayDiagnosticsPanel(diagnostics: d)),
    ));
    expect(
        tester
            .widget<ExpansionTile>(find.byType(ExpansionTile))
            .initiallyExpanded,
        isFalse);
    expect(find.text('Local playback drift: +750.0 ms'), findsNothing);
    await tester.tap(find.text('Sync diagnostics'));
    await tester.pumpAndSettle();
    expect(find.text('Estimated network round trip: 81.3 ms'), findsOneWidget);
    expect(find.text('Server clock offset: -20.0 ms'), findsOneWidget);
    expect(find.text('Local playback drift: +750.0 ms'), findsOneWidget);
    expect(find.textContaining('not a measured difference between friends'),
        findsOneWidget);
    expect(find.textContaining('not uploaded'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'diagnostics have no zero-error claim when samples are unavailable',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
          body: SyncPlayDiagnosticsPanel(diagnostics: SyncPlayDiagnostics())),
    ));
    await tester.tap(find.text('Sync diagnostics'));
    await tester.pumpAndSettle();
    expect(
        find.text('Local playback drift: No current sample'), findsOneWidget);
    expect(find.text('Estimated network round trip: No current sample'),
        findsOneWidget);
    expect(find.textContaining('0.0 ms'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('expanded diagnostics wrap on a narrow screen with large text',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await showPanel(
      tester,
      scaler: const TextScaler.linear(2),
      state: SyncPlayViewState(
          room: SyncPlayControllerState(
        status: SyncPlayStatus.joined,
        group: SyncPlayGroup(
          groupId: '00000000000000000000000000000001',
          groupName: 'JMS-123456',
          lastUpdatedAt: DateTime.utc(2026, 10, 24),
          participants: const ['synthetic'],
        ),
      )),
    );
    await tester.ensureVisible(find.text('Sync diagnostics'));
    await tester.tap(find.text('Sync diagnostics'));
    await tester.pumpAndSettle();
    expect(find.textContaining('not uploaded'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('permission gating disables both creation and joining',
      (tester) async {
    var calls = 0;
    await showPanel(tester,
        canJoin: false, canCreate: false, create: () async => calls++);
    expect(find.textContaining('administrator'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(
                find.byWidgetPredicate((widget) => widget is FilledButton))
            .onPressed,
        isNull);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    expect(calls, 0);
  });

  testWidgets(
      'checking and unknown permissions are not displayed as a server denial',
      (tester) async {
    await showPanel(tester, checkingPermission: true, permissionKnown: false);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.textContaining('administrator'), findsNothing);
    expect(
        tester
            .widget<FilledButton>(
                find.byWidgetPredicate((widget) => widget is FilledButton))
            .onPressed,
        isNull);
    await showPanel(tester, permissionKnown: false);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.textContaining('Unable to confirm SyncPlay permission'),
        findsOneWidget);
    expect(find.textContaining('administrator'), findsNothing);
    expect(
        tester
            .widget<FilledButton>(
                find.byWidgetPredicate((widget) => widget is FilledButton))
            .onPressed,
        isNull);
  });

  testWidgets('join-only account cannot create a room', (tester) async {
    await showPanel(tester, canCreate: false);
    expect(find.textContaining('cannot create'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(
                find.byWidgetPredicate((widget) => widget is FilledButton))
            .onPressed,
        isNull);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
  });

  testWidgets('pending confirmation blocks duplicate room actions',
      (tester) async {
    await showPanel(tester,
        state: const SyncPlayViewState(
          room: SyncPlayControllerState(status: SyncPlayStatus.joining),
          busy: true,
        ));
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(
                find.byWidgetPredicate((widget) => widget is FilledButton))
            .onPressed,
        isNull);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
  });

  testWidgets(
      'unknown membership offers reconciliation instead of another create',
      (tester) async {
    var reconnects = 0;
    await showPanel(tester,
        state: const SyncPlayViewState(
          room: SyncPlayControllerState(status: SyncPlayStatus.unknown),
        ),
        reconnect: () async => reconnects++);
    expect(find.byWidgetPredicate((widget) => widget is FilledButton),
        findsNothing);
    expect(find.byType(TextField), findsNothing);
    await tester.ensureVisible(find.text('Reconnect and check'));
    await tester.tap(find.text('Reconnect and check'));
    expect(reconnects, 1);
  });

  for (final size in [const Size(320, 568), const Size(640, 360)]) {
    testWidgets('joined room remains usable with large text at $size',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final group = SyncPlayGroup(
        groupId: '11111111111111111111111111111111',
        groupName: 'JMS-123456',
        lastUpdatedAt: DateTime.utc(2026),
        participants: ['Alice', 'Bob'],
      );
      await showPanel(tester,
          state: SyncPlayViewState(
              room: SyncPlayControllerState(
            status: SyncPlayStatus.joined,
            group: group,
            connected: true,
            clockSynchronized: true,
          )),
          scaler: const TextScaler.linear(2));
      await tester.pump();
      expect(find.text('123456'), findsOneWidget);
      expect(find.text('2 participants'), findsOneWidget);
      expect(find.text('Leave room'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
