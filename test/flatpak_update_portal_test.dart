import 'dart:async';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/services/flatpak_update_portal.dart';
import 'package:fladder/services/flatpak_update_portal_dbus.dart'
    show decodeFlatpakPortalDbusSignal;

const _monitorPath = '/org/freedesktop/portal/Flatpak/update_monitor/1_2/test';

class _FakeTransport implements FlatpakPortalTransport {
  final signalController = StreamController<FlatpakPortalSignal>.broadcast(
    sync: true,
  );
  final calls = <String>[];
  final parents = <String>[];
  int version = 2;
  String monitorPath = _monitorPath;
  Future<int> Function()? onVersion;
  Future<void> Function()? onSubscribe;
  Future<String> Function()? onCreate;
  Future<void> Function()? onUpdate;
  Future<void> Function()? onCloseMonitor;
  Future<void> Function()? onClose;

  @override
  Stream<FlatpakPortalSignal> get signals => signalController.stream;

  @override
  Future<int> getVersion() {
    calls.add('version');
    return onVersion?.call() ?? Future<int>.value(version);
  }

  @override
  Future<void> subscribe() {
    calls.add('subscribe');
    return onSubscribe?.call() ?? Future<void>.value();
  }

  @override
  Future<String> createMonitor() {
    calls.add('create');
    return onCreate?.call() ?? Future<String>.value(monitorPath);
  }

  @override
  Future<void> update(String monitorPath, {String parentWindow = ''}) {
    calls.add('update:$monitorPath');
    parents.add(parentWindow);
    return onUpdate?.call() ?? Future<void>.value();
  }

  @override
  Future<void> closeMonitor(String monitorPath) {
    calls.add('close-monitor:$monitorPath');
    return onCloseMonitor?.call() ?? Future<void>.value();
  }

  @override
  Future<void> close() {
    calls.add('close');
    return onClose?.call() ?? Future<void>.value();
  }

  void emit(
    String name,
    Map<String, Object?> values, {
    String path = _monitorPath,
    FlatpakPortalFailureCode? failure,
  }) {
    signalController.add(FlatpakPortalSignal(
      path: path,
      name: name,
      values: values,
      failure: failure,
    ));
  }

  int count(String call) => calls.where((entry) => entry == call).length;

  Future<void> dispose() => signalController.close();
}

TransportFlatpakUpdatePortal _portal(
  _FakeTransport transport, {
  Duration methodTimeout = const Duration(seconds: 1),
}) =>
    TransportFlatpakUpdatePortal(
      transportFactory: () => transport,
      methodTimeout: methodTimeout,
    );

Matcher _failure(FlatpakPortalFailureCode code) =>
    isA<FlatpakPortalFailure>().having((error) => error.code, 'code', code);

Future<void> _flush() => Future<void>.delayed(Duration.zero);

Map<String, Object?> _commits({
  String running = 'running',
  String local = 'local',
  String remote = 'remote',
}) =>
    {
      'running-commit': running,
      'local-commit': local,
      'remote-commit': remote,
    };

DBusSignal _dbusSignal(
  String name,
  List<DBusValue> values, {
  String interface = 'org.freedesktop.portal.Flatpak.UpdateMonitor',
}) =>
    DBusSignal(
      sender: ':1.2',
      path: DBusObjectPath(_monitorPath),
      interface: interface,
      name: name,
      values: values,
    );

