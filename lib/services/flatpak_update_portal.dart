import 'dart:async';

export 'flatpak_update_portal_stub.dart'
    if (dart.library.io) 'flatpak_update_portal_dbus.dart'
    show createFlatpakUpdatePortal;

const _maxCommitLength = 128;
const _maxMonitorPathLength = 512;

enum FlatpakPortalFailureCode {
  unsupported,
  unavailable,
  denied,
  permissionChange,
  timeout,
  invalidResponse,
  failed,
}

class FlatpakPortalFailure implements Exception {
  const FlatpakPortalFailure(this.code);

  final FlatpakPortalFailureCode code;

  @override
  String toString() => 'FlatpakPortalFailure(${code.name})';
}

class FlatpakPortalUpdate {
  const FlatpakPortalUpdate({
    required this.runningCommit,
    required this.localCommit,
    required this.remoteCommit,
  });

  final String runningCommit;
  final String localCommit;
  final String remoteCommit;

  bool get hasRemoteUpdate => remoteCommit != localCommit;
  bool get restartRequired => localCommit != runningCommit;
}

enum FlatpakPortalProgressStatus { running, empty, done, failed }

class FlatpakPortalProgress {
  const FlatpakPortalProgress({
    required this.status,
    this.percent,
    this.failure,
  });

  final FlatpakPortalProgressStatus status;
  final int? percent;
  final FlatpakPortalFailureCode? failure;
}

abstract class FlatpakUpdatePortal {
  Stream<FlatpakPortalUpdate> get updates;
  Stream<FlatpakPortalProgress> get progress;
  Future<void> open();
  Future<void> requestUpdate({String parentWindow = ''});
  Future<void> close();
}

/// Only canonical error codes cross the transport boundary. Never retain a
/// D-Bus error message, which can contain local paths or other private details.
FlatpakPortalFailureCode flatpakPortalFailureCodeForErrorName(
  String name, {
  bool updating = false,
}) =>
    switch (name) {
      'org.freedesktop.DBus.Error.NotSupported' => updating
          ? FlatpakPortalFailureCode.permissionChange
          : FlatpakPortalFailureCode.unsupported,
      'org.freedesktop.DBus.Error.AccessDenied' ||
      'org.freedesktop.DBus.Error.AuthFailed' ||
      'org.freedesktop.portal.Error.NotAllowed' ||
      'org.freedesktop.portal.Error.Cancelled' =>
        FlatpakPortalFailureCode.denied,
      'org.freedesktop.DBus.Error.ServiceUnknown' ||
      'org.freedesktop.DBus.Error.NameHasNoOwner' ||
      'org.freedesktop.DBus.Error.UnknownObject' ||
      'org.freedesktop.DBus.Error.UnknownInterface' ||
      'org.freedesktop.DBus.Error.UnknownMethod' ||
      'org.freedesktop.DBus.Error.Disconnected' =>
        FlatpakPortalFailureCode.unavailable,
      'org.freedesktop.DBus.Error.Timeout' ||
      'org.freedesktop.DBus.Error.TimedOut' ||
      'org.freedesktop.DBus.Error.NoReply' =>
        FlatpakPortalFailureCode.timeout,
      _ => FlatpakPortalFailureCode.failed,
    };

/// A small, fakeable boundary. Construction and reading [signals] must not
/// connect to a bus. [subscribe] completes only after the match is installed.
abstract class FlatpakPortalTransport {
  Stream<FlatpakPortalSignal> get signals;
  Future<int> getVersion();
  Future<void> subscribe();
  Future<String> createMonitor();
  Future<void> update(String monitorPath, {String parentWindow = ''});
  Future<void> closeMonitor(String monitorPath);
  Future<void> close();
}

class FlatpakPortalSignal {
  FlatpakPortalSignal({
    required String path,
    required this.name,
    required Map<String, Object?> values,
    this.failure,
  })  : path = path.length <= _maxMonitorPathLength ? path : '',
        values = Map.unmodifiable({
          for (final key in name == 'UpdateAvailable'
              ? const ['running-commit', 'local-commit', 'remote-commit']
              : const ['status', 'progress'])
            if (values.containsKey(key) &&
                !(name == 'UpdateAvailable' &&
                    values[key] is String &&
                    (values[key] as String).length > _maxCommitLength))
              key: values[key],
        });

  final String path;
  final String name;
  final Map<String, Object?> values;
  final FlatpakPortalFailureCode? failure;
}

class UnsupportedFlatpakUpdatePortal implements FlatpakUpdatePortal {
  const UnsupportedFlatpakUpdatePortal();

  @override
  Stream<FlatpakPortalUpdate> get updates => const Stream.empty();

  @override
  Stream<FlatpakPortalProgress> get progress => const Stream.empty();

  @override
  Future<void> open() => Future.error(
        const FlatpakPortalFailure(FlatpakPortalFailureCode.unsupported),
      );

  @override
  Future<void> requestUpdate({String parentWindow = ''}) => open();

  @override
  Future<void> close() async {}
}

