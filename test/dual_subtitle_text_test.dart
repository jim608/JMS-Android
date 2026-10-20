import 'package:fladder/models/settings/subtitle_settings_model.dart';
import 'package:fladder/widgets/dual_subtitle_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _primaryKey = Key('primary-subtitle');
const _secondaryKey = Key('secondary-subtitle');
const _columnKey = Key('dual-subtitle-column');

Future<void> _pumpSubtitles(
  WidgetTester tester, {
  String primary = '',
  String secondary = '',
  Size viewport = const Size(1280, 720),
  double textScale = 1,
  double bottomOffset = 0.1,
  EdgeInsets padding = EdgeInsets.zero,
  VoidCallback? onTap,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = viewport;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
            size: viewport, textScaler: TextScaler.linear(textScale)),
        child: Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: [
              if (onTap != null)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onTap,
                  child: const SizedBox.expand(),
                ),
              DualSubtitleText(
                primaryText: primary,
                secondaryText: secondary,
                settings: const SubtitleSettingsModel(fontSize: 72),
                padding: padding,
                bottomOffset: bottomOffset,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

void _expectOrderedAndVisible(WidgetTester tester, Size viewport) {
  final primary = tester.getRect(find.byKey(_primaryKey));
  final secondary = tester.getRect(find.byKey(_secondaryKey));
  expect(primary.bottom, lessThanOrEqualTo(secondary.top + 0.01));
  expect(primary.center.dx, closeTo(secondary.center.dx, 0.1));
  for (final rect in [primary, secondary]) {
    expect(rect.left, greaterThanOrEqualTo(-0.01));
    expect(rect.right, lessThanOrEqualTo(viewport.width + 0.01));
    expect(rect.top, greaterThanOrEqualTo(-0.01));
    expect(rect.bottom, lessThanOrEqualTo(viewport.height + 0.01));
  }
}

void main() {
  testWidgets('primary appears above a smaller secondary in one bottom group',
      (tester) async {
    await _pumpSubtitles(tester, primary: 'Primary', secondary: 'Secondary');
    expect(find.byKey(_columnKey), findsOneWidget);
    final primary = tester.widget<Text>(find.byKey(_primaryKey));
    final secondary = tester.widget<Text>(find.byKey(_secondaryKey));
    expect(primary.data, 'Primary');
    expect(secondary.data, 'Secondary');
    expect(secondary.style!.fontSize!,
        closeTo(primary.style!.fontSize! * 0.75, 0.01));
    _expectOrderedAndVisible(tester, const Size(1280, 720));
    expect(tester.takeException(), isNull);
  });

  testWidgets('secondary-only cue keeps its smaller secondary identity',
      (tester) async {
    await _pumpSubtitles(tester,
        primary: ' \n ', secondary: '  Secondary only  ');
    expect(find.byKey(_primaryKey), findsNothing);
    expect(
        tester.widget<Text>(find.byKey(_secondaryKey)).data, 'Secondary only');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'cue updates replace both languages without retaining previous text',
      (tester) async {
    await _pumpSubtitles(tester,
        primary: 'Old primary', secondary: 'Old secondary');
    await _pumpSubtitles(tester,
        primary: 'New primary', secondary: 'New secondary');
    expect(find.text('Old primary'), findsNothing);
    expect(find.text('Old secondary'), findsNothing);
    expect(tester.widget<Text>(find.byKey(_primaryKey)).data, 'New primary');
    expect(
        tester.widget<Text>(find.byKey(_secondaryKey)).data, 'New secondary');
  });

  testWidgets(
      'each cue can clear independently and both blank cues render no text',
      (tester) async {
    await _pumpSubtitles(tester, primary: 'Primary', secondary: 'Secondary');
    await _pumpSubtitles(tester, primary: 'Primary', secondary: '');
    expect(find.byKey(_primaryKey), findsOneWidget);
    expect(find.byKey(_secondaryKey), findsNothing);
    await _pumpSubtitles(tester, primary: '', secondary: 'Secondary');
    expect(find.byKey(_primaryKey), findsNothing);
    expect(find.byKey(_secondaryKey), findsOneWidget);
    await _pumpSubtitles(tester, primary: '\n ', secondary: ' \n');
    expect(find.byKey(_primaryKey), findsNothing);
    expect(find.byKey(_secondaryKey), findsNothing);
    expect(find.text('Primary'), findsNothing);
    expect(find.text('Secondary'), findsNothing);
  });

  testWidgets(
      'multiline primary and wrapping secondary stay separated in a small window',
      (tester) async {
    const viewport = Size(320, 180);
    await _pumpSubtitles(
      tester,
      viewport: viewport,
      primary: 'First primary line\nSecond primary line',
      secondary: List.filled(18, 'A long secondary cue').join(' '),
      textScale: 2,
    );
    expect(tester.widget<Text>(find.byKey(_primaryKey)).data, contains('\n'));
    final secondary = tester.widget<Text>(find.byKey(_secondaryKey));
    expect(tester.getSize(find.byKey(_secondaryKey)).height,
        greaterThan(secondary.style!.fontSize! * 1.5));
    _expectOrderedAndVisible(tester, viewport);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'bottom offset moves both cues together inside horizontal video padding',
      (tester) async {
    const padding = EdgeInsets.only(left: 80, right: 60);
    await _pumpSubtitles(
      tester,
      primary: 'Primary',
      secondary: 'Secondary',
      padding: padding,
    );
    final firstPrimary = tester.getRect(find.byKey(_primaryKey));
    final firstSecondary = tester.getRect(find.byKey(_secondaryKey));
    await _pumpSubtitles(
      tester,
      primary: 'Primary',
      secondary: 'Secondary',
      padding: padding,
      bottomOffset: 0.3,
    );
    final nextPrimary = tester.getRect(find.byKey(_primaryKey));
    final nextSecondary = tester.getRect(find.byKey(_secondaryKey));
    expect(nextPrimary.top, lessThan(firstPrimary.top));
    expect(firstPrimary.top - nextPrimary.top,
        closeTo(firstSecondary.top - nextSecondary.top, 0.1));
    final group = tester.getRect(find.byKey(_columnKey));
    expect(group.left, greaterThanOrEqualTo(padding.left));
    expect(group.right, lessThanOrEqualTo(1280 - padding.right));
    _expectOrderedAndVisible(tester, const Size(1280, 720));
  });

  testWidgets(
      'font sizing follows the video viewport while preserving language hierarchy',
      (tester) async {
    await _pumpSubtitles(tester,
        primary: 'Primary',
        secondary: 'Secondary',
        viewport: const Size(640, 360));
    final smallerFont =
        tester.widget<Text>(find.byKey(_primaryKey)).style!.fontSize!;
    await _pumpSubtitles(tester,
        primary: 'Primary',
        secondary: 'Secondary',
        viewport: const Size(1280, 720));
    final largerFont =
        tester.widget<Text>(find.byKey(_primaryKey)).style!.fontSize!;
    expect(largerFont, greaterThan(smallerFont));
    _expectOrderedAndVisible(tester, const Size(1280, 720));
    final normalHeight = tester.getRect(find.byKey(_primaryKey)).height;
    await _pumpSubtitles(tester,
        primary: 'Primary', secondary: 'Secondary', textScale: 2);
    expect(tester.getRect(find.byKey(_primaryKey)).height,
        greaterThan(normalHeight));
    _expectOrderedAndVisible(tester, const Size(1280, 720));
    expect(tester.takeException(), isNull);
  });

  testWidgets('subtitle text leaves player tap controls reachable',
      (tester) async {
    var taps = 0;
    await _pumpSubtitles(
      tester,
      primary: 'Primary',
      secondary: 'Secondary',
      onTap: () => taps++,
    );
    await tester.tapAt(tester.getCenter(find.byKey(_secondaryKey)));
    expect(taps, 1);
  });
}
