import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:chopper/chopper.dart' show Response;
import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart' as jellyfin;
import 'package:fladder/l10n/generated/app_localizations.dart';
import 'package:fladder/localization_delegates.dart';
import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/credentials_model.dart';
import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/settings/client_settings_model.dart';
import 'package:fladder/models/views_model.dart';
import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/connectivity_provider.dart';
import 'package:fladder/providers/dashboard_mode_provider.dart';
import 'package:fladder/providers/dashboard_provider.dart';
import 'package:fladder/providers/music_dashboard_provider.dart';
import 'package:fladder/providers/playlist_provider.dart';
import 'package:fladder/providers/settings/client_settings_provider.dart';
import 'package:fladder/providers/syncplay_provider.dart';
import 'package:fladder/providers/update_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/providers/views_provider.dart';
import 'package:fladder/routes/auto_router.gr.dart';
import 'package:fladder/screens/dashboard/dashboard_screen.dart';
import 'package:fladder/screens/dashboard/music_dashboard_screen.dart';
import 'package:fladder/screens/home_screen.dart';
import 'package:fladder/screens/video_player/components/syncplay_dialog.dart';
import 'package:fladder/services/syncplay/syncplay_models.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout_model.dart';
import 'package:fladder/util/poster_defaults.dart';
import 'package:fladder/widgets/navigation_scaffold/components/collapse_button.dart';
import 'package:fladder/widgets/navigation_scaffold/components/destination_model.dart';
import 'package:fladder/widgets/navigation_scaffold/components/side_navigation_bar.dart';
import 'package:fladder/widgets/navigation_scaffold/components/syncplay_navigation_button.dart';
import 'package:fladder/widgets/navigation_scaffold/navigation_scaffold.dart';
import 'package:fladder/widgets/shared/controller_navigation.dart';
import 'package:fladder/widgets/shared/syncplay_home_entry.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iconsax_plus/iconsax_plus.dart';

final _account = AccountModel(
  name: 'Synthetic navigation fixture',
  id: '44444444444444444444444444444444',
  avatar: '',
  lastUsed: DateTime.utc(2026),
  credentials: CredentialsModel.internal(
    url: 'https://fixture.example.invalid',
    token: 'synthetic-only',
    serverId: '55555555555555555555555555555555',
    deviceId: 'synthetic-device',
  ),
  policy: const jellyfin.UserPolicy(
    authenticationProviderId: 'fixture',
    passwordResetProviderId: 'fixture',
    syncPlayAccess: jellyfin.SyncPlayUserAccessType.joingroups,
  ),
);

class _User extends User {
  _User(this.signedIn);
  final bool signedIn;
  @override
  AccountModel? build() => signedIn ? _account : null;
  @override
  Future<Response<AccountModel>?> updateInformation() async => null;
}

class _Views extends ViewsNotifier {
  _Views(super.ref);
  @override
  Future<ViewsModel?> fetchViews() async => state;
}

class _Dashboard extends DashboardNotifier {
  _Dashboard(super.ref);
  @override
  Future<void> fetchNextUpAndResume() async {}
}

class _Music extends MusicDashboardNotifier {
  _Music(super.ref);
  @override
  Future<void> fetchMusicHome() async {}
}

class _Playlist extends PlaylistNotifier {
  _Playlist(super.ref);
  @override
  Future<void> setItems(List<ItemBaseModel> items) async {}
}

class _Client extends ClientSettingsNotifier {
  _Client(super.ref, bool expanded) {
    applyRestoredSettings(state.copyWith(
      expandSideBar: expanded,
      backgroundImage: BackgroundType.disabled,
      enableBlurEffects: false,
    ));
  }
  @override
  void update(Function(ClientSettingsModel current) value) =>
      applyRestoredSettings(value(state));
}

class _Room extends SyncPlayNotifier {
  _Room(super.ref, this.signedIn);
  final bool signedIn;
  int permissionReads = 0;
  int joins = 0, cancels = 0;
  int? ticket;
  Completer<void>? cancelGate;
  @override
  Future<void> refreshPermission() async {
    permissionReads++;
  }

  @override
  bool get permissionKnown => true;
  @override
  bool get canJoinFromHome => signedIn;
  @override
  int? beginHomeJoin(String code) {
    ticket = ++joins;
    state = const SyncPlayViewState(busy: true, preparingPlayback: true);
    return ticket;
  }

  @override
  Future<void> cancelHomeJoin(int expected) async {
    if (ticket != expected) return;
    cancels++;
    ticket = null;
    await cancelGate?.future;
    state = const SyncPlayViewState();
  }

  void lateReady(int expected) {
    state = SyncPlayViewState(
      readyHomeJoin: expected,
      room: SyncPlayControllerState(
        status: SyncPlayStatus.joined,
        group: SyncPlayGroup(
          groupId: '11111111111111111111111111111111',
          groupName: 'JMS-123456',
          participants: const ['Fixture'],
          lastUpdatedAt: DateTime.utc(2026),
        ),
      ),
    );
  }
}

