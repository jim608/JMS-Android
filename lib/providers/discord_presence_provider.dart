import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/media_playback_model.dart';
import 'package:fladder/providers/incognito_mode_provider.dart';
import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/providers/settings/video_player_settings_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/services/discord/discord_activity.dart';
import 'package:fladder/services/discord/discord_ipc_client.dart';
import 'package:fladder/services/discord/discord_presence_controller.dart';

export 'package:fladder/services/discord/discord_presence_client.dart'
    show DiscordConnectionState;

final discordPresenceClientProvider = Provider<DiscordPresenceClient>(
  (ref) => createDiscordPresenceClient(),
);

final discordPresenceSettingsProvider =
    ChangeNotifierProvider<DiscordPresenceSettings>((ref) {
  final settings = DiscordPresenceSettings(
    preferences: ref.read(sharedPreferencesProvider),
    controller: DiscordPresenceController(
        client: ref.read(discordPresenceClientProvider)),
  );
  String? previousScope;
  Object? previousAccountPlayback;
  var initialized = false;
  void update() {
    final account = ref.read(userProvider);
    final scope = discordAccountScope(account);
    final model = ref.read(playBackModel);
    if (initialized && scope != previousScope) previousAccountPlayback = model;
    if (!identical(previousAccountPlayback, model)) {
      previousAccountPlayback = null;
    }
    initialized = true;
    previousScope = scope;
    settings.activateAccount(scope);
    final playback = ref.read(mediaPlaybackProvider);
    final item = model?.item;
    final title = item == null
        ? ''
        : (item.title == item.name
            ? item.title
            : '${item.title} • ${item.name}');
    settings.updatePlayback(
      DiscordPlaybackSnapshot(
        active: item != null &&
            !identical(previousAccountPlayback, model) &&
            playback.state != VideoPlayerState.disposed &&
            !playback.completed &&
            !playback.errorPlaying,
        title: title,
        playing: playback.playing,
        buffering: playback.buffering,
        audio: item?.type == FladderItemType.audio,
        position: playback.position,
        duration: playback.duration,
        rate: ref.read(playbackRateProvider),
      ),
      privateMode: scope == null || ref.read(incognitoProvider),
    );
  }

  ref.listen(userProvider, (_, __) => update());
  ref.listen(incognitoProvider, (_, __) => update());
  ref.listen(mediaPlaybackProvider, (_, __) => update());
  ref.listen(playBackModel, (_, __) => update());
  ref.listen(playbackRateProvider, (_, __) => update());
  update();
  return settings;
});

String? discordAccountScope(AccountModel? account) {
  if (account == null ||
      account.id.isEmpty ||
      account.credentials.serverId.isEmpty) {
    return null;
  }
  return sha256
      .convert(utf8.encode('${account.credentials.serverId}|${account.id}'))
      .toString();
}

class DiscordPresenceSettings extends ChangeNotifier {
  DiscordPresenceSettings(
      {required this.preferences, required this.controller}) {
    controller.addListener(_notify);
  }

  final SharedPreferences preferences;
  final DiscordPresenceController controller;
  String? _scope;
  bool _enabled = false;
  bool _shareTitle = false;
  bool _busy = false;
  bool _disposed = false;
  bool _privateMode = true;
  bool _suspended = false;
  DiscordPlaybackSnapshot? _playback;

  bool get supported => controller.supported;
  bool get hasAccount => _scope != null;
  bool get enabled => _enabled;
  bool get shareTitle => _shareTitle;
  bool get busy => _busy;
  String? get activeScope => _scope;
  DiscordConnectionState get status => controller.status;
  String _key(String field, String scope) =>
      'jms.discord.presence.v1.$scope.$field';

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void activateAccount(String? scope) {
    if (_disposed || _scope == scope) return;
    _scope = scope;
    _playback = null;
    _enabled = supported &&
        scope != null &&
        (preferences.getBool(_key('enabled', scope)) ?? false);
    _shareTitle = scope != null &&
        (preferences.getBool(_key('shareTitle', scope)) ?? false);
    _apply();
    _notify();
  }

  void updatePlayback(DiscordPlaybackSnapshot playback,
      {required bool privateMode}) {
    if (_disposed) return;
    _playback = playback;
    _privateMode = privateMode;
    _apply();
  }

  void _apply() => controller.update(
        scope: _scope,
        enabled: _enabled && !_suspended,
        shareTitle: _shareTitle,
        privateMode: _privateMode,
        playback: _playback,
      );

  Future<bool> setEnabled(bool value) => _save('enabled', value);
  Future<bool> setShareTitle(bool value) => _save('shareTitle', value);

  Future<bool> _save(String field, bool value) async {
    final scope = _scope;
    if (_disposed ||
        _busy ||
        scope == null ||
        !supported ||
        (field == 'shareTitle' && value && !_enabled)) {
      return false;
    }
    _busy = true;
    if (!value) {
      // Revoking disclosure takes effect before waiting for storage.
      if (field == 'enabled') _enabled = false;
      if (field == 'shareTitle') _shareTitle = false;
      _apply();
    }
    _notify();
    try {
      final saved = await preferences.setBool(_key(field, scope), value);
      if (!saved || _disposed || _scope != scope) return false;
      if (field == 'enabled') _enabled = value;
      if (field == 'shareTitle') _shareTitle = value;
      _apply();
      return true;
    } catch (_) {
      return false;
    } finally {
      _busy = false;
      _notify();
    }
  }

  /// Closing the app window must clear presence before platform teardown.
  void suspend() {
    _suspended = true;
    _playback = null;
    _apply();
  }

  @override
  void dispose() {
    _disposed = true;
    controller.removeListener(_notify);
    controller.dispose();
    super.dispose();
  }
}
