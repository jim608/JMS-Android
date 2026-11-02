import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/models/account_model.dart';
import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/incognito_mode_provider.dart';
import 'package:fladder/providers/sync_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/services/playback_reporting_scope.dart';

typedef CapturedPlaybackApiFactory = JellyfinOpenApi Function(
    AccountModel account);
final capturedPlaybackApiFactoryProvider = Provider<CapturedPlaybackApiFactory>(
    (ref) => (account) => createJellyfinApiForAccount(
        ref,
        account.credentials.url,
        Map<String, String>.unmodifiable(account.credentials.header(ref)),
        privateLink: true));

final capturedPlaybackReportingProvider =
    Provider<CapturedPlaybackReporting>((ref) {
  final reporting = CapturedPlaybackReporting(ref);
  ref.listen(userProvider, (previous, next) {
    if (previous?.id != next?.id ||
        previous?.credentials != next?.credentials ||
        next?.policy?.isDisabled == true ||
        next?.policy?.enableMediaPlayback == false) {
      reporting.invalidate();
    }
  });
  ref.onDispose(reporting.dispose);
  return reporting;
});

class CapturedPlaybackReporting {
  CapturedPlaybackReporting(this.ref);
  final Ref ref;
  int _generation = 0;
  bool _disposed = false;
  AccountModel? _account;
  PlaybackReportingCapture? _capture;
  // Released Jellyfin versions key this app's session by client/device, not
  // user. Keep one writer across account changes on the same server/browser.
  final _lanes = <(String, String), PlaybackReportLane>{};

  void invalidate() {
    _generation++;
    _capture?.close();
    _capture = null;
    _account = null;
  }

  void dispose() {
    _disposed = true;
    invalidate();
  }

  PlaybackReportingCapture? capture() {
    if (_disposed) return null;
    final account = ref.read(userProvider);
    if (account == null ||
        account.id.isEmpty ||
        account.policy?.isDisabled == true ||
        account.policy?.enableMediaPlayback == false) {
      return null;
    }
    if (_capture != null &&
        _account?.id == account.id &&
        _account?.credentials == account.credentials) {
      return _capture;
    }
    invalidate();
    final generation = _generation;
    _account = account;
    bool current() {
      if (_disposed || generation != _generation) return false;
      final user = ref.read(userProvider);
      return user?.id == account.id &&
          user?.credentials == account.credentials &&
          user?.policy?.isDisabled != true &&
          user?.policy?.enableMediaPlayback != false;
    }

    final api = ref.read(capturedPlaybackApiFactoryProvider)(account);
    return _capture = PlaybackReportingCapture(
      api: _PrivatePlaybackApi(api),
      playbackInfoRequest: (itemId, body) => api.itemsItemIdPlaybackInfoPost(
          itemId: itemId, body: body.copyWith(userId: account.id)),
      lane: _lanes.putIfAbsent((
        account.credentials.serverId.isNotEmpty
            ? account.credentials.serverId
            : account.credentials.url,
        account.credentials.deviceId
      ), PlaybackReportLane.new),
      isCurrent: current,
      isPlaybackCurrent: (scope) =>
          identical(ref.read(playBackModel)?.reportingScope, scope),
      enabled: () => !ref.read(incognitoProvider),
      onStopped: (info) {
        if (!current() || info.positionTicks == null) return;
        ref.read(syncProvider.notifier).updatePlaybackPosition(
            itemId: info.itemId,
            position: Duration(microseconds: info.positionTicks! ~/ 10));
      },
    );
  }
}

class _PrivatePlaybackApi implements PlaybackReportApi {
  _PrivatePlaybackApi(this.api);
  final JellyfinOpenApi api;
  @override
  Future<void> start(PlaybackStartInfo info) async {
    await api.sessionsPlayingPost(body: info);
  }

  @override
  Future<void> progress(PlaybackProgressInfo info) async {
    await api.sessionsPlayingProgressPost(body: info);
  }

  @override
  Future<void> stop(PlaybackStopInfo info) async {
    await api.sessionsPlayingStoppedPost(body: info);
  }

  @override
  void close() {
    try {
      api.client.httpClient.close();
    } catch (_) {}
    try {
      api.client.dispose();
    } catch (_) {}
  }
}
