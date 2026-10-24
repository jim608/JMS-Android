import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/focus_provider.dart';
import 'package:fladder/util/focus_helper.dart';
import 'package:fladder/util/input_detector.dart';

void main() {
  Future<void> pumpButton(
    WidgetTester tester, {
    required VoidCallback onTap,
    VoidCallback? onLongPress,
    FocusNode? focusNode,
    KeyEventResult Function(FocusNode, KeyEvent)? onParentKey,
  }) async {
    await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
      home: Scaffold(
        body: Focus(
          onKeyEvent: onParentKey,
          child: FocusButton(
            autoFocus: true,
            focusNode: focusNode,
            onTap: onTap,
            onLongPress: onLongPress,
            child:
                const SizedBox(width: 100, height: 60, child: Text('Select')),
          ),
        ),
      ),
    )));
    await tester.pumpAndSettle();
  }

  testWidgets('confirm is handled once on release without parent shortcut',
      (tester) async {
    var taps = 0;
    var bubbledKeys = 0;
    await pumpButton(tester,
        onTap: () => taps++,
        onParentKey: (_, event) {
          bubbledKeys++;
          return KeyEventResult.ignored;
        });
    await tester.sendKeyDownEvent(LogicalKeyboardKey.gameButtonA);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.gameButtonA);
    expect(taps, 0);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.gameButtonA);
    expect(taps, 1);
    expect(bubbledKeys, 0);
  });

  testWidgets(
      'holding confirm without a context action still selects on release',
      (tester) async {
    var taps = 0;
    await pumpButton(tester, onTap: () => taps++);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.gameButtonA);
    await tester.pump(const Duration(seconds: 1));
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.gameButtonA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.gameButtonA);
    expect(taps, 1);
  });

  testWidgets(
      'long confirm runs its context action once and does not also select',
      (tester) async {
    var taps = 0;
    var contexts = 0;
    await pumpButton(tester,
        onTap: () => taps++, onLongPress: () => contexts++);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.gameButtonA);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.gameButtonA);
    await tester.pump(const Duration(seconds: 1));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.gameButtonA);
    expect(contexts, 1);
    expect(taps, 0);
  });

  testWidgets('losing focus cancels a held confirm', (tester) async {
    final buttonFocus = FocusNode();
    addTearDown(buttonFocus.dispose);
    var taps = 0;
    await pumpButton(tester, onTap: () => taps++, focusNode: buttonFocus);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.gameButtonA);
    buttonFocus.unfocus();
    await tester.pump();
    buttonFocus.requestFocus();
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.gameButtonA);
    expect(taps, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
    expect(taps, 1);
  });

  testWidgets('an unrelated confirm release cannot activate a held key',
      (tester) async {
    var taps = 0;
    await pumpButton(tester, onTap: () => taps++);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.gameButtonA);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    expect(taps, 0);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.gameButtonA);
    expect(taps, 1);
  });

  testWidgets('focus navigation scrolls the selected card into view',
      (tester) async {
    final targetFocus = FocusNode();
    final controller = ScrollController();
    addTearDown(targetFocus.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 180,
          child: SingleChildScrollView(
            controller: controller,
            child: Column(children: [
              const SizedBox(height: 500),
              FocusButton(
                focusNode: targetFocus,
                onTap: () {},
                child: const SizedBox(height: 60, child: Text('Last card')),
              ),
            ]),
          ),
        ),
      ),
    )));
    targetFocus.requestFocus();
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(0));
    expect(
        tester.getRect(find.text('Last card')).bottom, lessThanOrEqualTo(180));
  });

  testWidgets('focus navigation also scrolls back to an earlier offscreen card',
      (tester) async {
    final targetFocus = FocusNode();
    final controller = ScrollController(initialScrollOffset: 400);
    addTearDown(targetFocus.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 180,
          child: SingleChildScrollView(
            controller: controller,
            child: Column(children: [
              FocusButton(
                focusNode: targetFocus,
                onTap: () {},
                child: const SizedBox(height: 60, child: Text('First card')),
              ),
              const SizedBox(height: 600),
            ]),
          ),
        ),
      ),
    )));
    targetFocus.requestFocus();
    await tester.pumpAndSettle();
    expect(controller.offset, 0);
    expect(
        tester.getRect(find.text('First card')).top, greaterThanOrEqualTo(0));
  });

  testWidgets('moving a mouse away keeps the controller focus outline visible',
      (tester) async {
    await pumpButton(tester, onTap: () {});
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(find.text('Select')));
    await tester.pumpAndSettle();
    await mouse.moveTo(const Offset(700, 500));
    await tester.pumpAndSettle();
    final focusButton =
        tester.state<FocusButtonState>(find.byType(FocusButton));
    expect(focusButton.focusNode.hasFocus, isTrue);
    final container = tester.widget<AnimatedContainer>(find.descendant(
        of: find.byType(FocusButton),
        matching: find.byType(AnimatedContainer)));
    final decoration = container.foregroundDecoration! as BoxDecoration;
    expect((decoration.border! as Border).top.width, 3.5);
    await mouse.removePointer();
  });

  testWidgets('focusing an already visible control does not recenter its list',
      (tester) async {
    final targetFocus = FocusNode();
    final controller = ScrollController();
    addTearDown(targetFocus.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 180,
          child: SingleChildScrollView(
            controller: controller,
            child: Column(children: [
              const SizedBox(height: 100),
              FocusButton(
                focusNode: targetFocus,
                onTap: () {},
                child: const SizedBox(height: 60, child: Text('Visible card')),
              ),
              const SizedBox(height: 600),
            ]),
          ),
        ),
      ),
    )));
    targetFocus.requestFocus();
    await tester.pumpAndSettle();
    expect(controller.offset, 0);
  });

  testWidgets('gamepad mode preserves the first touch and mouse activation',
      (tester) async {
    var taps = 0;
    InputDevice? mode;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InputDetector(
          isDesktop: false,
          htpcMode: false,
          child: (input) {
            mode = input;
            return TextButton(
              onPressed: () => taps++,
              child: const Text('Action'),
            );
          },
        ),
      ),
    ));
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonB);
    expect(InputDetector.activeInputDevice, InputDevice.dPad);
    await tester.pumpAndSettle();
    expect(mode, InputDevice.dPad);
    await tester.tap(find.text('Action'));
    await tester.pumpAndSettle();
    expect(mode, InputDevice.touch);
    expect(taps, 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonB);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Action'), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(mode, InputDevice.pointer);
    expect(taps, 2);
  });

  testWidgets('editing arrows retain text focus and touch mode',
      (tester) async {
    InputDevice? mode;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InputDetector(
          isDesktop: false,
          htpcMode: false,
          child: (input) {
            mode = input;
            return const TextField();
          },
        ),
      ),
    ));
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'JMS');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(mode, InputDevice.touch);
    expect(isEditableTextFocused(), isTrue);
  });

  testWidgets('keyboard arrows keep controller mode off', (tester) async {
    var modeBuilds = 0;
    await tester.pumpWidget(MaterialApp(
      home: InputDetector(
        isDesktop: true,
        htpcMode: false,
        child: (_) {
          modeBuilds++;
          return const SizedBox();
        },
      ),
    ));
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
    await tester.pump();
    expect(InputDetector.activeControllerMode, isTrue);
    final controllerBuilds = modeBuilds;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(InputDetector.activeInputDevice, InputDevice.dPad);
    expect(InputDetector.activeControllerMode, isFalse);
    await tester.pump();
    expect(modeBuilds, greaterThan(controllerBuilds));
  });

  testWidgets('native directional-pad arrow enables controller mode',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: InputDetector(
        isDesktop: false,
        htpcMode: false,
        child: (_) => const SizedBox(),
      ),
    ));
    for (final type in [ui.KeyEventType.down, ui.KeyEventType.up]) {
      tester.binding.platformDispatcher.onKeyData!(ui.KeyData(
        type: type,
        timeStamp: Duration.zero,
        logical: LogicalKeyboardKey.arrowRight.keyId,
        physical: PhysicalKeyboardKey.arrowRight.usbHidUsage,
        character: null,
        deviceType: ui.KeyEventDeviceType.directionalPad,
        synthesized: true,
      ));
    }
    expect(InputDetector.activeControllerMode, isTrue);
    await tester.pumpAndSettle();
  });

  testWidgets('explicit handheld mode enables mapped keyboard navigation',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: InputDetector(
        isDesktop: true,
        htpcMode: false,
        controllerMode: true,
        child: (_) => const SizedBox(),
      ),
    ));
    expect(InputDetector.activeControllerMode, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(InputDetector.activeControllerMode, isTrue);
    await tester.pumpAndSettle();
  });

  testWidgets('reduced motion reveals offscreen focus without an animation',
      (tester) async {
    final targetFocus = FocusNode();
    final controller = ScrollController();
    addTearDown(targetFocus.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Scaffold(
            body: SizedBox(
          height: 180,
          child: SingleChildScrollView(
            controller: controller,
            child: Column(children: [
              const SizedBox(height: 500),
              FocusButton(
                focusNode: targetFocus,
                onTap: () {},
                child:
                    const SizedBox(height: 60, child: Text('Reduced motion')),
              ),
            ]),
          ),
        )),
      ),
    )));
    targetFocus.requestFocus();
    await tester.pump();
    await tester.pump();
    expect(controller.offset, greaterThan(0));
    expect(controller.position.isScrollingNotifier.value, isFalse);
  });
}
