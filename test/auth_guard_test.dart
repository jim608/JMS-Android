import 'package:auto_route/auto_route.dart';
import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/credentials_model.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/routes/auto_router.dart';
import 'package:fladder/routes/auto_router.gr.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// Keep production guard behavior observable with the real auto_route engine.
class _RecordingGuard extends AuthGuard {
  _RecordingGuard({required super.ref});

  NavigationResolver? protectedResolver;

  @override
  Future<void> onNavigation(NavigationResolver resolver, StackRouter router) {
    if (resolver.routeName == 'ProtectedRoute') protectedResolver = resolver;
    return super.onNavigation(resolver, router);
  }
}

class _ProbeRouter extends RootStackRouter {
  _ProbeRouter(this.guard,
      {this.directLogin = false, this.splashLoggedIn = false});

  final _RecordingGuard guard;
  final bool directLogin;
  final bool splashLoggedIn;

  @override
  List<AutoRouteGuard> get guards => [guard];

  @override
  List<AutoRoute> get routes => [
        AutoRoute(
          page: PageInfo('ProtectedRoute',
              builder: (_) => const Scaffold(body: Text('protected'))),
          path: '/protected',
          initial: !directLogin,
        ),
        AutoRoute(
          page: PageInfo(SplashRoute.name, builder: (data) {
            return _SplashCallbackProbe(
                data.argsAs<SplashRouteArgs>().loggedIn!, splashLoggedIn);
          }),
          path: '/splash',
        ),
        AutoRoute(
          page: PageInfo(LoginRoute.name,
              builder: (_) => const Scaffold(body: Text('login'))),
          path: '/login',
          initial: directLogin,
          maintainState: false,
        ),
      ];
}

class _SplashCallbackProbe extends StatefulWidget {
  const _SplashCallbackProbe(this.callback, this.loggedIn);
  final Function(bool) callback;
  final bool loggedIn;

  @override
  State<_SplashCallbackProbe> createState() => _SplashCallbackProbeState();
}

class _SplashCallbackProbeState extends State<_SplashCallbackProbe> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      // Match SplashScreen.callBackOrNavigate with the stored-account result.
      widget.callback(widget.loggedIn);
      context.router.maybePop(widget.loggedIn);
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('splash'));
}

class _FixtureUser extends User {
  _FixtureUser(this.account);
  final AccountModel? account;

  @override
  AccountModel? build() => account;
}

class _Harness extends ConsumerStatefulWidget {
  const _Harness(
      {required this.onCreated,
      this.directLogin = false,
      this.splashLoggedIn = false});
  final void Function(_ProbeRouter) onCreated;
  final bool directLogin;
  final bool splashLoggedIn;

  @override
  ConsumerState<_Harness> createState() => _HarnessState();
}

class _HarnessState extends ConsumerState<_Harness> {
  late final _ProbeRouter router = _ProbeRouter(_RecordingGuard(ref: ref),
      directLogin: widget.directLogin, splashLoggedIn: widget.splashLoggedIn);

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
  Widget build(BuildContext context) =>
      MaterialApp.router(routerConfig: router.config());
}

void main() {
  testWidgets(
      'empty account startup reaches login and resolves initial navigation',
      (tester) async {
    late _ProbeRouter router;
    await tester.pumpWidget(ProviderScope(
      overrides: [userProvider.overrideWith(() => _FixtureUser(null))],
      child: _Harness(onCreated: (value) => router = value),
    ));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('login'), findsOneWidget);
    expect(router.guard.protectedResolver?.isResolved, isTrue);
    expect(router.stack.map((entry) => entry.name).toList(), [LoginRoute.name]);
  });

  testWidgets('existing account reaches protected page without splash',
      (tester) async {
    late _ProbeRouter router;
    final account = AccountModel(
      name: 'Synthetic test account',
      id: 'fixture',
      avatar: '',
      lastUsed: DateTime.utc(2026),
      credentials: CredentialsModel.internal(),
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [userProvider.overrideWith(() => _FixtureUser(account))],
      child: _Harness(onCreated: (value) => router = value),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('protected'), findsOneWidget);
    expect(router.guard.protectedResolver?.isResolved, isTrue);
  });

  testWidgets('successful splash callback completes protected navigation',
      (tester) async {
    late _ProbeRouter router;
    await tester.pumpWidget(ProviderScope(
      overrides: [userProvider.overrideWith(() => _FixtureUser(null))],
      child:
          _Harness(onCreated: (value) => router = value, splashLoggedIn: true),
    ));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('protected'), findsOneWidget);
    expect(router.guard.protectedResolver?.isResolved, isTrue);
    expect(
        router.stack.map((entry) => entry.name).toList(), ['ProtectedRoute']);
  });

  testWidgets('login can navigate again after cancelling initial navigation',
      (tester) async {
    late _ProbeRouter router;
    final container = ProviderContainer(overrides: [
      userProvider.overrideWith(() => _FixtureUser(null)),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: _Harness(onCreated: (value) => router = value),
    ));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(router.guard.protectedResolver?.isResolved, isTrue);
    container.read(userProvider.notifier).loginUser(AccountModel(
          name: 'Synthetic test account',
          id: 'fixture',
          avatar: '',
          lastUsed: DateTime.utc(2026),
          credentials: CredentialsModel.internal(),
        ));
    router.replace(const PageRouteInfo<void>('ProtectedRoute'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('protected'), findsOneWidget);
    expect(find.text('login'), findsNothing);
  });

  testWidgets('explicit login route remains accessible without an account',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [userProvider.overrideWith(() => _FixtureUser(null))],
      child: _Harness(onCreated: (_) {}, directLogin: true),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('login'), findsOneWidget);
  });
}
