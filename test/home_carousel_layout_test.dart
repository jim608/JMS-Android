import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart' as dto;
import 'package:fladder/localization_delegates.dart';
import 'package:fladder/models/items/movie_model.dart';
import 'package:fladder/models/settings/home_settings_model.dart';
import 'package:fladder/providers/settings/home_settings_provider.dart';
import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/screens/dashboard/home_banner_widget.dart';
import 'package:fladder/screens/shared/media/banner_play_button.dart';
import 'package:fladder/screens/shared/media/carousel_banner.dart';
import 'package:fladder/theme.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout_model.dart';
import 'package:fladder/util/poster_defaults.dart';
import 'package:fladder/util/themes_data.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:square_progress_indicator/square_progress_indicator.dart';

import 'helpers/interface_typography_environment_stub.dart'
    if (dart.library.js_interop) 'helpers/interface_typography_environment_web.dart';

const _title = '在海岸的盡頭等待最後一班列車';
const _locale = Locale('zh', 'TW');

Future<void> _mount(
  WidgetTester tester,
  Size size, {
  int count = 1,
  double scale = 1,
  bool rtl = false,
  SharedPreferences? preferences,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  final desktop = size.width > 600;
  final theme = FladderTheme.theme(
    FladderTheme.defaultScheme(Brightness.dark),
    DynamicSchemeVariant.tonalSpot,
    locale: _locale,
  );
  final movies = List.generate(
    count,
    (i) =>
        MovieModel.fromBaseDto(dto.BaseItemDto(id: '$i', name: i == 0 ? _title : '電影 $i', productionYear: 2026), null),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (preferences != null)
          sharedUtilityProvider.overrideWith((ref) => SharedUtility(ref: ref, sharedPreferences: preferences)),
      ],
      child: MaterialApp(
        locale: _locale,
        supportedLocales: const [_locale],
        localizationsDelegates: FladderLocalizations.localizationsDelegates,
        theme: theme,
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
            child: Directionality(
              textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
              child: ThemesData(
                light: theme,
                dark: theme,
                child: AdaptiveLayout(
                  data: AdaptiveLayoutModel(
                    viewSize: desktop ? ViewSize.desktop : ViewSize.phone,
                    layoutMode: LayoutMode.single,
                    inputDevice: desktop ? InputDevice.pointer : InputDevice.touch,
                    platform: desktop ? TargetPlatform.windows : TargetPlatform.android,
                    isDesktop: desktop,
                    posterDefaults: const PosterDefaults(size: 240, ratio: 0.55),
                    controller: const {},
                    sideBarWidth: 0,
                    topBarHeight: 0,
                    statusBarHeight: 0,
                  ),
                  child: Scaffold(
                    body: HomeBannerWidget(posters: movies, onSelect: (_) {}),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder get _play => find.descendant(of: find.byType(BannerPlayButton), matching: find.byType(IconButton));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final restoreEnvironment = useBundledTypographyFonts();
  tearDownAll(restoreEnvironment);
  setUpAll(() async {
    if (kIsWeb) return;
    final loader = FontLoader('NotoSansTC');
    for (final weight in ['Regular', 'SemiBold', 'Bold']) {
      loader.addFont(rootBundle.load('assets/fonts/notosanstc/NotoSansTC-$weight.ttf'));
    }
    await loader.load();
  });

  for (final (size, scale, rtl) in [(const Size(390, 844), 1.0, false), (const Size(320, 568), 2.0, true)]) {
    testWidgets('Chinese title wraps beside the hit-testable play button at ${size.width}px, text scale $scale', (
      tester,
    ) async {
      await _mount(tester, size, scale: scale, rtl: rtl);
      final title = find.text(_title);
      expect(title, findsOneWidget);
      if (scale == 1) expect(find.text('2026'), findsOneWidget);
      final text = tester.renderObject<RenderParagraph>(title);
      final boxes = text.getBoxesForSelection(const TextSelection(baseOffset: 0, extentOffset: _title.length));
      expect(boxes.map((box) => box.top).toSet(), hasLength(2));
      final card = tester.getRect(find.byType(CarouselView));
      final button = tester.getRect(_play.hitTestable());
      expect(button.center.dx, rtl ? lessThan(card.center.dx) : greaterThan(card.center.dx));
      for (final box in boxes) {
        final line = box.toRect().shift(text.localToGlobal(Offset.zero));
        expect(card.intersect(line), line);
        expect(line.overlaps(button), isFalse);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('desktop only offers paging when there is somewhere to scroll', (tester) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(50, 50));
    addTearDown(mouse.removePointer);
    await _mount(tester, const Size(1280, 800));
    await mouse.moveTo(const Offset(100, 50));
    await tester.pumpAndSettle();
    final l10n = MaterialLocalizations.of(tester.element(find.byType(CarouselBanner)));
    final next = find.byTooltip(l10n.nextPageTooltip);
    expect(find.byType(IconButton), findsOneWidget);
    expect(next, findsNothing);
    expect(find.byTooltip(l10n.previousPageTooltip), findsNothing);
    expect(_play.hitTestable(), findsOneWidget);

    await _mount(tester, const Size(1280, 800), count: 5);
    final position = tester.state<ScrollableState>(find.byType(Scrollable)).position;
    final start = position.pixels;
    await tester.tap(next);
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(start));
    await tester.tap(find.byTooltip(l10n.previousPageTooltip));
    await tester.pumpAndSettle();
    expect(position.pixels, closeTo(start, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing banner style reaches the visible carousel and slideshow without restarting', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await _mount(tester, const Size(390, 844), preferences: preferences);
    final container = ProviderScope.containerOf(tester.element(find.byType(HomeBannerWidget)), listen: false);
    final settings = container.read(homeSettingsProvider.notifier);
    final squareProgress = find.descendant(
      of: find.byType(BannerPlayButton),
      matching: find.byType(SquareProgressIndicator),
    );

    expect(squareProgress, findsNothing);
    settings.update((state) => state.copyWith(useClassicBannerStyle: true));
    await tester.pumpAndSettle();
    expect(tester.widget<CarouselBanner>(find.byType(CarouselBanner)).useClassicStyle, isTrue);
    expect(squareProgress, findsOneWidget);
    expect(_play.hitTestable(), findsOneWidget);

    settings.update((state) => state.copyWith(homeBanner: HomeBanner.banner));
    await tester.pumpAndSettle();
    expect(find.byType(CarouselBanner), findsNothing);
    expect(squareProgress, findsOneWidget);
    settings.update((state) => state.copyWith(useClassicBannerStyle: false));
    await tester.pumpAndSettle();
    expect(squareProgress, findsNothing);
    expect(_play.hitTestable(), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}
