import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/user_provider.dart';

part 'connectivity_provider.g.dart';

enum ConnectionState {
  offline,
  mobile,
  wifi,
  ethernet,
  vpn;

  bool get homeInternet => switch (this) {
        ConnectionState.offline => false,
        ConnectionState.mobile => false,
        ConnectionState.wifi => true,
        ConnectionState.ethernet => true,
        ConnectionState.vpn => true,
      };
}

final offlineStateProvider = Provider<bool>((ref) {
  final isLoggedIn = ref.watch(userProvider.select((value) => value != null));
  return ref.watch(
        connectivityStatusProvider.select(
          (value) => value == ConnectionState.offline,
        ),
      ) &&
      isLoggedIn;
});

@Riverpod(keepAlive: true)
class ConnectivityStatus extends _$ConnectivityStatus {
  Timer? _debounceTimer;
  int _probeId = 0;
  Completer<void>? _probeCompleter;
  bool _active = true;
  final _pendingConnectivityChecks = <void Function()>{};

  @override
  ConnectionState build() {
    ref.listen(userProvider.select((value) => value?.credentials.url), (
      previous,
      next,
    ) {
      if (previous != next) {
        checkConnectivity(immediate: true);
      }
    });

    _active = true;
    StreamSubscription<List<ConnectivityResult>>? subscription;
    void unavailable(Object error, StackTrace stack) {
      // Linux connectivity backends can fail in their asynchronous onListen
      // callback before forwarding an error through the stream itself.
      scheduleMicrotask(() {
        if (_active) {
          _handleHardwareChange(const [
            ConnectivityResult.none,
          ], immediate: true);
        }
      });
    }

    runZonedGuarded(() {
      subscription = Connectivity().onConnectivityChanged.listen((results) {
        if (_active) _handleHardwareChange(results);
      }, onError: unavailable);
    }, unavailable);

    ref.onDispose(() {
      _active = false;
      for (final finish in _pendingConnectivityChecks.toList()) {
        finish();
      }
      _debounceTimer?.cancel();
      subscription?.cancel();
      _probeId++;
      _resolveProbe();
    });

    checkConnectivity(immediate: true);

    return ConnectionState.mobile;
  }

  Future<void> checkConnectivity({bool immediate = false}) {
    if (!_active) return Future<void>.value();
    // Some Linux plugin initialization errors are detached from its returned
    // Future. Keep that work in a guarded zone and complete in the caller's zone.
    final done = Completer<void>();
    var finished = false;
    Timer? watchdog;
    void finish() {
      if (finished) return;
      finished = true;
      watchdog?.cancel();
      watchdog = null;
      _pendingConnectivityChecks.remove(finish);
      if (!done.isCompleted) done.complete();
    }

    void unavailable(Object error, StackTrace stack) {
      if (finished) return;
      finish();
      scheduleMicrotask(() {
        if (_active) {
          _handleHardwareChange(const [
            ConnectivityResult.none,
          ], immediate: true);
        }
      });
    }

    _pendingConnectivityChecks.add(finish);
    watchdog = Timer(const Duration(seconds: 3), () {
      unavailable(
        TimeoutException('Connectivity backend unavailable'),
        StackTrace.empty,
      );
    });
    runZonedGuarded(() async {
      try {
        final results = await Connectivity().checkConnectivity();
        if (!finished && _active) {
          _handleHardwareChange(results, immediate: immediate);
        }
      } catch (error, stack) {
        unavailable(error, stack);
      } finally {
        finish();
      }
    }, unavailable);
    return done.future;
  }

  Future<void> waitForProbe() async => _probeCompleter?.future;

  void _handleHardwareChange(
    List<ConnectivityResult> results, {
    bool immediate = false,
  }) {
    final hardwareState = _parseHardwareState(results);

    if (hardwareState == ConnectionState.offline) {
      _debounceTimer?.cancel();
      _probeId++;
      _resolveProbe();
      _updateState(ConnectionState.offline);
      return;
    }

    _queueProbe(hardwareState, immediate: immediate);
  }

  void _queueProbe(ConnectionState candidateState, {bool immediate = false}) {
    _debounceTimer?.cancel();
    final id = ++_probeId;
    _probeCompleter ??= Completer<void>();

    if (immediate) {
      unawaited(_probeReachability(id, candidateState));
    } else {
      _debounceTimer = Timer(
        const Duration(milliseconds: 500),
        () => unawaited(_probeReachability(id, candidateState)),
      );
    }
  }

  Future<void> _probeReachability(
    int id,
    ConnectionState candidateState,
  ) async {
    try {
      final user = ref.read(userProvider);
      if (user == null) return;

      if (_probeId != id) return;

      final remoteUrl = user.credentials.url;
      if (remoteUrl.isNotEmpty) {
        final checkServer = await fetchSystemInfoDynamic(
          normalizeUrl(remoteUrl),
        );

        if (_probeId != id) return;

        if (checkServer != null) {
          _updateState(candidateState);
          return;
        }
      }

      if (_probeId == id) {
        _updateState(ConnectionState.offline);
      }
    } finally {
      if (_probeId == id) {
        _resolveProbe();
      }
    }
  }

  void _updateState(ConnectionState newState) {
    state = newState;
  }

  void _resolveProbe() {
    if (!(_probeCompleter?.isCompleted ?? true)) {
      _probeCompleter?.complete();
    }
    _probeCompleter = null;
  }

  ConnectionState _parseHardwareState(List<ConnectivityResult> results) {
    if (results.contains(ConnectivityResult.vpn)) return ConnectionState.vpn;
    if (results.contains(ConnectivityResult.ethernet)) {
      return ConnectionState.ethernet;
    }
    if (results.contains(ConnectivityResult.wifi)) return ConnectionState.wifi;
    if (results.contains(ConnectivityResult.mobile)) {
      return ConnectionState.mobile;
    }
    return ConnectionState.offline;
  }
}

Future<PublicSystemInfo?> fetchSystemInfoDynamic(String baseUrl) async {
  if (baseUrl.isEmpty) return null;
  try {
    final uri = buildServerUriFromBase(
      baseUrl,
      pathSegments: const ['System', 'Info', 'Public'],
    );
    if (uri == null) return null;

    final response = await http.get(uri).timeout(const Duration(seconds: 2));

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return PublicSystemInfo.fromJson(jsonDecode(response.body));
    }
    return null;
  } catch (e) {
    log(e.toString());
    return null;
  }
}
