import 'package:fladder/util/handheld_layout.dart';
import 'package:fladder/models/settings/arguments_model.dart';
import 'package:fladder/widgets/shared/controller_navigation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Steam Input keyboard mapping requires an explicit handheld launch flag',
      () {
    expect(ArgumentsModel.fromArguments([], '', false).handheldMode, isFalse);
    final handheld = ArgumentsModel.fromArguments([' --handheld '], '', false);
    expect(handheld.handheldMode, isTrue);
    expect(handheld.htpcMode, isFalse);
    expect(handheld.leanBackMode, isFalse);
    expect(ArgumentsModel.fromArguments([], '--handheld', false).handheldMode,
        isTrue);
  });
  test(
      'Deck logical viewports fit handheld layout without treating a TV or portrait phone as one',
      () {
    for (final size in [
      const Size(1280, 800),
      const Size(1280, 720),
      const Size(853, 533),
      const Size(640, 400)
    ]) {
      expect(isHandheldViewport(size), isTrue);
    }
    for (final size in [
      const Size(1920, 1080),
      const Size(400, 853),
      const Size(1280, 320)
    ]) {
      expect(isHandheldViewport(size), isFalse);
    }
    expect(handheldPosterSize(const Size(853, 533)),
        lessThan(handheldPosterSize(const Size(1280, 800))));
  });

  testWidgets(
      'controller activates Material buttons once and returns from dialog to its opener',
      (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    final opener = FocusNode();
    final observer = ControllerFocusObserver(enabled: () => true);
    addTearDown(opener.dispose);
    var opens = 0;
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigator,
      navigatorObservers: [observer],
      builder: (context, child) => ControllerNavigation(
        onBack: () {
          navigator.currentState!.maybePop();
        },
        child: child!,
      ),
      home: Scaffold(
          body: Builder(
              builder: (context) => Center(
                    child: FilledButton(
                      focusNode: opener,
                      onPressed: () {
                        opens++;
                        showDialog<void>(
                            context: context,
                            builder: (context) => AlertDialog(
                                  content: const Text('Playback menu'),
                                  actions: [
                                    TextButton(
                                        autofocus: true,
                                        onPressed: () {},
                                        child: const Text('Action'))
                                  ],
                                ));
                      },
                      child: const Text('Open menu'),
                    ),
                  ))),
    ));
    opener.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
    await tester.pumpAndSettle();
    expect(opens, 1);
    expect(find.text('Playback menu'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonB);
    await tester.pumpAndSettle();
    expect(find.text('Playback menu'), findsNothing);
    expect(opener.hasPrimaryFocus, isTrue);
    final buttonTheme =
        Theme.of(tester.element(find.text('Open menu'))).filledButtonTheme;
    expect(buttonTheme.style!.side!.resolve({WidgetState.focused})!.width, 2.5);
  });

  testWidgets(
      'direction navigation keeps offscreen dialog actions visible and Escape closes it',
      (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    final first = FocusNode();
    final scroll = ScrollController();
    addTearDown(first.dispose);
    addTearDown(scroll.dispose);
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigator,
      builder: (context, child) => ControllerNavigation(
        onBack: () {
          navigator.currentState!.maybePop();
        },
        child: child!,
      ),
      home: Scaffold(
          body: Builder(
              builder: (context) => TextButton(
                    onPressed: () => showDialog<void>(
                        context: context,
                        builder: (context) => AlertDialog(
                              content: SizedBox(
                                  height: 160,
                                  width: 300,
                                  child: SingleChildScrollView(
                                    controller: scroll,
                                    child: Column(
                                        children: List.generate(
                                            12,
                                            (index) => SizedBox(
                                                height: 60,
                                                child: TextButton(
                                                  focusNode:
                                                      index == 0 ? first : null,
                                                  autofocus: index == 0,
                                                  onPressed: () {},
                                                  child: Text('Track $index'),
                                                )))),
                                  )),
                            )),
                    child: const Text('Tracks'),
                  ))),
    ));
    await tester.tap(find.text('Tracks'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 5; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }
    expect(scroll.offset, greaterThan(0));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Track 0'), findsNothing);
  });
}
