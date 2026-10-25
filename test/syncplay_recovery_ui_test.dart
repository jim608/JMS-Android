import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/providers/syncplay_provider.dart';
import 'package:fladder/screens/video_player/components/syncplay_dialog.dart';
import 'package:fladder/services/syncplay/syncplay_models.dart';

void main() {
  Future<void> panel(
    WidgetTester tester,
    SyncPlayViewState state, {
    Future<void> Function()? reconnect,
    Future<void> Function()? leave,
    TextScaler scale = TextScaler.noScaling,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: scale),
          child: Scaffold(
            body: SyncPlayRoomPanel(
              state: state,
              supported: true,
              canJoin: true,
              canCreate: true,
              createRoom: () async {},
              joinRoom: (_) async {},
              leaveRoom: leave ?? () async {},
              reconnect: reconnect ?? () async {},
              close: () async {},
            ),
          ),
        ),
      ),
    );
  }

  testWidgets(
    'automatic recovery hides transient manual warning and coalesces UI retry',
    (tester) async {
      await panel(
        tester,
        const SyncPlayViewState(
          recoveryActive: true,
          room: SyncPlayControllerState(
            status: SyncPlayStatus.unknown,
            failure: SyncPlayFailure(SyncPlayFailureCode.timeoutUnknown),
          ),
        ),
      );
      expect(find.text('Checking room connection…'), findsOneWidget);
      expect(find.textContaining('Confirmation timed out.'), findsNothing);
      expect(find.text('Create room with this video'), findsNothing);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Reconnect and check'),
            )
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('bounded recovery exhaustion keeps an honest manual retry', (
    tester,
  ) async {
    var calls = 0;
    await panel(
      tester,
      const SyncPlayViewState(
        recoveryExhausted: true,
        room: SyncPlayControllerState(status: SyncPlayStatus.unknown),
      ),
      reconnect: () async => calls++,
    );
    expect(find.text('Automatic reconnect paused.'), findsOneWidget);
    expect(find.text('Checking room connection…'), findsNothing);
    await tester.ensureVisible(find.text('Reconnect and check'));
    await tester.tap(find.text('Reconnect and check'));
    expect(calls, 1);
    expect(find.text('Create room with this video'), findsNothing);
  });

  testWidgets('automatic joining retains a usable leave cancellation', (
    tester,
  ) async {
    var leaves = 0;
    await panel(
      tester,
      SyncPlayViewState(
        recoveryActive: true,
        room: SyncPlayControllerState(
          status: SyncPlayStatus.joining,
          group: SyncPlayGroup(
            groupId: '00000000000000000000000000000001',
            groupName: 'JMS-123456',
            lastUpdatedAt: DateTime.utc(2026, 10, 25),
            participants: const ['synthetic'],
          ),
        ),
      ),
      leave: () async => leaves++,
    );
    expect(find.text('Checking room connection…'), findsOneWidget);
    final button = find.widgetWithText(TextButton, 'Leave room');
    expect(tester.widget<TextButton>(button).onPressed, isNotNull);
    await tester.ensureVisible(button);
    await tester.tap(button);
    expect(leaves, 1);
  });

  testWidgets(
    'terminal denial remains visible instead of pretending recovery',
    (tester) async {
      await panel(
        tester,
        const SyncPlayViewState(
          recoveryExhausted: true,
          room: SyncPlayControllerState(
            status: SyncPlayStatus.unknown,
            failure: SyncPlayFailure(SyncPlayFailureCode.denied),
          ),
        ),
      );
      expect(
        find.textContaining('The server denied the action.'),
        findsOneWidget,
      );
      expect(find.text('Checking room connection…'), findsNothing);
    },
  );

  testWidgets('recovery status wraps with large text on a narrow screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await panel(
      tester,
      const SyncPlayViewState(
        recoveryActive: true,
        room: SyncPlayControllerState(status: SyncPlayStatus.disconnected),
      ),
      scale: const TextScaler.linear(2),
    );
    expect(find.text('Checking room connection…'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
