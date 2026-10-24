import 'package:chopper/chopper.dart';
import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/l10n/generated/app_localizations.dart';
import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/credentials_model.dart';
import 'package:fladder/models/seerr_credentials_model.dart';
import 'package:fladder/models/views_model.dart';
import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/cultures_provider.dart';
import 'package:fladder/providers/discord_presence_provider.dart';
import 'package:fladder/providers/home_preferences_provider.dart';
import 'package:fladder/providers/service_provider.dart';
import 'package:fladder/providers/update_notifications_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/providers/views_provider.dart';
import 'package:fladder/screens/settings/profile_settings_page.dart';
import 'package:fladder/screens/settings/widgets/home_preferences_editors.dart';
import 'package:fladder/screens/settings/widgets/jms_entry_config_tile.dart';
import 'package:fladder/screens/settings/widgets/settings_discord_presence.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout_model.dart';
import 'package:fladder/util/poster_defaults.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Service implements JellyService {
  UserConfiguration? saved;
  int writes = 0;

  @override
  Future<UserConfiguration?> updateUserConfiguration(UserConfiguration config) async {
    writes++;
    saved = config;
    return config;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected service operation ${invocation.memberName}');
}

class _Api extends JellyApi {
  _Api(this.service);
  final JellyService service;

  @override
  JellyService build() => service;
}

class _User extends User {
  _User(this.initial, this.service);
  final AccountModel initial;
  final _Service service;
  int refreshes = 0;

  @override
  AccountModel? build() => initial;

  @override
  Future<Response<AccountModel>?> updateInformation() async {
    refreshes++;
    state = state?.copyWith(userConfiguration: service.saved);
    return null;
  }

  void changeConfiguration(UserConfiguration config) {
    state = state?.copyWith(userConfiguration: config);
  }
}

class _Views extends ViewsNotifier {
  _Views(super.ref);
  int refreshes = 0;

  @override
  Future<ViewsModel?> fetchViews() async {
    refreshes++;
    return state;
  }
}

class _Cultures extends Cultures {
  @override
  List<CultureDto> build() => const [];
}

class _Discord extends ChangeNotifier implements DiscordPresenceSettings {
  @override
  bool get supported => true;
  @override
  String? get activeScope => 'synthetic-account';
  @override
  bool get hasAccount => true;
  @override
  bool get busy => false;
  @override
  bool get enabled => false;
  @override
  bool get shareTitle => false;
  @override
  bool get shareArtwork => false;
  @override
  DiscordConnectionState get status => DiscordConnectionState.disconnected;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected Discord operation ${invocation.memberName}');
}