void main() {
  test('commit facts distinguish a remote update from a pending restart', () {
    const current = FlatpakPortalUpdate(
      runningCommit: 'a',
      localCommit: 'a',
      remoteCommit: 'a',
    );
    const available = FlatpakPortalUpdate(
      runningCommit: 'a',
      localCommit: 'a',
      remoteCommit: 'b',
    );
    const installed = FlatpakPortalUpdate(
      runningCommit: 'a',
      localCommit: 'b',
      remoteCommit: 'b',
    );
    expect(current.hasRemoteUpdate, isFalse);
    expect(current.restartRequired, isFalse);
    expect(available.hasRemoteUpdate, isTrue);
    expect(available.restartRequired, isFalse);
    expect(installed.hasRemoteUpdate, isFalse);
    expect(installed.restartRequired, isTrue);
  });

  test('signal messages copy only allowed fields and omit raw diagnostics', () {
    final values = <String, Object?>{
      'status': 3,
      'progress': 10,
      'error': 'org.freedesktop.portal.Error.NotAllowed',
      'error_message': 'private local path or account details',
    };
    final signal = FlatpakPortalSignal(
      path: _monitorPath,
      name: 'Progress',
      values: values,
      failure: FlatpakPortalFailureCode.denied,
    );
    values['status'] = 2;
    expect(signal.values, {'status': 3, 'progress': 10});
    expect(signal.failure, FlatpakPortalFailureCode.denied);
    expect(() => signal.values['status'] = 2, throwsUnsupportedError);
    expect(signal.values.toString(), isNot(contains('private local path')));
  });

  group('real D-Bus value decoder without a bus', () {
    test('decodes only documented commit strings', () {
      final signal = decodeFlatpakPortalDbusSignal(_dbusSignal(
        'UpdateAvailable',
        [
          DBusDict.stringVariant({
            'running-commit': const DBusString('running'),
            'local-commit': const DBusString('local'),
            'remote-commit': const DBusString('remote'),
            'unknown-private-field': const DBusString('private detail'),
          }),
        ],
      ));
      expect(signal, isNotNull);
      expect(signal!.path, _monitorPath);
      expect(signal.name, 'UpdateAvailable');
      expect(signal.values, _commits());
      expect(signal.failure, isNull);
      expect(signal.values.toString(), isNot(contains('private detail')));
    });

    test('does not coerce incorrect or string-like commit values into facts',
        () {
      final signal = decodeFlatpakPortalDbusSignal(_dbusSignal(
        'UpdateAvailable',
        [
          DBusDict.stringVariant({
            'running-commit': const DBusString('running'),
            'local-commit': const DBusUint32(1),
            'remote-commit': DBusObjectPath('/string_like_object_path'),
          }),
        ],
      ));
      expect(signal!.values, {'running-commit': 'running'});
    });

    test('decodes uint32 progress and canonical permission failure only', () {
      final signal = decodeFlatpakPortalDbusSignal(_dbusSignal(
        'Progress',
        [
          DBusDict.stringVariant({
            'status': const DBusUint32(3),
            'progress': const DBusUint32(20),
            'error':
                const DBusString('org.freedesktop.DBus.Error.NotSupported'),
            'error_message':
                const DBusString('private path or account details'),
            'unknown': const DBusString('another private detail'),
          }),
        ],
      ));
      expect(signal!.values, {'status': 3, 'progress': 20});
      expect(signal.failure, FlatpakPortalFailureCode.permissionChange);
      expect(signal.values.toString(), isNot(contains('private')));
    });

    test('maps a denial name without retaining the name or its message', () {
      final signal = decodeFlatpakPortalDbusSignal(_dbusSignal(
        'Progress',
        [
          DBusDict.stringVariant({
            'status': const DBusUint32(3),
            'error':
                const DBusString('org.freedesktop.portal.Error.NotAllowed'),
            'error_message': const DBusString('private diagnostic'),
          }),
        ],
      ));
      expect(signal!.values, {'status': 3});
      expect(signal.failure, FlatpakPortalFailureCode.denied);
    });

    test('allows the documented optional progress fields to be absent', () {
      final signal = decodeFlatpakPortalDbusSignal(_dbusSignal(
        'Progress',
        [DBusDict.stringVariant(const {})],
      ));
      expect(signal!.values, isEmpty);
      expect(signal.failure, isNull);
    });

    test('rejects signed, floating point, and string progress values', () {
      for (final field in ['status', 'progress']) {
        for (final value in <DBusValue>[
          const DBusInt32(0),
          const DBusDouble(0),
          const DBusString('0'),
        ]) {
          expect(
            () => decodeFlatpakPortalDbusSignal(_dbusSignal(
              'Progress',
              [
                DBusDict.stringVariant({field: value})
              ],
            )),
            throwsA(_failure(FlatpakPortalFailureCode.invalidResponse)),
            reason: '$field must have the documented uint32 wire type',
          );
        }
      }
    });

    test('rejects a recognized signal whose signature is not a single vardict',
        () {
      for (final name in ['UpdateAvailable', 'Progress']) {
        for (final values in <List<DBusValue>>[
          [],
          [const DBusString('private raw payload')],
          [const DBusUint32(0)],
          [DBusDict.stringVariant(const {}), const DBusUint32(0)],
        ]) {
          expect(
            () => decodeFlatpakPortalDbusSignal(_dbusSignal(name, values)),
            throwsA(_failure(FlatpakPortalFailureCode.invalidResponse)),
          );
        }
      }
    });

    test('ignores unknown interfaces and members without interpreting values',
        () {
      expect(
        decodeFlatpakPortalDbusSignal(_dbusSignal(
          'Progress',
          [],
          interface: 'org.freedesktop.portal.Unrelated',
        )),
        isNull,
      );
      expect(
        decodeFlatpakPortalDbusSignal(_dbusSignal('UnrelatedSignal', [])),
        isNull,
      );
    });
  });

  test('construction and stream listeners do not create a transport', () async {
    var factories = 0;
    final transport = _FakeTransport();
    final portal = TransportFlatpakUpdatePortal(transportFactory: () {
      factories++;
      return transport;
    });
    final updates = portal.updates.listen((_) {});
    final progress = portal.progress.listen((_) {});
    addTearDown(transport.dispose);
    addTearDown(portal.close);
    addTearDown(updates.cancel);
    addTearDown(progress.cancel);
    await _flush();
    expect(factories, 0);
    expect(transport.calls, isEmpty);
    await portal.open();
    expect(factories, 1);
    expect(transport.count('create'), 1);
  });

  test('open shares monitor creation and creates no synthetic update',
      () async {
    final created = Completer<String>();
    final transport = _FakeTransport()..onCreate = () => created.future;
    final portal = _portal(transport);
    final seen = <FlatpakPortalUpdate>[];
    final subscription = portal.updates.listen(seen.add);
    addTearDown(transport.dispose);
    addTearDown(portal.close);
    addTearDown(subscription.cancel);
    final first = portal.open();
    final second = portal.open();
    await _flush();
    expect(transport.count('create'), 1);
    expect(transport.calls.indexOf('subscribe'),
        lessThan(transport.calls.indexOf('create')));
    created.complete(_monitorPath);
    await Future.wait([first, second]);
    await portal.open();
    expect(transport.count('create'), 1);
    expect(seen, isEmpty);
  });

  test('waits for signal subscription before creating the monitor', () async {
    final subscribed = Completer<void>();
    final transport = _FakeTransport()..onSubscribe = () => subscribed.future;
    final portal = _portal(transport);
    addTearDown(transport.dispose);
    addTearDown(portal.close);
    final opening = portal.open();
    await _flush();
    expect(transport.count('subscribe'), 1);
    expect(transport.count('create'), 0);
    subscribed.complete();
    await opening;
    expect(transport.count('create'), 1);
  });

  test('buffers early updates and accepts only its returned monitor path',
      () async {
    final transport = _FakeTransport();
    transport.onCreate = () async {
      transport.emit('UpdateAvailable', _commits(remote: 'unrelated'),
          path: '${_monitorPath}_other');
      transport.emit('UpdateAvailable', _commits());
      return _monitorPath;
    };
    final portal = _portal(transport);
    final seen = <FlatpakPortalUpdate>[];
    final subscription = portal.updates.listen(seen.add);
    addTearDown(transport.dispose);
    addTearDown(portal.close);
    addTearDown(subscription.cancel);
    await portal.open();
    await _flush();
    expect(seen, hasLength(1));
    expect(seen.single.runningCommit, 'running');
    expect(seen.single.localCommit, 'local');
    expect(seen.single.remoteCommit, 'remote');
    transport.emit('UpdateAvailable', _commits(remote: 'still-unrelated'),
        path: '${_monitorPath}_other');
    await _flush();
    expect(seen, hasLength(1));
  });

  test('an overflowing early signal buffer fails closed', () async {
    final transport = _FakeTransport();
    transport.onCreate = () async {
      for (var index = 0; index < 65; index++) {
        transport.emit('UpdateAvailable', _commits(remote: 'remote-$index'));
      }
      return _monitorPath;
    };
    final portal = _portal(transport);
    final seen = <FlatpakPortalUpdate>[];
    final subscription = portal.updates.listen(seen.add);
    addTearDown(transport.dispose);
    addTearDown(portal.close);
    addTearDown(subscription.cancel);
    await expectLater(portal.open(),
        throwsA(_failure(FlatpakPortalFailureCode.invalidResponse)));
    await _flush();
    expect(seen, isEmpty);
    expect(transport.count('close'), 1);
  });

  test('oversized early and live metadata is discarded at the signal boundary',
      () async {
    final oversized = List.filled(129, 'x').join();
    final early = FlatpakPortalSignal(
      path: _monitorPath,
      name: 'UpdateAvailable',
      values: _commits(remote: oversized),
    );
    final oversizedPath = FlatpakPortalSignal(
      path: List.filled(513, 'x').join(),
      name: 'UpdateAvailable',
      values: _commits(),
    );
    expect(early.values.containsKey('remote-commit'), isFalse);
    expect(early.values.values, isNot(contains(oversized)));
    expect(oversizedPath.path, isEmpty);
    final transport = _FakeTransport();
    transport.onCreate = () async {
      transport.signalController.add(early);
      transport.signalController.add(oversizedPath);
      return _monitorPath;
    };
    final portal = _portal(transport);
    final seen = <FlatpakPortalUpdate>[];
    final errors = <Object>[];
    final subscription = portal.updates.listen(seen.add, onError: errors.add);
    addTearDown(transport.dispose);
    addTearDown(portal.close);
    addTearDown(subscription.cancel);
    await portal.open();
    await _flush();
    expect(seen, isEmpty);
    expect(errors, hasLength(1));
    expect(errors.single, _failure(FlatpakPortalFailureCode.invalidResponse));
    transport.emit('UpdateAvailable', _commits(local: oversized));
    await _flush();
    expect(seen, isEmpty);
    expect(errors, hasLength(2));
    expect(errors,
        everyElement(_failure(FlatpakPortalFailureCode.invalidResponse)));
  });

  for (final version in [0, 1]) {
    test('portal version $version cannot create an update monitor', () async {
      final transport = _FakeTransport()..version = version;
      final portal = _portal(transport);
      addTearDown(transport.dispose);
      addTearDown(portal.close);
      await expectLater(portal.open(),
          throwsA(_failure(FlatpakPortalFailureCode.unsupported)));
      expect(transport.count('create'), 0);
      expect(transport.count('close'), 1);
    });
  }

  test('rejects a returned object path outside the update monitor namespace',
      () async {
    final transport = _FakeTransport()..monitorPath = '/unrelated/object';
    final portal = _portal(transport);
    addTearDown(transport.dispose);
    addTearDown(portal.close);
    await expectLater(portal.open(),
        throwsA(_failure(FlatpakPortalFailureCode.invalidResponse)));
  });

  test('rejects an oversized monitor reply without retaining it for Close',
      () async {
    final transport = _FakeTransport()
      ..monitorPath = '$_monitorPath${List.filled(513, 'x').join()}';
    final portal = _portal(transport);
    addTearDown(transport.dispose);
    addTearDown(portal.close);
    await expectLater(portal.open(),
        throwsA(_failure(FlatpakPortalFailureCode.invalidResponse)));
    expect(transport.calls.where((call) => call.startsWith('close-monitor:')),
        isEmpty);
    expect(transport.count('close'), 1);
  });

  test('failed open can retry with a fresh transport', () async {
    final failed = _FakeTransport()..version = 1;
    final working = _FakeTransport();
    final transports = [failed, working];
    final portal = TransportFlatpakUpdatePortal(
      transportFactory: () => transports.removeAt(0),
    );
    addTearDown(failed.dispose);
    addTearDown(working.dispose);
    addTearDown(portal.close);
    await expectLater(
        portal.open(), throwsA(_failure(FlatpakPortalFailureCode.unsupported)));
    await portal.open();
    expect(failed.count('create'), 0);
    expect(working.count('create'), 1);
  });

  test('update is singleflight through method ack and running progress 100',
      () async {
    final acknowledged = Completer<void>();
    final transport = _FakeTransport()..onUpdate = () => acknowledged.future;
    final portal = _portal(transport);
    final seen = <FlatpakPortalProgress>[];
    final subscription = portal.progress.listen(seen.add);
    addTearDown(transport.dispose);
    addTearDown(portal.close);
    addTearDown(subscription.cancel);
    await portal.open();
    final first = portal.requestUpdate(parentWindow: 'x11:123');
    final second = portal.requestUpdate(parentWindow: 'x11:456');
    await _flush();
    expect(transport.count('update:$_monitorPath'), 1);
    expect(transport.parents, ['x11:123']);
    acknowledged.complete();
    await Future.wait([first, second]);
    transport.emit('Progress', {'status': 0, 'progress': 100});
    await _flush();
    expect(seen.last.status, FlatpakPortalProgressStatus.running);
    expect(seen.last.percent, 100);
    await portal.requestUpdate();
    expect(transport.count('update:$_monitorPath'), 1);
    transport.emit('Progress', {'status': 2});
    await _flush();
    expect(seen.last.status, FlatpakPortalProgressStatus.done);
    await portal.requestUpdate();
    expect(transport.count('update:$_monitorPath'), 2);
  });

  test('terminal progress before the method reply does not resend Update',
      () async {
    final acknowledged = Completer<void>();
    final transport = _FakeTransport()..onUpdate = () => acknowledged.future;
    final portal = _portal(transport);
    addTearDown(transport.dispose);
    addTearDown(portal.close);
    await portal.open();
    final first = portal.requestUpdate();
    await _flush();
    transport.emit('Progress', {'status': 2});
    await _flush();
    final second = portal.requestUpdate();
    expect(transport.count('update:$_monitorPath'), 1);
    acknowledged.complete();
    await Future.wait([first, second]);
    await portal.requestUpdate();
    expect(transport.count('update:$_monitorPath'), 2);
  });

  test('optional progress fields do not fabricate completion', () async {
    final transport = _FakeTransport();
    final portal = _portal(transport);
    final seen = <FlatpakPortalProgress>[];
    final subscription = portal.progress.listen(seen.add);
    addTearDown(transport.dispose);
    addTearDown(portal.close);
    addTearDown(subscription.cancel);
    await portal.open();
    await portal.requestUpdate();
    transport.emit('Progress', {});
    await _flush();
    expect(seen.last.status, FlatpakPortalProgressStatus.running);
    expect(seen.last.percent, isNull);
    await portal.requestUpdate();
    expect(transport.count('update:$_monitorPath'), 1);
  });

  for (final terminal in {
    1: FlatpakPortalProgressStatus.empty,
    2: FlatpakPortalProgressStatus.done,
    3: FlatpakPortalProgressStatus.failed,
  }.entries) {
    test(
        '${terminal.value.name} is terminal and permits a later explicit update',
        () async {
      final transport = _FakeTransport();
      final portal = _portal(transport);
      final seen = <FlatpakPortalProgress>[];
      final subscription = portal.progress.listen(seen.add);
      addTearDown(transport.dispose);
      addTearDown(portal.close);
      addTearDown(subscription.cancel);
      await portal.open();
      await portal.requestUpdate();
      transport.emit('Progress', {'status': terminal.key},
          failure: terminal.key == 3 ? FlatpakPortalFailureCode.denied : null);
      await _flush();
      expect(seen.last.status, terminal.value);
      if (terminal.key == 3) {
        expect(seen.last.failure, FlatpakPortalFailureCode.denied);
      }
      await portal.requestUpdate();
      expect(transport.count('update:$_monitorPath'), 2);
    });
  }

  test('malformed commit facts emit only a canonical update stream error',
      () async {
    final transport = _FakeTransport();
    final portal = _portal(transport);
    final seen = <FlatpakPortalUpdate>[];
    final errors = <Object>[];
    final subscription = portal.updates.listen(seen.add, onError: errors.add);
    addTearDown(transport.dispose);
    addTearDown(portal.close);
    addTearDown(subscription.cancel);
    await portal.open();
    transport.emit('UpdateAvailable', {
      'running-commit': 'running',
      'local-commit': 'local',
    });
    transport.emit('UpdateAvailable', _commits(remote: ''));
    transport.emit('UpdateAvailable', {
      ..._commits(),
      'local-commit': 123,
    });
    await _flush();
    expect(seen, isEmpty);
    expect(errors, hasLength(3));
    expect(errors,
        everyElement(_failure(FlatpakPortalFailureCode.invalidResponse)));
  });

  test('transport stream errors expose a canonical failure only', () async {
    final transport = _FakeTransport();
    final portal = _portal(transport);
    final errors = <Object>[];
    final subscription = portal.updates.listen((_) {}, onError: errors.add);
    addTearDown(transport.dispose);
    addTearDown(portal.close);
    addTearDown(subscription.cancel);
    await portal.open();
    transport.signalController.addError(StateError('private raw message'));
    await _flush();
    expect(errors, hasLength(1));
    expect(errors.single, _failure(FlatpakPortalFailureCode.failed));
    expect(errors.single.toString(), isNot(contains('private raw message')));
  });

  for (final values in <Map<String, Object?>>[
    {'status': 9},
    {'status': '0'},
    {'status': 0, 'progress': -1},
    {'status': 0, 'progress': 101},
    {'status': 0, 'progress': '100'},
  ]) {
    test('malformed progress $values reports uncertainty and keeps the latch',
        () async {
      final transport = _FakeTransport();
      final portal = _portal(transport);
      final seen = <FlatpakPortalProgress>[];
      final errors = <Object>[];
      final subscription =
          portal.progress.listen(seen.add, onError: errors.add);
      addTearDown(transport.dispose);
      addTearDown(portal.close);
      addTearDown(subscription.cancel);
      await portal.open();
      await portal.requestUpdate();
      transport.emit('Progress', values);
      await _flush();
      expect(errors, hasLength(1));
      expect(errors.single, _failure(FlatpakPortalFailureCode.invalidResponse));
      expect(seen, isEmpty);
      await portal.requestUpdate();
      expect(transport.count('update:$_monitorPath'), 1);
      transport.emit('Progress', {'status': 2});
      await _flush();
      expect(seen.last.status, FlatpakPortalProgressStatus.done);
      await portal.requestUpdate();
      expect(transport.count('update:$_monitorPath'), 2);
    });
  }

  test('a real malformed D-Bus Progress signal preserves the active latch',
      () async {
    final transport = _FakeTransport();
    final portal = _portal(transport);
    final seen = <FlatpakPortalProgress>[];
    final progressErrors = <Object>[];
    final updateErrors = <Object>[];
    final progressSubscription =
        portal.progress.listen(seen.add, onError: progressErrors.add);
    final updateSubscription =
        portal.updates.listen((_) {}, onError: updateErrors.add);
    addTearDown(transport.dispose);
    addTearDown(portal.close);
    addTearDown(progressSubscription.cancel);
    addTearDown(updateSubscription.cancel);
    await portal.open();
    await portal.requestUpdate();
    try {
      final decoded = decodeFlatpakPortalDbusSignal(_dbusSignal(
        'Progress',
        [
          DBusDict.stringVariant({'status': const DBusString('0')})
        ],
      ));
      if (decoded != null) transport.signalController.add(decoded);
    } catch (error) {
      transport.signalController.addError(error);
    }
    await _flush();
    expect(progressErrors, hasLength(1));
    expect(progressErrors.single,
        _failure(FlatpakPortalFailureCode.invalidResponse));
    expect(updateErrors, isEmpty);
    expect(seen, isEmpty);
    await portal.requestUpdate();
    expect(transport.count('update:$_monitorPath'), 1);
    expect(transport.count('close-monitor:$_monitorPath'), 0);
    transport.emit('Progress', {'status': 2});
    await _flush();
    expect(seen.last.status, FlatpakPortalProgressStatus.done);
    await portal.requestUpdate();
    expect(transport.count('update:$_monitorPath'), 2);
  });

  test('active transport errors retain the latch and expose no raw message',
      () async {
    final transport = _FakeTransport();
    final portal = _portal(transport);
    final seen = <FlatpakPortalProgress>[];
    final errors = <Object>[];
    final subscription = portal.progress.listen(seen.add, onError: errors.add);
    addTearDown(transport.dispose);
    addTearDown(portal.close);
    addTearDown(subscription.cancel);
    await portal.open();
    await portal.requestUpdate();
    transport.signalController.addError(StateError('private raw message'));
    await _flush();
    expect(errors, hasLength(1));
    expect(errors.single, _failure(FlatpakPortalFailureCode.failed));
    expect(errors.single.toString(), isNot(contains('private raw message')));
    expect(seen, isEmpty);
    await portal.requestUpdate();
    expect(transport.count('update:$_monitorPath'), 1);
    transport.emit('Progress', {'status': 3},
        failure: FlatpakPortalFailureCode.failed);
    await _flush();
    expect(seen.last.status, FlatpakPortalProgressStatus.failed);
    await portal.requestUpdate();
    expect(transport.count('update:$_monitorPath'), 2);
  });

  test('bounded monitor creation times out without reviving on a late reply',
      () async {
    final created = Completer<String>();
    final transport = _FakeTransport()..onCreate = () => created.future;
    final portal =
        _portal(transport, methodTimeout: const Duration(milliseconds: 1));
    final seen = <FlatpakPortalUpdate>[];
    final subscription = portal.updates.listen(seen.add);
    addTearDown(transport.dispose);
    addTearDown(portal.close);
    addTearDown(subscription.cancel);
    await expectLater(
        portal.open(), throwsA(_failure(FlatpakPortalFailureCode.timeout)));
    expect(transport.count('close'), 1);
    created.complete(_monitorPath);
    transport.emit('UpdateAvailable', _commits());
    await _flush();
    expect(seen, isEmpty);
  });

  test(
      'Update timeout keeps its monitor and latch until a late terminal signal',
      () async {
    final acknowledged = Completer<void>();
    final transport = _FakeTransport()..onUpdate = () => acknowledged.future;
    final portal =
        _portal(transport, methodTimeout: const Duration(milliseconds: 1));
    final seen = <FlatpakPortalProgress>[];
    final errors = <Object>[];
    final subscription = portal.progress.listen(seen.add, onError: errors.add);
    addTearDown(transport.dispose);
    addTearDown(portal.close);
    addTearDown(subscription.cancel);
    await portal.open();
    await expectLater(portal.requestUpdate(),
        throwsA(_failure(FlatpakPortalFailureCode.timeout)));
    expect(transport.count('update:$_monitorPath'), 1);
    expect(transport.count('close-monitor:$_monitorPath'), 0);
    expect(transport.count('close'), 0);
    await expectLater(portal.requestUpdate(),
        throwsA(_failure(FlatpakPortalFailureCode.timeout)));
    expect(transport.count('update:$_monitorPath'), 1);
    transport.emit('Progress', {'status': 0, 'progress': 100});
    await _flush();
    expect(seen.last.status, FlatpakPortalProgressStatus.running);
    expect(seen.last.percent, 100);
    await expectLater(portal.requestUpdate(),
        throwsA(_failure(FlatpakPortalFailureCode.timeout)));
    expect(transport.count('update:$_monitorPath'), 1);
    transport.emit('Progress', {'status': 2});
    await _flush();
    expect(seen.last.status, FlatpakPortalProgressStatus.done);
    transport.onUpdate = () => Future<void>.value();
    await portal.requestUpdate();
    expect(transport.count('update:$_monitorPath'), 2);
    acknowledged.complete();
    await _flush();
  });

  test('close cancels its monitor once and makes the instance terminal',
      () async {
    final transport = _FakeTransport();
    final portal = _portal(transport);
    final updates = <FlatpakPortalUpdate>[];
    final progress = <FlatpakPortalProgress>[];
    final updatesSubscription = portal.updates.listen(updates.add);
    final progressSubscription = portal.progress.listen(progress.add);
    addTearDown(transport.dispose);
    addTearDown(portal.close);
    addTearDown(updatesSubscription.cancel);
    addTearDown(progressSubscription.cancel);
    await portal.open();
    await portal.requestUpdate();
    await Future.wait([portal.close(), portal.close()]);
    expect(transport.count('close-monitor:$_monitorPath'), 1);
    expect(transport.count('close'), 1);
    transport.emit('UpdateAvailable', _commits());
    transport.emit('Progress', {'status': 2});
    await _flush();
    expect(updates, isEmpty);
    expect(
        progress
            .where((event) => event.status == FlatpakPortalProgressStatus.done),
        isEmpty);
    await expectLater(
        portal.open(), throwsA(_failure(FlatpakPortalFailureCode.unavailable)));
    await expectLater(portal.requestUpdate(),
        throwsA(_failure(FlatpakPortalFailureCode.unavailable)));
  });

  test('close during CreateUpdateMonitor rejects a late successful reply',
      () async {
    final created = Completer<String>();
    final transport = _FakeTransport()..onCreate = () => created.future;
    final portal = _portal(transport);
    final seen = <FlatpakPortalUpdate>[];
    final subscription = portal.updates.listen(seen.add);
    addTearDown(transport.dispose);
    addTearDown(portal.close);
    addTearDown(subscription.cancel);
    final opening = portal.open();
    final rejected = expectLater(
        opening, throwsA(_failure(FlatpakPortalFailureCode.unavailable)));
    await _flush();
    expect(transport.count('create'), 1);
    await portal.close();
    created.complete(_monitorPath);
    transport.emit('UpdateAvailable', _commits());
    await rejected;
    await _flush();
    expect(seen, isEmpty);
    expect(transport.count('close'), 1);
  });

  test('an unresponsive Close method cannot prevent transport cleanup',
      () async {
    final never = Completer<void>();
    final transport = _FakeTransport()..onCloseMonitor = () => never.future;
    final portal =
        _portal(transport, methodTimeout: const Duration(milliseconds: 1));
    addTearDown(transport.dispose);
    addTearDown(portal.close);
    await portal.open();
    await portal.close();
    expect(transport.count('close-monitor:$_monitorPath'), 1);
    expect(transport.count('close'), 1);
    never.complete();
  });

  test('close during Update rejects its late reply and ignores later done',
      () async {
    final acknowledged = Completer<void>();
    final transport = _FakeTransport()..onUpdate = () => acknowledged.future;
    final portal = _portal(transport);
    final seen = <FlatpakPortalProgress>[];
    final subscription = portal.progress.listen(seen.add);
    addTearDown(transport.dispose);
    addTearDown(portal.close);
    addTearDown(subscription.cancel);
    await portal.open();
    final updating = portal.requestUpdate();
    final rejected = expectLater(
        updating, throwsA(_failure(FlatpakPortalFailureCode.unavailable)));
    await _flush();
    expect(transport.count('update:$_monitorPath'), 1);
    await portal.close();
    acknowledged.complete();
    transport.emit('Progress', {'status': 2});
    await rejected;
    await _flush();
    expect(
        seen.where((event) => event.status == FlatpakPortalProgressStatus.done),
        isEmpty);
  });

  test('D-Bus error names map to canonical failures without raw message data',
      () {
    const prefix = 'org.freedesktop.DBus.Error.';
    expect(flatpakPortalFailureCodeForErrorName('${prefix}NotSupported'),
        FlatpakPortalFailureCode.unsupported);
    expect(
        flatpakPortalFailureCodeForErrorName('${prefix}NotSupported',
            updating: true),
        FlatpakPortalFailureCode.permissionChange);
    for (final suffix in ['AccessDenied', 'AuthFailed']) {
      expect(flatpakPortalFailureCodeForErrorName('$prefix$suffix'),
          FlatpakPortalFailureCode.denied);
    }
    expect(
        flatpakPortalFailureCodeForErrorName(
            'org.freedesktop.portal.Error.NotAllowed'),
        FlatpakPortalFailureCode.denied);
    for (final suffix in [
      'ServiceUnknown',
      'NameHasNoOwner',
      'UnknownObject'
    ]) {
      expect(flatpakPortalFailureCodeForErrorName('$prefix$suffix'),
          FlatpakPortalFailureCode.unavailable);
    }
    for (final suffix in ['Timeout', 'TimedOut', 'NoReply']) {
      expect(flatpakPortalFailureCodeForErrorName('$prefix$suffix'),
          FlatpakPortalFailureCode.timeout);
    }
    expect(flatpakPortalFailureCodeForErrorName('unrecognized.private.detail'),
        FlatpakPortalFailureCode.failed);
    expect(
        const FlatpakPortalFailure(FlatpakPortalFailureCode.denied).toString(),
        isNot(contains('unrecognized.private.detail')));
  });
}