/// Owns only the calling app's monitor. It never invokes a native installer or
/// creates a repository, trust key, permission, or host process.
class TransportFlatpakUpdatePortal implements FlatpakUpdatePortal {
  TransportFlatpakUpdatePortal({
    required FlatpakPortalTransport Function() transportFactory,
    this.methodTimeout = const Duration(seconds: 15),
  }) : _transportFactory = transportFactory;

  final FlatpakPortalTransport Function() _transportFactory;
  final Duration methodTimeout;
  final _updates = StreamController<FlatpakPortalUpdate>.broadcast();
  final _progress = StreamController<FlatpakPortalProgress>.broadcast();
  _PortalSession? _session;
  Future<void>? _opening;
  Future<void>? _updating;
  Future<void>? _closing;
  bool _transactionActive = false;
  bool _updateAcknowledged = false;
  bool _updateDispatched = false;
  bool _closed = false;
  int _generation = 0;

  @override
  Stream<FlatpakPortalUpdate> get updates => _updates.stream;

  @override
  Stream<FlatpakPortalProgress> get progress => _progress.stream;

  Future<T> _bounded<T>(Future<T> operation) => operation.timeout(
        methodTimeout,
        onTimeout: () => throw const FlatpakPortalFailure(
          FlatpakPortalFailureCode.timeout,
        ),
      );

  bool _current(_PortalSession session) =>
      !_closed &&
      identical(_session, session) &&
      session.generation == _generation;

  void _requireCurrent(_PortalSession session) {
    if (!_current(session)) {
      throw const FlatpakPortalFailure(FlatpakPortalFailureCode.unavailable);
    }
  }

  @override
  Future<void> open() {
    if (_closed) {
      return Future.error(
        const FlatpakPortalFailure(FlatpakPortalFailureCode.unavailable),
      );
    }
    final opening = _opening;
    if (opening != null) return opening;
    if (_session?.path != null) return Future.value();
    final session = _PortalSession(_transportFactory(), ++_generation);
    _session = session;
    final operation = _openSession(session);
    _opening = operation;
    operation.then<void>((_) {
      if (identical(_opening, operation)) _opening = null;
    }, onError: (Object _, StackTrace __) {
      if (identical(_opening, operation)) _opening = null;
    });
    return operation;
  }

  Future<void> _openSession(_PortalSession session) async {
    try {
      final version = await _bounded(session.transport.getVersion());
      _requireCurrent(session);
      if (version < 2) {
        throw const FlatpakPortalFailure(FlatpakPortalFailureCode.unsupported);
      }
      session.subscription = session.transport.signals.listen(
        (signal) => _receive(session, signal),
        onError: (Object error) => _transportFailure(session, error),
        onDone: () => _transportFailure(
          session,
          const FlatpakPortalFailure(FlatpakPortalFailureCode.unavailable),
        ),
      );
      await _bounded(session.transport.subscribe());
      _requireCurrent(session);
      final subscriptionFailure = session.failureBeforeMonitor;
      if (subscriptionFailure != null) throw subscriptionFailure;
      final path =
          await _bounded(session.transport.createMonitor()).then((value) {
        if (value.length > _maxMonitorPathLength) {
          throw const FlatpakPortalFailure(
            FlatpakPortalFailureCode.invalidResponse,
          );
        }
        return value;
      });
      if (!_current(session)) {
        await _ignoreFailure(() => session.transport.closeMonitor(path));
        _requireCurrent(session);
      }
      if (!RegExp(
        r'^/org/freedesktop/portal/Flatpak/update_monitor/[A-Za-z0-9_]+/[A-Za-z0-9_]+$',
      ).hasMatch(path)) {
        throw const FlatpakPortalFailure(
          FlatpakPortalFailureCode.invalidResponse,
        );
      }
      session.path = path;
      final monitorFailure = session.failureBeforeMonitor;
      if (monitorFailure != null) throw monitorFailure;
      if (session.overflow) {
        throw const FlatpakPortalFailure(
          FlatpakPortalFailureCode.invalidResponse,
        );
      }
      final early = List<FlatpakPortalSignal>.of(session.earlySignals);
      session.earlySignals.clear();
      for (final signal in early) {
        _receive(session, signal);
      }
    } catch (error) {
      if (identical(_session, session)) _session = null;
      await _disposeSession(session);
      throw _canonical(error);
    }
  }

  @override
  Future<void> requestUpdate({String parentWindow = ''}) {
    if (_closed) {
      return Future.error(
        const FlatpakPortalFailure(FlatpakPortalFailureCode.unavailable),
      );
    }
    final updating = _updating;
    if (updating != null) return updating;
    _transactionActive = true;
    _updateAcknowledged = false;
    _updateDispatched = false;
    final operation = _requestUpdate(parentWindow);
    _updating = operation;
    operation.then<void>((_) {
      _updateAcknowledged = true;
      if (!_transactionActive && identical(_updating, operation)) {
        _updating = null;
      }
    }, onError: (Object error, StackTrace _) {
      final code = _canonical(error).code;
      final explicitlyRejected = code == FlatpakPortalFailureCode.denied ||
          code == FlatpakPortalFailureCode.permissionChange ||
          code == FlatpakPortalFailureCode.unsupported;
      if (_updateDispatched && _transactionActive && !explicitlyRejected) {
        // No method reply is not evidence that installation did not start.
        // Retain the monitor and latch until an actual terminal Progress.
        _updateAcknowledged = true;
        return;
      }
      _transactionActive = false;
      if (identical(_updating, operation)) _updating = null;
    });
    return operation;
  }

