import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/l10n/generated/app_localizations.dart';
import 'package:fladder/models/items/chapters_model.dart';
import 'package:fladder/screens/video_player/components/chapter_navigation_controls.dart';

Chapter _chapter(int seconds) => Chapter(
      name: 'Chapter $seconds',
      imageUrl: '',
      startPosition: Duration(seconds: seconds),
    );

void main() {
  Future<void> mount(
    WidgetTester tester, {
    required List<Chapter> chapters,
    int position = 0,
    bool controllerMode = false,
    VoidCallback? previous,
    VoidCallback? next,
    double textScale = 1,
  }) =>
      tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
            child: ChapterNavigationButtons(
              navigation: chapters.navigationAt(Duration(seconds: position),
                  duration: const Duration(minutes: 2)),
              controllerMode: controllerMode,
              onPrevious: previous ?? () {},
              onNext: next ?? () {},
            ),
          ),
        ),
      ));

  testWidgets(
      'missing or invalid chapters hide both controls and controller hint',
      (tester) async {
    await mount(tester, chapters: [], controllerMode: true);
    expect(find.byType(TextButton), findsNothing);
    expect(find.byType(Text), findsNothing);
    await mount(tester,
        chapters: [_chapter(-1), _chapter(120)], controllerMode: true);
    expect(find.byType(TextButton), findsNothing);
  });

  testWidgets(
      'first and final chapter disable unavailable direction without wrapping',
      (tester) async {
    var previous = 0;
    var next = 0;
    final chapters = [_chapter(0), _chapter(30), _chapter(60)];
    await mount(tester,
        chapters: chapters, previous: () => previous++, next: () => next++);
    final previousFinder = find.byKey(const ValueKey('previous-chapter'));
    final nextFinder = find.byKey(const ValueKey('next-chapter'));
    expect(tester.widget<TextButton>(previousFinder).onPressed, isNull);
    expect(tester.widget<TextButton>(nextFinder).onPressed, isNotNull);
    await tester.tap(nextFinder);
    expect(next, 1);
    expect(previous, 0);

    await mount(tester,
        chapters: chapters,
        position: 60,
        previous: () => previous++,
        next: () => next++);
    expect(tester.widget<TextButton>(previousFinder).onPressed, isNotNull);
    expect(tester.widget<TextButton>(nextFinder).onPressed, isNull);
    await tester.tap(previousFinder);
    expect(previous, 1);
    expect(next, 1);
  });

  testWidgets(
      'chapter buttons expose labels and controller hint without adding bindings',
      (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await mount(tester,
          chapters: [_chapter(0), _chapter(30)], controllerMode: true);
      expect(find.text('Previous Chapter'), findsOneWidget);
      expect(find.text('Next Chapter'), findsOneWidget);
      expect(find.bySemanticsLabel('Previous Chapter'), findsOneWidget);
      expect(find.bySemanticsLabel('Next Chapter'), findsOneWidget);
      final context = tester.element(find.byType(ChapterNavigationButtons));
      final hint = AppLocalizations.of(context).chapterControllerHint;
      expect(find.text(hint), findsOneWidget);
      await mount(tester, chapters: [_chapter(0), _chapter(30)]);
      expect(find.text(hint), findsNothing);
    } finally {
      // Release before testWidgets checks framework invariants.
      semantics.dispose();
    }
  });

  testWidgets('chapter labels and hint wrap on phone with large text',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(280, 640);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(tester,
        chapters: [_chapter(0), _chapter(30)],
        controllerMode: true,
        textScale: 1.8);
    await tester.pumpAndSettle();
    expect(find.text('Previous Chapter'), findsOneWidget);
    expect(find.text('Next Chapter'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
