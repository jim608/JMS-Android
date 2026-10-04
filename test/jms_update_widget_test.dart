import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fladder/l10n/generated/app_localizations.dart';
import 'package:fladder/providers/update_provider.dart';
import 'package:fladder/screens/settings/widgets/settings_update_information.dart';
import 'package:fladder/util/update_checker.dart';
import 'package:fladder/util/update_controller.dart';
import 'package:fladder/util/update_source.dart';
import 'package:fladder/util/linux_update_bridge_io.dart';

import 'jms_update_test.dart' show FakeBridge;
import 'jms_windows_update_test.dart'
    show desktopRelease, desktopSource, desktopDevice;
import 'jms_update_flow_test.dart'
    show FlowBridge, FlowChecker, flowController, flowRelease;
import 'jms_linux_update_test.dart' show linuxDevice, linuxManifest;

class DesktopUiBridge extends FakeBridge {
  @override
  bool get isDesktop => true;
  @override
  Future<UpdateDevice> device() async => desktopDevice;
}

Future<void> mountUpdateUi(WidgetTester tester, UpdateController controller) =>
    tester.pumpWidget(ProviderScope(
      overrides: [updateProvider.overrideWith((ref) => controller)],
      child: const MaterialApp(
        locale: Locale('en'),
        localizationsDelegates: [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
            body: SingleChildScrollView(child: SettingsUpdateInformation())),
      ),
    ));

