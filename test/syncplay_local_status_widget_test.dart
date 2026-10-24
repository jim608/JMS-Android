import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/providers/syncplay_provider.dart';
import 'package:fladder/screens/video_player/components/syncplay_dialog.dart';
import 'package:fladder/services/syncplay/syncplay_models.dart';
import 'package:fladder/services/syncplay/syncplay_prebuffer.dart';

SyncPlayPrebufferDecision _decision(
        {SyncPlayPrebufferStatus status = SyncPlayPrebufferStatus.needsBuffer,
        Duration? ahead = const Duration(seconds: 3),
        Duration target = const Duration(seconds: 30),
        bool limited = false}) =>
    SyncPlayPrebufferDecision(
        status: status,
        ready: status == SyncPlayPrebufferStatus.ready ||
            status == SyncPlayPrebufferStatus.fallbackReady,
        needsBuffer: status == SyncPlayPrebufferStatus.needsBuffer,
        timedOut: status == SyncPlayPrebufferStatus.timedOut,
        target: target,
        waited: Duration.zero,
        ahead: ahead,
        deliveryRate: null,
        byteBudgetLimited: limited);

void main() {
  Future<void> show(WidgetTester tester, Widget child,
      {Locale locale = const Locale('en'),
      double scale = 1,
      bool settle = true}) async {
    await tester.pumpWidget(MaterialApp(
        locale: locale,
        supportedLocales: const [Locale('en'), Locale('zh')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Scaffold(body: child))));
    if (settle) await tester.pumpAndSettle();
  }

  testWidgets(
      'local measured ahead and target remain distinct and visible without opening diagnostics',
      (tester) async {
    await show(
        tester,
        SyncPlayLocalBufferPanel(
            room: const SyncPlayControllerState(mediaReady: false),
            prebuffer: _decision()));
    expect(find.text('Prebuffering on this player…'), findsOneWidget);
    expect(find.text('Ahead on this player: 3.0 s · target 30.0 s'),
        findsOneWidget);
    expect(find.byType(ExpansionTile), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'unknown fallback and stale measurements never resurrect old buffered seconds',
      (tester) async {
    for (final status in [
      SyncPlayPrebufferStatus.fallbackReady,
      SyncPlayPrebufferStatus.stale
    ]) {
      await show(
          tester,
          SyncPlayLocalBufferPanel(
              room: const SyncPlayControllerState(
                  bufferedAhead: Duration(seconds: 99), mediaReady: true),
              prebuffer: _decision(status: status, ahead: null)));
      expect(find.text('Ahead on this player: Unknown · target 30.0 s'),
          findsOneWidget);
      expect(find.textContaining('99.0'), findsNothing);
      expect(find.textContaining('30.0 s'), findsOneWidget);
    }
    expect(find.textContaining('out of date'), findsOneWidget);
  });
  testWidgets(
      'catchup and independent waiting describe this device without naming a slow peer',
      (tester) async {
    for (final mode in [
      SyncPlayWaitParticipation.ignoring,
      SyncPlayWaitParticipation.ignored,
      SyncPlayWaitParticipation.recovering,
      SyncPlayWaitParticipation.ignoredRecovered,
      SyncPlayWaitParticipation.unsupported,
      SyncPlayWaitParticipation.uncertain
    ]) {
      await show(
          tester,
          SyncPlayLocalBufferPanel(
              room: SyncPlayControllerState(waitParticipation: mode)));
      final text = tester
          .widget<Text>(find.byKey(const ValueKey('syncplay-local-status')))
          .data!;
      expect(text, isNotEmpty);
      expect(text.contains('peer'), isFalse);
      expect(text.contains('slow'), isFalse);
      expect(find.byType(TextButton), findsNothing);
    }
  });
  testWidgets('preparation, timeout and byte budget adjustments are explicit',
      (tester) async {
    await show(
        tester,
        SyncPlayLocalBufferPanel(
            room: const SyncPlayControllerState(),
            prebuffer: _decision(
                status: SyncPlayPrebufferStatus.preparing, limited: true)));
    expect(find.text('Preparing this player…'), findsOneWidget);
    expect(find.text('Target adjusted to the local cache budget.'),
        findsOneWidget);
    expect(find.textContaining('Prebuffering'), findsNothing);
    await show(
        tester,
        SyncPlayLocalBufferPanel(
            room: const SyncPlayControllerState(),
            prebuffer: _decision(status: SyncPlayPrebufferStatus.timedOut)));
    expect(find.textContaining('waiting reached its limit'), findsOneWidget);
  });
  testWidgets(
      'Traditional Chinese states keep unknown amount separate from a configured target',
      (tester) async {
    await show(
        tester,
        SyncPlayLocalBufferPanel(
            room: const SyncPlayControllerState(),
            prebuffer: _decision(
                status: SyncPlayPrebufferStatus.fallbackReady, ahead: null)),
        locale: const Locale('zh'));
    expect(find.text('本機可跟隨播放；緩衝量仍未知。'), findsOneWidget);
    expect(find.text('本機可播放緩衝：未知 · 目標 30.0 秒'), findsOneWidget);
  });
  testWidgets(
      'unconfirmed room status replaces connected assurance while existing close and leave work',
      (tester) async {
    var closed = 0, left = 0;
    await show(
        tester,
        SyncPlayRoomPanel(
            state: SyncPlayViewState(
                room: SyncPlayControllerState(
                    status: SyncPlayStatus.joined,
                    connected: true,
                    clockSynchronized: true,
                    membershipFreshness: SyncPlayMembershipFreshness.stale,
                    group: SyncPlayGroup(
                        groupId: '00000000000000000000000000000001',
                        groupName: 'JMS-123456',
                        lastUpdatedAt: DateTime.utc(2026, 10, 24),
                        participants: const ['Fixture']))),
            supported: true,
            canJoin: true,
            canCreate: true,
            createRoom: () async {},
            joinRoom: (_) async {},
            leaveRoom: () async {
              left++;
            },
            reconnect: () async {},
            close: () async {
              closed++;
            }));
    expect(find.textContaining('confirmation is out of date'), findsOneWidget);
    expect(
        find.text(
            'Connected. Playback controls are synchronized with the room.'),
        findsNothing);
    await tester.tap(find.text('Close'));
    await tester.pump();
    expect(closed, 1);
    await tester.tap(find.text('Leave room'));
    await tester.pump();
    expect(left, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'local status wraps at phone and handheld sizes with large text without extra focus stops',
      (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final size in [const Size(390, 844), const Size(853, 533)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await show(
          tester,
          SyncPlayLocalBufferPanel(
              room: const SyncPlayControllerState(
                  waitParticipation: SyncPlayWaitParticipation.ignored),
              prebuffer: _decision(limited: true)),
          scale: 2);
      expect(find.byType(ButtonStyleButton), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
      'Home pending cancellation keeps focus and errors while local status is visible',
      (tester) async {
    var cancelled = 0;
    await show(
        tester,
        SyncPlayRoomPanel(
            state: SyncPlayViewState(
                busy: true,
                preparingPlayback: true,
                failure: const SyncPlayFailure(SyncPlayFailureCode.player),
                prebuffer: _decision(
                    status: SyncPlayPrebufferStatus.unknown, ahead: null),
                room: SyncPlayControllerState(
                    status: SyncPlayStatus.joined,
                    group: SyncPlayGroup(
                        groupId: '00000000000000000000000000000001',
                        groupName: 'JMS-123456',
                        lastUpdatedAt: DateTime.utc(2026, 10, 24)))),
            joinFromHome: true,
            supported: true,
            canJoin: true,
            canCreate: false,
            createRoom: () async {},
            joinRoom: (_) async {},
            leaveRoom: () async {},
            reconnect: () async {},
            close: () async {
              cancelled++;
            }),
        settle: false);
    await tester.pump();
    expect(find.text('Local buffer measurements are not available yet…'),
        findsOneWidget);
    expect(
        find.textContaining('Unable to load the room video'), findsOneWidget);
    final cancel =
        tester.widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'));
    expect(cancel.onPressed, isNotNull);
    expect(cancel.focusNode!.hasFocus, isTrue);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(cancelled, 1);
  });

  testWidgets(
      'full room dialog keeps actions usable with long local status at handheld dimensions',
      (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final size in [const Size(390, 844), const Size(853, 533)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      var closed = 0;
      await show(
          tester,
          SyncPlayRoomPanel(
              state: SyncPlayViewState(
                  prebuffer: _decision(limited: true),
                  room: SyncPlayControllerState(
                      status: SyncPlayStatus.joined,
                      waitParticipation: SyncPlayWaitParticipation.ignored,
                      group: SyncPlayGroup(
                          groupId: '00000000000000000000000000000001',
                          groupName: 'JMS-123456',
                          lastUpdatedAt: DateTime.utc(2026, 10, 24)))),
              supported: true,
              canJoin: true,
              canCreate: true,
              createRoom: () async {},
              joinRoom: (_) async {},
              leaveRoom: () async {},
              reconnect: () async {},
              close: () async {
                closed++;
              }),
          scale: 2);
      await tester
          .ensureVisible(find.byKey(const ValueKey('syncplay-local-status')));
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Close'));
      await tester.pump();
      expect(closed, 1);
      expect(tester.takeException(), isNull);
    }
  });
}
