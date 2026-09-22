import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:auto_route/auto_route.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fladder/localization_delegates.dart';
import 'package:fladder/l10n/generated/app_localizations.dart';
import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/providers/connectivity_provider.dart' show offlineStateProvider;
import 'package:fladder/providers/seerr_link_provider.dart';
import 'package:fladder/providers/seerr_api_provider.dart';
import 'package:fladder/screens/seerr/widgets/seerr_request_popup.dart';
import 'package:fladder/seerr/seerr_models.dart';
import 'package:fladder/util/custom_cache_manager.dart';
import 'package:fladder/screens/seerr/seerr_records_screen.dart';
import 'package:fladder/screens/seerr/seerr_report_dialog.dart';
import 'package:fladder/screens/seerr/seerr_search_screen.dart';
import 'package:fladder/screens/seerr/seerr_details_screen.dart';
import 'package:fladder/screens/home_screen.dart';
import 'package:fladder/theme.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout_model.dart';
import 'package:fladder/util/poster_defaults.dart';
import 'package:fladder/util/focus_provider.dart';
import 'fixtures/seerr_test_scope.dart';

void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;
  late SeerrFixture fixture;
  late ProviderContainer container;
  final boundary = GlobalKey();
  final scroll = ScrollController();

  setUp(() async {
    fixture = SeerrFixture()
      ..requested = true
      ..reported = true;
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final cache = await Directory('artifacts/checks/m14/ui-cache').create(recursive: true);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'), (call) async => cache.absolute.path);
    messenger.setMockMethodCallHandler(const MethodChannel('window_manager'), (call) async => null);
    container = ProviderContainer(overrides: [
      ...fixture.overrides(),
      offlineStateProvider.overrideWithValue(false),
      sharedPreferencesProvider.overrideWith((ref) => preferences)
    ]);
    await container.read(seerrLinkProvider.notifier).ensure(username: 'fixture', password: 'TEST_ONLY');
    final font = FontLoader('JmsProofCjk')
      ..addFont(File('assets/subtitle_fonts/NotoSansCJKtc-Regular.otf')
          .readAsBytes()
          .then((bytes) => ByteData.sublistView(bytes)));
    await font.load();
    final material = FontLoader('MaterialIcons')
      ..addFont(File('.jms-tools/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf')
          .readAsBytes()
          .then((bytes) => ByteData.sublistView(bytes)));
    await material.load();
    final fonts = jsonDecode(await rootBundle.loadString('FontManifest.json')) as List<dynamic>;
    for (final entry in fonts) {
      final loader = FontLoader(entry['family'] as String);
      for (final asset in entry['fonts'] as List<dynamic>) {
        loader.addFont(rootBundle.load(asset['asset'] as String));
      }
      await loader.load();
    }
  });
  tearDown(() {
    container.dispose();
    fixture.dispose();
  });

  Future<void> show(WidgetTester tester, Widget child, {bool dark = true, double scale = 1}) async {
    tester.view.physicalSize = const Size(432, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final scheme = ColorScheme.fromSeed(seedColor: Colors.teal, brightness: dark ? Brightness.dark : Brightness.light);
    final theme = FladderTheme.theme(scheme, DynamicSchemeVariant.tonalSpot);
    final router = RootStackRouter.build(
        routes: [NamedRouteDef(name: 'SeerrProof', path: '/', builder: (context, data) => child)]);
    addTearDown(router.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router.config(),
          locale: const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
          localizationsDelegates: FladderLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: theme.copyWith(textTheme: theme.textTheme.apply(fontFamily: 'JmsProofCjk')),
          builder: (context, body) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
              child: AdaptiveLayout(
                  data: AdaptiveLayoutModel(
                      viewSize: ViewSize.phone,
                      layoutMode: LayoutMode.single,
                      inputDevice: InputDevice.touch,
                      platform: TargetPlatform.android,
                      isDesktop: false,
                      posterDefaults: const PosterDefaults(size: 160, ratio: 0.67),
                      controller: {for (final tab in HomeTabs.values) tab: scroll},
                      sideBarWidth: 0,
                      topBarHeight: 0,
                      statusBarHeight: 0),
                  child: RepaintBoundary(key: boundary, child: body!))),
        )));
    await tester.pumpAndSettle();
  }

  Future<void> capture(WidgetTester tester, String name, {String folder = 'm14/ui'}) async {
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      final render = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('artifacts/checks/$folder/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets('records wait for identity instead of sending unauthenticated requests', (tester) async {
    container.dispose();
    fixture.statusStatus = 403;
    fixture.store.values.clear();
    container = ProviderContainer(overrides: [
      ...fixture.overrides(),
      offlineStateProvider.overrideWithValue(false),
    ]);
    await container.read(seerrLinkProvider.notifier).ensure(username: 'fixture', password: 'TEST_ONLY');
    fixture.calls.clear();
    await show(tester, const SeerrRecordsScreen());
    expect(fixture.calls, isEmpty);
    expect(find.text('1 / 1'), findsNothing);
    expect(find.text('複製連線診斷'), findsOneWidget);
    await capture(tester, 'records-connection-failed', folder: 'm15/ui');
  });

  testWidgets('native records distinguish approved from playable and show issue history', (tester) async {
    await show(tester, const SeerrRecordsScreen());
    expect(find.textContaining('已批准（不代表已可播放）'), findsOneWidget);
    await capture(tester, 'records-dark');
    await tester.tap(find.text('我的回報'));
    await tester.pumpAndSettle();
    expect(find.textContaining('未解決'), findsOneWidget);
    await capture(tester, 'issues-dark');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('native report form has preview and cancellation at enlarged text scale', (tester) async {
    fixture.reported = false;
    await show(
        tester,
        Builder(
            builder: (context) => Scaffold(
                body: Center(
                    child: FilledButton(
                        onPressed: () => showDialog<void>(
                            context: context,
                            builder: (_) =>
                                const SeerrReportDialog(tmdbId: 42, position: Duration(minutes: 12, seconds: 34))),
                        child: const Text('開啟測試回報'))))),
        dark: false,
        scale: 1.2);
    await tester.tap(find.text('開啟測試回報'));
    await tester.pumpAndSettle();
    expect(find.text('預覽並送出'), findsOneWidget);
    expect(find.text('00:12:34'), findsOneWidget);
    await capture(tester, 'report-light-large-text');
    await tester.enterText(find.byType(TextField).last, '字幕動畫未顯示，這是本機合成測試。');
    await tester.tap(find.text('預覽並送出'));
    await tester.pumpAndSettle();
    expect(find.textContaining('不代表已判定根因'), findsOneWidget);
    await tester.tap(find.text('修改'));
    await tester.pumpAndSettle();
    expect(fixture.calls.where((call) => call.url.path == '/api/v1/issue' && call.method == 'POST'), isEmpty);
    await tester.tap(find.text('預覽並送出'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('確認送出'));
    await tester.pumpAndSettle();
    expect(fixture.reported, isTrue);
    expect(fixture.calls.last.url.path, '/api/v1/issue/91');
    expect(find.byType(SeerrReportDialog), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('actual native request search and details render', (tester) async {
    await show(tester, const Scaffold(body: SeerrSearchScreen()));
    await tester.enterText(find.byType(TextField).first, '測試');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text('測試影片'), findsWidgets);
    await capture(tester, 'request-search-dark');
    await tester.pumpWidget(const SizedBox.shrink());
    await show(tester, const Scaffold(body: SeerrDetailsScreen(mediaType: 'movie', tmdbId: 42)), dark: false);
    await capture(tester, 'request-details-light');
    await tester.pumpWidget(const SizedBox.shrink());
    fixture.requested = false;
    final poster = await container
        .read(seerrApiProvider)
        .fetchDashboardPosterFromIds(tmdbId: 42, mediaType: SeerrMediaType.tvshow);
    await show(
        tester,
        Scaffold(
            body: Builder(
                builder: (context) => FilledButton(
                    onPressed: () => showDialog<void>(
                        context: context,
                        builder: (context) => Dialog(child: SeerrRequestPopup(requestModel: poster!))),
                    child: const Text('開啟選季測試')))));
    await tester.tap(find.text('開啟選季測試'));
    await tester.pumpAndSettle();
    final season = find.ancestor(of: find.text('季 1'), matching: find.byType(FocusButton));
    await tester.tap(find.descendant(of: season, matching: find.byType(InkWell)).first);
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(find.byType(Checkbox).first).value, isTrue);
    await capture(tester, 'request-seasons-dark');
    await tester.tap(find.text('送出請求'));
    await tester.pumpAndSettle();
    final submitted = fixture.calls.where((call) => call.method == 'POST' && call.url.path == '/api/v1/request').single;
    expect(jsonDecode(submitted.body)['mediaId'], 42);
    expect(jsonDecode(submitted.body)['seasons'], [1]);
    expect(find.byType(SeerrRequestPopup), findsNothing,
        reason: tester.widgetList<Text>(find.byType(Text)).map((text) => text.data).join(' / '));
    expect(fixture.calls.where((call) => call.url.path.startsWith('/api/v1/service/')), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 11));
    await tester.runAsync(() => CustomCacheManager.instance.dispose());
  });
}