void main() {
  Future<ProviderContainer> dashboard(
    WidgetTester tester, {
    Size size = const Size(1280, 800),
    bool expanded = false,
    bool music = false,
    bool rtl = false,
    bool phone = false,
    bool controller = false,
    bool signedIn = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('window_manager'),
        (call) async => call.method.startsWith('is') ? false : null);
    addTearDown(() => messenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'), null));
    final container = ProviderContainer(overrides: [
      userProvider.overrideWith(() => _User(signedIn)),
      viewsProvider.overrideWith((ref) => _Views(ref)),
      dashboardProvider.overrideWith((ref) => _Dashboard(ref)),
      musicDashboardProvider.overrideWith((ref) => _Music(ref)),
      musicDashboardModeProvider.overrideWith((ref) => music),
      playlistProvider.overrideWith((ref) => _Playlist(ref)),
      clientSettingsProvider.overrideWith((ref) => _Client(ref, expanded)),
      offlineStateProvider.overrideWithValue(false),
      hasNewUpdateProvider.overrideWithValue(false),
      syncPlayProvider.overrideWith((ref) => _Room(ref, signedIn)),
      jellyApiProvider.overrideWith(
          () => throw StateError('No HTTP in navigation fixture')),
      videoPlayerProvider.overrideWith((ref) =>
          throw StateError('Home navigation must not initialize a player')),
    ]);
    final controllers = {
      for (final tab in HomeTabs.values) tab: ScrollController()
    };
    final destinations = [
      for (final tab in HomeTabs.values)
        DestinationModel(
          label: tab.name,
          route: tab == HomeTabs.dashboard ? const DashboardRoute() : null,
          icon: Icon(tab.icon),
          selectedIcon: Icon(tab.selectedIcon),
          action: () {},
        ),
    ];
    final observer = ControllerFocusObserver(enabled: () => true);
    final router = RootStackRouter.build(routes: [
      NamedRouteDef(
        name: DashboardRoute.name,
        path: '/',
        builder: (context, data) => NavigationScaffold(
          currentRouteName: DashboardRoute.name,
          destinations: destinations,
          nestedChild: const DashboardScreen(),
        ),
      ),
    ]);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
      container.dispose();
      for (final scroll in controllers.values) {
        scroll.dispose();
      }
    });
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router.config(navigatorObservers: () => [observer]),
        locale: const Locale('en'),
        localizationsDelegates: FladderLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: EdgeInsets.only(top: phone ? 24 : 35),
            viewPadding: EdgeInsets.only(top: phone ? 24 : 35),
          ),
          child: Directionality(
            textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
            child: AdaptiveLayout(
              data: AdaptiveLayoutModel(
                viewSize: phone ? ViewSize.phone : ViewSize.tablet,
                layoutMode: phone || size.width < 960
                    ? LayoutMode.single
                    : LayoutMode.dual,
                inputDevice: controller
                    ? InputDevice.dPad
                    : phone
                        ? InputDevice.touch
                        : InputDevice.pointer,
                controllerMode: controller,
                platform:
                    phone ? TargetPlatform.android : TargetPlatform.windows,
                isDesktop: !phone,
                posterDefaults: const PosterDefaults(size: 240, ratio: 0.55),
                controller: controllers,
                sideBarWidth: 0,
                topBarHeight: 0,
                statusBarHeight: 0,
              ),
              child: ControllerNavigation(
                onBack: () => router.maybePopTop(),
                child: child!,
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(DashboardScreen), findsOneWidget);
    expect(find.byType(MusicDashboardScreen),
        music ? findsOneWidget : findsNothing);
    return container;
  }

  Finder entry() => find.byType(SyncPlayNavigationButton).hitTestable();
  Finder entryInk() =>
      find.descendant(of: entry(), matching: find.byType(InkWell)).first;
  void expectSideNavigationGeometry(WidgetTester tester) {
    expect(entry(), findsOneWidget);
    final action = tester.getRect(entryInk());
    final rail = tester.getRect(find.byKey(const Key('navigation_rail')));
    expect(action.left, greaterThanOrEqualTo(rail.left));
    expect(action.right, lessThanOrEqualTo(rail.right));
    expect(action.height, greaterThanOrEqualTo(48));
    for (final menu in find.byType(CollapseButton).evaluate()) {
      expect(
          action.overlaps(tester.getRect(find.byWidget(menu.widget))), isFalse);
    }
    expect(
        find.descendant(
            of: find.byType(DashboardScreen),
            matching: find.byType(SyncPlayNavigationButton)),
        findsNothing);
    expect(
        find.descendant(
            of: find.byType(DashboardScreen),
            matching: find.byType(SyncPlayHomeEntry)),
        findsNothing);
  }

  for (final size in [
    const Size(1280, 800),
    const Size(1920, 1080),
    const Size(853, 533),
    const Size(640, 400)
  ]) {
    for (final expanded in [false, true]) {
      testWidgets(
          'actual Dashboard side navigation ${size.width} expanded=$expanded remains clickable',
          (tester) async {
        final container =
            await dashboard(tester, size: size, expanded: expanded);
        await tester.ensureVisible(find.byType(SyncPlayNavigationButton));
        await tester.pumpAndSettle();
        expectSideNavigationGeometry(tester);
        await tester.tap(entryInk());
        await tester.pumpAndSettle();
        expect(find.byType(SyncPlayDialog), findsOneWidget);
        expect(container.read(syncPlayProvider.notifier), isA<_Room>());
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(SyncPlayDialog), findsNothing);
      }, variant: const TargetPlatformVariant({TargetPlatform.windows}));
    }
  }

  testWidgets('music Dashboard and RTL share the actual side navigation action',
      (tester) async {
    await dashboard(tester, music: true, rtl: true, expanded: true);
    expectSideNavigationGeometry(tester);
    await tester.tap(entryInk());
    await tester.pumpAndSettle();
    expect(find.byType(SyncPlayDialog), findsOneWidget);
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets(
      'Tab Enter and held controller A open one dialog and B returns focus',
      (tester) async {
    await dashboard(tester, controller: true);
    navBarNode.requestFocus();
    await tester.pump();
    for (var index = 0; index < 12; index++) {
      final context = FocusManager.instance.primaryFocus?.context;
      if (context?.findAncestorWidgetOfExactType<SyncPlayNavigationButton>() !=
          null) {
        break;
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    final opener = FocusManager.instance.primaryFocus!;
    expect(
        opener.context!
            .findAncestorWidgetOfExactType<SyncPlayNavigationButton>(),
        isNotNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(SyncPlayDialog), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonB,
        platform: 'android');
    await tester.pumpAndSettle();
    expect(find.byType(SyncPlayDialog), findsNothing);
    expect(FocusManager.instance.primaryFocus, same(opener));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.gameButtonA,
        platform: 'android');
    await tester.pumpAndSettle();
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.gameButtonA,
        platform: 'android');
    await tester.pump();
    expect(find.byType(SyncPlayDialog), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonB,
        platform: 'android');
    await tester.pumpAndSettle();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.gameButtonA,
        platform: 'android');
    await tester.pumpAndSettle();
    expect(find.byType(SyncPlayDialog), findsNothing);
    expect(FocusManager.instance.primaryFocus, same(opener));
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets(
      'phone home opens the shared navigation drawer before joining a room',
      (tester) async {
    await dashboard(tester,
        phone: true, size: const Size(390, 844), signedIn: false);
    expect(entry(), findsNothing);
    await tester.tap(find.byIcon(IconsaxPlusLinear.menu));
    await tester.pumpAndSettle();
    expect(entry(), findsOneWidget);
    await tester.tap(entryInk());
    await tester.pumpAndSettle();
    expect(find.byType(SyncPlayDialog), findsOneWidget);
    expect(find.text('Sign in to Jellyfin before entering a room code.'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));

  testWidgets(
      'signed-in phone drawer cancels pending join and ignores late ready without a disposed ref',
      (tester) async {
    final container =
        await dashboard(tester, phone: true, size: const Size(390, 844));
    await tester.tap(find.byIcon(IconsaxPlusLinear.menu));
    await tester.pumpAndSettle();
    navBarNode.requestFocus();
    await tester.pump();
    for (var index = 0; index < 12; index++) {
      final context = FocusManager.instance.primaryFocus?.context;
      if (context?.findAncestorWidgetOfExactType<SyncPlayNavigationButton>() !=
          null) {
        break;
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    final opener = FocusManager.instance.primaryFocus!;
    expect(
        opener.context!
            .findAncestorWidgetOfExactType<SyncPlayNavigationButton>(),
        isNotNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '123456');
    await tester.pump();
    await tester.ensureVisible(find.text('Join room'));
    await tester.tap(find.text('Join room'));
    await tester.pump();
    final room = container.read(syncPlayProvider.notifier) as _Room;
    final ticket = room.ticket!;
    room.cancelGate = Completer<void>();
    await tester.ensureVisible(find.text('Cancel'));
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(room.cancels, 1);
    expect(room.ticket, isNull);
    room.lateReady(ticket);
    await tester.pump();
    expect(container.exists(videoPlayerProvider), isFalse);
    room.cancelGate!.complete();
    await tester.pumpAndSettle();
    expect(find.byType(SyncPlayDialog), findsNothing);
    room.lateReady(ticket);
    await tester.pumpAndSettle();
    expect(container.exists(videoPlayerProvider), isFalse);
    expect(entry(), findsOneWidget);
    expect(opener.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(SyncPlayDialog), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));
}
