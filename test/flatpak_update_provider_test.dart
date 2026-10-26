import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/providers/settings/client_settings_provider.dart';
import 'package:fladder/providers/update_provider.dart';
import 'package:fladder/services/flatpak_update_portal.dart';
import 'package:fladder/util/flatpak_update_controller.dart';
import 'package:fladder/util/linux_update_bridge_io.dart';

class _Settings extends ClientSettingsNotifier {
  _Settings(super.ref, bool enabled) {
    applyRestoredSettings(state.copyWith(checkForUpdates: enabled));
  }
  void setEnabled(bool enabled) =>
      applyRestoredSettings(state.copyWith(checkForUpdates: enabled));
}

class _Portal implements FlatpakUpdatePortal {
  final snapshots = StreamController<FlatpakPortalUpdate>.broadcast(sync: true);
  final events = StreamController<FlatpakPortalProgress>.broadcast(sync: true);
  int opens = 0, requests = 0, closes = 0;
  @override
  Stream<FlatpakPortalUpdate> get updates => snapshots.stream;
  @override
  Stream<FlatpakPortalProgress> get progress => events.stream;
  @override
  Future<void> open() async {
    opens++;
    snapshots.add(FlatpakPortalUpdate(
      runningCommit: 'a' * 64,
      localCommit: 'a' * 64,
      remoteCommit: 'b' * 64,
    ));
  }

  @override
  Future<void> requestUpdate({String parentWindow = ''}) async => requests++;
  @override
  Future<void> close() async => closes++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  for (final enabled in [false, true]) {
    test('Flatpak startup respects saved automatic preference $enabled',
        () async {
      final portal = _Portal();
      final updater = FlatpakUpdateController(portalFactory: () => portal);
      final container = ProviderContainer(overrides: [
        updateBridgeProvider.overrideWithValue(FlatpakUpdateBridge()),
        flatpakUpdateProvider.overrideWith((_) => updater),
        clientSettingsProvider.overrideWith((ref) => _Settings(ref, enabled)),
      ]);
      container.read(updateProvider);
      await settle();
      expect(portal.opens, enabled ? 1 : 0);
      expect(portal.requests, 0);
      expect(container.read(hasNewUpdateProvider), enabled);
      container.dispose();
      await settle();
      await portal.snapshots.close();
      await portal.events.close();
    });
  }

  test('saved preference changes start and stop only the automatic monitor',
      () async {
    final portal = _Portal();
    final updater = FlatpakUpdateController(portalFactory: () => portal);
    final container = ProviderContainer(overrides: [
      updateBridgeProvider.overrideWithValue(FlatpakUpdateBridge()),
      flatpakUpdateProvider.overrideWith((_) => updater),
      clientSettingsProvider.overrideWith((ref) => _Settings(ref, false)),
    ]);
    container.read(updateProvider);
    await settle();
    final settings =
        container.read(clientSettingsProvider.notifier) as _Settings;
    settings.setEnabled(true);
    await settle();
    expect(portal.opens, 1);
    settings.setEnabled(false);
    await settle();
    expect(portal.closes, 1);
    expect(portal.requests, 0);
    expect(container.read(hasNewUpdateProvider), isFalse);
    container.dispose();
    await settle();
    await portal.snapshots.close();
    await portal.events.close();
  });
}
