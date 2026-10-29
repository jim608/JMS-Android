import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout_model.dart';
import 'package:fladder/util/poster_defaults.dart';
import 'package:fladder/widgets/shared/focus_row.dart';
import 'package:fladder/widgets/shared/horizontal_list.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _railKey = ValueKey('lifecycle-rail');

class _Harness extends StatefulWidget {
  const _Harness({required this.nodes, this.empty = false, this.widths, super.key});

  final List<FocusNode> nodes;
  final bool empty;
  final List<double>? widths;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  double height = 90;

  void resize() => setState(() => height += 10);

  @override
  Widget build(BuildContext context) {
    return HorizontalList<int>(
      key: _railKey,
      label: 'Synthetic lifecycle rail',
      items: widget.empty ? const [] : List.generate(widget.nodes.length, (index) => index),
      height: height,
      startIndex: 0,
      itemWidthBuilder: widget.widths == null ? null : (index) => widget.widths![index],
      itemBuilder: (context, index) => Focus(
        focusNode: widget.nodes[index],
        child: SizedBox(width: widget.widths?[index] ?? 120, child: Text('Item $index')),
      ),
    );
  }
}

Future<List<FocusNode>> _mount(
  WidgetTester tester, {
  GlobalKey<_HarnessState>? harnessKey,
  GlobalKey<NavigatorState>? navigatorKey,
  bool empty = false,
  List<double>? widths,
  bool directionalTraversal = false,
}) async {
  final nodes = List.generate(12, (index) => FocusNode(debugLabel: 'caller item $index'));
  addTearDown(() {
    for (final node in nodes) {
      node.dispose();
    }
  });
  await tester.pumpWidget(ProviderScope(
    child: MaterialApp(
      navigatorKey: navigatorKey,
      // Web arrows normally scroll. This fixture explicitly tests the rail's
      // directional focus contract, using the same standard intent everywhere.
      shortcuts: directionalTraversal
          ? {
              ...WidgetsApp.defaultShortcuts,
              const SingleActivator(LogicalKeyboardKey.arrowRight):
                  const DirectionalFocusIntent(TraversalDirection.right),
            }
          : null,
      builder: (context, child) => AdaptiveLayout(
        data: const AdaptiveLayoutModel(
          viewSize: ViewSize.desktop,
          layoutMode: LayoutMode.single,
          inputDevice: InputDevice.pointer,
          platform: TargetPlatform.windows,
          isDesktop: true,
          posterDefaults: PosterDefaults(size: 280, ratio: 0.55),
          controller: {},
          sideBarWidth: 0,
          topBarHeight: 0,
          statusBarHeight: 0,
        ),
        child: child!,
      ),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 600,
            height: 300,
            child: SingleChildScrollView(
              child: _Harness(key: harnessKey, nodes: nodes, empty: empty, widths: widths),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return nodes;
}

HorizontalRailFocus _policy(WidgetTester tester) =>
    tester.widget<FocusRow>(find.byType(FocusRow)).traversalPolicy! as HorizontalRailFocus;

ScrollController _controller(WidgetTester tester) => tester.widget<ListView>(find.byType(ListView)).controller!;

Set<Ticker> _trackedTickers(State state) {
  final properties = DiagnosticPropertiesBuilder();
  state.debugFillProperties(properties);
  return properties.properties
          .whereType<DiagnosticsProperty<Set<Ticker>>>()
          .singleWhere((property) => property.name == 'tickers')
          .value ??
      <Ticker>{};
}

void main() {
  testWidgets('rapid focus changes dispose cancelled animations and reach the latest item', (tester) async {
    final nodes = await _mount(tester);
    final state = tester.state(find.byKey(_railKey));
    final controller = _controller(tester);
    final tickers = _trackedTickers(state);
    expect(tickers, isEmpty);

    for (final index in [1, 2, 3]) {
      _policy(tester).onFocused(nodes[index], intervalMillis: 50);
      await tester.pump(const Duration(milliseconds: 15));
    }
    await tester.pumpAndSettle();

    expect(controller.offset, closeTo(3 * (120 + 8), 0.01));
    expect(tickers, isEmpty, reason: 'Stopped, replaced animations must release their tickers too.');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('leaving during interrupted scroll releases tickers and rail-owned resources', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    final nodes = await _mount(tester, navigatorKey: navigator);
    final tickers = _trackedTickers(tester.state(find.byKey(_railKey)));
    final controller = _controller(tester);
    final parentFocus = tester.widget<FocusRow>(find.byType(FocusRow)).focusNode!;
    _policy(tester).onFocused(nodes[1]);
    await tester.pump(const Duration(milliseconds: 10));
    _policy(tester).onFocused(nodes[2]);
    await tester.pump(const Duration(milliseconds: 10));

    navigator.currentState!.pushReplacement(PageRouteBuilder<void>(
      pageBuilder: (_, __, ___) => const Scaffold(body: Text('Left rail')),
      transitionDuration: Duration.zero,
    ));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));

    expect(tester.takeException(), isNull);
    expect(tickers, isEmpty);
    expect(() => ChangeNotifier.debugAssertNotDisposed(controller), throwsFlutterError);
    expect(() => ChangeNotifier.debugAssertNotDisposed(parentFocus), throwsFlutterError);
    expect(ChangeNotifier.debugAssertNotDisposed(nodes[1]), isTrue, reason: 'Item focus nodes belong to the caller.');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('idle rail disposes its focus node and scroll controller without disposing item nodes', (tester) async {
    final nodes = await _mount(tester);
    final controller = _controller(tester);
    final parentFocus = tester.widget<FocusRow>(find.byType(FocusRow)).focusNode!;
    await tester.pumpWidget(const SizedBox.shrink());

    expect(() => ChangeNotifier.debugAssertNotDisposed(controller), throwsFlutterError);
    expect(() => ChangeNotifier.debugAssertNotDisposed(parentFocus), throwsFlutterError);
    for (final node in nodes) {
      expect(ChangeNotifier.debugAssertNotDisposed(node), isTrue);
    }
  });

  testWidgets('queued measurement after a height change is harmless when the rail leaves', (tester) async {
    final harness = GlobalKey<_HarnessState>();
    await _mount(tester, harnessKey: harness, empty: true);
    harness.currentState!.resize();
    // didUpdateWidget schedules measurement, which schedules another frame.
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('variable-width item focus keeps cumulative offsets after interruption', (tester) async {
    final widths = List.generate(12, (index) => 90.0 + index * 10);
    final nodes = await _mount(tester, widths: widths);
    final controller = _controller(tester);
    _policy(tester).onFocused(nodes[1]);
    await tester.pump(const Duration(milliseconds: 10));
    _policy(tester).onFocused(nodes[3]);
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(widths.take(3).reduce((a, b) => a + b) + 3 * 8, 0.01));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('rapid directional-key traversal preserves the selected item and finishes scrolling', (tester) async {
    final nodes = await _mount(tester, directionalTraversal: true);
    final controller = _controller(tester);
    final tickers = _trackedTickers(tester.state(find.byKey(_railKey)));
    nodes.first.requestFocus();
    await tester.pump();
    for (var index = 0; index < 3; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 15));
    }
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, nodes[3]);
    expect(controller.offset, closeTo(3 * (120 + 8), 0.01));
    expect(tickers, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
