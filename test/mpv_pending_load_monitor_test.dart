import 'dart:async';

import 'package:fladder/util/mpv_hdr_tonemap.dart';
import 'package:fladder/util/mpv_pending_load_monitor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
      'synchronous duration readiness is not overwritten with buffering',
      (tester) async {
    var timedOut = false;
    final completion = Completer<void>();
    final monitor = MpvPendingLoadMonitor(
      networkStream: true,
      isCurrent: () => true,
      retryLocal: () async => fail('ready network media must not reopen'),
      onTimeout: () => timedOut = true,
      onFailure: (_) => fail('ready load failed'),
    )..start();
    final readiness = MpvLoadReadiness(
      isCurrent: () => true,
      isReady: () => true, // Duration was already present after open.
      onReady: () {
        completion.complete();
        monitor.cancel();
      },
    );
    readiness.observe(const []);
    expect(
      mpvInitialBuffering(
        readinessCompleted: completion.isCompleted,
        hdrGated: false,
        backendBuffering: false,
      ),
      isFalse,
    );
    await tester.pump(const Duration(minutes: 2));
    expect(timedOut, isFalse);
  });

  testWidgets(
      'pending duration does not uncover media or bypass a backend buffer',
      (tester) async {
    final completion = Completer<void>();
    final readiness = MpvLoadReadiness(
      isCurrent: () => true,
      isReady: () => false,
      onReady: completion.complete,
    );
    readiness.observe(const []);
    expect(
      mpvInitialBuffering(
        readinessCompleted: completion.isCompleted,
        hdrGated: false,
        backendBuffering: false,
      ),
      isTrue,
    );
    readiness.cancel();
    expect(
      mpvInitialBuffering(
        readinessCompleted: true,
        hdrGated: true,
        backendBuffering: true,
      ),
      isTrue,
    );
  });

  testWidgets('slow network startup keeps one open across retry intervals',
      (tester) async {
    var resets = 0;
    var timeouts = 0;
    final monitor = MpvPendingLoadMonitor(
      networkStream: true,
      isCurrent: () => true,
      retryLocal: () async => resets++,
      onTimeout: () => timeouts++,
      onFailure: (_) => fail('unexpected retry error'),
    )..start();
    await tester.pump(const Duration(seconds: 25));
    expect(resets, 0, reason: 'pending HTTP cache/progress must be retained');
    expect(timeouts, 0);
    monitor.cancel(); // The same media became ready, without another open.
    await tester.pump(const Duration(minutes: 2));
    expect(timeouts, 0);
  });

  testWidgets('network startup has one absolute bounded timeout',
      (tester) async {
    var resets = 0;
    var timeouts = 0;
    MpvPendingLoadMonitor(
      networkStream: true,
      isCurrent: () => true,
      retryLocal: () async => resets++,
      onTimeout: () => timeouts++,
      onFailure: (_) => fail('unexpected retry error'),
    ).start();
    await tester.pump(const Duration(seconds: 59));
    expect(timeouts, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(timeouts, 1);
    await tester.pump(const Duration(minutes: 2));
    expect(timeouts, 1);
    expect(resets, 0);
  });

  testWidgets('local startup retains retry behavior without overlapping opens',
      (tester) async {
    var retries = 0;
    var timeouts = 0;
    var failures = 0;
    final pending = Completer<void>();
    MpvPendingLoadMonitor(
      networkStream: false,
      isCurrent: () => true,
      retryLocal: () {
        retries++;
        return pending.future;
      },
      onTimeout: () => timeouts++,
      onFailure: (_) => failures++,
    ).start();
    await tester.pump(const Duration(seconds: 20));
    expect(retries, 1);
    await tester.pump(const Duration(seconds: 40));
    expect(timeouts, 1, reason: 'a pending retry must not extend the budget');
    pending.completeError(StateError('synthetic late local failure'));
    await tester.pump();
    expect(
      failures,
      0,
      reason: 'expired retry errors must be handled silently',
    );
    await tester.pump(const Duration(minutes: 2));
    expect(retries, 1);
  });

  testWidgets('superseded and cancelled media cannot act on a new load',
      (tester) async {
    for (final network in [false, true]) {
      var current = true;
      var actions = 0;
      final monitor = MpvPendingLoadMonitor(
        networkStream: network,
        isCurrent: () => current,
        retryLocal: () async => actions++,
        onTimeout: () => actions++,
        onFailure: (_) => actions++,
      )..start();
      current = false;
      await tester.pump(const Duration(minutes: 2));
      expect(actions, 0);
      monitor.cancel();
    }
  });

  testWidgets('local failure is caught once and ends the monitor',
      (tester) async {
    var retries = 0;
    final errors = <Object>[];
    MpvPendingLoadMonitor(
      networkStream: false,
      isCurrent: () => true,
      retryLocal: () async {
        retries++;
        throw StateError('synthetic retry failure');
      },
      onTimeout: () => fail('failure already ended the monitor'),
      onFailure: errors.add,
    ).start();
    await tester.pump(const Duration(minutes: 2));
    expect(retries, 1);
    expect(errors.single, isA<StateError>());
  });

  testWidgets(
      'elapsed initialization budget expires without another local retry',
      (tester) async {
    var timeouts = 0;
    MpvPendingLoadMonitor(
      networkStream: false,
      isCurrent: () => true,
      retryLocal: () async => fail('no startup budget remains'),
      onTimeout: () => timeouts++,
      onFailure: (_) => fail('unexpected failure'),
      budget: const Duration(seconds: -1),
    ).start();
    await tester.pump(Duration.zero);
    expect(timeouts, 1);
  });

  testWidgets('cancellation before start prevents any delayed action',
      (tester) async {
    final monitor = MpvPendingLoadMonitor(
      networkStream: false,
      isCurrent: () => true,
      retryLocal: () async => fail('cancelled'),
      onTimeout: () => fail('cancelled'),
      onFailure: (_) => fail('cancelled'),
    )..cancel();
    monitor.start();
    await tester.pump(const Duration(minutes: 2));
  });
}
