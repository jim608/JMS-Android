import 'dart:ui' show Tristate;

import 'package:auto_route/auto_route.dart';
import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/localization_delegates.dart';
import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/credentials_model.dart';
import 'package:fladder/models/syncing/sync_settings_model.dart';
import 'package:fladder/providers/connectivity_provider.dart' as network;
import 'package:fladder/providers/cultures_provider.dart';
import 'package:fladder/providers/settings/home_settings_provider.dart';
import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/providers/sync_provider.dart';
import 'package:fladder/providers/update_notifications_provider.dart';
import 'package:fladder/providers/update_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/routes/auto_router.gr.dart';
import 'package:fladder/screens/settings/about_settings_page.dart';
import 'package:fladder/screens/settings/client_settings_page.dart';
import 'package:fladder/screens/settings/player_settings_page.dart';
import 'package:fladder/screens/settings/profile_settings_page.dart';
import 'package:fladder/screens/settings/settings_list_tile.dart';
import 'package:fladder/screens/settings/settings_scaffold.dart';
import 'package:fladder/theme.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout_model.dart';
import 'package:fladder/util/localization_helper.dart';
import 'package:fladder/util/poster_defaults.dart';
import 'package:fladder/util/update_checker.dart';
import 'package:fladder/util/update_controller.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Offline extends network.ConnectivityStatus {
  @override
  network.ConnectionState build() => network.ConnectionState.offline;
}

class _Cultures extends Cultures {
  @override
  List<CultureDto> build() => const [];
}

