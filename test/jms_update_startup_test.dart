import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fladder/util/update_checker.dart';
import 'package:fladder/util/update_controller.dart';

import 'jms_update_flow_test.dart' show FlowBridge, FlowChecker;

class StartupChecker extends FlowChecker {
  Completer<UpdateCheckResult>? pending;
  Object? error;

  StartupChecker() : super(const UpdateCheckResult(UpdateStatus.noRelease));

  @override
  Future<UpdateCheckResult> check(UpdateDevice device,
      {bool prerelease = false}) async {
    checks++;
    if (error != null) throw error!;
    return pending == null ? result : await pending!.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final epoch = DateTime.utc(2026, 10, 17, 12);
  const key = UpdateController.lastAutomaticCheckKey;

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<UpdateController> initialize(StartupChecker checker,
      {DateTime Function()? clock, FlowBridge? bridge}) async {
    final controller = UpdateController(
        checker: checker,
        bridge: bridge ?? FlowBridge(),
        now: clock ?? () => epoch);
    addTearDown(controller.dispose);
    await controller.initialize();
    return controller;
  }

  test('first startup persists its attempt and does not await the network',
      () async {
    final checker = StartupChecker()..pending = Completer<UpdateCheckResult>();
    final bridge = FlowBridge();
    final controller = await initialize(checker, bridge: bridge);
    expect(controller.ready, isTrue);
    expect(checker.checks, 0);

    final request = controller.check(manual: false);
    await Future<void>.delayed(Duration.zero);
    expect(checker.checks, 1);
    expect(controller.busy, isTrue);
    expect((await SharedPreferences.getInstance()).getInt(key),
        epoch.millisecondsSinceEpoch);
    expect(bridge.downloads, 0);
    expect(bridge.installs, 0);
    checker.pending!.complete(checker.result);
    await request;
    expect(controller.status, UpdateStatus.noRelease);
  });

  test('restart skips before five hours and checks exactly at five hours',
      () async {
    final first = StartupChecker();
    await (await initialize(first)).check(manual: false);
    expect(first.checks, 1);

    final before = StartupChecker();
    await (await initialize(before,
            clock: () => epoch.add(const Duration(hours: 5, milliseconds: -1))))
        .check(manual: false);
    expect(before.checks, 0);

    final boundary = StartupChecker();
    await (await initialize(boundary,
            clock: () => epoch.add(const Duration(hours: 5))))
        .check(manual: false);
    expect(boundary.checks, 1);
  });

  test(
      'manual checks bypass the cooldown without changing the automatic timestamp',
      () async {
    final saved =
        epoch.subtract(const Duration(hours: 1)).millisecondsSinceEpoch;
    SharedPreferences.setMockInitialValues({key: saved});
    final checker = StartupChecker();
    final controller = await initialize(checker);
    await controller.check(manual: false);
    expect(checker.checks, 0);
    await controller.check();
    await controller.check();
    expect(checker.checks, 2);
    expect((await SharedPreferences.getInstance()).getInt(key), saved);
  });

  test('a cooldown skip cannot swallow a simultaneous manual check', () async {
    final saved =
        epoch.subtract(const Duration(hours: 1)).millisecondsSinceEpoch;
    SharedPreferences.setMockInitialValues({key: saved});
    final checker = StartupChecker()..pending = Completer<UpdateCheckResult>();
    final controller = await initialize(checker);

    final automatic = controller.check(manual: false);
    final manual = controller.check();
    await Future<void>.delayed(Duration.zero);
    expect(checker.checks, 1);
    expect(controller.busy, isTrue);
    expect((await SharedPreferences.getInstance()).getInt(key), saved);
    checker.pending!.complete(checker.result);
    await Future.wait([automatic, manual]);
    expect(controller.status, UpdateStatus.noRelease);
  });

  test('clock normalization cannot swallow a simultaneous manual check',
      () async {
    SharedPreferences.setMockInitialValues(
        {key: epoch.add(const Duration(days: 365)).millisecondsSinceEpoch});
    final checker = StartupChecker()..pending = Completer<UpdateCheckResult>();
    final controller = await initialize(checker);

    final automatic = controller.check(manual: false);
    final manual = controller.check();
    await Future<void>.delayed(Duration.zero);
    expect(checker.checks, 1);
    expect(controller.busy, isTrue);
    expect((await SharedPreferences.getInstance()).getInt(key),
        epoch.millisecondsSinceEpoch);
    checker.pending!.complete(checker.result);
    await Future.wait([automatic, manual]);
    expect(controller.status, UpdateStatus.noRelease);
  });

  test('offline failure is persisted and does not retry on the next restart',
      () async {
    final offline = StartupChecker()..error = StateError('TEST_ONLY offline');
    final controller = await initialize(offline);
    await controller.check(manual: false);
    expect(controller.status, UpdateStatus.network);
    expect((await SharedPreferences.getInstance()).getInt(key),
        epoch.millisecondsSinceEpoch);

    final restarted = StartupChecker();
    await (await initialize(restarted,
            clock: () => epoch.add(const Duration(minutes: 1))))
        .check(manual: false);
    expect(restarted.checks, 0);
    final due = StartupChecker();
    await (await initialize(due,
            clock: () => epoch.add(const Duration(hours: 5))))
        .check(manual: false);
    expect(due.checks, 1);
  });

  for (final automaticFirst in [true, false]) {
    test(
        'simultaneous manual and automatic checks coalesce (automatic first: $automaticFirst)',
        () async {
      final checker = StartupChecker()
        ..pending = Completer<UpdateCheckResult>();
      final controller = await initialize(checker);
      final first = controller.check(manual: !automaticFirst);
      final others =
          List.generate(8, (index) => controller.check(manual: index.isEven));
      await Future<void>.delayed(Duration.zero);
      expect(checker.checks, 1);
      checker.pending!.complete(checker.result);
      await Future.wait([first, ...others]);
      await controller.check(manual: false);
      expect(checker.checks, 1);
    });
  }

  test('startup deferred during playback runs once after playback stops',
      () async {
    final checker = StartupChecker();
    final controller = await initialize(checker);
    controller.setPlayback(true);
    await controller.check(manual: false);
    expect(checker.checks, 0);
    expect((await SharedPreferences.getInstance()).containsKey(key), isFalse);
    controller.setPlayback(false);
    await Future<void>.delayed(Duration.zero);
    expect(checker.checks, 1);
    controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    controller.setPlayback(false);
    await Future<void>.delayed(Duration.zero);
    expect(checker.checks, 1);
  });

  test('elapsed time in an open app never creates another automatic check',
      () async {
    var time = epoch;
    final checker = StartupChecker();
    final controller = await initialize(checker, clock: () => time);
    await controller.check(manual: false);
    time = epoch.add(const Duration(hours: 24));
    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    controller.setPlayback(false);
    await controller.check(manual: false);
    await Future<void>.delayed(Duration.zero);
    expect(checker.checks, 1);
    await controller.check();
    expect(checker.checks, 2);
  });

  test('clock rollback normalizes a future timestamp and waits five hours',
      () async {
    SharedPreferences.setMockInitialValues(
        {key: epoch.add(const Duration(days: 365)).millisecondsSinceEpoch});
    final rollback = StartupChecker();
    await (await initialize(rollback)).check(manual: false);
    expect(rollback.checks, 0);
    expect((await SharedPreferences.getInstance()).getInt(key),
        epoch.millisecondsSinceEpoch);
    final before = StartupChecker();
    await (await initialize(before,
            clock: () => epoch.add(const Duration(hours: 4))))
        .check(manual: false);
    expect(before.checks, 0);
    final due = StartupChecker();
    await (await initialize(due,
            clock: () => epoch.add(const Duration(hours: 5))))
        .check(manual: false);
    expect(due.checks, 1);
  });

  for (final invalid in [0, -1, 'TEST_ONLY invalid timestamp']) {
    test('invalid stored timestamp $invalid is replaced by a valid attempt',
        () async {
      SharedPreferences.setMockInitialValues({key: invalid});
      final checker = StartupChecker();
      await (await initialize(checker)).check(manual: false);
      expect(checker.checks, 1);
      expect((await SharedPreferences.getInstance()).getInt(key),
          epoch.millisecondsSinceEpoch);
    });
  }

  test('invalid system clock skips automatic checks but permits a manual check',
      () async {
    final checker = StartupChecker();
    final controller = await initialize(checker,
        clock: () => DateTime.fromMillisecondsSinceEpoch(-1));
    await controller.check(manual: false);
    expect(checker.checks, 0);
    expect((await SharedPreferences.getInstance()).containsKey(key), isFalse);
    await controller.check();
    expect(checker.checks, 1);
  });

  test(
      'automatic preference is respected while manual checking remains available',
      () async {
    SharedPreferences.setMockInitialValues({'jms.update.auto': false});
    final checker = StartupChecker();
    final controller = await initialize(checker);
    await controller.check(manual: false);
    expect(checker.checks, 0);
    await controller.check();
    expect(checker.checks, 1);
  });
}