void main() {
  const serviceCredentials = SeerrCredentialsModel(
    serverUrl: 'https://requests.example.invalid',
    sessionCookie: 'fixture-test-only-session',
    linkedServerId: 'synthetic-server',
  );
  const original = UserConfiguration(
    orderedViews: ['unavailable-library', 'library-b', 'library-a'],
    latestItemsExcludes: ['hidden-library', 'unavailable-library'],
    groupedFolders: ['grouped-folder'],
    hidePlayedInLatest: false,
    subtitleLanguagePreference: 'jpn',
    rememberSubtitleSelections: true,
  );
  late _Service service;
  late _User user;
  late _Views views;
  late ProviderContainer container;

  setUp(() {
    service = _Service();
    user = _User(
      AccountModel(
        name: 'Synthetic account',
        id: 'synthetic-user',
        avatar: '',
        lastUsed: DateTime.utc(2026),
        credentials: CredentialsModel.internal(url: 'https://media.example.invalid'),
        userConfiguration: original,
        seerrCredentials: serviceCredentials,
        seerrRequestsEnabled: true,
      ),
      service,
    );
    container = ProviderContainer(overrides: [
      jellyApiProvider.overrideWith(() => _Api(service)),
      userProvider.overrideWith(() => user),
      viewsProvider.overrideWith((ref) => views = _Views(ref)),
      culturesProvider.overrideWith(_Cultures.new),
      supportsNotificationsProvider.overrideWith((ref) => false),
      discordPresenceSettingsProvider.overrideWith((ref) => _Discord()),
    ]);
  });
  tearDown(() => container.dispose());

  Future<AppLocalizations> showEditor(WidgetTester tester,
      {Locale locale = const Locale('en'), bool fullProfile = false}) async {
    await container.read(homePreferencesProvider.notifier).load();
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AdaptiveLayout(
          data: const AdaptiveLayoutModel(
            viewSize: ViewSize.desktop,
            layoutMode: LayoutMode.single,
            inputDevice: InputDevice.pointer,
            platform: TargetPlatform.windows,
            isDesktop: true,
            posterDefaults: PosterDefaults(size: 100, ratio: 0.7),
            controller: {},
            sideBarWidth: 0,
            topBarHeight: 0,
            statusBarHeight: 0,
          ),
          child: Scaffold(body: fullProfile ? const ProfileSettingsPage() : const HomePreferencesEditor()),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return AppLocalizations.of(tester.element(find.byType(HomePreferencesEditor)));
  }

  for (final locale in [const Locale('en'), const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant')]) {
    testWidgets('only watched-content preference remains visible in $locale', (tester) async {
      final strings = await showEditor(tester, locale: locale);
      expect(find.text(strings.libraryOrderTitle), findsNothing);
      expect(find.text(strings.libraryOrderDescription), findsNothing);
      expect(find.text(strings.groupedFoldersTitle), findsNothing);
      expect(find.text(strings.groupedFoldersDescription), findsNothing);
      expect(find.text(strings.hidePlayedInLatestTitle), findsOneWidget);
      expect(find.text(strings.hidePlayedInLatestDescription), findsOneWidget);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      expect(container.read(homePreferencesProvider.notifier).hasChanges, isFalse);
      expect(service.writes, 0);
    });
  }

  testWidgets('watched-content toggle saves without rewriting library configuration', (tester) async {
    final strings = await showEditor(tester);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(service.writes, 0);
    await tester.tap(find.text(strings.save));
    await tester.pumpAndSettle();
    expect(service.writes, 1);
    expect(service.saved, original.copyWith(hidePlayedInLatest: true));
    expect(user.refreshes, 1);
    expect(views.refreshes, 1);
    expect(container.read(homePreferencesProvider.notifier).hasChanges, isFalse);
  });

  testWidgets('cancelling restores watched-content preference without writing settings', (tester) async {
    final strings = await showEditor(tester);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.tap(find.text(strings.cancel));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    expect(container.read(homePreferencesProvider.notifier).hasChanges, isFalse);
    expect(service.writes, 0);
    expect(container.read(userProvider)?.userConfiguration, original);
  });

  testWidgets('save retains library changes received after opening the editor', (tester) async {
    final strings = await showEditor(tester);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    final latest = original.copyWith(
      orderedViews: ['new-library', 'unavailable-library', 'library-a'],
      latestItemsExcludes: ['new-exclusion'],
      groupedFolders: ['new-group'],
    );
    user.changeConfiguration(latest);
    await tester.tap(find.text(strings.save));
    await tester.pumpAndSettle();
    expect(service.saved, latest.copyWith(hidePlayedInLatest: true));
    expect(service.writes, 1);
  });

  test('missing watched preference stays unchanged until explicitly edited', () async {
    container.read(userProvider);
    user.changeConfiguration(original.copyWithWrapped(hidePlayedInLatest: const Wrapped.value(null)));
    final notifier = container.read(homePreferencesProvider.notifier);
    await notifier.load();
    expect(container.read(homePreferencesProvider).hidePlayedInLatest, isFalse);
    expect(notifier.hasChanges, isFalse);
    expect(service.writes, 0);
  });

  testWidgets('profile exposes Discord without other service entries or changing saved service settings',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final strings = await showEditor(tester, fullProfile: true);
    expect(find.byType(SettingsDiscordPresence), findsOneWidget);
    expect(find.byKey(const ValueKey('discord-presence-enabled')), findsOneWidget);
    expect(find.byKey(const ValueKey('discord-presence-share-title')), findsOneWidget);
    expect(find.byKey(const ValueKey('discord-presence-share-artwork')), findsOneWidget);
    expect(find.byType(JmsEntryConfigTile), findsNothing);
    expect(find.text('Jellyseerr / Seerr'), findsNothing);
    expect(find.text('Service integrations'), findsNothing);
    expect(find.text(strings.seerrRequestNotifications), findsNothing);
    expect(find.text(strings.libraryOrderTitle), findsNothing);
    expect(find.text(strings.groupedFoldersTitle), findsNothing);
    expect(find.text(strings.hidePlayedInLatestTitle), findsOneWidget);
    final watchedToggle = find.descendant(of: find.byType(HomePreferencesEditor), matching: find.byType(Switch));
    await tester.tap(watchedToggle);
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(watchedToggle).value, isTrue);
    await tester.tap(find.text(strings.save));
    await tester.pumpAndSettle();
    expect(service.saved, original.copyWith(hidePlayedInLatest: true));
    expect(container.read(userProvider)?.seerrCredentials, serviceCredentials);
    expect(container.read(userProvider)?.seerrRequestsEnabled, isTrue);
    expect(service.writes, 1);
    expect(tester.takeException(), isNull);
  });
}
