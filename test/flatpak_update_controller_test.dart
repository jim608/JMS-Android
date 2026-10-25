import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/services/flatpak_update_portal.dart';
import 'package:fladder/util/flatpak_update_capability.dart';
import 'package:fladder/util/flatpak_update_controller.dart';

FlatpakPortalUpdate _snapshot({String remote = 'b', String local = 'a'}) =>
    FlatpakPortalUpdate(
      runningCommit: 'a' * 64,
      localCommit: local * 64,
      remoteCommit: remote * 64,
    );

class _Portal implements FlatpakUpdatePortal {
  _Portal(
      {this.initial,
      this.openGate,
      this.openError,
      this.updateError,
      this.updateGate});
  final FlatpakPortalUpdate? initial;
  final Future<void>? openGate;
  final Object? openError;
  final Object? updateError;
  final Future<void>? updateGate;
  final updateEvents =
      StreamController<FlatpakPortalUpdate>.broadcast(sync: true);
  final progressEvents =
      StreamController<FlatpakPortalProgress>.broadcast(sync: true);
  int opens = 0;
  int requests = 0;
  int closes = 0;

  @override
  Stream<FlatpakPortalUpdate> get updates => updateEvents.stream;
  @override
  Stream<FlatpakPortalProgress> get progress => progressEvents.stream;
  @override
  Future<void> open() async {
    opens++;
    if (openError != null) throw openError!;
    if (initial != null) updateEvents.add(initial!);
    await openGate;
  }

  @override
  Future<void> requestUpdate({String parentWindow = ''}) async {
    requests++;
    if (updateError != null) throw updateError!;
    await updateGate;
  }

  @override
  Future<void> close() async => closes++;

