import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart' as dto;
import 'package:fladder/localization_delegates.dart';
import 'package:fladder/models/items/movie_model.dart';
import 'package:fladder/models/settings/home_settings_model.dart';
import 'package:fladder/providers/settings/home_settings_provider.dart';
import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/screens/dashboard/home_banner_widget.dart';
import 'package:fladder/screens/shared/media/banner_play_button.dart';
import 'package:fladder/screens/shared/media/carousel_banner.dart';
import 'package:fladder/screens/shared/media/components/media_play_button.dart';
import 'package:fladder/theme.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout_model.dart';
import 'package:fladder/util/focus_provider.dart';
import 'package:fladder/util/localization_helper.dart';
import 'package:fladder/util/poster_defaults.dart';
import 'package:fladder/util/themes_data.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:square_progress_indicator/square_progress_indicator.dart';

import 'helpers/interface_typography_environment_stub.dart'
    if (dart.library.js_interop) 'helpers/interface_typography_environment_web.dart';

const _title = '在海岸的盡頭等待最後一班穿越山谷的夜行列車';
const _nextTitle = '在黎明前穿過落雪的群峰與沉睡的城市';
const _locale = Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant');

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
    (i) => MovieModel.fromBaseDto(
      dto.BaseItemDto(
        id: '$i',
        name: switch (i) { 0 => _title, 1 => _nextTitle, _ => '電影 $i' },
        productionYear: 2026,
        userData: dto.UserItemDataDto(playedPercentage: i == 0 ? 38 : 0),
      ),
      null,
    ),
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

Finder _featureAction(String label) => find
    .ancestor(
      of: find.text(label),
      matching: find.byElementPredicate(
        (e) => e.widget is FocusButton && e.findAncestorWidgetOfExactType<MediaPlayButton>() != null,
      ),
    )
    .hitTestable();

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
    testWidgets('Chinese title and resume action stay separate at ${size.width}px, text scale $scale', (tester) async {
      await _mount(tester, size, scale: scale, rtl: rtl);
      final title = find.text(_title);
      expect(title, findsOneWidget);
      final context = tester.element(find.byType(HomeBannerWidget));
      final play = _featureAction(context.localized.resumeVideo);
      if (scale == 1) expect(find.textContaining('2026'), findsOneWidget);
      final text = tester.renderObject<RenderParagraph>(title);
      final boxes = text.getBoxesForSelection(const TextSelection(baseOffset: 0, extentOffset: _title.length));
      expect(boxes.map((box) => box.top).toSet(), hasLength(2));
      final card = tester.getRect(find.byType(HomeBannerWidget));
      final button = tester.getRect(play);
      expect(card.contains(button.center), isTrue);
      expect(button.height, greaterThanOrEqualTo(48));
      for (final box in boxes) {
        final line = box.toRect().shift(text.localToGlobal(Offset.zero));
        expect(card.intersect(line), line);
        expect(line.overlaps(button), isFalse);
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final (size, rtl) in [
    (const Size(390, 844), false),
    (const Size(390, 844), true),
    (const Size(1280, 800), false),
  ]) {
    testWidgets('the feature pages by one complete film at ${size.width}px, rtl=$rtl', (tester) async {
      await _mount(tester, size, rtl: rtl);
      final context = tester.element(find.byType(HomeBannerWidget));
      final l10n = MaterialLocalizations.of(context);
      final next = find.byTooltip(l10n.nextPageTooltip);
      final previous = find.byTooltip(l10n.previousPageTooltip);
      expect(next, findsNothing);
      expect(previous, findsNothing);
      expect(_featureAction(context.localized.resumeVideo), findsOneWidget);

      await _mount(tester, size, count: 3, rtl: rtl);
      IconButton previousButton() => tester.widget(find.ancestor(of: previous, matching: find.byType(IconButton)));
      TextButton nextButton() => tester.widget(find.descendant(of: next, matching: find.byType(TextButton)));
      void expectPage(int number) {
        expect(find.text('${l10n.formatDecimal(number)} / ${l10n.formatDecimal(3)}'), findsOneWidget);
        expect(find.bySemanticsLabel(l10n.tabLabel(tabIndex: number, tabCount: 3)), findsOneWidget);
      }

      expectPage(1);
      expect(previousButton().onPressed, isNull);
      final scroll = find.descendant(of: find.byType(HomeBannerWidget), matching: find.byType(Scrollable));
      final position = tester.state<ScrollableState>(scroll).position;
      expect(tester.getRect(next).top, greaterThanOrEqualTo(tester.getRect(scroll).bottom));
      expect(find.descendant(of: next, matching: find.text(_nextTitle)), findsOneWidget);
      expect(_featureAction(context.localized.playLabel), findsNothing);
      await tester.tap(next);
      await tester.pumpAndSettle();
      expect(position.pixels, closeTo(position.viewportDimension, 1));
      expect(tester.getRect(scroll).contains(tester.getCenter(find.text(_nextTitle))), isTrue);
      expectPage(2);
      expect(_featureAction(context.localized.playLabel), findsOneWidget);

      await tester.tap(previous);
      await tester.pumpAndSettle();
      expect(position.pixels, closeTo(0, 1));
      expectPage(1);
      final viewport = tester.getRect(scroll);
      await tester.dragFrom(viewport.center, Offset(viewport.width * (rtl ? 0.8 : -0.8), 0));
      await tester.pumpAndSettle();
      expect(position.pixels, closeTo(position.viewportDimension, 1));
      expectPage(2);
      await tester.tap(next);
      await tester.pumpAndSettle();
      expectPage(3);
      expect(nextButton().onPressed, isNull);

      await _mount(tester, size, rtl: rtl);
      expect(next, findsNothing);
      expect(_featureAction(context.localized.resumeVideo), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the film navigation fits below the artwork with large RTL text', (tester) async {
    await _mount(tester, const Size(320, 568), count: 3, rtl: true, scale: 2);
    final context = tester.element(find.byType(HomeBannerWidget));
    final strings = MaterialLocalizations.of(context);
    final next = find.byTooltip(strings.nextPageTooltip);
    final previous = find.byTooltip(strings.previousPageTooltip);
    final card = tester.getRect(find.byType(PageView));
    expect(tester.getRect(next).top, greaterThanOrEqualTo(card.bottom));
    expect(tester.getRect(next).right, lessThan(tester.getRect(previous).left));
    final count = find.text('1 / 3');
    expect(tester.getRect(count).left - tester.getRect(next).right, greaterThanOrEqualTo(8));
    expect(tester.getRect(next).height, greaterThanOrEqualTo(48));
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard traversal reaches the active resume button separately from film details', (tester) async {
    await _mount(tester, const Size(1280, 800), count: 3);
    final context = tester.element(find.byType(HomeBannerWidget));
    final action = tester.widget<FocusButton>(_featureAction(context.localized.resumeVideo));

    FocusButton? focusedButton() => FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType();
    for (var tab = 0; tab < 6 && focusedButton() != action; tab++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
    }
    expect(focusedButton(), same(action));
    final playFocus = FocusManager.instance.primaryFocus;
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, isNot(same(playFocus)));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, same(playFocus));
    final buttons = tester.semantics.simulatedAccessibilityTraversal().where(
      (node) => node.getSemanticsData().hasAction(SemanticsAction.tap),
    );
    expect(buttons.where((node) => node.label == _title), hasLength(1));
    expect(buttons.where((node) => node.label.contains(context.localized.resume(_title))), hasLength(1));
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
