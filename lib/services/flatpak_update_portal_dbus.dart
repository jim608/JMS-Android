import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';

import 'flatpak_update_portal.dart';

const _portalName = 'org.freedesktop.portal.Flatpak';
const _portalPath = '/org/freedesktop/portal/Flatpak';
const _monitorInterface = 'org.freedesktop.portal.Flatpak.UpdateMonitor';

FlatpakUpdatePortal createFlatpakUpdatePortal() {
  if (!Platform.isLinux ||
      (!(Platform.environment['FLATPAK_ID']?.trim().isNotEmpty ?? false) &&
          !File('/.flatpak-info').existsSync())) {
    return const UnsupportedFlatpakUpdatePortal();
  }
  // No DBusClient, connection, or method call exists until explicit open().
  return TransportFlatpakUpdatePortal(
    transportFactory: _DbusFlatpakPortalTransport.new,
  );
}

class _DbusFlatpakPortalTransport implements FlatpakPortalTransport {
  final _signals = StreamController<FlatpakPortalSignal>.broadcast();
  DBusClient? _client;
  StreamSubscription<DBusSignal>? _subscription;
  String? _owner;
  bool _closed = false;
  Future<void>? _closing;

  @override
  Stream<FlatpakPortalSignal> get signals => _signals.stream;

  DBusClient get _bus {
    if (_closed) {
      throw const FlatpakPortalFailure(FlatpakPortalFailureCode.unavailable);
    }
    return _client ??= DBusClient.session(introspectable: false);
  }

  FlatpakPortalFailure _failure(Object error, {bool updating = false}) {
    if (error is FlatpakPortalFailure) return error;
    if (error is DBusMethodResponseException) {
      return FlatpakPortalFailure(flatpakPortalFailureCodeForErrorName(
        error.errorName,
        updating: updating,
      ));
    }
    if (error is DBusReplySignatureException ||
        error is DBusSignalSignatureException ||
        error is FormatException ||
        error is TypeError) {
      return const FlatpakPortalFailure(
          FlatpakPortalFailureCode.invalidResponse);
    }
    if (error is SocketException ||
        error is FileSystemException ||
        error is DBusClosedException) {
      return const FlatpakPortalFailure(FlatpakPortalFailureCode.unavailable);
    }
    if (error is TimeoutException) {
      return const FlatpakPortalFailure(FlatpakPortalFailureCode.timeout);
    }
    return const FlatpakPortalFailure(FlatpakPortalFailureCode.failed);
  }

  /// dbus 0.7.11 starts AddMatch from a stream's onListen without awaiting it.
  /// Keep that asynchronous error path inside the same sanitized boundary.
  Future<T> _guarded<T>(
    Future<T> Function() operation, {
    bool updating = false,
  }) {
    final result = Completer<T>();
    runZonedGuarded(() async {
      try {
        final value = await operation();
        if (_closed) {
          await _client?.close();
          throw const FlatpakPortalFailure(
              FlatpakPortalFailureCode.unavailable);
        }
        if (!result.isCompleted) result.complete(value);
      } catch (error) {
        if (!result.isCompleted) {
          result.completeError(
            _failure(error, updating: updating),
            StackTrace.empty,
          );
        }
      }
    }, (Object error, StackTrace _) {
      final failure = _failure(error, updating: updating);
      if (!result.isCompleted) result.completeError(failure, StackTrace.empty);
      if (!_closed) _signals.addError(failure, StackTrace.empty);
    });
    return result.future;
  }

  Future<DBusMethodSuccessResponse> _call(
    String path,
    String interface,
    String name,
    List<DBusValue> values,
    String replySignature,
  ) =>
      _bus.callMethod(
        destination: _owner ?? _portalName,
        path: DBusObjectPath(path),
        interface: interface,
        name: name,
        values: values,
        replySignature: DBusSignature(replySignature),
      );

  @override
  Future<int> getVersion() => _guarded(() async {
        final reply = await _call(
          _portalPath,
          'org.freedesktop.DBus.Properties',
          'Get',
          [const DBusString(_portalName), const DBusString('version')],
          'v',
        );
        final version = reply.returnValues.single.asVariant();
        if (version is! DBusUint32) {
          throw const FlatpakPortalFailure(
            FlatpakPortalFailureCode.invalidResponse,
          );
        }
        return version.value;
      });

