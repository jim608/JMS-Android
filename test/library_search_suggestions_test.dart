import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart' as dto;
import 'package:fladder/localization_delegates.dart';
import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/items/movie_model.dart';
import 'package:fladder/providers/library_search_provider.dart';
import 'package:fladder/providers/settings/home_settings_provider.dart';
import 'package:fladder/screens/library_search/widgets/suggestion_search_bar.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout_model.dart';
import 'package:fladder/util/poster_defaults.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _fieldKey = ValueKey('search');
const _title = '在海岸線的盡頭等待第一道曙光';

class _Search extends LibrarySearchNotifier {
  _Search(super.ref);

  @override
  Future<List<ItemBaseModel>> fetchSuggestions(String searchTerm, {int limit = 25}) async => [
    MovieModel.fromBaseDto(const dto.BaseItemDto(id: 'coast', name: _title, productionYear: 2023), null),
    MovieModel.fromBaseDto(const dto.BaseItemDto(id: 'bird', name: '北大西洋的海鸚'), null),
  ];
}

Future<void> _openSearch(
  WidgetTester tester, {
  required bool classic,
  required bool rtl,
  required ValueChanged<ItemBaseModel> selected,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(320, 640);
  tester.view.padding = const FakeViewPadding(left: 8, right: 12);
  addTearDown(tester.view.reset);
  const locale = Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant');
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        librarySearchProvider(_fieldKey).overrideWith((ref) => _Search(ref)),
        classicInterfaceProvider.overrideWithValue(classic),
      ],
      child: MaterialApp(
        locale: locale,
        supportedLocales: const [locale],
        localizationsDelegates: FladderLocalizations.localizationsDelegates,
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.6)),
            child: AdaptiveLayout(
              data: const AdaptiveLayoutModel(
                viewSize: ViewSize.phone,
                layoutMode: LayoutMode.single,
                inputDevice: InputDevice.pointer,
                platform: TargetPlatform.windows,
                isDesktop: false,
                posterDefaults: PosterDefaults(size: 240, ratio: 0.55),
                controller: {},
                sideBarWidth: 0,
                topBarHeight: 0,
                statusBarHeight: 0,
              ),
              child: Scaffold(
                body: Directionality(
                  textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 50),
                      child: IntrinsicHeight(
                        child: SuggestionSearchBar(key: _fieldKey, onItem: selected),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  final field = find.byType(TextField);
  await tester.tap(field);
  await tester.enterText(field, '海');
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pumpAndSettle();
  expect(find.text(_title), findsOneWidget);
}

void main() {
  for (final (classic, rtl) in [(false, false), (false, true), (true, false)]) {
    testWidgets('suggestion opens once from pointer or keyboard, classic=$classic, rtl=$rtl', (tester) async {
      final selected = <String>[];
      await _openSearch(tester, classic: classic, rtl: rtl, selected: (item) => selected.add(item.id));
      expect(tester.widget<Text>(find.text(_title)).maxLines, classic ? 1 : 2);
      if (!classic) {
        expect(find.text('電影  ·  2023'), findsOneWidget);
        final panel = find.ancestor(
          of: find.text(_title),
          matching: find.byWidgetPredicate(
            (widget) => widget is Material && widget.borderRadius == BorderRadius.circular(16),
          ),
        );
        final bounds = tester.getRect(panel);
        expect(bounds.left, greaterThanOrEqualTo(8));
        expect(bounds.right, lessThanOrEqualTo(320 - 12));
        expect(bounds.width, greaterThan(tester.getSize(find.byType(TextField)).width + 40));
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(selected, ['coast']);
      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), '海岸');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      await tester.tap(find.text('北大西洋的海鸚'));
      await tester.pumpAndSettle();
      expect(selected, ['coast', 'bird']);
      expect(find.byTooltip('清除'), findsOneWidget);
      await tester.tap(find.byTooltip('清除'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }
}
