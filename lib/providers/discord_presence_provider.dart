import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/items/episode_model.dart';
import 'package:fladder/models/media_playback_model.dart';
import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/incognito_mode_provider.dart';
import 'package:fladder/providers/discord_browsing_provider.dart';
import 'package:fladder/screens/login/lock_screen.dart';
import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/providers/settings/video_player_settings_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/services/discord/discord_activity.dart';
import 'package:fladder/services/discord/discord_artwork.dart';
import 'package:fladder/services/discord/discord_ipc_client.dart';
import 'package:fladder/services/discord/discord_presence_controller.dart';

export 'package:fladder/services/discord/discord_presence_client.dart' show DiscordConnectionState;

final discordPresenceClientProvider = Provider<DiscordPresenceClient>(
  (ref) => createDiscordPresenceClient(),
);

final discordArtworkLoaderProvider = Provider<DiscordArtworkLoader>((ref) {
  return (itemId) async {
    final account = ref.read(userProvider);
    if (account == null) return null;
    // Bind the request before any await. A later account switch must never
    // route this item's lookup through the next account's server or headers.
    final api =
        createJellyfinApiForAccount(ref, account.credentials.url, account.credentials.header(ref), privateLink: true);
    try {
      final response = await api
          .itemsItemIdRemoteImagesGet(
            itemId: itemId,
            type: ItemsItemIdRemoteImagesGetType.primary,
            includeAllLanguages: true,
            limit: 20,
          )
          .timeout(const Duration(seconds: 8));
      if (!response.isSuccessful) return null;
      for (final image in response.body?.images ?? <RemoteImageInfo>[]) {
        if (image.type != ImageType.primary) continue;
        final url = discordArtworkUrl(image.url);
        if (url != null) return url;
      }
      return null;
    } finally {
      api.client.dispose();
    }
  };
});

String? discordArtworkItemId(ItemBaseModel? item) {
  if (item == null || item.type == FladderItemType.audio) return null;
  final id = item is EpisodeModel ? item.parentId : item.id;
  return id == null || id.isEmpty ? null : id;
}

final discordPresenceSettingsProvider = ChangeNotifierProvider<DiscordPresenceSettings>((ref) {
  final settings = DiscordPresenceSettings(
    preferences: ref.read(sharedPreferencesProvider),
    artworkLoader: (itemId) => ref.read(discordArtworkLoaderProvider)(itemId),
    controller: DiscordPresenceController(client: ref.read(discordPresenceClientProvider)),
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
    final title = item == null ? '' : (item.title == item.name ? item.title : '${item.title} • ${item.name}');
    final privateMode = scope == null ||
        ref.read(incognitoProvider) ||
        ref.read(lockScreenActiveProvider) ||
        ref.read(discordBrowsingProvider).blocked;
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
      privateMode: privateMode,
      artworkItemId: discordArtworkItemId(item),
    );
    final browsing = ref.read(discordBrowsingProvider);
    settings.updateBrowsing(
      browsing.scope == scope
          ? browsing.snapshot
          : browsing.snapshot == null
              ? null
              : const DiscordBrowsingSnapshot.selecting(),
      privateMode: privateMode,
    );
  }

  ref.listen(userProvider, (_, __) => update());
  ref.listen(incognitoProvider, (_, __) => update());
  ref.listen(lockScreenActiveProvider, (_, __) => update());
  ref.listen(discordBrowsingProvider, (_, __) => update());
  ref.listen(mediaPlaybackProvider, (_, __) => update());
  ref.listen(playBackModel, (_, __) => update());
  ref.listen(playbackRateProvider, (_, __) => update());
  update();
  return settings;
});

String? discordAccountScope(AccountModel? account) {
  if (account == null || account.id.isEmpty || account.credentials.serverId.isEmpty) {
    return null;
  }
  return sha256.convert(utf8.encode('${account.credentials.serverId}|${account.id}')).toString();
}

class DiscordPresenceSettings extends ChangeNotifier {
  DiscordPresenceSettings({required this.preferences, required this.controller, this.artworkLoader}) {
    controller.addListener(_notify);
  }

  final SharedPreferences preferences;
  final DiscordPresenceController controller;
  final DiscordArtworkLoader? artworkLoader;
  String? _scope;
  bool _enabled = false;
  bool _shareTitle = false;
  bool _shareArtwork = false;
  bool _busy = false;
  bool _disposed = false;
  bool _privateMode = true;
  bool _suspended = false;
  DiscordPlaybackSnapshot? _playback;
  DiscordBrowsingSnapshot? _browsing;
  String? _artworkItemId;
  String? _artworkRequestKey;
  String? _artworkUrl;
  int _artworkGeneration = 0;

