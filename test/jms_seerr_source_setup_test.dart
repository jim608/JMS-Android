import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fladder/providers/seerr_link_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/screens/seerr/seerr_link_panel.dart';
import 'package:fladder/seerr/seerr_source.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout_model.dart';
import 'package:fladder/util/poster_defaults.dart';
import 'fixtures/seerr_test_scope.dart';

void main() {
  testWidgets(
      'Linux sign-in offers source setup and retains explicit link consent',
      (tester) async {
    final fixture = SeerrFixture();
    await fixture.initializePreferences();
    final container = ProviderContainer(
        overrides: fixture.overrides(
      account:
          seerrFixtureAccount(bound: false).copyWith(seerrCredentials: null),
    ));
    addTearDown(container.dispose);
    addTearDown(fixture.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        builder: (context, child) => AdaptiveLayout(
          data: const AdaptiveLayoutModel(
            viewSize: ViewSize.desktop,
            layoutMode: LayoutMode.single,
            inputDevice: InputDevice.pointer,
            platform: TargetPlatform.linux,
            isDesktop: true,
            posterDefaults: PosterDefaults(size: 160, ratio: .67),
            controller: {},
            sideBarWidth: 0,
            topBarHeight: 0,
            statusBarHeight: 0,
          ),
          child: child!,
        ),
        home: Scaffold(
            body: Consumer(
                builder: (context, ref, _) => TextButton(
                      onPressed: () => openSeerrAccountLink(context, ref),
                      child: const Text('Sign in'),
                    ))),
      ),
    ));
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    final input = find.byKey(const Key('seerr-service-url'));
    final save = find.byKey(const Key('seerr-save-service-url'));
    expect(input, findsOneWidget);
    await tester.enterText(input, 'https://user@example.invalid');
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(container.read(userProvider)!.seerrCredentials, isNull);
    expect(input, findsOneWidget);
    await tester.enterText(input, 'https://requests.example.invalid/');
    await tester.tap(save);
    await tester.pumpAndSettle();
    final saved = container.read(userProvider)!.seerrCredentials!;
    expect(saved.serverUrl, 'https://requests.example.invalid');
    expect(saved.linkedServerId, isEmpty);
    expect(container.read(seerrLinkProvider), 'binding_required');
    expect(find.text('Link my Jellyfin account'), findsOneWidget);
    expect(input, findsNothing);
    expect(tester.takeException(), isNull);
  },
      skip: jmsSeerrSource.isNotEmpty,
      variant: const TargetPlatformVariant({TargetPlatform.linux}));
}
