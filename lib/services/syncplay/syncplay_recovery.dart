import 'dart:async';
import 'dart:math';

import 'syncplay_clock.dart';
import 'syncplay_models.dart';

/// Bounded recovery of one retained, previously confirmed membership.
/// Socket failures may retry; an attempted Join is never automatically repeated.
class SyncPlayRecovery {
  SyncPlayRecovery({
    required this.readState,
    required this.isCurrent,
    required this.reconnectTransport,
    required this.rejoinKnownGroup,
    required this.revalidate,
    required this.onChanged,
    SyncPlayScheduler scheduler = const SyncPlayTimerScheduler(),
    double Function()? jitter,
    this.maximumAttempts = 3,
    this.maximumDuration = const Duration(seconds: 45),
    this.validationCooldown = const Duration(seconds: 15),
  })  : _scheduler = scheduler,
        _jitter = jitter ?? Random().nextDouble;

  final SyncPlayControllerState Function() readState;
  final bool Function() isCurrent;
  final Future<void> Function() reconnectTransport;
  final Future<void> Function(bool Function() isCurrent) rejoinKnownGroup;
  final Future<void> Function() revalidate;
  final void Function() onChanged;
  final SyncPlayScheduler _scheduler;
  final double Function() _jitter;
  final int maximumAttempts;
  final Duration maximumDuration;
  final Duration validationCooldown;
  SyncPlayCancellation? _timer;
  SyncPlayCancellation? _deadline;
  SyncPlayCancellation? _validationCooldown;
  Future<void>? _flight;
  Future<void>? _validation;
  String? _knownGroup;
  int _generation = 0;
  int _attempts = 0;
  bool _joinAttempted = false;
  bool _disposed = false;
  bool _manual = false;
  bool active = false;
  bool exhausted = false;

  bool get _current => !_disposed && isCurrent();
  bool _eligible(SyncPlayControllerState state) =>
      _current &&
      !_manual &&
      _knownGroup != null &&
      state.group?.groupId == _knownGroup &&
      const {SyncPlayStatus.disconnected, SyncPlayStatus.unknown}
          .contains(state.status) &&
      !const {
        SyncPlayFailureCode.denied,
        SyncPlayFailureCode.noGroup,
        SyncPlayFailureCode.protocol,
        SyncPlayFailureCode.unsupported
      }.contains(state.failure?.code);

  void observe(SyncPlayControllerState state) {
    if (!_current) return;
    if (state.isJoined && state.connected) {
      _knownGroup = state.group!.groupId;
      _manual = false;
      _attempts = 0;
      _joinAttempted = false;
      _timer?.cancel();
      _timer = null;
      _deadline?.cancel();
      _deadline = null;
      final changed = active || exhausted;
      active = exhausted = false;
      if (changed) onChanged();
      return;
    }
    if (const {
      SyncPlayStatus.idle,
      SyncPlayStatus.leaving,
      SyncPlayStatus.disposed
    }.contains(state.status)) {
      cancel();
      return;
    }
    if (state.status == SyncPlayStatus.joining && _joinAttempted) return;
    if (!_eligible(state)) {
      if (active) _finish(exhausted: true);
      return;
    }
    if (!active && !exhausted && _flight == null) _schedule();
  }

  /// Resume/network events do not reset a failed episode or its attempt budget.
  void wake() {
    if (!_current) return;
    final state = readState();
    if (state.isJoined && state.connected) {
      if (_validation != null || _validationCooldown != null) return;
      _validationCooldown = _scheduler.schedule(validationCooldown, () {
        _validationCooldown = null;
      });
      _validation = Future<void>.sync(revalidate)
          .then<void>((_) {}, onError: (Object _, StackTrace __) {})
          .whenComplete(() => _validation = null);
    } else {
      observe(state);
    }
  }

  void _schedule() {
    if (!_eligible(readState()) ||
        exhausted ||
        _timer != null ||
        _flight != null) {
      return;
    }
    if (_attempts >= maximumAttempts || _joinAttempted) {
      _finish(exhausted: true);
      return;
    }
    active = true;
    _deadline ??= _scheduler.schedule(maximumDuration, () {
      _finish(exhausted: true);
    });
    onChanged();
    final generation = _generation;
    final seconds = 1 << _attempts.clamp(0, 2);
    final delay = Duration(
        milliseconds: seconds * 1000 + (_jitter().clamp(0, 1) * 250).round());
    _timer = _scheduler.schedule(delay, () {
      _timer = null;
      if (_current && generation == _generation) _drive(generation);
    });
  }

  void _drive(int generation) {
    if (_flight != null || !_eligible(readState())) return;
    _attempts++;
    var retryTransport = false;
    final task = Future<void>.sync(() async {
      try {
        if (!readState().connected) await reconnectTransport();
        if (!_current || generation != _generation || !_eligible(readState())) {
          return;
        }
        _joinAttempted = true;
        await rejoinKnownGroup(() => _current && generation == _generation);
        if (!_current || generation != _generation) return;
        if (!readState().isJoined) _finish(exhausted: true);
      } catch (_) {
        if (!_current || generation != _generation) return;
        if (_joinAttempted) {
          _finish(exhausted: true);
        } else {
          retryTransport = true;
        }
      }
    });
    _flight = task;
    unawaited(task.whenComplete(() {
      if (identical(_flight, task)) _flight = null;
      if (_current && generation == _generation) {
        if (retryTransport) {
          _schedule();
        } else {
          observe(readState());
        }
      }
    }));
  }

  void _finish({required bool exhausted}) {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _deadline?.cancel();
    _deadline = null;
    active = false;
    this.exhausted = exhausted;
    onChanged();
  }

  /// Explicit Leave/Cancel revokes delayed work before its first await.
  void cancel() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _deadline?.cancel();
    _deadline = null;
    _knownGroup = null;
    _manual = true;
    final changed = active || exhausted;
    active = exhausted = false;
    if (changed && !_disposed) onChanged();
  }

  void manualRetry() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _deadline?.cancel();
    _deadline = null;
    _manual = true;
    active = exhausted = false;
    onChanged();
  }

  void dispose() {
    _disposed = true;
    _validationCooldown?.cancel();
    _validationCooldown = null;
    cancel();
  }
}