  Future<void> _requestUpdate(String parentWindow) async {
    _PortalSession? session;
    try {
      await open();
      session = _session;
      if (session == null) {
        throw const FlatpakPortalFailure(FlatpakPortalFailureCode.unavailable);
      }
      _requireCurrent(session);
      _updateDispatched = true;
      await _bounded(session.transport.update(
        session.path!,
        parentWindow: parentWindow,
      ));
      _requireCurrent(session);
    } catch (error) {
      throw _canonical(error);
    }
  }

  void _transportFailure(_PortalSession session, Object error) {
    if (!_current(session)) return;
    final failure = _canonical(error);
    if (session.path == null) session.failureBeforeMonitor = failure;
    if (_transactionActive && _updateDispatched) {
      _progress.addError(failure);
    } else {
      _updates.addError(failure);
    }
  }

  void _receive(_PortalSession session, FlatpakPortalSignal signal) {
    if (!_current(session)) return;
    if (session.path == null) {
      if (session.earlySignals.length < 64) {
        session.earlySignals.add(signal);
      } else {
        session.overflow = true;
      }
      return;
    }
    if (signal.path != session.path) return;
    if (signal.name == 'UpdateAvailable') {
      final running = signal.values['running-commit'];
      final local = signal.values['local-commit'];
      final remote = signal.values['remote-commit'];
      if (running is! String ||
          running.isEmpty ||
          local is! String ||
          local.isEmpty ||
          remote is! String ||
          remote.isEmpty) {
        _updates.addError(
          const FlatpakPortalFailure(FlatpakPortalFailureCode.invalidResponse),
        );
        return;
      }
      _updates.add(FlatpakPortalUpdate(
        runningCommit: running,
        localCommit: local,
        remoteCommit: remote,
      ));
    } else if (signal.name == 'Progress' && _transactionActive) {
      final status = signal.values['status'] ?? 0;
      final percent = signal.values['progress'];
      if (status is! int ||
          status < 0 ||
          status > 3 ||
          (percent != null &&
              (percent is! int || percent < 0 || percent > 100))) {
        // A malformed message is not a terminal result from the portal.
        // Keep the transaction latched instead of allowing another install.
        _progress.addError(
          const FlatpakPortalFailure(FlatpakPortalFailureCode.invalidResponse),
        );
        return;
      }
      final parsedStatus = FlatpakPortalProgressStatus.values[status];
      if (parsedStatus != FlatpakPortalProgressStatus.running) {
        _endTransaction();
      }
      _progress.add(FlatpakPortalProgress(
        status: parsedStatus,
        percent: percent as int?,
        failure: parsedStatus == FlatpakPortalProgressStatus.failed
            ? signal.failure ?? FlatpakPortalFailureCode.failed
            : null,
      ));
    }
  }

  void _endTransaction() {
    _transactionActive = false;
    if (_updateAcknowledged) _updating = null;
  }

  FlatpakPortalFailure _canonical(Object error) => error is FlatpakPortalFailure
      ? error
      : const FlatpakPortalFailure(FlatpakPortalFailureCode.failed);

  Future<void> _ignoreFailure(Future<void> Function() operation) async {
    try {
      await _bounded(operation());
    } catch (_) {
      // Cleanup is bounded and best effort; private bus closure also disposes
      // the caller's monitor. Never expose an exception's raw text.
    }
  }

  Future<void> _disposeSession(_PortalSession session) =>
      session.disposing ??= _disposeSessionOnce(session);

  Future<void> _disposeSessionOnce(_PortalSession session) async {
    session.earlySignals.clear();
    final subscription = session.subscription;
    session.subscription = null;
    if (subscription != null) await _ignoreFailure(subscription.cancel);
    final path = session.path;
    session.path = null;
    if (path != null) {
      await _ignoreFailure(() => session.transport.closeMonitor(path));
    }
    await _ignoreFailure(session.transport.close);
  }

  @override
  Future<void> close() {
    final closing = _closing;
    if (closing != null) return closing;
    _closed = true;
    ++_generation;
    _transactionActive = false;
    final session = _session;
    _session = null;
    final operation = () async {
      if (session != null) await _disposeSession(session);
      // A paused observer must not keep the bus or cancellation alive.
      unawaited(_updates.close());
      unawaited(_progress.close());
    }();
    _closing = operation;
    return operation;
  }
}

class _PortalSession {
  _PortalSession(this.transport, this.generation);

  final FlatpakPortalTransport transport;
  final int generation;
  StreamSubscription<FlatpakPortalSignal>? subscription;
  final earlySignals = <FlatpakPortalSignal>[];
  String? path;
  bool overflow = false;
  FlatpakPortalFailure? failureBeforeMonitor;
  Future<void>? disposing;
}
