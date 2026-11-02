import 'dart:async';

import 'remote_control_models.dart';

class _Intent {
  _Intent(this.target, this.action, this.generation);
  final RemoteTarget target;
  final RemoteAction action;
  final int generation;
  final done = Completer<void>();
  void complete() {
    if (!done.isCompleted) done.complete();
  }
}

class _AwaitingReport {
  _AwaitingReport(this.intent, this.baseline, this.acceptedAt, this.readSerial);
  final _Intent intent;
  final RemoteTarget baseline;
  final DateTime acceptedAt;
  final int readSerial;
}

/// A sender with one mutation in flight and at most three latest intents.
/// Its owner closes the shared API separately after receiver disposal.
class RemoteControlController {
  RemoteControlController({
    required RemoteControlApi api,
    bool Function()? isCurrent,
    DateTime Function()? now,
    this.pollInterval = const Duration(seconds: 2),
    this.confirmationTimeout = const Duration(seconds: 6),
  })  : _api = api,
        _isCurrent = isCurrent ?? _alwaysCurrent,
        _now = now ?? DateTime.now;

  final RemoteControlApi _api;
  final bool Function() _isCurrent;
  final DateTime Function() _now;
  final Duration pollInterval;
  final Duration confirmationTimeout;
  final _states = StreamController<RemoteControlState>.broadcast(sync: true);
  final _pending = <RemoteActionType, _Intent>{};
  RemoteControlState _state = const RemoteControlState();
  Timer? _poll;
  Timer? _confirmation;
  Future<void>? _refreshing;
  Future<void>? _draining;
  _AwaitingReport? _awaiting;
  int _generation = 0;
  int _readSerial = 0;
  bool _closed = false;
  static const _unchanged = Object();

  RemoteControlState get state => _state;
  Stream<RemoteControlState> get states => _states.stream;
  static bool _alwaysCurrent() => true;
  bool get _current {
    if (_closed) return false;
    try {
      return _isCurrent();
    } catch (_) {
      return false;
    }
  }

  void _emit({
    List<RemoteTarget>? targets,
    Object? target = _unchanged,
    List<RemoteSubtitle>? subtitles,
    RemoteCommandStatus? status,
    Object? failure = _unchanged,
    bool? refreshing,
  }) {
    if (!_current) return;
    _state = RemoteControlState(
      targets: targets == null ? _state.targets : List.unmodifiable(targets),
      target: identical(target, _unchanged)
          ? _state.target
          : target as RemoteTarget?,
      subtitles:
          subtitles == null ? _state.subtitles : List.unmodifiable(subtitles),
      status: status ?? _state.status,
      failure: identical(failure, _unchanged)
          ? _state.failure
          : failure as RemoteControlFailure?,
      refreshing: refreshing ?? _state.refreshing,
    );
    _states.add(_state);
  }

  Future<void> start() async {
    if (!_current) return;
    _poll ??= Timer.periodic(pollInterval, (_) => unawaited(refresh()));
    await refresh();
  }

  void _invalidateSelection() {
    _generation++;
    if (_api case RemoteControlCancellation cancellation) {
      cancellation.invalidatePending();
    }
    _confirmation?.cancel();
    _confirmation = null;
    _awaiting = null;
    for (final intent in _pending.values) {
      intent.complete();
    }
    _pending.clear();
  }

  bool _sameScope(int generation, RemoteTarget target) =>
      _current &&
      generation == _generation &&
      _state.target?.samePlayback(target) == true;

  Future<void> select(RemoteTarget? target) async {
    if (!_current) return;
    _invalidateSelection();
    RemoteTarget? candidate;
    if (target != null) {
      final matches =
          _state.targets.where((entry) => entry.sameEndpoint(target)).toList();
      if (matches.length != 1) {
        _emit(
          target: null,
          subtitles: const [],
          status: RemoteCommandStatus.failed,
          failure: const RemoteControlFailure(RemoteFailureCode.stale),
        );
        return;
      }
      candidate = matches.single;
    }
    _emit(
      target: candidate,
      subtitles: const [],
      status: RemoteCommandStatus.idle,
      failure: null,
    );
    if (candidate?.canControl == true) {
      await _loadSubtitles(candidate!, _generation);
    }
  }

  Future<void> _loadSubtitles(RemoteTarget target, int generation) async {
    try {
      final options = await _api.subtitles(target);
      if (_sameScope(generation, target)) {
        _emit(subtitles: options, failure: null);
      }
    } catch (error) {
      if (_sameScope(generation, target)) {
        _emit(subtitles: const [], failure: _safeFailure(error));
      }
    }
  }

  Future<void> refresh() {
    if (!_current) return Future.value();
    return _refreshing ??=
        Future<void>.microtask(_refresh).whenComplete(() => _refreshing = null);
  }