  bool get supported => controller.supported;
  bool get hasAccount => _scope != null;
  bool get enabled => _enabled;
  bool get shareTitle => _shareTitle;
  bool get shareArtwork => _shareArtwork;
  bool get busy => _busy;
  String? get activeScope => _scope;
  DiscordConnectionState get status => controller.status;
  String _key(String field, String scope) => 'jms.discord.presence.v1.$scope.$field';

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void activateAccount(String? scope) {
    if (_disposed || _scope == scope) return;
    _scope = scope;
    _playback = null;
    _browsing = null;
    _enabled = supported && scope != null && (preferences.getBool(_key('enabled', scope)) ?? false);
    _shareTitle = scope != null && (preferences.getBool(_key('shareTitle', scope)) ?? false);
    _shareArtwork = scope != null && (preferences.getBool(_key('shareArtwork', scope)) ?? false);
    _apply();
    _notify();
  }

  void updatePlayback(DiscordPlaybackSnapshot playback, {required bool privateMode, String? artworkItemId}) {
    if (_disposed) return;
    _playback = playback;
    _privateMode = privateMode;
    _artworkItemId = artworkItemId;
    _apply();
  }

  void updateBrowsing(DiscordBrowsingSnapshot? browsing, {required bool privateMode}) {
    if (_disposed) return;
    _browsing = browsing;
    _privateMode = privateMode;
    _apply();
  }

  void _apply() {
    final playing = _playback?.active == true;
    final title = playing ? _playback!.title : _browsing?.title ?? '';
    final artworkItemId = playing ? _artworkItemId : _browsing?.artworkItemId;
    final publicPoster = playing ? null : discordArtworkUrl(_browsing?.artworkUrl);
    final canShareArtwork = supported &&
        _scope != null &&
        _enabled &&
        _shareTitle &&
        _shareArtwork &&
        !_privateMode &&
        !_suspended &&
        (playing || _browsing?.viewingDetails == true) &&
        (!playing || _playback?.audio == false) &&
        discordDisplayTitle(title) != null;
    final canLoadArtwork = canShareArtwork && publicPoster == null && artworkItemId != null && artworkLoader != null;
    final key = canLoadArtwork ? '$_scope|$artworkItemId' : null;
    if (key != _artworkRequestKey) {
      _artworkRequestKey = key;
      _artworkUrl = null;
      final generation = ++_artworkGeneration;
      if (key != null) {
        unawaited(_loadArtwork(artworkItemId!, generation));
      }
    }
    controller.update(
      scope: _scope,
      enabled: _enabled && !_suspended,
      shareTitle: _shareTitle,
      // Navigation changes the payload, not the account consent.
      shareArtwork: _shareArtwork,
      artworkUrl: canShareArtwork ? publicPoster ?? _artworkUrl : null,
      privateMode: _privateMode,
      playback: _playback,
      browsing: _browsing,
    );
  }

  Future<void> _loadArtwork(String itemId, int generation) async {
    String? url;
    try {
      url = discordArtworkUrl(await artworkLoader!(itemId).timeout(const Duration(seconds: 8)));
    } catch (_) {
      // Missing metadata, offline servers and timeouts keep text presence.
      // Do not log replies, item IDs or server details.
    }
    if (_disposed || generation != _artworkGeneration) return;
    _artworkUrl = url;
    _apply();
  }

  Future<bool> setEnabled(bool value) => _save('enabled', value);
  Future<bool> setShareTitle(bool value) => _save('shareTitle', value);
  Future<bool> setShareArtwork(bool value) => _save('shareArtwork', value);

  Future<bool> _save(String field, bool value) async {
    final scope = _scope;
    if (_disposed ||
        _busy ||
        scope == null ||
        !supported ||
        (field == 'shareTitle' && value && !_enabled) ||
        (field == 'shareArtwork' && value && (!_enabled || !_shareTitle))) {
      return false;
    }
    _busy = true;
    if (!value) {
      // Revoking disclosure takes effect before waiting for storage.
      if (field == 'enabled') _enabled = false;
      if (field == 'shareTitle') _shareTitle = false;
      if (field == 'shareArtwork') _shareArtwork = false;
      _apply();
    }
    _notify();
    try {
      final saved = await preferences.setBool(_key(field, scope), value);
      if (!saved || _disposed || _scope != scope) return false;
      if (field == 'enabled') _enabled = value;
      if (field == 'shareTitle') _shareTitle = value;
      if (field == 'shareArtwork') _shareArtwork = value;
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
    _browsing = null;
    _apply();
  }

  @override
  void dispose() {
    _disposed = true;
    _artworkGeneration++;
    _artworkUrl = null;
    controller.removeListener(_notify);
    controller.dispose();
    super.dispose();
  }
}
