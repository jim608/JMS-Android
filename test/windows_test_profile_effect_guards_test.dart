import 'dart:ui';

import 'package:fladder/background/update_notifications_worker.dart';
import 'package:fladder/logic/application_menu.dart';
import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/notification_model.dart';
import 'package:fladder/providers/diagnostics_provider.dart';
import 'package:fladder/providers/discord_presence_provider.dart';
import 'package:fladder/services/discord/discord_activity.dart';
import 'package:fladder/services/discord/discord_presence_controller.dart';
import 'package:fladder/services/notification_service.dart';
import 'package:fladder/util/app_diagnostics.dart';
import 'package:fladder/util/jms_test_profile_policy.dart';
import 'package:fladder/util/update_checker.dart';
import 'package:fladder/util/update_controller.dart';
import 'package:fladder/util/update_source.dart';
import 'package:fladder/wrappers/media_control_wrapper.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

import 'fixtures/discord_fake_client.dart';

class _ForbiddenUpdateBridge extends UpdateBridge {
  int calls = 0;
  Never _called() {
    calls++;
    throw StateError('Fixture updater bridge must not be called');
  }

  @override
  Future<UpdateDevice> device() async => _called();
  @override
  Future<void> setAllowed(bool allowed) async => _called();
  @override
  Future<void> cancel() async => _called();
  @override
  Future<void> download(ReleaseInfo release) async => _called();
  @override
  Future<bool> canInstall() async => _called();
  @override
  Future<void> permission() async => _called();
  @override
  Future<String> install() async => _called();
  @override
  Future<UpdateTransfer?> restoreTransfer() async => _called();
}

class _ForbiddenPreferences extends InMemorySharedPreferencesStore {
  _ForbiddenPreferences() : super.empty();
  int reads = 0;
  @override
  Future<Map<String, Object>> getAll() async {
    reads++;
    throw StateError('Fixture preference read must not occur');
  }

  @override
  Future<Map<String, Object>> getAllWithParameters(
      GetAllParameters parameters) async {
    reads++;
    throw StateError('Fixture preference read must not occur');
  }
}

