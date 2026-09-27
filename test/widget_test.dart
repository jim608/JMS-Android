import 'package:fladder/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fladder/models/settings/arguments_model.dart';
import 'package:fladder/providers/arguments_provider.dart';
import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/providers/update_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/screens/login/login_screen.dart';
import 'package:fladder/screens/login/login_screen_credentials.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/update_checker.dart';
import 'package:fladder/util/update_controller.dart';

void main() {
  testWidgets('JMS startup without an account reaches server login without authenticating', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/connectivity'), (call) async => ['wifi']);
    messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/connectivity_status'), (call) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/dynamic_color'), (call) async => null);
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWith((ref) => preferences),
      argumentsStateProvider.overrideWith((ref) => ArgumentsModel(skipNotifications: true)),
      updateProvider.overrideWith(
          (ref) => UpdateController(checker: UpdateChecker(), bridge: AndroidUpdateBridge(), supported: false)),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: AdaptiveLayoutBuilder(child: (context) => const Main()),
    ));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.byType(LoginScreenCredentials), findsOneWidget);
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).title, 'JMS');
    expect(container.read(userProvider), isNull);
    expect(preferences.getStringList('loginCredentialsKey'), isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