  @override
  Future<void> subscribe() => _guarded(() async {
        final bus = _bus;
        final owner = await bus.getNameOwner(_portalName);
        if (owner == null) {
          throw const FlatpakPortalFailure(
              FlatpakPortalFailureCode.unavailable);
        }
        _owner = owner;
        _subscription = DBusSignalStream(
          bus,
          interface: _monitorInterface,
        ).listen((signal) {
          if (_closed || signal.sender != owner) return;
          try {
            final parsed = decodeFlatpakPortalDbusSignal(signal);
            if (parsed != null) _signals.add(parsed);
          } catch (error) {
            _signals.addError(_failure(error), StackTrace.empty);
          }
        }, onError: (Object error) {
          if (!_closed) _signals.addError(_failure(error), StackTrace.empty);
        });
        // A successful, awaited AddMatch is the subscription barrier. The
        // stream's local listener above is already in place before Create.
        await bus.callMethod(
          destination: 'org.freedesktop.DBus',
          path: DBusObjectPath('/org/freedesktop/DBus'),
          interface: 'org.freedesktop.DBus',
          name: 'AddMatch',
          values: [
            DBusString(
              "type='signal',sender='$owner',interface='$_monitorInterface'",
            ),
          ],
          replySignature: DBusSignature(''),
        );
      });

  @override
  Future<String> createMonitor() => _guarded(() async {
        final reply = await _call(
          _portalPath,
          _portalName,
          'CreateUpdateMonitor',
          [DBusDict.stringVariant(const {})],
          'o',
        );
        final path = reply.returnValues.single.asObjectPath().value;
        final sender = _bus.uniqueName.substring(1).replaceAll('.', '_');
        if (!path.startsWith('$_portalPath/update_monitor/$sender/')) {
          throw const FlatpakPortalFailure(
            FlatpakPortalFailureCode.invalidResponse,
          );
        }
        return path;
      });

  @override
  Future<void> update(String monitorPath, {String parentWindow = ''}) =>
      _guarded(() async {
        await _call(
          monitorPath,
          _monitorInterface,
          'Update',
          [DBusString(parentWindow), DBusDict.stringVariant(const {})],
          '',
        );
      }, updating: true);

  @override
  Future<void> closeMonitor(String monitorPath) async {
    if (_closed) return;
    await _guarded(() async {
      await _call(monitorPath, _monitorInterface, 'Close', const [], '');
    });
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    try {
      await _subscription?.cancel().timeout(const Duration(seconds: 2));
    } catch (_) {
      // A stalled RemoveMatch must not prevent private-client shutdown.
    } finally {
      try {
        await _client?.close().timeout(const Duration(seconds: 2));
      } catch (_) {
        // Cleanup must also return if the dependency's shutdown stalls.
      } finally {
        unawaited(_signals.close());
      }
    }
  }
}

/// Decodes only documented fields; raw diagnostic messages are never copied.
/// Kept separate so tests can supply real D-Bus values without opening a bus.
FlatpakPortalSignal? decodeFlatpakPortalDbusSignal(DBusSignal signal) {
  if (signal.interface != _monitorInterface ||
      !const ['UpdateAvailable', 'Progress'].contains(signal.name)) {
    return null;
  }
  if (signal.signature != DBusSignature('a{sv}')) {
    throw const FlatpakPortalFailure(FlatpakPortalFailureCode.invalidResponse);
  }
  final fields = signal.values.single.asStringVariantDict();
  final values = <String, Object?>{};
  FlatpakPortalFailureCode? failure;
  if (signal.name == 'UpdateAvailable') {
    for (final key in const [
      'running-commit',
      'local-commit',
      'remote-commit',
    ]) {
      final value = fields[key];
      if (value is DBusString && value.signature == DBusSignature('s')) {
        values[key] = value.value;
      }
    }
  } else {
    for (final key in const ['status', 'progress']) {
      final value = fields[key];
      if (value != null) {
        if (value is! DBusUint32) {
          throw const FlatpakPortalFailure(
            FlatpakPortalFailureCode.invalidResponse,
          );
        }
        values[key] = value.value;
      }
    }
    final error = fields['error'];
    if (error is DBusString && error.signature == DBusSignature('s')) {
      failure =
          flatpakPortalFailureCodeForErrorName(error.value, updating: true);
    }
  }
  return FlatpakPortalSignal(
    path: signal.path.value,
    name: signal.name,
    values: values,
    failure: failure,
  );
}
