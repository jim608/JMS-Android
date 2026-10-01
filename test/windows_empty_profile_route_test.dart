import 'package:fladder/l10n/generated/app_localizations.dart';
import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/routes/auto_router.dart' as production;
import 'package:fladder/routes/auto_router.gr.dart';
import 'package:fladder/screens/login/login_screen.dart';
import 'package:fladder/screens/login/login_screen_credentials.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/localization_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RealRouteHarness extends ConsumerStatefulWidget {
  const _RealRouteHarness({required this.onCreated});
  final void Function(production.AutoRouter) onCreated;

  @override
  ConsumerState<_RealRouteHarness> createState() => _RealRouteHarnessState();
}

class _RealRouteHarnessState extends ConsumerState<_RealRouteHarness> {
  late final router = production.AutoRouter(ref: ref);

  @override
  void initState() {
    super.initState();
    widget.onCreated(router);
  }

  @override
  void dispose() {
    router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => LocalizationContextWrapper(
          currentLocale: const Locale('en'),
          child: child ?? const SizedBox.shrink(),
        ),
        routerConfig: router.config(),
      );
}

void main() {
  testWidgets(
      'actual Splash and Login render from empty preferences on Windows',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/connectivity'),
        (call) async => ['wifi']);
    messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/connectivity_status'),
        (call) async => null);
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWith((ref) => preferences),
    ]);
    addTearDown(container.dispose);
    late production.AutoRouter router;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: AdaptiveLayoutBuilder(
        child: (_) => _RealRouteHarness(onCreated: (value) => router = value),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.byType(LoginScreenCredentials), findsOneWidget);
    expect(router.current.name, LoginRoute.name);
    expect(container.read(userProvider), isNull);
    expect(preferences.getStringList('loginCredentialsKey'), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
