import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/l10n/generated/app_localizations.dart';
import 'package:fladder/providers/update_provider.dart';
import 'package:fladder/screens/settings/widgets/settings_update_information.dart';
import 'package:fladder/util/update_checker.dart';
import 'package:fladder/util/update_controller.dart';
import 'package:fladder/util/update_source.dart';

import 'jms_update_test.dart' show FakeBridge;

void main() {
  testWidgets('unconfigured update UI is honest, usable and localized', (tester) async {
    final font = FontLoader('JmsTestCjk')..addFont(rootBundle.load('assets/subtitle_fonts/NotoSansCJKtc-Regular.otf'));
    await font.load();
    tester.view.physicalSize = const Size(480, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = UpdateController(checker: UpdateChecker(), bridge: FakeBridge())..ready = true;
    final key = GlobalKey();
    await tester.pumpWidget(ProviderScope(
      overrides: [updateProvider.overrideWith((ref) => controller)],
      child: MaterialApp(
        theme: ThemeData(fontFamily: 'JmsTestCjk', colorSchemeSeed: Colors.teal),
        locale: const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: RepaintBoundary(
            key: key, child: const Scaffold(body: SingleChildScrollView(child: SettingsUpdateInformation()))),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('尚未設定更新來源'), findsNWidgets(2));
    expect(find.text('檢查更新'), findsOneWidget);
    expect(find.text('接收測試版'), findsOneWidget);
    expect(find.text('下載更新／手動重試'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('artifacts/checks/update-unconfigured-m9.png').writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  });
  for (final entry in {
    UpdateStatus.noRelease: '已連上更新來源，此頻道尚無可用的已發布版本',
    UpdateStatus.sourceUnavailable: '無法存取更新儲存庫：不存在或沒有權限',
    UpdateStatus.rateLimited: 'GitHub 限流，請稍後再試',
  }.entries) {
    testWidgets('configured source displays distinct ${entry.key.name} status', (tester) async {
      final controller = UpdateController(
          checker: UpdateChecker(source: const UpdateSource(owner: 'fixture-owner', repo: 'jms-fixture')),
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
          home: Scaffold(body: SingleChildScrollView(child: SettingsUpdateInformation())),
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
