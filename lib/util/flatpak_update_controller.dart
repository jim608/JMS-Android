import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:fladder/services/flatpak_update_portal.dart';
import 'package:fladder/util/flatpak_update_capability.dart';

enum FlatpakUpdatePhase {
  idle,
  checking,
  monitoring,
  manual,
  available,
  current,
  updating,
  noUpdate,
  restartRequired,
  outcomeUnknown,
  failed,
  unsupported,
}

/// Self-update never falls through to the native installer and never restarts a
/// process. A portal snapshot is required before requesting an update.
class FlatpakUpdateController extends ChangeNotifier {
  FlatpakUpdateController({
    required this.portalFactory,
    this.checkTimeout = const Duration(seconds: 15),
    this.updateTimeout = const Duration(minutes: 10),
  });

  final FlatpakUpdatePortal Function() portalFactory;
  final Duration checkTimeout;
  final Duration updateTimeout;
  FlatpakUpdatePhase phase = FlatpakUpdatePhase.idle;
  FlatpakPortalFailureCode? failure;
  FlatpakPortalUpdate? candidate;
  FlatpakUpdateCapability capability = const FlatpakUpdateCapability();
  int? progress;
  bool _disposed = false;
  bool _portalOpened = false;
  bool _installed = false;
  bool _automatic = false;
  bool _automaticMonitor = false;
  bool _hostUpdatePending = false;
  final Set<String> _completedTargets = {};
  String? _requestedTarget;
  bool _playbackActive = false;
  bool _syncPlayActive = false;
  int _generation = 0;
  FlatpakUpdatePortal? _portal;
  StreamSubscription<FlatpakPortalUpdate>? _updates;
  StreamSubscription<FlatpakPortalProgress>? _progress;
  Future<void>? _check;
  Future<void>? _install;
  Completer<void>? _firstSnapshot;
  Completer<void>? _terminalProgress;
  Completer<void>? _checkCancelled;

  bool get automatic => _automatic;
  bool get restartRequired => _installed || candidate?.restartRequired == true;
  bool get restartDeferred =>
      restartRequired && (_playbackActive || _syncPlayActive);
  bool get waitingForSnapshot =>
      _portalOpened && candidate == null && failure == null;
  bool get busy =>
      phase == FlatpakUpdatePhase.checking ||
      phase == FlatpakUpdatePhase.updating;
  bool get canCheck =>
      !_disposed &&
      !_hostUpdatePending &&
      !busy &&
      phase != FlatpakUpdatePhase.outcomeUnknown;
  bool get canRequestUpdate =>
      !_disposed &&
      _portalOpened &&
      capability.canRequestPortalCheck &&
      !_hostUpdatePending &&
      phase == FlatpakUpdatePhase.available &&
      candidate?.hasRemoteUpdate == true &&
      !_completedTargets.contains(candidate!.remoteCommit.toLowerCase());

  bool _current(int generation) => !_disposed && generation == _generation;

  // Disposing UI must not close a monitor whose host transaction is uncertain.
  // Its first explicit terminal result can still release the owned resources.
  bool _monitorCurrent(int generation) =>
      generation == _generation && (!_disposed || _hostUpdatePending);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void setActivity({required bool playback, required bool syncPlay}) {
    if (_disposed) return;
    if (_playbackActive == playback && _syncPlayActive == syncPlay) return;
    _playbackActive = playback;
    _syncPlayActive = syncPlay;
    _notify();
  }

  FlatpakPortalFailureCode _safeFailure(Object error) =>
      error is FlatpakPortalFailure
          ? error.code
          : error is TimeoutException
              ? FlatpakPortalFailureCode.timeout
              : FlatpakPortalFailureCode.failed;