class _UnreadFixtureItem implements ItemBaseModel {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Media guard must return before reading fixture fields');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('isolated new-instance action cannot open a normal-profile process',
      () async {
    var launches = 0;
    final menu =
        ApplicationMenuImp(newInstanceLauncher: () async => launches++);
    await menu.newInstance();
    expect(launches, 0);
    JmsTestProfilePolicy.resetRuntimeIsolationForTesting();
    await menu.newInstance();
    expect(launches, 1);
  });

  setUp(() {
    JmsTestProfilePolicy.resetRuntimeIsolationForTesting();
    JmsTestProfilePolicy.enableRuntimeIsolation();
  });

  tearDown(() {
    JmsTestProfilePolicy.resetRuntimeIsolationForTesting();
    SharedPreferences.resetStatic();
  });

  test('runtime isolation applies to default service constructors', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final client = FakeDiscordPresenceClient();
    final discord = DiscordPresenceSettings(
      preferences: prefs,
      controller: DiscordPresenceController(client: client),
    );
    final diagnostics = DiagnosticsSettings(
      preferences: prefs,
      version: '0.11.1-jms.51',
      buildId: 'JMS-0.11.1-jms.51-123456abcdef',
      platform: 'windows',
    );
    final reporter = AppDiagnostics(
      endpoint: Uri.parse('https://diagnostics.example.invalid/fixture'),
      platform: 'windows',
      version: '0.11.1-jms.51',
      buildId: 'JMS-0.11.1-jms.51-123456abcdef',
    );
    final bridge = _ForbiddenUpdateBridge();
    var requests = 0;
    final updater = UpdateController(
      checker: UpdateChecker(
        source: const UpdateSource(owner: 'fixture-owner', repo: 'jms-fixture'),
        client: MockClient((_) async {
          requests++;
          throw StateError('Runtime-isolated updater must not use the network');
        }),
      ),
      bridge: bridge,
      preferences: () async => throw StateError(
          'Runtime-isolated updater must not request preferences'),
    );
    expect(discord.disabledForTestProfile, isTrue);
    expect(diagnostics.disabledForTestProfile, isTrue);
    expect(reporter.disabledForTestProfile, isTrue);
    expect(updater.disabledForTestProfile, isTrue);
    expect(updater.supported, isFalse);
    await updater.initialize();
    await updater.check();
    expect(bridge.calls, 0);
    expect(requests, 0);
    updater.dispose();
    reporter.dispose();
    diagnostics.dispose();
    discord.dispose();
    await client.events.close();
  });

  testWidgets(
      'isolated profile cannot enable IPC or artwork with saved consent',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'jms.discord.presence.v1.fixture-scope.enabled': true,
      'jms.discord.presence.v1.fixture-scope.shareTitle': true,
      'jms.discord.presence.v1.fixture-scope.shareArtwork': true,
    });
    final prefs = await SharedPreferences.getInstance();
    final client = FakeDiscordPresenceClient();
    var artworkCalls = 0;
    final settings = DiscordPresenceSettings(
      preferences: prefs,
      controller: DiscordPresenceController(client: client),
      artworkLoader: (_) async {
        artworkCalls++;
        return 'https://images.example.invalid/fixture.jpg';
      },
      // An explicit false cannot override validated runtime isolation.
      disabledForTestProfile: false,
    );
    settings.activateAccount('fixture-scope');
    settings.updatePlayback(
      const DiscordPlaybackSnapshot(
          active: true, title: 'Fixture title', playing: true),
      privateMode: false,
      artworkItemId: 'fixture-item',
    );
    settings.updateBrowsing(
      const DiscordBrowsingSnapshot.details(
          title: 'Fixture title', artworkItemId: 'fixture-item'),
      privateMode: false,
    );
    expect(await settings.setEnabled(true), isFalse);
    expect(await settings.setShareTitle(true), isFalse);
    expect(await settings.setShareArtwork(true), isFalse);
    await tester.pump(const Duration(seconds: 3));
    expect(settings.supported, isFalse);
    expect(settings.enabled, isFalse);
    expect(client.connections, 0);
    expect(client.activities, isEmpty);
    expect(artworkCalls, 0);
    settings.dispose();
    await tester.pump();
    await client.events.close();
  });

  test('isolated diagnostics settings never activate or replace error hooks',
      () async {
    const endpoint =
        'https://diagnostics.example.invalid/api/jms/diagnostics/v1';
    SharedPreferences.setMockInitialValues({
      DiagnosticsSettings.consentKey: true,
      DiagnosticsSettings.endpointKey: endpoint,
    });
    final prefs = await SharedPreferences.getInstance();
    final originalFlutter = FlutterError.onError;
    final originalPlatform = PlatformDispatcher.instance.onError;
    var clients = 0;
    final settings = DiagnosticsSettings(
      preferences: prefs,
      version: '0.11.1-jms.45',
      buildId: 'JMS-0.11.1-jms.45-123456abcdef',
      platform: 'windows',
      disabledForTestProfile: false,
      clientFactory: () {
        clients++;
        return MockClient((_) async => http.Response('', 202));
      },
    );
    expect(await settings.activateServer('fixture-server', endpoint), isFalse);
    expect(await settings.setEndpoint(endpoint), isFalse);
    expect(await settings.setEnabled(true), isFalse);
    expect(settings.endpointValue, isEmpty);
    expect(settings.configured, isFalse);
    expect(settings.enabled, isFalse);
    expect(clients, 0);
    expect(FlutterError.onError, same(originalFlutter));
    expect(PlatformDispatcher.instance.onError, same(originalPlatform));
    settings.dispose();
  });

  test('direct diagnostic reporter cannot create a transport or install hooks',
      () async {
    var clients = 0;
    final reporter = AppDiagnostics(
      endpoint: Uri.parse(
          'https://diagnostics.example.invalid/api/jms/diagnostics/v1'),
      platform: 'windows',
      version: '0.11.1-jms.45',
      buildId: 'JMS-0.11.1-jms.45-123456abcdef',
      disabledForTestProfile: false,
      clientFactory: () {
        clients++;
        return MockClient((_) async => http.Response('', 202));
      },
    )..enabled = true;
    final originalFlutter = FlutterError.onError;
    final originalPlatform = PlatformDispatcher.instance.onError;
    final hooks = DiagnosticsHooks(reporter)..start();
    expect(await reporter.runtimeError(DiagnosticCategory.flutterFramework),
        isFalse);
    expect(
        await reporter.performance(
            frameCount: 10,
            slowFrameCount: 5,
            worstFrameMs: 100,
            totalDurationMs: 1000),
        isFalse);
    expect(clients, 0);
    expect(FlutterError.onError, same(originalFlutter));
    expect(PlatformDispatcher.instance.onError, same(originalPlatform));
    hooks.stop();
    reporter.dispose();
  });

  test(
      'runtime isolation blocks notification registration, permissions and delivery',
      () async {
    var channelCalls = 0;
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
      channelCalls++;
      throw StateError(
          'Isolated test build must not call notification plugins');
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await NotificationService.init();
    expect(await NotificationService.requestPermission(), isFalse);
    expect(await NotificationService.getInitialNotificationPayload(), isNull);
    await NotificationService.showNewItemsNotification('Fixture', 'Fixture');
    await NotificationService.showGroupedNotifications(
        'fixture',
        'Fixture',
        [
          const NotificationModel(
              key: 'fixture',
              id: 'fixture',
              title: 'Fixture',
              payLoad: 'jms:///fixture'),
        ],
        'Fixture summary');
    expect(channelCalls, 0);
  });

  test(
      'disabled updater rejects direct actions before preferences or native calls',
      () async {
    var preferenceReads = 0;
    var networkCalls = 0;
    final bridge = _ForbiddenUpdateBridge();
    const source = UpdateSource(owner: 'fixture-owner', repo: 'jms-fixture');
    final checker = UpdateChecker(
      source: source,
      client: MockClient((_) async {
        networkCalls++;
        throw StateError('Fixture update network must not be used');
      }),
    );
    final controller = UpdateController(
      checker: checker,
      bridge: bridge,
      preferences: () async {
        preferenceReads++;
        throw StateError('Fixture updater preferences must not be read');
      },
      disabledForTestProfile: false,
    );
    await controller.initialize();
    controller.ready = true;
    controller.latestRelease = ReleaseInfo(
      UpdateManifest.parse({
        'schemaVersion': 1,
        'applicationId': 'com.jim608.jms',
        'versionName': '0.11.1-jms.6',
        'versionCode': 2006,
        'minSdk': 24,
        'abis': ['arm64-v8a'],
        'sourceCommit': 'a' * 40,
        'apk': {'name': 'JMS.apk', 'size': 100, 'sha256': 'b' * 64},
        'source': {'name': 'JMS-source.zip', 'size': 200, 'sha256': 'c' * 64},
      }),
      '',
      DateTime(2026),
      Uri.parse(
          'https://github.com/fixture-owner/jms-fixture/releases/download/v6/JMS.apk'),
      source.identity,
    );
    controller.automatic = false;
    await controller.check();
    await controller.download();
    await controller.install(openPermission: true);
    await controller.cancel();
    await controller.setAutomatic(true);
    await controller.setPrerelease(true);
    await controller.skip();
    controller.later();
    controller.setPlayback(true);
    controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    expect(controller.status, UpdateStatus.unsupported);
    expect(controller.automatic, isFalse);
    expect(controller.prerelease, isFalse);
    expect(controller.skipped, isNull);
    expect(controller.deferred, isFalse);
    expect(controller.playback, isFalse);
    expect(controller.hasNewUpdate, isFalse);
    controller.dispose();
    expect(preferenceReads, 0);
    expect(networkCalls, 0);
    expect(bridge.calls, 0);
  });

  test(
      'headless worker returns before requesting even a synthetic preferences store',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = _ForbiddenPreferences();
    SharedPreferencesStorePlatform.instance = store;
    addTearDown(() => SharedPreferences.setMockInitialValues({}));
    callbackDispatcher();
    expect(await performHeadlessUpdateCheck(debug: true), isNull);
    expect(store.reads, 0);
  });

  test('raw Windows media metadata setup is disabled before media or OS access',
      () async {
    final provider = Provider((ref) => MediaControlsWrapper(ref: ref));
    final container = ProviderContainer();
    final wrapper = container.read(provider);
    try {
      await wrapper.windowSMTCSetup(_UnreadFixtureItem(), Duration.zero, true);
      expect(wrapper.smtc, isNull);
    } finally {
      await wrapper.dispose();
      container.dispose();
    }
  });
}
