import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/models/settings/key_combinations.dart';
import 'package:fladder/util/input_handler.dart';

Future<void> _pumpInputHandler(
  WidgetTester tester, {
  required List<KeyEvent> customEvents,
  required VoidCallback onMappedKey,
  bool ignoreWhenTextFieldFocused = true,
  bool listenRawKeyboard = false,
  VoidCallback? onEscape,
}) async {
  await tester.pumpWidget(ProviderScope(
    child: MaterialApp(
      home: Scaffold(
        body: InputHandler<String>(
          ignoreWhenTextFieldFocused: ignoreWhenTextFieldFocused,
          listenRawKeyboard: listenRawKeyboard,
          onKeyEvent: (_, event) {
            customEvents.add(event);
            return KeyEventResult.ignored;
          },
          keyMap: {'action': KeyCombination(key: LogicalKeyboardKey.f1)},
          keyMapResult: (_) {
            onMappedKey();
            return true;
          },
          child: Focus(
            onKeyEvent: (_, event) {
              if (onEscape != null &&
                  event is KeyDownEvent &&
                  event.logicalKey == LogicalKeyboardKey.escape) {
                onEscape();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: TextField(
              key: const Key('offset-input'),
              // Keep focus after Enter so subsequent key-up events are editing.
              onEditingComplete: () {},
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  for (final raw in [false, true]) {
    testWidgets('releasing a modifier inside a boundary clears raw=$raw state',
        (tester) async {
      final outsideFocus = FocusNode();
      final insideFocus = FocusNode();
      addTearDown(outsideFocus.dispose);
      addTearDown(insideFocus.dispose);
      var mapped = 0;
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          home: InputHandler<String>(
            listenRawKeyboard: raw,
            keyMap: {
              'action': KeyCombination(
                  key: LogicalKeyboardKey.f1,
                  modifier: LogicalKeyboardKey.controlLeft),
            },
            keyMapResult: (_) {
              mapped++;
              return true;
            },
            child: Column(children: [
              Focus(focusNode: outsideFocus, child: const SizedBox(height: 20)),
              PlayerShortcutBoundary(
                child: Focus(
                    focusNode: insideFocus, child: const SizedBox(height: 20)),
              ),
            ]),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      outsideFocus.requestFocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);

      insideFocus.requestFocus();
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      outsideFocus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.f1);
      expect(mapped, 0);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.f1);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(mapped, 1);
    });
  }

  testWidgets('a local slider boundary blocks raw and normal player keys',
      (tester) async {
    final sliderFocus = FocusNode();
    addTearDown(sliderFocus.dispose);
    var sliderValue = 0.5;
    var sliderChanges = 0;
    var rawMapped = 0;
    var normalMapped = 0;
    var customEvents = 0;
    var closed = 0;
    final keys = {
      'left': KeyCombination(key: LogicalKeyboardKey.arrowLeft),
      'right': KeyCombination(key: LogicalKeyboardKey.arrowRight),
      'screenshot': KeyCombination(key: LogicalKeyboardKey.f1),
    };
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: InputHandler<String>(
            // Explicit editable opt-out does not bypass a local control scope.
            ignoreWhenTextFieldFocused: false,
            onKeyEvent: (_, event) {
              customEvents++;
              return KeyEventResult.ignored;
            },
            keyMap: keys,
            keyMapResult: (_) {
              normalMapped++;
              return true;
            },
            child: InputHandler<String>(
              listenRawKeyboard: true,
              ignoreWhenTextFieldFocused: false,
              keyMap: keys,
              keyMapResult: (_) {
                rawMapped++;
                return true;
              },
              child: PlayerShortcutBoundary(
                child: FocusScope(
                  autofocus: true,
                  child: Focus(
                    onKeyEvent: (_, event) {
                      if (event is KeyDownEvent &&
                          event.logicalKey == LogicalKeyboardKey.escape) {
                        closed++;
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                    child: StatefulBuilder(builder: (context, setState) {
                      return Slider(
                        focusNode: sliderFocus,
                        value: sliderValue,
                        divisions: 100,
                        onChanged: (value) => setState(() {
                          sliderValue = value;
                          sliderChanges++;
                        }),
                      );
                    }),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    sliderFocus.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(sliderValue, greaterThan(0.5));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(sliderValue, closeTo(0.5, 0.0001));
    expect(sliderChanges, 2);

    await tester.sendKeyEvent(LogicalKeyboardKey.f1);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(closed, 1);
    expect(rawMapped, 0);
    expect(normalMapped, 0);
    expect(customEvents, 0);
    expect(sliderFocus.hasFocus, isTrue);
  });

  testWidgets('editing numeric offsets bypasses custom and mapped shortcuts',
      (tester) async {
    final events = <KeyEvent>[];
    var mapped = 0;
    await _pumpInputHandler(tester,
        customEvents: events, onMappedKey: () => mapped++);
    await tester.tap(find.byKey(const Key('offset-input')));
    await tester.enterText(find.byType(TextField), '-0.05');
    await tester.pump();

    for (final key in [
      LogicalKeyboardKey.minus,
      LogicalKeyboardKey.period,
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.space,
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.f1,
    ]) {
      await tester.sendKeyDownEvent(key);
      await tester.sendKeyUpEvent(key);
    }
    await tester.pump();

    expect(events, isEmpty);
    expect(mapped, 0);
    expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .focusNode
            .hasFocus,
        isTrue);
    expect(tester.testTextInput.hasAnyClients, isTrue);
  });

  testWidgets('explicit editing shortcut opt-out still receives down and up',
      (tester) async {
    final events = <KeyEvent>[];
    var mapped = 0;
    await _pumpInputHandler(tester,
        customEvents: events,
        onMappedKey: () => mapped++,
        ignoreWhenTextFieldFocused: false);
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.f1);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.f1);

    expect(events.whereType<KeyDownEvent>(), hasLength(1));
    expect(events.whereType<KeyUpEvent>(), hasLength(1));
    expect(mapped, 1);
  });

  testWidgets('normal shortcuts still work without an editable focus',
      (tester) async {
    final events = <KeyEvent>[];
    var mapped = 0;
    await _pumpInputHandler(tester,
        customEvents: events, onMappedKey: () => mapped++);
    await tester.sendKeyEvent(LogicalKeyboardKey.f1);

    expect(events.whereType<KeyDownEvent>(), hasLength(1));
    expect(events.whereType<KeyUpEvent>(), hasLength(1));
    expect(mapped, 1);
  });

  testWidgets('raw shortcuts keep ignoring editable focus', (tester) async {
    final events = <KeyEvent>[];
    var mapped = 0;
    await _pumpInputHandler(tester,
        customEvents: events,
        onMappedKey: () => mapped++,
        listenRawKeyboard: true);
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.f1);

    expect(events, isEmpty);
    expect(mapped, 0);
  });

  testWidgets('raw editable opt-out still works outside a local boundary',
      (tester) async {
    final events = <KeyEvent>[];
    var mapped = 0;
    await _pumpInputHandler(tester,
        customEvents: events,
        onMappedKey: () => mapped++,
        listenRawKeyboard: true,
        ignoreWhenTextFieldFocused: false);
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.f1);

    expect(mapped, 1);
    expect(events, isEmpty);
  });

  testWidgets('a descendant overlay can still handle Escape while editing',
      (tester) async {
    final events = <KeyEvent>[];
    var mapped = 0;
    var closed = 0;
    await _pumpInputHandler(tester,
        customEvents: events,
        onMappedKey: () => mapped++,
        onEscape: () => closed++);
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);

    expect(closed, 1);
    expect(events, isEmpty);
    expect(mapped, 0);
  });
}