  Future<void> disposeFixture() async {
    await updateEvents.close();
    await progressEvents.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  FlatpakUpdateController controller(_Portal portal,
      {Duration checkTimeout = const Duration(seconds: 15),
      Duration updateTimeout = const Duration(minutes: 10)}) {
    addTearDown(portal.disposeFixture);
    final result = FlatpakUpdateController(
        portalFactory: () => portal,
        checkTimeout: checkTimeout,
        updateTimeout: updateTimeout);
    addTearDown(result.dispose);
    return result;
  }

  test('construction is passive and concurrent checks share one monitor',
      () async {
    final gate = Completer<void>();
    final portal = _Portal(initial: _snapshot(), openGate: gate.future);
    final updates = controller(portal);
    expect(portal.opens, 0);
    expect(
        updates.capability.code, FlatpakUpdateCapabilityCode.remoteUnverified);
    final first = updates.check();
    final second = updates.check();
    expect(second, same(first));
    await Future<void>.delayed(Duration.zero);
    expect(portal.opens, 1);
    expect(updates.canRequestUpdate, isFalse);
    gate.complete();
    await first;
    expect(updates.phase, FlatpakUpdatePhase.available);
    expect(updates.canRequestUpdate, isTrue);
    expect(portal.requests, 0);
  });

  test(
      'automatic preference opens once, observes signals and leaves manual checks available',
      () async {
    final first = _Portal(initial: _snapshot());
    final manual = _Portal(initial: _snapshot(remote: 'c'));
    addTearDown(first.disposeFixture);
    addTearDown(manual.disposeFixture);
    var factories = 0;
    final updates = FlatpakUpdateController(
        portalFactory: () => factories++ == 0 ? first : manual);
    addTearDown(updates.dispose);
    expect(updates.automatic, isFalse);
    await updates.check(automatic: true);
    expect(factories, 0);
    final enabled = updates.setAutomatic(true);
    final check = updates.check();
    expect(check, same(enabled));
    await updates.setAutomatic(true);
    await enabled;
    first.updateEvents.add(_snapshot(remote: 'd'));
    expect(updates.candidate?.remoteCommit, 'd' * 64);
    expect(factories, 1);
    expect(first.requests, 0);
    await updates.setAutomatic(false);
    expect(first.closes, 1);
    first.updateEvents.add(_snapshot(remote: 'e'));
    expect(updates.candidate?.remoteCommit, 'd' * 64);
    await updates.check(automatic: true);
    expect(factories, 1);
    await updates.check();
    expect(factories, 2);
    expect(manual.opens, 1);
    expect(updates.canRequestUpdate, isTrue);
  });

  test('disabling a pending automatic open retires it without late revival',
      () async {
    final gate = Completer<void>();
    final portal = _Portal(openGate: gate.future);
    final updates = controller(portal);
    final check = updates.setAutomatic(true);
    await Future<void>.delayed(Duration.zero);
    expect(portal.opens, 1);
    await updates.setAutomatic(false);
    await check;
    expect(portal.closes, 1);
    expect(updates.phase, FlatpakUpdatePhase.idle);
    portal.updateEvents.add(_snapshot());
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(updates.candidate, isNull);
    expect(updates.canRequestUpdate, isFalse);
    expect(portal.opens, 1);
    expect(portal.requests, 0);
  });

  testWidgets(
      'automatic off preserves a pending or uncertain host update until terminal',
      (tester) async {
    final portal = _Portal(initial: _snapshot());
    final updates =
        controller(portal, updateTimeout: const Duration(seconds: 1));
    final check = updates.setAutomatic(true);
    await tester.pump();
    await check;
    final install = updates.requestUpdate(
        userConfirmed: true, expectedRemoteCommit: 'b' * 64);
    await tester.pump();
    await updates.setAutomatic(false);
    expect(portal.closes, 0);
    expect(updates.phase, FlatpakUpdatePhase.updating);
    await tester.pump(const Duration(seconds: 2));
    await install;
    expect(updates.phase, FlatpakUpdatePhase.outcomeUnknown);
    await updates.setAutomatic(true);
    await updates.setAutomatic(false);
    await updates.check();
    await updates.requestUpdate(
        userConfirmed: true, expectedRemoteCommit: 'b' * 64);
    expect(portal.opens, 1);
    expect(portal.requests, 1);
    expect(portal.closes, 0);
    portal.progressEvents.add(
        const FlatpakPortalProgress(status: FlatpakPortalProgressStatus.done));
    await tester.pump();
    // Retire both stream subscriptions before observing the owned portal close.
    // Only drain another event-loop turn; do not expire the cleanup timeout.
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(updates.restartRequired, isTrue);
    expect(updates.phase, FlatpakUpdatePhase.restartRequired);
    expect(portal.closes, 1);
  });

  test(
      'completed target stays latched through stale snapshots and a new confirmed target',
      () async {
    final portal = _Portal(initial: _snapshot());
    final next = _Portal(initial: _snapshot());
    addTearDown(portal.disposeFixture);
    addTearDown(next.disposeFixture);
    var monitors = 0;
    final updates = FlatpakUpdateController(
        portalFactory: () => monitors++ == 0 ? portal : next);
    addTearDown(updates.dispose);
    await updates.check();
    final first = updates.requestUpdate(
        userConfirmed: true, expectedRemoteCommit: 'b' * 64);
    // A newer advertisement must not change which dispatched target succeeded.
    portal.updateEvents.add(_snapshot(remote: 'c'));
    portal.progressEvents.add(
        const FlatpakPortalProgress(status: FlatpakPortalProgressStatus.done));
    await first;
    expect(updates.restartRequired, isTrue);
    expect(updates.canRequestUpdate, isTrue);
    portal.updateEvents.add(_snapshot());
    portal.progressEvents.add(const FlatpakPortalProgress(
        status: FlatpakPortalProgressStatus.failed));
    expect(updates.phase, FlatpakUpdatePhase.restartRequired);
    expect(updates.restartRequired, isTrue);
    expect(updates.failure, isNull);
    await updates.requestUpdate(
        userConfirmed: true, expectedRemoteCommit: 'b' * 64);
    expect(portal.requests, 1);
    // Rechecking a stale portal snapshot cannot offer the completed target.
    await updates.check();
    expect(updates.phase, FlatpakUpdatePhase.restartRequired);
    expect(updates.canRequestUpdate, isFalse);
    next.updateEvents.add(_snapshot(remote: 'c'));
    await updates.requestUpdate(
        userConfirmed: false, expectedRemoteCommit: 'c' * 64);
    expect(next.requests, 0);
    final second = updates.requestUpdate(
        userConfirmed: true, expectedRemoteCommit: 'c' * 64);
    next.progressEvents.add(
        const FlatpakPortalProgress(status: FlatpakPortalProgressStatus.done));
    await second;
    expect(portal.requests, 1);
    expect(next.requests, 1);
    for (final remote in ['b', 'c']) {
      next.updateEvents.add(_snapshot(remote: remote));
      expect(updates.canRequestUpdate, isFalse);
      expect(updates.restartRequired, isTrue);
    }
  });

  test('disposing pending host update releases the monitor only after terminal',
      () async {
    final portal = _Portal(initial: _snapshot());
    final updates = controller(portal);
    var notifications = 0;
    updates.addListener(() => notifications++);
    await updates.check();
    final install = updates.requestUpdate(
        userConfirmed: true, expectedRemoteCommit: 'b' * 64);
    updates.dispose();
    final beforeTerminal = notifications;
    expect(portal.closes, 0);
    portal.progressEvents.add(
        const FlatpakPortalProgress(status: FlatpakPortalProgressStatus.done));
    await install;
    await Future<void>.delayed(Duration.zero);
    expect(portal.closes, 1);
    expect(notifications, beforeTerminal);
  });

  test(
      'a late explicit refusal after disposal releases the monitor without notifying UI',
      () async {
    final acknowledgement = Completer<void>();
    final portal =
        _Portal(initial: _snapshot(), updateGate: acknowledgement.future);
    final updates = controller(portal);
    var notifications = 0;
    updates.addListener(() => notifications++);
    await updates.check();
    final install = updates.requestUpdate(
        userConfirmed: true, expectedRemoteCommit: 'b' * 64);
    updates.dispose();
    final beforeRefusal = notifications;
    expect(portal.closes, 0);
    acknowledgement.completeError(
        const FlatpakPortalFailure(FlatpakPortalFailureCode.denied));
    await install;
    await Future<void>.delayed(Duration.zero);
    expect(portal.closes, 1);
    expect(notifications, beforeRefusal);
  });

  testWidgets(
      'no initial portal snapshot does not imply latest or remote ready',
      (tester) async {
    final portal = _Portal();
    final updates =
        controller(portal, checkTimeout: const Duration(seconds: 1));
    final check = updates.check();
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await check;
    expect(updates.phase, FlatpakUpdatePhase.manual);
    expect(updates.capability.appRemote, FlatpakAppRemoteState.unverified);
    expect(updates.canRequestUpdate, isFalse);
    expect(portal.requests, 0);
  });

  test(
      'confirmation and current candidate are required; 100 percent is not done',
      () async {
    final portal = _Portal(initial: _snapshot());
    final updates = controller(portal);
    await updates.check();
    await updates.requestUpdate(
        userConfirmed: false, expectedRemoteCommit: 'b' * 64);
    await updates.requestUpdate(
        userConfirmed: true, expectedRemoteCommit: 'c' * 64);
    expect(portal.requests, 0);
    final install = updates.requestUpdate(
        userConfirmed: true, expectedRemoteCommit: 'b' * 64);
    final repeated = updates.requestUpdate(
        userConfirmed: true, expectedRemoteCommit: 'b' * 64);
    expect(repeated, same(install));
    await Future<void>.delayed(Duration.zero);
    expect(portal.requests, 1);
    portal.progressEvents.add(const FlatpakPortalProgress(
        status: FlatpakPortalProgressStatus.running, percent: 100));
    expect(updates.phase, FlatpakUpdatePhase.updating);
    expect(updates.restartRequired, isFalse);
    portal.progressEvents.add(const FlatpakPortalProgress(
        status: FlatpakPortalProgressStatus.done, percent: 100));
    await install;
    expect(updates.phase, FlatpakUpdatePhase.restartRequired);
    expect(updates.restartRequired, isTrue);
    expect(portal.requests, 1);
  });

  test(
      'playback or a paused watch room defers restart without restarting media',
      () async {
    final portal = _Portal(initial: _snapshot(local: 'b'));
    final updates = controller(portal);
    updates.setActivity(playback: true, syncPlay: true);
    await updates.check();
    expect(updates.phase, FlatpakUpdatePhase.restartRequired);
    expect(updates.restartDeferred, isTrue);
    updates.setActivity(playback: false, syncPlay: true);
    expect(updates.restartDeferred, isTrue);
    updates.setActivity(playback: false, syncPlay: false);
    expect(updates.restartDeferred, isFalse);
    expect(portal.requests, 0);
  });

  test('unsupported portal remains manual without an update request', () async {
    final portal = _Portal(
        openError:
            const FlatpakPortalFailure(FlatpakPortalFailureCode.unsupported));
    final updates = controller(portal);
    await updates.check();
    expect(updates.phase, FlatpakUpdatePhase.unsupported);
    expect(updates.canRequestUpdate, isFalse);
    expect(portal.requests, 0);
  });

  test('new check ignores late metadata from the retired monitor', () async {
    final old = _Portal(initial: _snapshot());
    final next = _Portal(initial: _snapshot(remote: 'c'));
    addTearDown(old.disposeFixture);
    addTearDown(next.disposeFixture);
    var calls = 0;
    final updates =
        FlatpakUpdateController(portalFactory: () => calls++ == 0 ? old : next);
    addTearDown(updates.dispose);
    await updates.check();
    await updates.check();
    old.updateEvents.add(_snapshot(remote: 'd'));
    expect(updates.candidate?.remoteCommit, 'c' * 64);
    expect(old.closes, 1);
    expect(next.requests, 0);
  });

  testWidgets(
      'update timeout blocks repeat requests and accepts a late terminal',
      (tester) async {
    final portal = _Portal(initial: _snapshot());
    final updates =
        controller(portal, updateTimeout: const Duration(seconds: 1));
    final check = updates.check();
    await tester.pump();
    await check;
    final install = updates.requestUpdate(
        userConfirmed: true, expectedRemoteCommit: 'b' * 64);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await install;
    expect(updates.phase, FlatpakUpdatePhase.outcomeUnknown);
    expect(updates.canCheck, isFalse);
    await updates.requestUpdate(
        userConfirmed: true, expectedRemoteCommit: 'b' * 64);
    expect(portal.requests, 1);
    portal.progressEvents.add(
        const FlatpakPortalProgress(status: FlatpakPortalProgressStatus.done));
    expect(updates.phase, FlatpakUpdatePhase.restartRequired);
  });

  test('permission-changing update falls back without a native installer',
      () async {
    final portal = _Portal(
        initial: _snapshot(),
        updateError: const FlatpakPortalFailure(
            FlatpakPortalFailureCode.permissionChange));
    final updates = controller(portal);
    await updates.check();
    await updates.requestUpdate(
        userConfirmed: true, expectedRemoteCommit: 'b' * 64);
    expect(updates.phase, FlatpakUpdatePhase.failed);
    expect(updates.failure, FlatpakPortalFailureCode.permissionChange);
    expect(updates.capability.canUseStandaloneInstaller, isFalse);
    expect(portal.requests, 1);
  });

  test('uncertain dispatched transport failure cannot enable another check',
      () async {
    final portal = _Portal(
        initial: _snapshot(),
        updateError:
            const FlatpakPortalFailure(FlatpakPortalFailureCode.unavailable));
    final updates = controller(portal);
    await updates.check();
    await updates.requestUpdate(
        userConfirmed: true, expectedRemoteCommit: 'b' * 64);
    expect(updates.phase, FlatpakUpdatePhase.outcomeUnknown);
    expect(updates.canCheck, isFalse);
    await updates.check();
    expect(portal.opens, 1);
    expect(portal.requests, 1);
  });

  test('empty transaction is not proof that a new deployment was installed',
      () async {
    final portal = _Portal(initial: _snapshot());
    final updates = controller(portal);
    await updates.check();
    final install = updates.requestUpdate(
        userConfirmed: true, expectedRemoteCommit: 'b' * 64);
    await Future<void>.delayed(Duration.zero);
    portal.progressEvents.add(
        const FlatpakPortalProgress(status: FlatpakPortalProgressStatus.empty));
    await install;
    expect(updates.phase, FlatpakUpdatePhase.noUpdate);
    expect(updates.restartRequired, isFalse);
    expect(portal.requests, 1);
  });

  testWidgets('terminal progress wins over a late method timeout',
      (tester) async {
    final ack = Completer<void>();
    final portal = _Portal(initial: _snapshot(), updateGate: ack.future);
    final updates =
        controller(portal, checkTimeout: const Duration(seconds: 1));
    final check = updates.check();
    await tester.pump();
    await check;
    final install = updates.requestUpdate(
        userConfirmed: true, expectedRemoteCommit: 'b' * 64);
    await tester.pump();
    portal.progressEvents.add(
        const FlatpakPortalProgress(status: FlatpakPortalProgressStatus.done));
    await tester.pump();
    await install;
    await tester.pump(const Duration(seconds: 2));
    expect(updates.phase, FlatpakUpdatePhase.restartRequired);
    expect(updates.failure, isNull);
    expect(portal.requests, 1);
    ack.complete();
  });

  test('signal failure during installation is an uncertain result, not retry',
      () async {
    final portal = _Portal(initial: _snapshot());
    final updates = controller(portal);
    await updates.check();
    final install = updates.requestUpdate(
        userConfirmed: true, expectedRemoteCommit: 'b' * 64);
    await Future<void>.delayed(Duration.zero);
    portal.progressEvents.addError(
        const FlatpakPortalFailure(FlatpakPortalFailureCode.invalidResponse));
    await install;
    expect(updates.phase, FlatpakUpdatePhase.outcomeUnknown);
    expect(updates.canCheck, isFalse);
    expect(portal.requests, 1);
    portal.progressEvents.add(const FlatpakPortalProgress(
        status: FlatpakPortalProgressStatus.failed,
        failure: FlatpakPortalFailureCode.failed));
    expect(updates.phase, FlatpakUpdatePhase.failed);
    expect(updates.canCheck, isTrue);
  });
}