  Future<void> _refresh() async {
    final generation = _generation;
    final readSerial = ++_readSerial;
    _emit(refreshing: true);
    try {
      final targets = await _api.discover();
      if (!_current || generation != _generation) return;
      final selected = _state.target;
      if (selected == null) {
        _emit(targets: targets, failure: null);
        return;
      }
      final matches =
          targets.where((entry) => entry.sameEndpoint(selected)).toList();
      if (matches.length != 1) {
        _invalidateSelection();
        _emit(
          targets: targets,
          target: null,
          subtitles: const [],
          status: RemoteCommandStatus.failed,
          failure: const RemoteControlFailure(RemoteFailureCode.stale),
        );
        return;
      }
      final fresh = matches.single;
      final changed = fresh.binding != selected.binding;
      if (changed) {
        _invalidateSelection();
        _emit(
          targets: targets,
          target: fresh,
          subtitles: const [],
          status: RemoteCommandStatus.idle,
          failure: null,
        );
        if (fresh.canControl) unawaited(_loadSubtitles(fresh, _generation));
      } else {
        _emit(targets: targets, target: fresh);
        _confirmFrom(fresh, readSerial);
      }
    } catch (error) {
      if (!_current || generation != _generation) return;
      final failure = _safeFailure(error);
      if (const {
        RemoteFailureCode.denied,
        RemoteFailureCode.stale,
        RemoteFailureCode.closed,
        RemoteFailureCode.unsupported,
      }.contains(failure.code)) {
        _invalidateSelection();
        _emit(
          targets: const [],
          target: null,
          subtitles: const [],
          status: RemoteCommandStatus.failed,
          failure: failure,
        );
      } else {
        _emit(failure: failure);
      }
    } finally {
      if (_current) _emit(refreshing: false);
    }
  }

  static RemoteControlFailure _safeFailure(Object error) =>
      error is RemoteControlFailure
          ? error
          : const RemoteControlFailure(RemoteFailureCode.server);

  void _confirmFrom(RemoteTarget fresh, int readSerial) {
    final waiting = _awaiting;
    if (waiting == null ||
        readSerial <= waiting.readSerial ||
        !fresh.samePlayback(waiting.intent.target)) {
      return;
    }
    final report = fresh.lastPlaybackCheckIn;
    final baseline = waiting.baseline.lastPlaybackCheckIn;
    if (report == null ||
        (baseline != null && !report.isAfter(baseline)) ||
        (baseline == null &&
            report.isBefore(
              waiting.acceptedAt.subtract(const Duration(seconds: 5)),
            ))) {
      return;
    }
    final action = waiting.intent.action;
    final elapsed = _now().difference(waiting.acceptedAt);
    final elapsedTicks = elapsed.isNegative ? 0 : elapsed.inMicroseconds * 10;
    final confirmed = switch (action.type) {
      RemoteActionType.play => fresh.paused == false,
      RemoteActionType.pause => fresh.paused == true,
      RemoteActionType.subtitle => fresh.subtitleIndex == action.subtitleIndex,
      RemoteActionType.seek => fresh.positionTicks != null &&
          (fresh.positionTicks! - action.position!.inMicroseconds * 10).abs() <=
              20000000 + (fresh.paused == false ? elapsedTicks : 0),
    };
    if (!confirmed) return;
    _confirmation?.cancel();
    _confirmation = null;
    _awaiting = null;
    _emit(status: RemoteCommandStatus.confirmed, failure: null);
  }

  Future<void> dispatch(RemoteAction action) {
    if (!_current) return Future.value();
    final target = _state.target;
    if (target?.canControl != true) {
      _emit(
        status: RemoteCommandStatus.failed,
        failure: const RemoteControlFailure(RemoteFailureCode.invalidTarget),
      );
      return Future.value();
    }
    final key = action.type == RemoteActionType.pause
        ? RemoteActionType.play
        : action.type;
    final intent = _Intent(target!, action, _generation);
    _pending.remove(key)?.complete();
    _pending[key] = intent;
    // play/pause, seek and subtitle are the only independently coalesced intents.
    _ensureDrain();
    return intent.done.future;
  }

  void _ensureDrain() {
    if (_draining != null || !_current || _pending.isEmpty) return;
    _draining = Future<void>.microtask(_drain).whenComplete(() {
      _draining = null;
      _ensureDrain();
    });
  }

  Future<void> _drain() async {
    while (_current && _pending.isNotEmpty) {
      final key = _pending.keys.first;
      final intent = _pending.remove(key)!;
      if (!_sameScope(intent.generation, intent.target)) {
        intent.complete();
        continue;
      }
      _confirmation?.cancel();
      _awaiting = null;
      _emit(status: RemoteCommandStatus.pending, failure: null);
      try {
        await _api.send(intent.target, intent.action);
        if (!_sameScope(intent.generation, intent.target)) continue;
        final observed = _api is RemoteControlSendObservation
            ? (_api as RemoteControlSendObservation).lastAcceptedBaseline
            : null;
        final baseline = observed?.samePlayback(intent.target) == true
            ? observed!
            : intent.target;
        final waiting = _AwaitingReport(intent, baseline, _now(), _readSerial);
        _awaiting = waiting;
        _emit(status: RemoteCommandStatus.accepted, failure: null);
        _confirmation = Timer(confirmationTimeout, () {
          if (_sameScope(intent.generation, intent.target) &&
              identical(_awaiting, waiting)) {
            _awaiting = null;
            _emit(
              status: RemoteCommandStatus.unknown,
              failure: const RemoteControlFailure(
                RemoteFailureCode.timeoutUnknown,
              ),
            );
          }
        });
        unawaited(refresh());
      } catch (error) {
        if (!_sameScope(intent.generation, intent.target)) continue;
        final failure = _safeFailure(error);
        _emit(
          status: failure.code == RemoteFailureCode.timeoutUnknown
              ? RemoteCommandStatus.unknown
              : RemoteCommandStatus.failed,
          failure: failure,
        );
      } finally {
        intent.complete();
      }
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _invalidateSelection();
    _closed = true;
    _poll?.cancel();
    _poll = null;
    unawaited(_states.close());
  }
}
