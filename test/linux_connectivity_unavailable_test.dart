import 'dart:async';

// Supplied by the locked flutter_test dependency.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';

// The package is supplied by the locked connectivity_plus dependency.
// ignore: depend_on_referenced_packages
import 'package:connectivity_plus_platform_interface/connectivity_plus_platform_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/models/account_model.dart';
import 'package:fladder/providers/connectivity_provider.dart';
import 'package:fladder/providers/user_provider.dart';

class SignedOutUser extends User {
  @override
  AccountModel? build() => null;
}

class MissingLinuxConnectivity extends ConnectivityPlatform {
  MissingLinuxConnectivity({this.pending = false}) {
    events = StreamController<List<ConnectivityResult>>.broadcast(
      onListen: () {
        if (pending) return;
        // Reproduce connectivity_plus_linux's unawaited async onListen failure.
        Future<void>.microtask(() => throw StateError('synthetic missing bus'));
      },
    );
  }

  late final StreamController<List<ConnectivityResult>> events;
  final bool pending;

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => events.stream;

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async {
    if (pending) return Completer<List<ConnectivityResult>>().future;
    Future<void>.microtask(
      () => throw StateError('synthetic bus signal error'),
    );
    throw StateError('synthetic missing NetworkManager');
  }
}

class ControlledConnectivity extends ConnectivityPlatform {
  final events = StreamController<List<ConnectivityResult>>.broadcast();
  final checks = <Completer<List<ConnectivityResult>>>[];

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => events.stream;

  @override
  Future<List<ConnectivityResult>> checkConnectivity() {
    final result = Completer<List<ConnectivityResult>>();
    checks.add(result);
    return result.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('successful overlapping checks cancel their owned watchdog timers', () {
    fakeAsync((clock) {
      final original = ConnectivityPlatform.instance;
      final backend = ControlledConnectivity();
      ConnectivityPlatform.instance = backend;
      final container = ProviderContainer(
        overrides: [userProvider.overrideWith(SignedOutUser.new)],
      );
      try {
        final notifier = container.read(connectivityStatusProvider.notifier);
        var completed = false;
        notifier.checkConnectivity().then((_) => completed = true);
        expect(backend.checks, hasLength(2));
        expect(clock.nonPeriodicTimerCount, 2);
        for (final check in backend.checks) {
          check.complete(const [ConnectivityResult.none]);
        }
        clock.flushMicrotasks();
        expect(completed, isTrue);
        expect(clock.nonPeriodicTimerCount, 0);
        expect(container.read(connectivityStatusProvider),
            ConnectionState.offline);
      } finally {
        container.dispose();
        unawaited(backend.events.close());
        clock.flushMicrotasks();
        ConnectivityPlatform.instance = original;
      }
    });
  });

  test('backend failure cancels watchdog before provider disposal', () {
    fakeAsync((clock) {
      final original = ConnectivityPlatform.instance;
      final backend = ControlledConnectivity();
      ConnectivityPlatform.instance = backend;
      final container = ProviderContainer(
        overrides: [userProvider.overrideWith(SignedOutUser.new)],
      );
      try {
        container.read(connectivityStatusProvider);
        expect(clock.nonPeriodicTimerCount, 1);
        backend.checks.single.completeError(StateError('synthetic absent bus'));
        clock.flushMicrotasks();
        expect(clock.nonPeriodicTimerCount, 0);
        expect(container.read(connectivityStatusProvider),
            ConnectionState.offline);
      } finally {
        container.dispose();
        unawaited(backend.events.close());
        clock.flushMicrotasks();
        ConnectivityPlatform.instance = original;
      }
    });
  });

  test('dispose finishes all pending checks and tolerates their late errors',
      () {
    fakeAsync((clock) {
      final original = ConnectivityPlatform.instance;
      final backend = ControlledConnectivity();
      ConnectivityPlatform.instance = backend;
      final container = ProviderContainer(
        overrides: [userProvider.overrideWith(SignedOutUser.new)],
      );
      try {
        final notifier = container.read(connectivityStatusProvider.notifier);
        var completed = false;
        notifier.checkConnectivity().then((_) => completed = true);
        expect(clock.nonPeriodicTimerCount, 2);
        container.dispose();
        clock.flushMicrotasks();
        expect(completed, isTrue);
        expect(clock.nonPeriodicTimerCount, 0);
        for (final check in backend.checks) {
          check.completeError(StateError('synthetic late absent bus'));
        }
        clock.flushMicrotasks();
        notifier.checkConnectivity();
        expect(clock.nonPeriodicTimerCount, 0);
      } finally {
        container.dispose();
        unawaited(backend.events.close());
        clock.flushMicrotasks();
        ConnectivityPlatform.instance = original;
      }
    });
  });

  test('watchdog timeout retires itself and has no timer after completion', () {
    fakeAsync((clock) {
      final original = ConnectivityPlatform.instance;
      final backend = ControlledConnectivity();
      ConnectivityPlatform.instance = backend;
      final container = ProviderContainer(
        overrides: [userProvider.overrideWith(SignedOutUser.new)],
      );
      try {
        container.read(connectivityStatusProvider);
        clock.elapse(const Duration(seconds: 3));
        clock.flushMicrotasks();
        expect(clock.nonPeriodicTimerCount, 0);
        expect(container.read(connectivityStatusProvider),
            ConnectionState.offline);
        backend.checks.single.complete(const [ConnectivityResult.none]);
        clock.flushMicrotasks();
        expect(clock.nonPeriodicTimerCount, 0);
      } finally {
        container.dispose();
        unawaited(backend.events.close());
        clock.flushMicrotasks();
        ConnectivityPlatform.instance = original;
      }
    });
  });

  test(
    'unresponsive backend check finishes offline within a bounded wait',
    () async {
      final original = ConnectivityPlatform.instance;
      final fake = MissingLinuxConnectivity(pending: true);
      ConnectivityPlatform.instance = fake;
      final container = ProviderContainer(
        overrides: [userProvider.overrideWith(SignedOutUser.new)],
      );
      try {
        await container
            .read(connectivityStatusProvider.notifier)
            .checkConnectivity()
            .timeout(const Duration(seconds: 4));
        expect(
          container.read(connectivityStatusProvider),
          ConnectionState.offline,
        );
      } finally {
        container.dispose();
        await fake.events.close();
        ConnectivityPlatform.instance = original;
      }
    },
  );

  test(
    'detached backend failure after disposal does not update disposed state',
    () async {
      final original = ConnectivityPlatform.instance;
      final fake = MissingLinuxConnectivity();
      ConnectivityPlatform.instance = fake;
      final container = ProviderContainer(
        overrides: [userProvider.overrideWith(SignedOutUser.new)],
      );
      container.read(connectivityStatusProvider);
      container.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await fake.events.close();
      ConnectivityPlatform.instance = original;
    },
  );

  test(
    'unavailable Linux bus enters offline without an uncaught async error',
    () async {
      final original = ConnectivityPlatform.instance;
      final fake = MissingLinuxConnectivity();
      ConnectivityPlatform.instance = fake;
      final container = ProviderContainer(
        overrides: [userProvider.overrideWith(SignedOutUser.new)],
      );
      addTearDown(() async {
        container.dispose();
        await fake.events.close();
        ConnectivityPlatform.instance = original;
      });

      container.read(connectivityStatusProvider);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        container.read(connectivityStatusProvider),
        ConnectionState.offline,
      );
      await container
          .read(connectivityStatusProvider.notifier)
          .checkConnectivity();
      expect(
        container.read(connectivityStatusProvider),
        ConnectionState.offline,
      );
    },
  );
}