class _Downloads extends StateNotifier<SyncSettingsModel>
    implements SyncNotifier {
  _Downloads() : super(SyncSettingsModel());

  @override
  String? get savePath => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Viewer extends User {
  _Viewer(this.preferences);
  final UserSettings? preferences;
  @override
  AccountModel build() => AccountModel(
    name: '觀影者',
    id: 'viewer',
    avatar: '',
    lastUsed: DateTime.utc(2026),
    credentials: CredentialsModel(
      url: 'https://fixture.example.invalid',
      token: '',
      serverId: 'server',
      deviceId: 'device',
    ),
    userSettings: preferences,
  );
}

Future<RootStackRouter> _mount(
  WidgetTester tester, {
  required bool phone,
  bool classic = false,
  double scale = 1,
  bool preferencesLoaded = true,
  bool allCategories = false,
  bool startAtHome = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = phone ? const Size(320, 700) : const Size(1280, 800);
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  const locale = Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant');
  final theme = FladderTheme.theme(
    FladderTheme.defaultScheme(Brightness.dark),
    DynamicSchemeVariant.tonalSpot,
    locale: locale,
    useClassicInterface: classic,
  );
  final router = RootStackRouter.build(
    routes: [
      if (startAtHome)
        AutoRoute(
          page: PageInfo('TestHome', builder: (_) => const SizedBox.shrink()),
          path: '/',
        ),
      AutoRoute(
        page: SettingsRoute.page,
        path: startAtHome ? '/settings' : '/',
        children: [
          AutoRoute(page: SettingsSelectionRoute.page, path: '', initial: true),
          if (allCategories) AutoRoute(page: ClientSettingsRoute.page, path: 'client', maintainState: false),
          if (allCategories) AutoRoute(page: ProfileSettingsRoute.page, path: 'security', maintainState: false),
          AutoRoute(page: PlayerSettingsRoute.page, path: 'player', maintainState: !allCategories),
          if (allCategories) AutoRoute(page: AboutSettingsRoute.page, path: 'about'),
        ],
      ),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    router.dispose();
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        sharedUtilityProvider.overrideWith((ref) => SharedUtility(ref: ref, sharedPreferences: prefs)),
        if (!allCategories) classicInterfaceProvider.overrideWithValue(classic),
        syncProvider.overrideWith((ref) => _Downloads()),
        culturesProvider.overrideWith(_Cultures.new),
        supportsNotificationsProvider.overrideWithValue(false),
        network.connectivityStatusProvider.overrideWith(_Offline.new),
        userProvider.overrideWith(() => _Viewer(preferencesLoaded ? UserSettings() : null)),
        updateProvider.overrideWith(
          (ref) => UpdateController(checker: UpdateChecker(), bridge: TestProfileUpdateBridge(), supported: false),
        ),
      ],
      child: MaterialApp.router(
        locale: locale,
        theme: theme,
        supportedLocales: const [locale],
        localizationsDelegates: FladderLocalizations.localizationsDelegates,
        routerConfig: router.config(),
        builder: (context, child) => AdaptiveLayout(
          data: AdaptiveLayoutModel(
            viewSize: phone ? ViewSize.phone : ViewSize.desktop,
            layoutMode: phone ? LayoutMode.single : LayoutMode.dual,
            inputDevice: phone ? InputDevice.touch : InputDevice.pointer,
            platform: phone ? TargetPlatform.android : TargetPlatform.windows,
            isDesktop: !phone,
            posterDefaults: const PosterDefaults(size: 240, ratio: 0.55),
            controller: const {},
            sideBarWidth: 0,
            topBarHeight: 0,
            statusBarHeight: 0,
          ),
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

void main() {
  for (final phone in [true, false]) {
    final layout = phone ? 'phone' : 'desktop';
    testWidgets('all settings categories open from the $layout menu', (
      tester,
    ) async {
      await _mount(tester, phone: phone, allCategories: true);
      final strings = tester
          .element(find.byType(SettingsScaffold).first)
          .localized;
      if (!phone) expect(find.byType(ClientSettingsPage), findsOneWidget);
      for (final (label, pageType) in [
        (strings.general, ClientSettingsPage),
        (strings.settingsProfileTitle, ProfileSettingsPage),
        (strings.settingsPlayerTitle, PlayerSettingsPage),
        (strings.about, AboutSettingsPage),
      ]) {
        final entry = find.widgetWithText(SettingsListTile, label).first;
        await tester.ensureVisible(entry);
        await tester.tap(
          find.descendant(of: entry, matching: find.byType(InkWell)).first,
        );
        await tester.pumpAndSettle();
        final page = find.byType(pageType);
        expect(page, findsOneWidget);
        expect(
          find.descendant(of: page, matching: find.text(label)).hitTestable(),
          findsWidgets,
        );
        if (phone) {
          await tester.tap(
            find.descendant(of: page, matching: find.byType(BackButton)),
          );
          await tester.pumpAndSettle();
          expect(entry.hitTestable(), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      }
    });
  }

  testWidgets('an explicit settings tab opens first and re-entering uses the desktop default', (tester) async {
    final router = await _mount(tester, phone: false, allCategories: true, startAtHome: true);

    router.push(const SettingsRoute(children: [ProfileSettingsRoute()]));
    await tester.pumpAndSettle();
    expect(find.byType(ProfileSettingsPage), findsOneWidget);
    expect(find.byType(ClientSettingsPage), findsNothing);

    await router.maybePop();
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScaffold), findsNothing);

    router.push(const ClientSettingsRoute());
    await tester.pumpAndSettle();
    expect(find.byType(ClientSettingsPage), findsOneWidget);
    expect(find.byType(ProfileSettingsPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching to classic and back saves the interface preference', (
    tester,
  ) async {
    await _mount(tester, phone: false, allCategories: true);
    final page = find.byType(ClientSettingsPage);
    final context = tester.element(page);
    final strings = context.localized;
    final storage = ProviderScope.containerOf(
      context,
    ).read(sharedUtilityProvider);
    final preference = find.widgetWithText(
      SettingsListTileCheckbox,
      strings.useClassicInterface,
    );
    final scrollable = find
        .descendant(of: page, matching: find.byType(Scrollable))
        .first;

    for (final classic in [true, false]) {
      await tester.scrollUntilVisible(preference, 300, scrollable: scrollable);
      final toggle = find.descendant(
        of: preference,
        matching: find.byType(Switch),
      );
      final action = find.descendant(of: preference, matching: find.byType(InkWell));
      await Scrollable.ensureVisible(tester.element(action), alignment: 0.5);
      await tester.tap(action.hitTestable());
      await tester.pumpAndSettle();
      expect(storage.homeSettings.useClassicBannerStyle, classic);
      expect(tester.widget<Switch>(toggle).value, classic);
      expect(
        find.byType(PinnedHeaderSliver),
        classic ? findsNothing : findsNWidgets(2),
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('phone double-tap seeking switch saves its value', (
    tester,
  ) async {
    await _mount(tester, phone: true, allCategories: true);
    final context = tester.element(find.byType(SettingsScaffold));
    final strings = context.localized;
    final storage = ProviderScope.containerOf(
      context,
    ).read(sharedUtilityProvider);
    final entry = find.widgetWithText(
      SettingsListTile,
      strings.settingsPlayerTitle,
    );
    await tester.tap(
      find.descendant(of: entry, matching: find.byType(InkWell)),
    );
    await tester.pumpAndSettle();

    final page = find.byType(PlayerSettingsPage);
    final scrollable = find
        .descendant(of: page, matching: find.byType(Scrollable))
        .first;
    final seekTile = find.widgetWithText(
      SettingsListTile,
      strings.enableDoubleTapSeekTitle,
    );
    await tester.scrollUntilVisible(seekTile, 300, scrollable: scrollable);
    final toggle = find.descendant(of: seekTile, matching: find.byType(Switch));
    final action = find.descendant(of: seekTile, matching: find.byType(InkWell));
    await Scrollable.ensureVisible(tester.element(action), alignment: 0.5);
    final previous = storage.videoPlayerSettings.enableDoubleTapSeek;
    await tester.tap(action.hitTestable());
    await tester.pumpAndSettle();
    expect(storage.videoPlayerSettings.enableDoubleTapSeek, !previous);
    expect(tester.widget<Switch>(toggle).value, !previous);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings categories explain their contents and the selected pane names the category', (tester) async {
    await _mount(tester, phone: false);
    final strings = tester.element(find.byType(SettingsScaffold).first).localized;
    expect(find.text(strings.settingsClientDesc), findsOneWidget);
    expect(find.text(strings.settingsPlayerDesc), findsOneWidget);
    expect(find.text(strings.settingsPlayerTitle), findsNWidgets(2));
    expect(find.byType(PinnedHeaderSliver), findsNWidgets(2));
    expect(tester.getSize(find.byType(SettingsScaffold).first).width, lessThan(400));
    final playerCategory = tester.semantics
        .simulatedAccessibilityTraversal()
        .where(
          (node) => node.label.contains(strings.settingsPlayerTitle) && node.label.contains(strings.settingsPlayerDesc),
        )
        .single;
    expect(playerCategory.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    expect(playerCategory.flagsCollection.isSelected, Tristate.isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('classic settings keep their original category list and desktop header', (tester) async {
    await _mount(tester, phone: false, classic: true);
    final strings = tester.element(find.byType(SettingsScaffold).first).localized;
    expect(find.text(strings.settingsClientDesc), findsNothing);
    expect(find.text(strings.settingsPlayerTitle), findsOneWidget);
    expect(find.byType(PinnedHeaderSliver), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('player settings open while the account preferences are unavailable', (tester) async {
    await _mount(tester, phone: false, preferencesLoaded: false);
    final strings = tester.element(find.byType(SettingsScaffold).first).localized;
    expect(find.text(strings.jmsPlaybackDiagnostics), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('large text on a small phone keeps the player title and back action after scrolling', (tester) async {
    await _mount(tester, phone: true, scale: 2);
    final strings = tester.element(find.byType(SettingsScaffold).first).localized;
    final entry = find.widgetWithText(SettingsListTile, strings.settingsPlayerTitle);
    await tester.ensureVisible(entry);
    await tester.tap(find.descendant(of: entry, matching: find.byType(InkWell)));
    await tester.pumpAndSettle();
    final page = find.byType(SettingsScaffold).last;
    final title = find.descendant(of: page, matching: find.text(strings.settingsPlayerTitle));
    final back = find.descendant(of: page, matching: find.byType(BackButton));
    final scroll = find.descendant(of: page, matching: find.byType(CustomScrollView));
    final start = tester.getTopLeft(title);
    await tester.drag(scroll, const Offset(0, -430));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(title), start);
    expect(back.hitTestable(), findsOneWidget);
    await tester.tap(back);
    await tester.pumpAndSettle();
    expect(find.descendant(of: entry, matching: find.byType(InkWell)).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
