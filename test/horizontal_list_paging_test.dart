import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fladder/providers/settings/home_settings_provider.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout_model.dart';
import 'package:fladder/util/poster_defaults.dart';
import 'package:fladder/widgets/shared/horizontal_list.dart';

void main() {
  testWidgets('a desktop poster row offers paging only while it overflows', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 600);
    addTearDown(tester.view.reset);

    Future<void> mount(int count, {bool classic = false, int? startIndex}) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [classicInterfaceProvider.overrideWithValue(classic)],
          child: MaterialApp(
            home: AdaptiveLayout(
              data: const AdaptiveLayoutModel(
                viewSize: ViewSize.desktop,
                layoutMode: LayoutMode.single,
                inputDevice: InputDevice.pointer,
                platform: TargetPlatform.windows,
                isDesktop: true,
                posterDefaults: PosterDefaults(size: 240, ratio: .55),
                controller: {},
                sideBarWidth: 0,
                topBarHeight: 0,
                statusBarHeight: 0,
              ),
              child: Scaffold(
                body: HorizontalList<int>(
                  items: List.generate(count, (i) => i),
                  label: 'Movies',
                  height: 100,
                  startIndex: startIndex,
                  itemBuilder: (context, i) => SizedBox(width: 120, child: Text('Movie $i')),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await mount(4);
    final l10n = MaterialLocalizations.of(tester.element(find.byType(Scrollable)));
    final next = find.byTooltip(l10n.nextPageTooltip);
    expect(next, findsNothing);
    tester.view.physicalSize = const Size(320, 600);
    await tester.pumpAndSettle();
    expect(next, findsOneWidget);
    await tester.tap(next);
    await tester.pumpAndSettle();
    expect(tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels, greaterThan(0));
    await mount(2, startIndex: 0);
    expect(next, findsNothing);
    expect(find.byIcon(Icons.circle), findsOneWidget);
    await mount(4);
    expect(next, findsOneWidget);
    tester.view.physicalSize = const Size(900, 600);
    await tester.pumpAndSettle();
    expect(next, findsNothing);
    await mount(4, classic: true);
    expect(next, findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
