import 'package:auto_route/auto_route.dart';
import 'package:fladder/jellyfin/jellyfin_open_api.enums.swagger.dart';
import 'package:fladder/localization_delegates.dart';
import 'package:fladder/models/view_model.dart';
import 'package:fladder/providers/library_screen_provider.dart' as data;
import 'package:fladder/providers/settings/home_settings_provider.dart';
import 'package:fladder/providers/update_provider.dart';
import 'package:fladder/routes/auto_router.gr.dart';
import 'package:fladder/screens/home_screen.dart';
import 'package:fladder/screens/library/library_screen.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout_model.dart';
import 'package:fladder/util/localization_helper.dart';
import 'package:fladder/util/poster_defaults.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

final _first = ViewModel.createEmpty('films', CollectionType.movies).copyWith(name: '電影');
final _second = ViewModel.createEmpty('nature', CollectionType.tvshows).copyWith(name: '自然紀實與長篇海洋探險系列');

class _Library extends data.LibraryScreen {
  @override
  data.LibraryScreenModel build() => data.LibraryScreenModel(views: [_first, _second], selectedViewModel: _first);

  @override
  Future<void> fetchAllLibraries({bool refreshViews = false}) async {}

  @override
  Future<void> selectLibrary(ViewModel viewModel) async => state = state.copyWith(selectedViewModel: viewModel);
}

void main() {
  testWidgets('narrow library keeps search and tools visible and uses the selected library', (tester) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        data.libraryScreenProvider.overrideWith(_Library.new),
        hasNewUpdateProvider.overrideWithValue(false),
        classicInterfaceProvider.overrideWithValue(false),
      ],
    );
    final scroll = ScrollController();
    final router = RootStackRouter.build(
      routes: [
        NamedRouteDef(
          name: LibraryRoute.name,
          path: '/',
          builder: (_, _) => const Scaffold(body: LibraryScreen()),
        ),
        NamedRouteDef(
          name: LibrarySearchRoute.name,
          path: '/search',
          builder: (_, route) => Text(route.argsAs<LibrarySearchRouteArgs>().parentId!.single),
        ),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
      scroll.dispose();
      container.dispose();
    });
    const locale = Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router.config(),
          locale: locale,
          supportedLocales: const [locale],
          localizationsDelegates: FladderLocalizations.localizationsDelegates,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)),
            child: AdaptiveLayout(
              data: AdaptiveLayoutModel(
                viewSize: ViewSize.phone,
                layoutMode: LayoutMode.single,
                inputDevice: InputDevice.touch,
                isDesktop: false,
                platform: TargetPlatform.android,
                posterDefaults: const PosterDefaults(size: 240, ratio: .55),
                sideBarWidth: 0,
                topBarHeight: 0,
                statusBarHeight: 0,
                controller: {HomeTabs.library: scroll},
              ),
              child: child!,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final strings = tester.element(find.byType(LibraryScreen)).localized;
    final filters = find.byTooltip(strings.filter(2));
    expect(filters.hitTestable(), findsOneWidget);
    expect(find.byTooltip(strings.scanLibrary).hitTestable(), findsOneWidget);
    expect(find.text(_second.name), findsOneWidget);
    await tester.tap(filters);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<data.LibraryViewType>, strings.genre(2)));
    await tester.pumpAndSettle();
    expect(container.read(data.libraryScreenProvider).viewType, contains(data.LibraryViewType.genres));
    await tester.ensureVisible(find.byKey(Key(_second.id)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key(_second.id)));
    await tester.pumpAndSettle();
    expect(container.read(data.libraryScreenProvider).selectedViewModel, same(_second));
    final node = tester.semantics.simulatedAccessibilityTraversal().singleWhere((node) => node.label == _second.name);
    expect(node.getSemanticsData().flagsCollection.isSelected.toBoolOrNull(), true);
    final search = find.text('${strings.search} ${_second.name}');
    expect(search.hitTestable(), findsOneWidget);
    await tester.tap(search);
    await tester.pumpAndSettle();
    expect(find.text(_second.id), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
