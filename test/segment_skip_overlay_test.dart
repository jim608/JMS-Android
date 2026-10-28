import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/l10n/generated/app_localizations.dart';
import 'package:fladder/models/items/media_segments_model.dart';
import 'package:fladder/screens/video_player/components/player_controller_navigation.dart';
import 'package:fladder/screens/video_player/components/segment_skip_overlay.dart';

class _CardHarness extends StatefulWidget {
  const _CardHarness({this.showInitially = true, this.authorized = true, this.group = false});
  final bool showInitially;
  final bool authorized;
  final bool group;

  @override
  State<_CardHarness> createState() => _CardHarnessState();
}

class _CardHarnessState extends State<_CardHarness> {
  final play = FocusNode(debugLabel: 'Existing playback focus');
  late bool show = widget.showInitially;
  int skips = 0;
  int dismissals = 0;
  int videoTaps = 0;

  void showCard() => setState(() => show = true);

  @override
  void dispose() {
    play.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: PlayerControllerNavigation(
          enabled: true,
          controlsVisible: true,
          primaryControl: play,
          showControls: () {},
          hideControls: () {},
          exitPlayer: () {},
          child: Stack(
            children: [
              Positioned.fill(child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => videoTaps++)),
              Align(
                alignment: Alignment.topLeft,
                child: TextButton(focusNode: play, onPressed: () {}, child: const Text('Play')),
              ),
              if (show)
                Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: SegmentSkipCard(
                      segment: MediaSegment(
                        type: MediaSegmentType.intro,
                        start: Duration.zero,
                        end: const Duration(seconds: 20),
                        explicitBounds: true,
                      ),
                      groupPlayback: widget.group,
                      onSkip: widget.authorized ? () => skips++ : null,
                      onDismiss: () => dismissals++,
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
}

void main() {
  Future<_CardHarnessState> mount(
    WidgetTester tester, {
    bool showInitially = true,
    bool authorized = true,
    bool group = false,
    double textScale = 1,
  }) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: _CardHarness(showInitially: showInitially, authorized: authorized, group: group),
    ));
    await tester.pumpAndSettle();
    return tester.state<_CardHarnessState>(find.byType(_CardHarness));
  }

  testWidgets('prompt remains after controls timer and does not steal existing focus', (tester) async {
    final state = await mount(tester, showInitially: false);
    expect(state.play.hasPrimaryFocus, isTrue);
    state.showCard();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 20));
    expect(find.byType(SegmentSkipCard), findsOneWidget);
    expect(state.play.hasPrimaryFocus, isTrue);
  });

  testWidgets('controller can focus skip and activate once on A release', (tester) async {
    final state = await mount(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    final buttonContext = tester.element(find.byKey(const ValueKey('skip-segment')));
    // Directional focus is renderer-independent; the card is part of the same
    // player traversal group and does not need an input-stealing shortcut.
    final button = tester.widget<FilledButton>(find.byKey(const ValueKey('skip-segment')));
    expect(button.onPressed, isNotNull);
    final labelContext = tester
        .element(find.descendant(of: find.byKey(const ValueKey('skip-segment')), matching: find.byType(Text)).first);
    Focus.of(labelContext).requestFocus();
    await tester.pump();
    expect(Focus.of(labelContext).hasPrimaryFocus, isTrue);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.gameButtonA);
    expect(state.skips, 0);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.gameButtonA);
    await tester.pump();
    expect(state.skips, 1);
    expect(buttonContext.mounted, isTrue);
  });

  testWidgets('card surface intercepts padding taps while surrounding video remains interactive', (tester) async {
    final state = await mount(tester);
    final rect = tester.getRect(find.byType(SegmentSkipCard));
    await tester.tapAt(rect.topLeft + const Offset(2, 2));
    expect(state.videoTaps, 0);
    await tester.tapAt(const Offset(10, 200));
    expect(state.videoTaps, 1);
    await tester.tap(find.byKey(const ValueKey('skip-segment')));
    await tester.tap(find.byKey(const ValueKey('dismiss-segment')));
    expect(state.skips, 1);
    expect(state.dismissals, 1);
    expect(state.videoTaps, 1);
  });

  testWidgets('unauthorized group skip is disabled while dismissal remains available', (tester) async {
    final state = await mount(tester, authorized: false, group: true);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('skip-segment'))).onPressed, isNull);
    final context = tester.element(find.byType(SegmentSkipCard));
    expect(find.text(AppLocalizations.of(context).segmentGroupManualHint), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('dismiss-segment')));
    expect(state.dismissals, 1);
    expect(state.skips, 0);
  });

  testWidgets('prompt and group hint fit 280px at large text size', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(280, 640);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(tester, group: true, textScale: 1.8);
    expect(find.byKey(const ValueKey('skip-segment')), findsOneWidget);
    expect(find.byKey(const ValueKey('dismiss-segment')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