void main() {
  testWidgets('Flatpak shows managed updates without Arch actions or switches',
      (tester) async {
    final controller = UpdateController(
        checker: UpdateChecker(
            source: const UpdateSource(owner: 'jim608', repo: 'JMS-Linux')),
        bridge: FlatpakUpdateBridge());
    await controller.initialize();
    await mountUpdateUi(tester, controller);
    await tester.pumpAndSettle();
    expect(find.text('JMS Flatpak updates'), findsOneWidget);
    expect(
        find.textContaining('flatpak update com.jim608.jms'), findsOneWidget);
    expect(find.textContaining('newer .flatpak file'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
    expect(find.byKey(const ValueKey('update-primary-check')), findsNothing);
    expect(find.byKey(const ValueKey('update-primary-download')), findsNothing);
    expect(find.byKey(const ValueKey('update-primary-install')), findsNothing);
    expect(controller.supported, isFalse);
  });

  testWidgets(
      'failed Android initialization can retry from the visible check action',
      (tester) async {
    SharedPreferences.setMockInitialValues({'jms.update.auto': false});
    final bridge = FlowBridge()..deviceFailure = 'nativeUnavailable';
    final checker =
        FlowChecker(UpdateCheckResult(UpdateStatus.available, flowRelease()));
    final controller = UpdateController(checker: checker, bridge: bridge);
    await controller.initialize();
    await mountUpdateUi(tester, controller);
    await tester.pumpAndSettle();
    expect(
        find.text(
            'Updater could not initialize. Tap Check for updates to retry.'),
        findsOneWidget);
    expect(
        find.text('Installation blocked or verification failed'), findsNothing);
    final check = find.byKey(const ValueKey('update-primary-check'));
    expect(tester.widget<FilledButton>(check).onPressed, isNotNull);
    for (final tile
        in tester.widgetList<SwitchListTile>(find.byType(SwitchListTile))) {
      expect(tile.onChanged, isNotNull);
    }
    await tester.ensureVisible(check);
    await tester.tap(check);
    await tester.pumpAndSettle();
    expect(controller.ready, isFalse);
    expect(tester.widget<FilledButton>(check).onPressed, isNotNull);
    bridge.deviceFailure = null;
    await tester.tap(check);
    await tester.pumpAndSettle();
    expect(controller.ready, isTrue);
    expect(controller.status, UpdateStatus.available);
    expect(checker.checks, 1);
    expect(bridge.deviceCalls, 3);
    expect(bridge.installs, 0);
  });

  testWidgets(
      'community Linux install shows manual recipe instructions without an install action',
      (tester) async {
    SharedPreferences.setMockInitialValues({'jms.update.auto': false});
    final bridge = FlowBridge()
      ..installed = linuxDevice
      ..packageChannel = UpdatePackageChannel.community;
    final controller = await flowController(
        FlowChecker(UpdateCheckResult(UpdateStatus.available,
            flowRelease(metadata: linuxManifest(), platform: 'linux-x64'))),
        bridge);
    await controller.download();
    await controller.install();
    await mountUpdateUi(tester, controller);
    await tester.pumpAndSettle();
    expect(find.text('JMS EndeavourOS / Arch Linux updates'), findsOneWidget);
    expect(find.textContaining('yay -Bi ./jms-bin'), findsOneWidget);
    expect(find.byKey(const ValueKey('update-primary-install')), findsNothing);
    expect(find.byKey(const ValueKey('update-primary-download')), findsNothing);
    expect(bridge.installs, 0);
  });

  testWidgets('available update has one primary action and collapsed notes',
      (tester) async {
    SharedPreferences.setMockInitialValues({'jms.update.auto': false});
    final controller = await flowController(
        FlowChecker(UpdateCheckResult(UpdateStatus.available, flowRelease())),
        FlowBridge());
    await mountUpdateUi(tester, controller);
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('update-primary-download')), findsOneWidget);
    expect(find.byKey(const ValueKey('update-primary-install')), findsNothing);
    expect(find.byType(FilledButton), findsOneWidget);
    expect(find.text('TEST_ONLY notes'), findsNothing);
    await tester
        .ensureVisible(find.byKey(const ValueKey('update-release-notes')));
    await tester.tap(find.text('Release notes'));
    await tester.pumpAndSettle();
    expect(find.text('TEST_ONLY notes'), findsOneWidget);
  });

  testWidgets(
      'verified local installer replaces the download action after a network error',
      (tester) async {
    SharedPreferences.setMockInitialValues({'jms.update.auto': false});
    final checker =
        FlowChecker(UpdateCheckResult(UpdateStatus.available, flowRelease()));
    final bridge = FlowBridge();
    final controller = await flowController(checker, bridge);
    await controller.download();
    checker.result = const UpdateCheckResult(UpdateStatus.network);
    await controller.check();
    await mountUpdateUi(tester, controller);
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('update-primary-install')), findsOneWidget);
    expect(find.byKey(const ValueKey('update-primary-download')), findsNothing);
    expect(find.textContaining('still verified and available to install'),
        findsOneWidget);
    expect(find.byType(FilledButton), findsOneWidget);
    await tester
        .ensureVisible(find.byKey(const ValueKey('update-primary-install')));
    await tester.tap(find.byKey(const ValueKey('update-primary-install')));
    await tester.pumpAndSettle();
    expect(bridge.installs, 1);
  });

  testWidgets(
      'an active download shows progress and cancel, then one retry action',
      (tester) async {
    SharedPreferences.setMockInitialValues({'jms.update.auto': false});
    final bridge = FlowBridge()..transfer = Completer<void>();
    final controller = await flowController(
        FlowChecker(UpdateCheckResult(UpdateStatus.available, flowRelease())),
        bridge);
    final transfer = controller.download();
    bridge.onProgress?.call(.35);
    await mountUpdateUi(tester, controller);
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('35%'), findsOneWidget);
    expect(find.byKey(const ValueKey('update-primary-download')), findsNothing);
    expect(find.byKey(const ValueKey('update-primary-install')), findsNothing);
    await tester
        .ensureVisible(find.byKey(const ValueKey('update-cancel-download')));
    await tester.tap(find.byKey(const ValueKey('update-cancel-download')));
    await transfer;
    await tester.pumpAndSettle();
    expect(find.text('Retry download'), findsOneWidget);
    expect(find.byType(FilledButton), findsOneWidget);
    expect(bridge.installs, 0);
  });

  testWidgets(
      'permission is the sole primary action for a verified Android package',
      (tester) async {
    SharedPreferences.setMockInitialValues({'jms.update.auto': false});
    final bridge = FlowBridge()
      ..permissionCheck = (Completer<bool>()..complete(false));
    final controller = await flowController(
        FlowChecker(UpdateCheckResult(UpdateStatus.available, flowRelease())),
        bridge);
    await controller.download();
    await controller.install();
    await mountUpdateUi(tester, controller);
    await tester.pumpAndSettle();
    expect(find.text('Open installation permission'), findsOneWidget);
    expect(find.byType(FilledButton), findsOneWidget);
    expect(find.byKey(const ValueKey('update-primary-download')), findsNothing);
    expect(bridge.installs, 0);
  });

  testWidgets(
      'desktop installer requires explicit confirmation and can be cancelled',
      (tester) async {
    SharedPreferences.setMockInitialValues({'jms.update.auto': false});
    final bridge = DesktopUiBridge();
    final controller = UpdateController(
        checker: UpdateChecker(source: desktopSource), bridge: bridge);
    await controller.initialize();
    controller.latestRelease = desktopRelease();
    await controller.download();
    await tester.pumpWidget(ProviderScope(
      overrides: [updateProvider.overrideWith((ref) => controller)],
      child: const MaterialApp(
        locale: Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
        localizationsDelegates: [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
            body: SingleChildScrollView(child: SettingsUpdateInformation())),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('JMS Windows 線上更新'), findsOneWidget);
    await tester.ensureVisible(find.text('安裝更新'));
    await tester.tap(find.text('安裝更新'));
    await tester.pumpAndSettle();
    expect(find.textContaining('未經程式碼簽章'), findsOneWidget);
    expect(bridge.installs, 0);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(bridge.installs, 0);
    expect(find.byType(AlertDialog), findsNothing);
  });
  testWidgets('unconfigured update UI is honest, usable and localized',
      (tester) async {
    final font = FontLoader('JmsTestCjk')
      ..addFont(
          rootBundle.load('assets/subtitle_fonts/NotoSansCJKtc-Regular.otf'));
    await font.load();
    tester.view.physicalSize = const Size(480, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller =
        UpdateController(checker: UpdateChecker(), bridge: FakeBridge())
          ..ready = true;
    final key = GlobalKey();
    await tester.pumpWidget(ProviderScope(
      overrides: [updateProvider.overrideWith((ref) => controller)],
      child: MaterialApp(
        theme:
            ThemeData(fontFamily: 'JmsTestCjk', colorSchemeSeed: Colors.teal),
        locale:
            const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: RepaintBoundary(
            key: key,
            child: const Scaffold(
                body:
                    SingleChildScrollView(child: SettingsUpdateInformation()))),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('尚未設定更新來源'), findsNWidgets(2));
    expect(find.text('檢查更新'), findsOneWidget);
    expect(find.text('接收測試版'), findsOneWidget);
    expect(find.text('下載更新／手動重試'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('artifacts/checks/update-unconfigured-m9.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  });
  for (final entry in {
    UpdateStatus.noRelease: '已連上更新來源，此頻道尚無可用的已發布版本',
    UpdateStatus.sourceUnavailable: '無法存取更新儲存庫：不存在或沒有權限',
    UpdateStatus.rateLimited: 'GitHub 限流，請稍後再試',
    UpdateStatus.initializationFailed: '更新器初始化失敗，請點「檢查更新」重試。',
  }.entries) {
    testWidgets('configured source displays distinct ${entry.key.name} status',
        (tester) async {
      final controller = UpdateController(
          checker: UpdateChecker(
              source: const UpdateSource(
                  owner: 'fixture-owner', repo: 'jms-fixture')),
          bridge: FakeBridge())
        ..ready = true
        ..status = entry.key;
      await tester.pumpWidget(ProviderScope(
        overrides: [updateProvider.overrideWith((ref) => controller)],
        child: const MaterialApp(
          locale: Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
              body: SingleChildScrollView(child: SettingsUpdateInformation())),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text(entry.value), findsOneWidget);
      expect(find.text('fixture-owner/jms-fixture'), findsOneWidget);
      expect(find.text('尚未設定更新來源'), findsNothing);
      expect(find.text('下載更新／手動重試'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
