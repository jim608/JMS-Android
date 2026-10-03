import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:fladder/services/discord/discord_activity.dart';
import 'package:fladder/services/discord/discord_presence_client.dart';

const jmsDiscordApplicationId = '1555974444369969292';

/// Serializes local IPC operations and invalidates pending work on withdrawal.
class DiscordPresenceController extends ChangeNotifier {
  DiscordPresenceController({
    required DiscordPresenceClient client,
    DateTime Function()? now,
    this.minimumInterval = const Duration(seconds: 2),
    this.positionInterval = const Duration(seconds: 15),
    this.retryDelay = const Duration(seconds: 30),
  })  : _client = client,
        _now = now ?? DateTime.now {
    _subscription = _client.states.listen((state) {
      if (_disposed) return;
      _status = state;
      notifyListeners();
      if (state == DiscordConnectionState.disconnected ||
          state == DiscordConnectionState.error) {
        _connected = false;
        _lastSent = null;
        if (_desired != null && !_withdrawing) {
          _schedule(retryDelay, retry: true);
        }
      }
    });
  }

  final DiscordPresenceClient _client;
  final DateTime Function() _now;
  final Duration minimumInterval;
  final Duration positionInterval;
  final Duration retryDelay;
  late final StreamSubscription<DiscordConnectionState> _subscription;
  DiscordConnectionState _status = DiscordConnectionState.disconnected;
  Map<String, Object?>? _desired;
  String? _lastSent;
  String? _lastContent;
  String? _scope;
  DateTime? _sentAt;
  Timer? _timer;
  bool _connected = false;
  bool _disposed = false;
  bool _draining = false;
  bool _withdrawing = false;
  bool _retryPending = false;
  bool _sharingTitle = false;
  int _generation = 0;
  Future<void>? _closing;

  bool get supported => _client.supported;
  DiscordConnectionState get status => _status;

  void update({
    required String? scope,
    required bool enabled,
    required bool shareTitle,
    required bool privateMode,
    required DiscordPlaybackSnapshot? playback,
  }) {
    if (_disposed) return;
    final next = supported && scope != null && enabled && !privateMode
        ? discordActivity(playback, shareTitle: shareTitle, now: _now())
        : null;
    final changedScope = _scope != scope;
    final withdrewTitle = _sharingTitle && !shareTitle;
    _sharingTitle = shareTitle;
    _scope = scope;
    if (changedScope || withdrewTitle || next == null) {
      _generation++;
      _desired = next;
      _timer?.cancel();
      _timer = null;
      _retryPending = false;
      // Queue a null command before disconnecting, even if an ACK is pending.
      // Closing the IPC stream is an additional withdrawal safeguard.
      _withdraw();
      return;
    }
    _desired = next;
    final serialized = jsonEncode(next);
    if (_lastSent == serialized) return;
    final content = jsonEncode({...next}..remove('timestamps'));
    if (_timer != null && !_retryPending && content != _lastContent) {
      // Playback/pause/title changes supersede a queued position refresh.
      _timer!.cancel();
      _timer = null;
    }
    final interval =
        content == _lastContent ? positionInterval : minimumInterval;
    final since = _sentAt == null ? interval : _now().difference(_sentAt!);
    _schedule(since >= interval ? Duration.zero : interval - since);
  }

  void _schedule(Duration delay, {bool retry = false}) {
    if (_disposed || _desired == null || _timer != null) return;
    _retryPending = retry;
    _timer = Timer(delay, () {
      _timer = null;
      _retryPending = false;
      unawaited(_drain());
    });
  }

  void _withdraw() {
    if (_closing != null) return;
    _withdrawing = true;
    _closing = _clearAndClose().whenComplete(() {
      _withdrawing = false;
      _closing = null;
      if (!_disposed && _desired != null) _schedule(Duration.zero);
    });
  }

  Future<void> _clearAndClose() async {
    try {
      if (_connected) {
        await _client.setActivity(null).timeout(const Duration(seconds: 2));
      }
    } catch (_) {
      // Do not log Discord replies, IPC paths or display data.
    } finally {
      try {
        await _client.close();
      } catch (_) {}
      _connected = false;
      _lastSent = null;
      _lastContent = null;
      _sentAt = null;
    }
  }

  Future<void> _drain() async {
    if (_disposed || _draining || _desired == null || _closing != null) return;
    _draining = true;
    final generation = _generation;
    try {
      if (!_connected) {
        await _client.connect(jmsDiscordApplicationId);
        if (_disposed || generation != _generation || _desired == null) return;
        _connected = true;
      }
      final activity = _desired;
      if (activity == null || generation != _generation) return;
      final serialized = jsonEncode(activity);
      if (_lastSent == serialized) return;
      await _client.setActivity(activity);
      if (_disposed || generation != _generation || _desired == null) return;
      _lastSent = serialized;
      _lastContent = jsonEncode({...activity}..remove('timestamps'));
      _sentAt = _now();
    } catch (_) {
      _connected = false;
      _lastSent = null;
      if (!_disposed && generation == _generation && _desired != null) {
        _schedule(retryDelay, retry: true);
      }
    } finally {
      _draining = false;
      if (!_disposed &&
          _closing == null &&
          _desired != null &&
          _lastSent != jsonEncode(_desired)) {
        _schedule(minimumInterval);
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _desired = null;
    _timer?.cancel();
    unawaited(_subscription.cancel());
    _withdraw();
    super.dispose();
  }
}
