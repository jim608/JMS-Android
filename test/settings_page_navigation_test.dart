import 'dart:ui' show Tristate;

import 'package:auto_route/auto_route.dart';
import 'package:fladder/localization_delegates.dart';
import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/credentials_model.dart';
import 'package:fladder/providers/connectivity_provider.dart' as network;
import 'package:fladder/providers/settings/home_settings_provider.dart';
import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/providers/update_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/routes/auto_router.gr.dart';
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
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Offline extends network.ConnectivityStatus {
  @override
  network.ConnectionState build() => network.ConnectionState.offline;
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

Future<void> _mount(
  WidgetTester tester, {
  required bool phone,
  bool classic = false,
  double scale = 1,
  bool preferencesLoaded = true,
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
      AutoRoute(
        page: SettingsRoute.page,
        path: '/',
        children: [
          AutoRoute(page: SettingsSelectionRoute.page, path: '', initial: true),
          AutoRoute(page: PlayerSettingsRoute.page, path: 'player'),
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
        classicInterfaceProvider.overrideWithValue(classic),
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
}

void main() {
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