  void _complete(Completer<void>? completer) {
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  Future<void> setAutomatic(bool value) {
    if (_disposed || value == _automatic) return Future<void>.value();
    _automatic = value;
    _notify();
    return value ? check(automatic: true) : _stopAutomaticMonitor();
  }

  Future<void> check({bool automatic = false}) {
    if (_disposed || (automatic && !_automatic)) return Future<void>.value();
    // Enabling automatic checks can adopt an already pending manual check.
    if (_automatic) _automaticMonitor = true;
    final pending = _check;
    if (pending != null) return pending;
    if (!canCheck) return Future<void>.value();
    final task = _checkPortal();
    _check = task;
    unawaited(task.whenComplete(() {
      if (identical(_check, task)) _check = null;
    }));
    return task;
  }

  Future<void> _checkPortal() async {
    final generation = ++_generation;
    _automaticMonitor = _automatic;
    final cancelled = Completer<void>();
    _checkCancelled = cancelled;
    phase = FlatpakUpdatePhase.checking;
    failure = null;
    progress = null;
    candidate = null;
    _terminalProgress = null;
    capability = const FlatpakUpdateCapability();
    _portalOpened = false;
    _notify();
    final first = Completer<void>();
    _firstSnapshot = first;
    try {
      await _releasePortal();
      if (!_current(generation)) return;
      final portal = portalFactory();
      _portal = portal;
      void streamFailure(Object error, StackTrace stack) {
        if (!_monitorCurrent(generation)) return;
        failure = _safeFailure(error);
        if (_hostUpdatePending) {
          // A broken signal stream cannot prove that the host stopped updating.
          phase = FlatpakUpdatePhase.outcomeUnknown;
          _complete(_terminalProgress);
        } else {
          phase = failure == FlatpakPortalFailureCode.unsupported
              ? FlatpakUpdatePhase.unsupported
              : FlatpakUpdatePhase.manual;
        }
        _complete(first);
        _notify();
      }

      _updates = portal.updates.listen((update) {
        if (!_current(generation)) return;
        final commit = RegExp(r'^[a-fA-F0-9]{64}$');
        if (![update.runningCommit, update.localCommit, update.remoteCommit]
            .every(commit.hasMatch)) {
          streamFailure(
              const FlatpakPortalFailure(
                  FlatpakPortalFailureCode.invalidResponse),
              StackTrace.empty);
          return;
        }
        candidate = update;
        capability = const FlatpakUpdateCapability(
          appRemote: FlatpakAppRemoteState.configured,
          portal: FlatpakUpdatePortalState.available,
        );
        _installed = _installed || update.restartRequired;
        if (phase != FlatpakUpdatePhase.updating &&
            phase != FlatpakUpdatePhase.outcomeUnknown) {
          phase = update.hasRemoteUpdate &&
                  !_completedTargets.contains(update.remoteCommit.toLowerCase())
              ? FlatpakUpdatePhase.available
              : restartRequired
                  ? FlatpakUpdatePhase.restartRequired
                  : FlatpakUpdatePhase.current;
          failure = null;
        }
        _complete(first);
        _notify();
      }, onError: streamFailure);
      _progress = portal.progress.listen((event) {
        if (!_monitorCurrent(generation) || !_hostUpdatePending) return;
        progress = event.percent?.clamp(0, 100).toInt();
        switch (event.status) {
          case FlatpakPortalProgressStatus.running:
            // A single operation can report 100 before the transaction ends.
            break;
          case FlatpakPortalProgressStatus.empty:
            failure = null;
            phase = restartRequired
                ? FlatpakUpdatePhase.restartRequired
                : FlatpakUpdatePhase.noUpdate;
            _complete(_terminalProgress);
          case FlatpakPortalProgressStatus.done:
            final target = _requestedTarget;
            if (target != null) _completedTargets.add(target);
            _installed = true;
            failure = null;
            phase = candidate?.hasRemoteUpdate == true &&
                    !_completedTargets
                        .contains(candidate!.remoteCommit.toLowerCase())
                ? FlatpakUpdatePhase.available
                : FlatpakUpdatePhase.restartRequired;
            _complete(_terminalProgress);
          case FlatpakPortalProgressStatus.failed:
            failure = event.failure ?? FlatpakPortalFailureCode.failed;
            phase = FlatpakUpdatePhase.failed;
            _complete(_terminalProgress);
        }
        if (event.status != FlatpakPortalProgressStatus.running) {
          _hostUpdatePending = false;
          _requestedTarget = null;
        }
        _notify();
        if (event.status != FlatpakPortalProgressStatus.running) {
          _settledMonitor();
        }
      }, onError: streamFailure);
      // A missing signal is not proof of a missing remote or current version.
      await Future.any([portal.open(), cancelled.future]).timeout(checkTimeout);
      if (!_current(generation)) return;
      _portalOpened = true;
      capability = FlatpakUpdateCapability(
        appRemote: capability.appRemote,
        portal: FlatpakUpdatePortalState.available,
      );
      _notify();
      await Future.any([first.future, cancelled.future]).timeout(checkTimeout);
    } catch (error) {
      if (!_current(generation)) return;
      if (_portalOpened &&
          error is TimeoutException &&
          phase == FlatpakUpdatePhase.checking &&
          failure == null) {
        // Opening succeeded. The host may poll later and emits no snapshot
        // when nothing changes; silence is neither a failure nor "up to date".
        phase = restartRequired
            ? FlatpakUpdatePhase.restartRequired
            : FlatpakUpdatePhase.monitoring;
      } else {
        failure = _safeFailure(error);
        phase = failure == FlatpakPortalFailureCode.unsupported
            ? FlatpakUpdatePhase.unsupported
            : FlatpakUpdatePhase.manual;
        if (!_portalOpened) await _releasePortal();
      }
      _notify();
    } finally {
      if (identical(_firstSnapshot, first)) _firstSnapshot = null;
      if (identical(_checkCancelled, cancelled)) _checkCancelled = null;
    }
  }

  Future<void> requestUpdate({
    required bool userConfirmed,
    required String expectedRemoteCommit,
    String parentWindow = '',
  }) {
    final pending = _install;
    if (pending != null) return pending;
    if (!userConfirmed ||
        !canRequestUpdate ||
        candidate?.remoteCommit != expectedRemoteCommit) {
      return Future<void>.value();
    }
    final task = _requestUpdate(parentWindow, expectedRemoteCommit);
    _install = task;
    unawaited(task.whenComplete(() {
      if (identical(_install, task)) _install = null;
    }));
    return task;
  }

  Future<void> _requestUpdate(String parentWindow, String target) async {
    final generation = _generation;
    final terminal = Completer<void>();
    _terminalProgress = terminal;
    _hostUpdatePending = true;
    _requestedTarget = target.toLowerCase();
    phase = FlatpakUpdatePhase.updating;
    failure = null;
    progress = null;
    _notify();
    try {
      final acknowledgement = _portal!
          .requestUpdate(parentWindow: parentWindow)
          .timeout(checkTimeout);
      await Future.any([acknowledgement, terminal.future]);
      if (!_current(generation) || terminal.isCompleted) return;
      await terminal.future.timeout(updateTimeout);
    } catch (error) {
      if (!_monitorCurrent(generation)) return;
      if (terminal.isCompleted) return;
      failure = _safeFailure(error);
      final refused = const {
        FlatpakPortalFailureCode.denied,
        FlatpakPortalFailureCode.permissionChange,
        FlatpakPortalFailureCode.unsupported,
      }.contains(failure);
      phase = refused
          ? FlatpakUpdatePhase.failed
          : FlatpakUpdatePhase.outcomeUnknown;
      if (refused) {
        _hostUpdatePending = false;
        _requestedTarget = null;
        _complete(terminal);
      }
      _notify();
      if (refused) _settledMonitor();
    }
    // On timeout the monitor remains attached to accept a late terminal result.
  }

  void _settledMonitor() {
    if (_disposed) {
      _generation++;
      unawaited(_releasePortal());
    } else {
      unawaited(_stopAutomaticMonitor());
    }
  }

  Future<void> _stopAutomaticMonitor() async {
    if (_automatic || !_automaticMonitor || _hostUpdatePending) return;
    _automaticMonitor = false;
    _generation++;
    _portalOpened = false;
    _complete(_checkCancelled);
    _complete(_firstSnapshot);
    // A manual check can start immediately, without awaiting a retired open.
    _check = null;
    if (phase == FlatpakUpdatePhase.checking ||
        phase == FlatpakUpdatePhase.monitoring) {
      phase = restartRequired
          ? FlatpakUpdatePhase.restartRequired
          : FlatpakUpdatePhase.idle;
    }
    _notify();
    await _releasePortal();
  }

  Future<void> _releasePortal() async {
    final updates = _updates;
    final progress = _progress;
    final portal = _portal;
    _updates = null;
    _progress = null;
    _portal = null;
    try {
      await Future.wait([
        if (updates != null) updates.cancel(),
        if (progress != null) progress.cancel(),
      ]).timeout(const Duration(seconds: 2));
    } catch (_) {
      // Still close the owned portal if a subscription cannot finish cleanup.
    }
    try {
      await portal?.close().timeout(const Duration(seconds: 2));
    } catch (_) {
      // No host fallback or repeated update after uncertain cleanup.
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _automatic = false;
    _complete(_checkCancelled);
    _complete(_firstSnapshot);
    if (!_hostUpdatePending) {
      _generation++;
      _complete(_terminalProgress);
      unawaited(_releasePortal());
    }
    super.dispose();
  }
}
