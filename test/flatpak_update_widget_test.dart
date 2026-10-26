import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/l10n/generated/app_localizations.dart';
import 'package:fladder/providers/update_provider.dart';
import 'package:fladder/screens/settings/widgets/settings_update_information.dart';
import 'package:fladder/services/flatpak_update_portal.dart';
import 'package:fladder/util/flatpak_update_controller.dart';
import 'package:fladder/util/linux_update_bridge_io.dart';
import 'package:fladder/util/update_checker.dart';
import 'package:fladder/util/update_controller.dart';

class _Portal implements FlatpakUpdatePortal {
  _Portal({this.sendSnapshot = true});
  final bool sendSnapshot;
  final updateEvents =
      StreamController<FlatpakPortalUpdate>.broadcast(sync: true);
  final progressEvents =
      StreamController<FlatpakPortalProgress>.broadcast(sync: true);
  int requests = 0;
  @override
  Stream<FlatpakPortalUpdate> get updates => updateEvents.stream;
  @override
  Stream<FlatpakPortalProgress> get progress => progressEvents.stream;
  @override
  Future<void> open() async {
    if (sendSnapshot) {
      updateEvents.add(FlatpakPortalUpdate(
          runningCommit: 'a' * 64,
          localCommit: 'a' * 64,
          remoteCommit: 'b' * 64));
    }
  }

  @override
  Future<void> requestUpdate({String parentWindow = ''}) async => requests++;
  @override
  Future<void> close() async {}
}

Future<void> _mount(WidgetTester tester, FlatpakUpdateController portal) async {
  final native =
      UpdateController(checker: UpdateChecker(), bridge: FlatpakUpdateBridge());
  await native.initialize();
  await tester.pumpWidget(ProviderScope(
    overrides: [
      updateProvider.overrideWith((ref) => native),
      flatpakUpdateProvider.overrideWith((ref) => portal),
    ],
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(visualDensity: VisualDensity.compact),
      home: Scaffold(
        body: SingleChildScrollView(
          child: SettingsUpdateInformation(openExternalLink: (_) async => true),
        ),
      ),
    ),
  ));
}

void main() {
  testWidgets(
      'portal update needs confirmation and never restarts active playback',
      (tester) async {
    final portal = _Portal();
    final controller = FlatpakUpdateController(portalFactory: () => portal);
    controller.setActivity(playback: true, syncPlay: true);
    await _mount(tester, controller);
    expect(portal.requests, 0);
    await tester.tap(find.byKey(const ValueKey('flatpak-check-update')));
    await tester.pumpAndSettle();
    final update = find.byKey(const ValueKey('flatpak-confirm-update'));
    expect(update, findsOneWidget);
    expect(portal.requests, 0);
    await tester.tap(update);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    final cancel =
        find.byKey(const ValueKey('flatpak-update-cancel-confirmation'));
    expect(tester.getSize(cancel).height, greaterThanOrEqualTo(48));
    await tester.tap(cancel);
    await tester.pumpAndSettle();
    expect(portal.requests, 0);
    await tester.tap(update);
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('flatpak-update-accept-confirmation')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(portal.requests, 1);
    portal.progressEvents.add(
        const FlatpakPortalProgress(status: FlatpakPortalProgressStatus.done));
    await tester.pumpAndSettle();
    expect(controller.restartRequired, isTrue);
    expect(controller.restartDeferred, isTrue);
    expect(find.textContaining('after playback and the watch room have ended'),
        findsOneWidget);
    expect(find.byKey(const ValueKey('update-primary-install')), findsNothing);
    expect(portal.requests, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    await portal.updateEvents.close();
    await portal.progressEvents.close();
  });

  testWidgets(
      'missing remote evidence keeps manual instructions without readiness',
      (tester) async {
    final portal = _Portal(sendSnapshot: false);
    final controller = FlatpakUpdateController(
        portalFactory: () => portal, checkTimeout: const Duration(seconds: 1));
    await _mount(tester, controller);
    await tester.tap(find.byKey(const ValueKey('flatpak-check-update')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.byKey(const ValueKey('flatpak-update-remoteUnverified')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('flatpak-confirm-update')), findsNothing);
    expect(find.byKey(const ValueKey('flatpak-open-releases')), findsOneWidget);
    expect(find.textContaining('update source has not been confirmed'),
        findsOneWidget);
    expect(controller.canRequestUpdate, isFalse);
    expect(portal.requests, 0);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    await portal.updateEvents.close();
    await portal.progressEvents.close();
  });
}
