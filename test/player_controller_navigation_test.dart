import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/models/settings/key_combinations.dart';
import 'package:fladder/screens/video_player/components/player_controller_navigation.dart';
import 'package:fladder/util/input_handler.dart';
import 'package:fladder/util/input_detector.dart';
import 'package:fladder/widgets/shared/controller_navigation.dart';

class _Harness extends StatefulWidget {
  const _Harness({required this.enabled, this.initiallyVisible = true, this.dialogClosesOnAccept = true, super.key});
  final bool enabled;
  final bool initiallyVisible;
  final bool dialogClosesOnAccept;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final play = FocusNode();
  final menu = FocusNode();
  late bool visible = widget.initiallyVisible;
  int plays = 0;
  int exits = 0;
  int menuOpens = 0;
  final shortcuts = <String>[];

  @override
  void dispose() {
    play.dispose();
    menu.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PlayerControllerNavigation(
        enabled: widget.enabled,
        controlsVisible: visible,
        primaryControl: play,
        showControls: () => setState(() => visible = true),
        hideControls: () => setState(() => visible = false),
        exitPlayer: () => exits++,
        child: InputHandler<String>(
          listenRawKeyboard: true,
          keyMap: {
            'seek': KeyCombination(key: LogicalKeyboardKey.arrowRight),
            'volume': KeyCombination(key: LogicalKeyboardKey.arrowUp),
            'play': KeyCombination(key: LogicalKeyboardKey.space),
          },
          keyMapResult: (key) {
            shortcuts.add(key);
            return true;
          },
          child: ExcludeFocus(
            excluding: !visible,
            child: Row(
              children: [
                IconButton(
                  focusNode: play,
                  onPressed: () => plays++,
                  icon: const Icon(Icons.play_arrow),
                ),
                IconButton(
                  focusNode: menu,
                  onPressed: () {
                    menuOpens++;
                    showDialog<void>(
                      context: context,
                      builder: (context) => AlertDialog(
                        content: TextButton(
                          autofocus: true,
                          onPressed: () {
                            if (widget.dialogClosesOnAccept) Navigator.of(context).pop();
                          },
                          child: const Text('Close menu'),
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.more_horiz),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

void main() {
  Future<_HarnessState> mount(WidgetTester tester,
      {bool enabled = true,
      bool visible = true,
      bool detected = false,
      bool isDesktop = true,
      bool rootNavigation = false,
      bool dialogClosesOnAccept = true}) async {
    final key = GlobalKey<_HarnessState>();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        navigatorKey: navigator,
        navigatorObservers: rootNavigation ? [ControllerFocusObserver(enabled: () => true)] : [],
        builder: rootNavigation
            ? (context, child) => ControllerNavigation(
                  onBack: () => navigator.currentState!.maybePop(),
                  child: child!,
                )
            : null,
        home: detected
            ? InputDetector(
                isDesktop: isDesktop,
                htpcMode: false,
                child: (input) => _Harness(
                  key: key,
                  enabled: InputDetector.activeControllerMode ?? false,
                  initiallyVisible: visible,
                ),
              )
            : _Harness(
                key: key,
                enabled: enabled,
                initiallyVisible: visible,
                dialogClosesOnAccept: dialogClosesOnAccept,
              ),
      ),
    ));
    await tester.pumpAndSettle();
    return key.currentState!;
  }

  testWidgets('controller directions focus controls without seeking; keyboard hotkeys still work', (tester) async {
    final state = await mount(tester);
    expect(state.play.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(state.menu.hasPrimaryFocus, isTrue);
    expect(state.shortcuts, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(state.shortcuts, ['play']);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
    expect(state.plays, 1);
  });

  for (final acceptKey in [LogicalKeyboardKey.gameButtonA, LogicalKeyboardKey.select, LogicalKeyboardKey.enter]) {
    testWidgets('hidden controls wake first with ${acceptKey.keyLabel} and Back hides before exiting', (tester) async {
      final state = await mount(tester, visible: false);
      await tester.sendKeyEvent(acceptKey);
      await tester.pumpAndSettle();
      expect(state.visible, isTrue);
      expect(state.plays, 0);
      expect(state.play.hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(acceptKey);
      expect(state.plays, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonB);
      await tester.pump();
      expect(state.visible, isFalse);
      expect(state.exits, 0);
      expect(state.play.canRequestFocus, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonB);
      expect(state.exits, 1);
    });
  }

  testWidgets('dialog focus is isolated and returns to the menu opener', (tester) async {
    final state = await mount(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
    await tester.pumpAndSettle();
    expect(find.text('Close menu'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Close menu'), findsNothing);
    expect(state.visible, isTrue);
    expect(state.menu.hasPrimaryFocus, isTrue);
    expect(state.exits, 0);
  });

  testWidgets('pointer mode retains existing arrow shortcuts', (tester) async {
    final state = await mount(tester, enabled: false);
    state.play.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(state.shortcuts, ['seek']);
  });

  for (final acceptKey in [LogicalKeyboardKey.gameButtonA, LogicalKeyboardKey.select, LogicalKeyboardKey.enter]) {
    testWidgets('dialog accept press cannot reactivate its player opener on ${acceptKey.keyLabel} release',
        (tester) async {
      final state = await mount(tester, rootNavigation: true);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(acceptKey);
      await tester.pumpAndSettle();
      expect(state.menuOpens, 1);
      expect(find.text('Close menu'), findsOneWidget);

      // The app-level controller shortcut activates the focused dialog button
      // on press. Its release reaches the restored player menu opener.
      await tester.sendKeyDownEvent(acceptKey);
      await tester.pumpAndSettle();
      expect(find.text('Close menu'), findsNothing);
      expect(state.menu.hasPrimaryFocus, isTrue);
      await tester.sendKeyUpEvent(acceptKey);
      await tester.pumpAndSettle();
      expect(find.text('Close menu'), findsNothing);
      expect(state.menuOpens, 1);
      expect(state.plays, 0);
      expect(state.exits, 0);
    });
  }

  testWidgets('Back from dialog clears a held accept before player focus returns', (tester) async {
    final state = await mount(tester, rootNavigation: true, dialogClosesOnAccept: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
    await tester.pumpAndSettle();
    expect(find.text('Close menu'), findsOneWidget);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.gameButtonA);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonB);
    await tester.pumpAndSettle();
    expect(find.text('Close menu'), findsNothing);
    expect(state.menu.hasPrimaryFocus, isTrue);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.gameButtonA);
    await tester.pumpAndSettle();
    expect(find.text('Close menu'), findsNothing);
    expect(state.menuOpens, 1);
    expect(state.visible, isTrue);
    expect(state.exits, 0);
  });

  testWidgets('leaving and restoring the same player focus cancels its pending accept', (tester) async {
    final state = await mount(tester, rootNavigation: true);
    state.menu.requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.gameButtonA);
    // Open another route while the original control's accept is still held.
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    expect(find.text('Close menu'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonB);
    await tester.pumpAndSettle();
    expect(state.menu.hasPrimaryFocus, isTrue);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.gameButtonA);
    await tester.pumpAndSettle();
    expect(find.text('Close menu'), findsNothing);
    expect(state.menuOpens, 1);
  });

  for (final isDesktop in [true, false]) {
    testWidgets('first physical dpad arrow from ${isDesktop ? "pointer" : "touch"} focuses without seeking',
        (tester) async {
      final state = await mount(tester, enabled: false, detected: true, isDesktop: isDesktop);
      state.play.requestFocus();
      await tester.pump();
      // The SDK's sendKeyDownEvent models a keyboard and cannot specify a
      // controller device type. Dispatch through HardwareKeyboard here to
      // exercise device detection and raw playback handlers in their order.
      HardwareKeyboard.instance.handleKeyEvent(const KeyDownEvent(
        logicalKey: LogicalKeyboardKey.arrowRight,
        physicalKey: PhysicalKeyboardKey.arrowRight,
        timeStamp: Duration.zero,
        deviceType: ui.KeyEventDeviceType.directionalPad,
      ));
      expect(InputDetector.activeControllerMode, isTrue);
      expect(state.shortcuts, isEmpty);
      await tester.pump();
      HardwareKeyboard.instance.handleKeyEvent(const KeyUpEvent(
        logicalKey: LogicalKeyboardKey.arrowRight,
        physicalKey: PhysicalKeyboardKey.arrowRight,
        timeStamp: Duration.zero,
        deviceType: ui.KeyEventDeviceType.directionalPad,
      ));
      await tester.pump();
      expect(state.play.hasPrimaryFocus, isTrue);
      expect(state.shortcuts, isEmpty);
    });

    testWidgets('ordinary keyboard arrows retain seek and volume with ${isDesktop ? "desktop" : "touch"} detector',
        (tester) async {
      final state = await mount(tester, enabled: false, detected: true, isDesktop: isDesktop);
      state.play.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(InputDetector.activeControllerMode, isFalse);
      expect(state.shortcuts, ['seek', 'volume']);
    });
  }
}
