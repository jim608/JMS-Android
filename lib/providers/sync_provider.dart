import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart' hide ConnectionState;

import 'package:background_downloader/background_downloader.dart';
import 'package:collection/collection.dart';
import 'package:drift_db_viewer/drift_db_viewer.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/api_result.dart';
import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/items/album_model.dart';
import 'package:fladder/models/items/artist_model.dart';
import 'package:fladder/models/items/audio_model.dart';
import 'package:fladder/models/items/episode_model.dart';
import 'package:fladder/models/items/images_models.dart';
import 'package:fladder/models/items/item_shared_models.dart';
import 'package:fladder/models/items/media_streams_model.dart';
import 'package:fladder/models/items/movie_model.dart';
import 'package:fladder/models/items/photos_model.dart';
import 'package:fladder/models/items/playlist_model.dart';
import 'package:fladder/models/items/season_model.dart';
import 'package:fladder/models/items/series_model.dart';
import 'package:fladder/models/items/trick_play_model.dart';
import 'package:fladder/models/syncing/database_item.dart';
import 'package:fladder/models/syncing/download_stream.dart';
import 'package:fladder/models/syncing/sync_item.dart';
import 'package:fladder/models/syncing/sync_settings_model.dart';
import 'package:fladder/models/syncing/transcode_download_model.dart';
import 'package:fladder/models/syncing/transcode_music_download_model.dart';
import 'package:fladder/models/video_stream_model.dart';
import 'package:fladder/profiles/default_profile.dart';
import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/connectivity_provider.dart';
import 'package:fladder/providers/service_provider.dart';
import 'package:fladder/providers/settings/client_settings_provider.dart';
import 'package:fladder/providers/sync/background_download_provider.dart';
import 'package:fladder/providers/sync/sync_provider_media.dart';
import 'package:fladder/providers/sync/sync_provider_overlay.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/screens/shared/fladder_notification_overlay.dart';
import 'package:fladder/util/duration_extensions.dart';
import 'package:fladder/util/jelly_id.dart';
import 'package:fladder/util/localization_helper.dart';
import 'package:fladder/util/string_extensions.dart';
import 'package:fladder/util/jms_test_profile_policy.dart';

final syncProvider = StateNotifierProvider<SyncNotifier, SyncSettingsModel>((ref) => throw UnimplementedError());

final downloadTasksProvider = StateProvider.family<DownloadStream, String?>((ref, id) => DownloadStream.empty());

final activeDownloadTasksProvider = StateProvider<List<DownloadTask>>((ref) {
  return [];
});

const syncPathKey = "syncPathKey";

Future<String?> pickSyncDirectory({required String dialogTitle, String? initialDirectory}) async {
  if (kIsWeb) return null;
  if (Platform.isAndroid) {
    // The offline downloader still needs a filesystem path for Android storage.
    return FilePickerPlatform.instance.getDirectoryPath(dialogTitle: dialogTitle, initialDirectory: initialDirectory);
  }
  final directory = await FilePicker.pickDirectory(dialogTitle: dialogTitle, initialDirectory: initialDirectory);
  return directory != null && directory.isScheme('file') ? path.normalize(directory.toFilePath()) : null;
}

class _OfflineTrickPlay {
  _OfflineTrickPlay(this.isCurrentAccount);

  final _cancelled = Completer<void>();
  final bool Function() isCurrentAccount;
  http.Client? client;
  Future<bool>? enqueue;
  Future<void>? done;

  bool get isCancelled => _cancelled.isCompleted;
  bool get isCurrent => !isCancelled && isCurrentAccount();

  void cancel() {
    if (!isCancelled) _cancelled.complete();
    closeClient();
  }

  void closeClient() {
    client?.close();
    client = null;
  }

  Future<T?> requestMetadata<T>(Future<T> response) => Future.any([
        response.timeout(const Duration(seconds: 10)),
        _cancelled.future.then<T?>((_) => null),
      ]);

  Future<void> waitForCancellation() async {
    cancel();
    await enqueue?.then<void>((_) {}, onError: (Object _) {});
    await done;
  }
}

class SyncNotifier extends StateNotifier<SyncSettingsModel> {
  SyncNotifier(this.ref, this.mobileDirectory, {AppDatabase? database})
      : _db = database ?? AppDatabase(ref),
        super(SyncSettingsModel()) {
    _init();
  }

  final Ref ref;
  final AppDatabase _db;
  final Directory mobileDirectory;
  final String subPath = "Synced";

  int _offlineAccountEpoch = 0;
  final _replayingUserData = <(String, String)>{};
  final _replayRequested = <(String, String)>{};

  StreamSubscription<List<SyncedItem>>? _subscription;
  int _queryGeneration = 0;
  final _offlineTrickPlay = <String, _OfflineTrickPlay>{};

  @override
  set state(SyncSettingsModel value) {
    super.state = value;
    updateSyncStates();
  }

  bool _matchesDownloadAccount(AccountModel user, String? serverUrl) {
    if (!mounted) return false;
    final current = ref.read(userProvider);
    return current?.id == user.id &&
        current?.credentials == user.credentials &&
        ref.read(serverUrlProvider) == serverUrl;
  }

  Future<void> updateSyncStates() async {
    if (!mounted) return;
    final account = ref.read(userProvider);
    if (account == null || account.credentials.serverId.isEmpty) return;
    final server = ref.read(serverUrlProvider);
    if (server == null || server.isEmpty || ref.read(connectivityStatusProvider) == ConnectionState.offline) return;
    final credentials = account.credentials;
    final target = (account.id, credentials.serverId);
    final epoch = _offlineAccountEpoch;

    bool isCurrent() {
      if (!mounted || epoch != _offlineAccountEpoch) return false;
      final current = ref.read(userProvider);
      return current?.id == account.id && current?.credentials == credentials && ref.read(serverUrlProvider) == server;
    }

    if (!_replayingUserData.add(target)) {
      _replayRequested.add(target);
      return;
    }

    http.Client? client;
    try {
      final headers = credentials.header(ref);
      var changedDuringReplay = false;
      do {
        _replayRequested.remove(target);
        changedDuringReplay = false;
        final rows = await _db.pendingUserData(account.id);
        if (!isCurrent()) return;
        for (final row in rows) {
          final body = await _readPendingUserData(row, credentials.serverId);
          if (!isCurrent()) return;
          if (body == null) continue;
          final uri = buildServerUriFromBase(server,
              pathSegments: ['UserItems', row.id, 'UserData'], queryParameters: {'userId': account.id});
          if (uri == null || ref.read(connectivityStatusProvider) == ConnectionState.offline) return;
          client ??= http.Client();
          final accepted = await JellyService.postOfflineUserData(
            client: client,
            uri: uri,
            headers: headers,
            itemId: row.id,
            body: body,
          ).timeout(const Duration(seconds: 15));
          if (!isCurrent() || !accepted) return;
          final acknowledged = await _db.acknowledgeUserData(row);
          if (!isCurrent()) return;
          changedDuringReplay |= acknowledged == 0;
        }
      } while (changedDuringReplay || _replayRequested.contains(target));
    } catch (error) {
      log('Could not replay offline user data: ${error.runtimeType}');
    } finally {
      client?.close();
      _replayingUserData.remove(target);
      if (_replayRequested.remove(target) && mounted && !isCurrent()) {
        final current = ref.read(userProvider);
        if (current?.id == account.id && current?.credentials.serverId == credentials.serverId) {
          unawaited(updateSyncStates());
        }
      }
    }
  }

  Future<UserData?> _readPendingUserData(PendingUserData pending, String serverId) async {
    final directory = pending.path;
    if (directory == null) return null;
    try {
      final source = jsonDecode(await File(path.join(directory, 'data.json')).readAsString());
      if (source is! Map || source['ServerId'] != serverId) return null;
      final data = jsonDecode(pending.data);
      return data is String ? UserData.fromJson(data) : null;
    } catch (_) {
      return null;
    }
  }

  void _offlineAccountChanged() {
    _offlineAccountEpoch++;
    _cancelOfflineTrickPlayForAccountChange();
    scheduleMicrotask(() {
      if (mounted) unawaited(updateSyncStates());
    });
  }

  void _init() {
    ref.listen(
      userProvider,
      (previous, next) {
        if (previous?.id != next?.id || previous?.credentials != next?.credentials) {
          _offlineAccountChanged();
        }
        if (previous?.id != next?.id) _initializeQueryStream();
      },
    );
    ref.listen(serverUrlProvider, (previous, next) {
      if (previous != next) _offlineAccountChanged();
    });

    ref.listen(connectivityStatusProvider, (_, next) {
      if (next != ConnectionState.offline) {
        updateSyncStates();
      }
    });
    _initializeQueryStream();
  }

  void _initializeQueryStream() async {
    final generation = ++_queryGeneration;
    _subscription?.cancel();
    state = state.copyWith(items: []);

    if (ref.read(userProvider) == null) return;

    await cleanUpEmptyDatabaseEntries();

    if (!mounted || generation != _queryGeneration) return;
    _subscription = _db.getParentItems.watch().listen((items) {
      if (mounted && generation == _queryGeneration) state = state.copyWith(items: items);
    });
  }

  late final JellyService api = ref.read(jellyApiProvider);

  String? get _savePath => JmsTestProfilePolicy.enabled
      ? mobileDirectory.path
      : !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
          ? ref.read(clientSettingsProvider.select((value) => value.syncPath))
          : mobileDirectory.path;

  String? get savePath => _savePath;

  Directory get mainDirectory => Directory(path.joinAll([_savePath ?? "", subPath]));

  Directory? get saveDirectory {
    try {
      if (kIsWeb) return null;
      final directory = _savePath != null
          ? Directory(path.joinAll([_savePath ?? "", subPath, ref.read(userProvider)?.id ?? "UnknownUser"]))
          : null;
      directory?.createSync(recursive: true);
      if (directory?.existsSync() == true) {
        final noMedia = File(path.joinAll([directory?.path ?? "", ".nomedia"]));
        noMedia.writeAsString('');
        noMedia.createSync();
      }
      return directory;
    } catch (e) {
      log('Error accessing save directory: ${e.toString()}');
      return null;
    }
  }

  String? get syncPath => saveDirectory?.path;

  Future<int> get directorySize async {
    if (saveDirectory == null) return 0;
    var files = await saveDirectory!.list(recursive: true).toList();
    var dirSize = files.fold(0, (int sum, file) => sum + file.statSync().size);
    return dirSize;
  }

  @override
  void dispose() {
    _cancelOfflineTrickPlayForAccountChange();
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> refresh() async {
    final generation = _queryGeneration;
    final items = await _db.getParentItems.get();
    if (mounted && generation == _queryGeneration) state = state.copyWith(items: items);
  }

  Future<List<SyncedItem>> getNestedChildren(SyncedItem? item) async {
    if (item == null) return [];
    if (item.itemModel?.type == FladderItemType.playlist) {
      return _getPlaylistChildrenFromOverlay(item);
    }
    return _db.getNestedChildrenRecursive(item.id);
  }

  Future<List<SyncedItem>> getChildren(String parentId) => _db.getChildren(parentId);

  Future<List<SyncedItem>> getChildrenForItem(SyncedItem item) async {
    if (item.itemModel?.type == FladderItemType.playlist) {
      return _getPlaylistChildrenFromOverlay(item);
    }
    return getChildren(item.id);
  }

  Future<List<SyncedItem>> _getPlaylistChildrenFromOverlay(SyncedItem item) async {
    final childIds = await item.getPlaylistChildIdsAsync();
    if (childIds.isEmpty) return [];

    final children = await Future.wait(childIds.map(getSyncedItem));
    return children.whereType<SyncedItem>().where((child) => child.itemModel is AudioModel).toList();
  }

  Future<List<SyncedItem>> getSiblings(SyncedItem syncedItem) async {
    if (syncedItem.parentId == null) return [];
    return getChildren(syncedItem.parentId!);
  }

  Future<SyncedItem?> getSyncedItem(String? id) async {
    if (id == null) return null;
    return await _db.getItem(id).getSingleOrNull();
  }

  Stream<SyncedItem?> watchItem(String id) => _db.watchItem(id);

  Future<SyncedItem> refreshSyncItem(SyncedItem item) async {
    final epoch = _offlineAccountEpoch;
    bool currentAccount() => mounted && epoch == _offlineAccountEpoch && ref.read(userProvider)?.id == item.userId;
    if (!currentAccount()) return item;
    if (ref.read(offlineStateProvider)) return await getSyncedItem(item.id) ?? item;
    final itemsToSync = [item, ...await getNestedChildren(item)];
    for (final itemToSync in itemsToSync) {
      if (!currentAccount() || ref.read(offlineStateProvider)) break;
      final itemResponse = await api.usersUserIdItemsItemIdGetBaseItem(
        itemId: itemToSync.id,
      );
      if (itemResponse.statusCode == 202 || !currentAccount()) break;
      final itemModel = ItemBaseModel.fromBaseDto(itemResponse.bodyOrThrow, ref);
      if (!await itemToSync.directory.exists()) continue;
      final parentId = itemToSync.parentId;
      final parent = parentId == null ? null : await getSyncedItem(parentId);
      final metadata = await _syncItemData(parent, itemModel, itemResponse.bodyOrThrow, directory: itemToSync.directory);
      if (!currentAccount()) break;
      await _db.refreshMetadata(itemToSync, metadata.copyWith(
        userData: UserData.determineLastUserData([itemToSync.userData, itemModel.userData]),
      ));
    }
    return currentAccount() ? await getSyncedItem(item.id) ?? item : item;
  }

  Future<void> addSyncItem(BuildContext? context, ItemBaseModel item) async {
    try {
      if (context == null) return;

      if (saveDirectory == null) {
        final selectedDirectory = await pickSyncDirectory(dialogTitle: context.localized.syncSelectDownloadsFolder);
        if (selectedDirectory?.isEmpty == true && context.mounted) {
          FladderSnack.show(context.localized.syncNoFolderSetup, context: context);
          return;
        }
        ref.read(clientSettingsProvider.notifier).setSyncPath(selectedDirectory);
      }

      if (context.mounted) {
        FladderSnack.show(context.localized.syncAddItemForSyncing(item.detailedName(context.localized) ?? "Unknown"),
            context: context);
      }
      final newSync = switch (item) {
        EpisodeModel episode => await syncSeries(item.parentBaseModel, episode: episode),
        SeasonModel season => await syncSeries(item.parentBaseModel, season: season),
        SeriesModel series => await syncSeries(series),
        MovieModel movie => await syncMovie(movie),
        AudioModel audio => await syncAudio(audio),
        AlbumModel album => await syncAlbum(album),
        ArtistModel artist => await syncArtist(artist),
        PlaylistModel playlist => await syncPlaylist(playlist),
        PhotoModel photo => await syncPhotoAlbum(photo.albumId ?? photo.parentId, photo: photo),
        PhotoAlbumModel album => await syncPhotoAlbum(album.id),
        _ => null
      };
      if (context.mounted) {
        FladderSnack.show(
            newSync != null
                ? context.localized.startedSyncingItem(item.detailedName(context.localized) ?? "Unknown")
                : context.localized.unableToSyncItem(item.detailedName(context.localized) ?? "Unknown"),
            context: context);
      }

      return;
    } catch (e) {
      log('Error adding sync item: ${e.toString()}');
      if (context?.mounted == true) {
        FladderSnack.show(context!.localized.somethingWentWrong, context: context);
      }
    }
  }

  void viewDatabase(BuildContext context) =>
      Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(builder: (context) => DriftDbViewer(_db)));

  Future<bool> removeSync(BuildContext context, SyncedItem? item) async {
    try {
      if (item == null) return false;

      final nestedChildren = await getNestedChildren(item);

      state = state.copyWith(
          items: state.items
              .map(
                (e) => e.copyWith(markedForDelete: e.id == item.id ? true : false),
              )
              .toList());

      await Future.wait([item, ...nestedChildren].map((entry) => _cancelOfflineTrickPlay(entry.directory.path)));
      await ref.read(backgroundDownloaderProvider).cancelTaskWithId(item.id);

      await _db.deleteAllItems([...nestedChildren, item]);

      for (var i = 0; i < nestedChildren.length; i++) {
        final element = nestedChildren[i];
        await ref.read(backgroundDownloaderProvider).cancelTaskWithId(element.id);
        if (await element.directory.exists()) {
          await element.directory.delete(recursive: true);
        }
      }

      if (await item.directory.exists()) {
        await item.directory.delete(recursive: true);
      }

      return true;
    } catch (e) {
      log('Error deleting synced item ${e.toString()}');
      state = state.copyWith(items: state.items.map((e) => e.copyWith(markedForDelete: false)).toList());
      FladderSnack.show(context.localized.syncRemoveUnableToDeleteItem, context: context);
      return false;
    }
  }

  Future<bool> removePlaylistSync(
    BuildContext context,
    SyncedItem item, {
    required bool removeLinkedItems,
  }) async {
    try {
      state = state.copyWith(
          items: state.items.map((e) => e.copyWith(markedForDelete: e.id == item.id ? true : false)).toList());

      await ref.read(backgroundDownloaderProvider).cancelTaskWithId(item.id);

      if (removeLinkedItems) {
        final linkedIds = await item.getPlaylistChildIdsAsync();
        final removedTracks = <SyncedItem>[];
        for (final id in linkedIds) {
          final linkedItem = await getSyncedItem(id);
          if (linkedItem == null) continue;
          if (linkedItem.itemModel is AudioModel) {
            removedTracks.add(linkedItem);
          }
          await _deleteSyncedItemAndFiles(linkedItem);
        }

        await _cleanupOrphanedMusicParents(removedTracks);
      }

      await _deleteSyncedItemAndFiles(item);

      return true;
    } catch (e) {
      log('Error deleting synced playlist ${e.toString()}');
      state = state.copyWith(items: state.items.map((e) => e.copyWith(markedForDelete: false)).toList());
      FladderSnack.show(context.localized.syncRemoveUnableToDeleteItem, context: context);
      return false;
    }
  }

  Future<void> _deleteSyncedItemAndFiles(SyncedItem item) async {
    await _cancelOfflineTrickPlay(item.directory.path);
    await ref.read(backgroundDownloaderProvider).cancelTaskWithId(item.id);
    await _db.deleteAllItems([item]);
    if (await item.directory.exists()) {
      await item.directory.delete(recursive: true);
    }
  }

  Future<bool> _hasSyncedAudioDescendants(String parentId) async {
    final queue = <SyncedItem>[...await getChildren(parentId)];

    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      if (current.itemModel is AudioModel) return true;
      queue.addAll(await getChildren(current.id));
    }

    return false;
  }

  Future<void> _cleanupOrphanedMusicParents(Iterable<SyncedItem> removedTracks) async {
    final candidateAlbumIds = <String>{};
    final candidateArtistIds = <String>{};

    for (final removedTrack in removedTracks) {
      final parentId = removedTrack.parentId;
      if (parentId == null) continue;

      final parent = await getSyncedItem(parentId);
      if (parent == null) continue;

      switch (parent.itemModel?.type) {
        case FladderItemType.musicAlbum:
          candidateAlbumIds.add(parent.id);
          if (parent.parentId != null) {
            candidateArtistIds.add(parent.parentId!);
          }
          break;
        case FladderItemType.musicArtist:
          candidateArtistIds.add(parent.id);
          break;
        default:
          break;
      }
    }

    for (final albumId in candidateAlbumIds) {
      final album = await getSyncedItem(albumId);
      if (album == null || album.itemModel?.type != FladderItemType.musicAlbum) continue;

      final hasTracks = await _hasSyncedAudioDescendants(album.id);
      if (hasTracks) continue;

      if (album.parentId != null) {
        candidateArtistIds.add(album.parentId!);
      }

      await _deleteSyncedItemAndFiles(album);
    }

    for (final artistId in candidateArtistIds) {
      final artist = await getSyncedItem(artistId);
      if (artist == null || artist.itemModel?.type != FladderItemType.musicArtist) continue;

      final hasTracks = await _hasSyncedAudioDescendants(artist.id);
      if (hasTracks) continue;

      await _deleteSyncedItemAndFiles(artist);
    }
  }

  Future<int> updateItem(SyncedItem item) async {
    SyncedItem syncedItem = item;
    try {
      await ref.read(jellyApiProvider).userItemsItemIdUserDataPost(itemId: syncedItem.id, body: syncedItem.userData);
    } catch (e) {
      log('Error updating item: ${syncedItem.id}');
      syncedItem = syncedItem.copyWith(unSyncedData: true);
    }
    return _db.insertItem(syncedItem);
  }

  Future<void> queueDownloads(Iterable<SyncedItem> items, {
    TranscodeDownloadModel? transcodeModel,
    TranscodeMusicDownloadModel? musicTranscodeModel,
  }) async {
    final epoch = _offlineAccountEpoch;
    (Object, StackTrace)? firstError;
    for (final item in items) {
      if (!mounted || epoch != _offlineAccountEpoch || ref.read(userProvider)?.id != item.userId) break;
      try {
        await syncSyncedItem(item, transcodeModel: transcodeModel, musicTranscodeModel: musicTranscodeModel);
      } catch (error, stack) {
        firstError ??= (error, stack);
      }
    }
    if (firstError != null) Error.throwWithStackTrace(firstError.$1, firstError.$2);
  }

  Future<void> syncSyncedItem(
    SyncedItem syncedItem, {
    TranscodeDownloadModel? transcodeModel,
    TranscodeMusicDownloadModel? musicTranscodeModel,
  }) async {
    final model = syncedItem.itemModel;

    switch (model) {
      case AudioModel audio:
        await syncAudio(audio, musicTranscodeModel: musicTranscodeModel);
        return;
      case AlbumModel album:
        await syncAlbum(album, musicTranscodeModel: musicTranscodeModel);
        return;
      case ArtistModel artist:
        await syncArtist(artist, musicTranscodeModel: musicTranscodeModel);
        return;
      case PhotoAlbumModel album:
        await syncPhotoAlbum(album.id);
        return;
      case PhotoModel _:
        await syncPhotoFile(syncedItem);
        return;
      default:
        await syncFile(
          syncedItem,
          false,
          transcodeModel: transcodeModel,
          musicTranscodeModel: musicTranscodeModel,
        );
        return;
    }
  }

  Future<SyncedItem> deleteFullSyncFiles(SyncedItem syncedItem, DownloadTask? task) async {
    final itemType = syncedItem.itemModel?.type;

    if (itemType == FladderItemType.audio) {
      await _deleteSyncedItemAndFiles(syncedItem);
      ref.read(downloadTasksProvider(syncedItem.id).notifier).update((state) => DownloadStream.empty());
      await _cleanupOrphanedMusicParents([syncedItem]);
      refresh();
      return syncedItem;
    }

    if (itemType == FladderItemType.musicAlbum) {
      final nestedChildren = await getNestedChildren(syncedItem);
      final removedTracks = nestedChildren.where((element) => element.itemModel is AudioModel).toList();

      for (var i = 0; i < nestedChildren.length; i++) {
        final child = nestedChildren[i];
        await ref.read(backgroundDownloaderProvider).cancelTaskWithId(child.id);
        ref.read(downloadTasksProvider(child.id).notifier).update((state) => DownloadStream.empty());
      }

      await ref.read(backgroundDownloaderProvider).cancelTaskWithId(syncedItem.id);
      ref.read(downloadTasksProvider(syncedItem.id).notifier).update((state) => DownloadStream.empty());

      await _db.deleteAllItems([...nestedChildren, syncedItem]);

      if (await syncedItem.directory.exists()) {
        await syncedItem.directory.delete(recursive: true);
      }

      await _cleanupOrphanedMusicParents(removedTracks);

      refresh();
      return syncedItem;
    }

    await _cancelOfflineTrickPlay(syncedItem.directory.path);
    await ref.read(backgroundDownloaderProvider).cancelTaskWithId(syncedItem.id);
    await syncedItem.deleteDatFiles(ref);
    await _db.saveTrickPlay(syncedItem, null);

    syncedItem = syncedItem.copyWith(
      transcodeDownloadModel: null,
      fTrickPlayModel: null,
    );
    await updateItem(syncedItem);

    ref.read(downloadTasksProvider(syncedItem.id).notifier).update((state) => DownloadStream.empty());

    refresh();
    return syncedItem;
  }

  Future<bool?> syncFile(
    SyncedItem syncItem,
    bool skipDownload, {
    TranscodeDownloadModel? transcodeModel,
    TranscodeMusicDownloadModel? musicTranscodeModel,
  }) async {
    if (!skipDownload && syncItem.videoFile.existsSync()) {
      return true;
    }

    final globalTranscodeModel = ref.read(clientSettingsProvider.select((value) => value.transcodeDownloadModel));
    final globalMusicTranscodeModel =
        ref.read(clientSettingsProvider.select((value) => value.transcodeMusicDownloadModel));

    final effectiveTranscodeModel = transcodeModel ?? globalTranscodeModel;
    final effectiveMusicTranscodeModel = musicTranscodeModel ?? globalMusicTranscodeModel;

    final user = ref.read(userProvider);
    if (user == null || user.id != syncItem.userId) return null;
    final serverUrl = ref.read(serverUrlProvider);
    bool isCurrentAccount() => _matchesDownloadAccount(user, serverUrl);

    final item = syncItem.createItemModel(ref);
    if (item == null) return null;
    final isAudioItem = item is AudioModel;
    final streamModel = item.streamModel;
    final transcodeEnabled = isAudioItem ? effectiveMusicTranscodeModel.enabled : effectiveTranscodeModel.enabled;
    final maxBitrate =
        isAudioItem ? effectiveMusicTranscodeModel.maxBitrate.bitRate : effectiveTranscodeModel.maxBitrate.bitRate;
    final deviceProfile = isAudioItem
        ? (effectiveMusicTranscodeModel.enabled
            ? effectiveMusicTranscodeModel.deviceProfile
            : ref.read(videoProfileProvider))
        : (effectiveTranscodeModel.enabled ? effectiveTranscodeModel.deviceProfile : ref.read(videoProfileProvider));

    final playbackResponse = await FladderSnack.showResponse(
      api
          .itemsItemIdPlaybackInfoPost(
            itemId: syncItem.id,
            body: PlaybackInfoDto(
              userId: user.id,
              enableDirectPlay: !transcodeEnabled,
              enableDirectStream: !transcodeEnabled,
              enableTranscoding: true,
              autoOpenLiveStream: true,
              maxStreamingBitrate: transcodeEnabled ? maxBitrate : null,
              deviceProfile: deviceProfile,
              mediaSourceId: streamModel?.currentVersionStream?.id,
              audioStreamIndex: streamModel?.defaultAudioStreamIndex,
              subtitleStreamIndex: streamModel?.defaultSubStreamIndex,
            ),
          )
          .apiResult,
    );

    final playbackData = playbackResponse.data;
    if (playbackData == null) {
      log('No playback information received for offline download');
      return null;
    }
    if (!isCurrentAccount()) return null;

    final directory = await Directory(syncItem.directory.path).create(recursive: true);

    final newState = VideoStream.fromPlayBackInfo(playbackData, ref)?.copyWith();
    final subtitles = isAudioItem
        ? <SubStreamModel>[]
        : await saveExternalSubtitles(newState?.mediaStreamsModel?.subStreams, syncItem);

    final mediaSegments = isAudioItem ? null : (await api.mediaSegmentsGet(id: syncItem.id))?.body;

    syncItem = syncItem.copyWith(
      fChapters: await saveChapterImages(item.overview.chapters, directory) ?? [],
      subtitles: subtitles,
      videoFileName: transcodeEnabled
          ? syncItem.videoFileName?.replaceAll(
              path.extension(syncItem.videoFileName ?? ""),
              isAudioItem
                  ? effectiveMusicTranscodeModel.container.extension
                  : effectiveTranscodeModel.container.extension,
            )
          : syncItem.videoFileName,
      mediaSegments: mediaSegments,
      transcodeDownloadModel: isAudioItem ? null : effectiveTranscodeModel,
    );

    if (isAudioItem) {
      await writeMusicOverlayFile(syncItem, effectiveMusicTranscodeModel);
      await _saveSyncedLyrics(syncItem);
    } else {
      await writeOverlayFile(syncItem, effectiveTranscodeModel, subtitles);
    }

    if (!isCurrentAccount()) return null;
    await updateItem(syncItem);
    if (!isCurrentAccount()) return null;

    final mediaSource = playbackData.mediaSources?.firstOrNull;

    final String downloadUrl;
    if ((mediaSource?.supportsDirectStream ?? false) || (mediaSource?.supportsDirectPlay ?? false)) {
      final directOptions = {
        'Static': 'true',
        'mediaSourceId': mediaSource!.id,
      };
      downloadUrl = buildServerUrl(
        ref,
        pathSegments: [isAudioItem ? 'Audio' : 'Videos', mediaSource.id!, 'stream'],
        queryParameters: directOptions,
      );
      log('Using direct stream for offline download');
    } else if (mediaSource != null &&
        (mediaSource.supportsTranscoding ?? false) &&
        mediaSource.transcodingUrl != null) {
      downloadUrl = buildServerUrl(ref, relativeUrl: mediaSource.transcodingUrl);
      log('Using transcoded stream for offline download');
    } else {
      log('No supported playback method found');
      return null;
    }

    try {
      if (!skipDownload) {
        final curlHeaders = {
          ...user.credentials.header(ref),
          if (transcodeEnabled)
            ...(isAudioItem
                ? effectiveMusicTranscodeModel.curlHeaders(item.overview.runTime ?? Duration.zero, item: item)
                : effectiveTranscodeModel.curlHeaders(item.overview.runTime ?? Duration.zero, item: item)),
        };

        final downloadTask = DownloadTask(
          taskId: syncItem.id,
          metaData: jellyId,
          url: downloadUrl,
          directory: syncItem.directory.path,
          filename: syncItem.videoFileName,
          updates: Updates.statusAndProgress,
          baseDirectory: BaseDirectory.root,
          headers: curlHeaders,
          requiresWiFi: ref.read(clientSettingsProvider.select((value) => value.requireWifi)),
          retries: 3,
          allowPause: true,
        );

        final directoryPath = directory.path;
        final previousPreview = _offlineTrickPlay[directoryPath];
        final preview = isAudioItem ? null : _OfflineTrickPlay(isCurrentAccount);
        if (preview != null) _offlineTrickPlay[directoryPath] = preview;
        try {
          await previousPreview?.waitForCancellation();
          if (!(preview?.isCurrent ?? isCurrentAccount())) return null;
          final downloader = ref.read(backgroundDownloaderProvider);
          final currentTask = ref.read(downloadTasksProvider(syncItem.id));
          if (currentTask.task != null) await downloader.cancelTaskWithId(currentTask.id);
          if (!(preview?.isCurrent ?? isCurrentAccount())) return null;
          final enqueue = ref.read(backgroundDownloaderProvider.notifier).enqueueDownload(downloadTask);
          if (preview != null) preview.enqueue = enqueue;
          final queued = await enqueue;
          if (queued && preview != null && preview.isCurrent) {
            preview.done = _saveOfflineTrickPlay(syncItem, item, preview);
          }
          return queued;
        } finally {
          if (preview?.done == null && identical(_offlineTrickPlay[directoryPath], preview)) {
            _offlineTrickPlay.remove(directoryPath);
          }
        }
      }
    } catch (_) {
      log('Could not enqueue offline download');
      return null;
    }

    return null;
  }

  Future<void> _cancelOfflineTrickPlay(String directory) async {
    await _offlineTrickPlay[directory]?.waitForCancellation();
  }

  void _cancelOfflineTrickPlayForAccountChange() {
    for (final preview in _offlineTrickPlay.values) {
      preview.cancel();
    }
  }

  Future<void> cancelSyncTasks(List<DownloadTask> tasks) async {
    await Future.wait(tasks.map((task) => _cancelOfflineTrickPlay(task.directory)));
    await ref.read(backgroundDownloaderProvider).cancelAll(tasks: tasks);
  }

  Future<void> _saveOfflineTrickPlay(SyncedItem syncItem, ItemBaseModel item, _OfflineTrickPlay preview) async {
    Directory? tiles;
    var saved = false;
    try {
      if (!preview.isCurrent) return;
      final previous = await _db.readTrickPlay(syncItem);
      final oldModel = previous == null ? null : TrickPlayModel.fromJson(jsonDecode(previous));
      if (oldModel != null && await _hasOfflineTrickPlay(syncItem, oldModel)) return;
      if (!preview.isCurrent) return;
      final model = (await preview.requestMetadata(api.getTrickPlay(item: item, ref: ref)))?.body;
      if (!preview.isCurrent || model == null || model.images.isEmpty) return;

      final root = await syncItem.trickPlayDirectory.create(recursive: true);
      tiles = await root.createTemp('tiles-');
      if (!preview.isCurrent) return;
      final client = preview.client = http.Client();
      final images = <String>[];
      for (final (index, url) in model.images.indexed) {
        if (!preview.isCurrent) return;
        final response = await client.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
        if (!preview.isCurrent || response.statusCode != 200 || response.bodyBytes.isEmpty) return;
        final filename = 'tile_$index.jpg';
        await File(path.join(tiles.path, filename)).writeAsBytes(response.bodyBytes);
        images.add(path.relative(path.join(tiles.path, filename), from: syncItem.directory.path));
      }
      if (preview.isCurrent) {
        saved = await _db.saveTrickPlay(syncItem, model.copyWith(images: images), previous: previous) != 0;
        if (saved && oldModel != null) await _removeOldOfflineTrickPlay(root, oldModel);
      }
    } catch (error) {
      log('Failed to save offline previews for ${syncItem.id}: ${error.runtimeType}');
    } finally {
      preview.closeClient();
      if (!saved && tiles != null) {
        try {
          await tiles.delete(recursive: true);
        } on FileSystemException catch (error) {
          log('Failed to remove partial offline previews for ${syncItem.id}: ${error.runtimeType}');
        }
      }
      final directoryPath = syncItem.directory.path;
      if (identical(_offlineTrickPlay[directoryPath], preview)) _offlineTrickPlay.remove(directoryPath);
    }
  }

  Future<bool> _hasOfflineTrickPlay(SyncedItem item, TrickPlayModel model) async {
    if (model.images.isEmpty || model.images.length * model.imagesPerTile < model.thumbnailCount) return false;
    for (final image in model.images) {
      if (!await File(path.join(item.directory.path, image)).exists()) return false;
    }
    return true;
  }

  Future<void> _removeOldOfflineTrickPlay(Directory root, TrickPlayModel model) async {
    if (model.images.isEmpty) return;
    final parts = path.split(model.images.first);
    if (parts.length != 3 || parts[0] != SyncedItem.trickPlayPath || !parts[1].startsWith('tiles-')) return;
    final expected = model.images.indexed.every((tile) {
      final (index, file) = tile;
      return path.normalize(file) == path.join(SyncedItem.trickPlayPath, parts[1], 'tile_$index.jpg');
    });
    if (!expected) return;
    final directory = path.join(root.path, parts[1]);
    if (await FileSystemEntity.type(directory, followLinks: false) == FileSystemEntityType.directory) {
      await Directory(directory).delete(recursive: true);
    }
  }

  Future<void> removeAllSyncedData() async {
    await Future.wait(_offlineTrickPlay.keys.toList().map(_cancelOfflineTrickPlay));
    if (await mainDirectory.exists()) {
      await mainDirectory.delete(recursive: true);
    }
    await _db.clearDatabase();
    state = state.copyWith(items: []);
  }

  Future<void> updatePlaybackPosition({String? itemId, required Duration position}) async {
    if (itemId == null) return;

    final syncedItem = await _db.getItem(itemId).getSingleOrNull();
    if (syncedItem == null) return;

    final item = syncedItem.itemModel;
    if (item == null) return;

    final progress = position.inMilliseconds / (item.overview.runTime?.inMilliseconds ?? 0) * 100;

    final updatedItem = syncedItem.copyWith(
      userData: syncedItem.userData?.copyWith(
        playbackPositionTicks: position.toRuntimeTicks,
        progress: progress,
        played: UserData.isPlayed(position, item.overview.runTime ?? Duration.zero),
      ),
    );
    await _db.insertItem(updatedItem);
  }

  Future<void> updatePlayedItem(String? itemId,
      {DateTime? datePlayed, required bool played, bool responseSuccessful = false}) async {
    if (itemId == null) return;

    final syncedItem = _db.getItem(itemId).getSingleOrNull();
    syncedItem.then((item) async {
      if (item == null) return;
      final updatedUserData = item.userData?.copyWith(
        played: played,
        playbackPositionTicks: 0,
        progress: 0.0,
        lastPlayed: datePlayed ?? DateTime.now().toUtc(),
      );
      SyncedItem updatedItem = item.copyWith(userData: updatedUserData, unSyncedData: !responseSuccessful);

      List<SyncedItem> children = [];
      final shouldUpdateChildren = {FladderItemType.series, FladderItemType.season}.contains(item.itemModel?.type);
      if (shouldUpdateChildren) {
        // Update child items with the same played status, jellyfin server does this was well
        // when marking a series or season as played
        children = (await getNestedChildren(item))
            .map((e) => e.copyWith(
                  userData: e.userData?.copyWith(
                    played: played,
                    playbackPositionTicks: 0,
                    progress: 0.0,
                  ),
                ))
            .toList();
      }
      await _db.insertMultipleEntries([updatedItem, ...children]);
    });
  }

  Future<void> updateFavoriteItem(String? itemId, {required bool isFavorite, bool responseSuccessful = false}) async {
    if (itemId == null) return;

    final syncedItem = _db.getItem(itemId).getSingleOrNull();
    syncedItem.then((item) async {
      if (item == null) return;
      final updatedUserData = item.userData?.copyWith(isFavourite: isFavorite);
      final updatedItem = item.copyWith(userData: updatedUserData, unSyncedData: !responseSuccessful);
      await _db.insertItem(updatedItem);
    });
  }

  Future<void> _saveSyncedLyrics(SyncedItem syncItem) async {
    try {
      final response = await api.audioItemIdLyricsGet(itemId: syncItem.id);
      final lyrics = response.body;
      if (lyrics == null) {
        if (syncItem.lyricsFile.existsSync()) {
          await syncItem.lyricsFile.delete();
        }
        return;
      }

      await syncItem.lyricsFile.writeAsString(jsonEncode(lyrics.toJson()));
    } catch (e) {
      log('Error saving lyrics for item ${syncItem.id}: ${e.toString()}');
    }
  }

  /// Removes database entries whose sync folder no longer exists on disk.
  Future<void> cleanUpEmptyDatabaseEntries() async {
    try {
      if (kIsWeb) return;
      if (!mainDirectory.existsSync()) return;
      final entries = await _db.downloadLocations();
      final missingEntries = entries.where((entry) => !entry.directory.existsSync()).toList();
      if (missingEntries.isEmpty) return;
      await _db.deleteAllItems(missingEntries);
    } catch (e) {
      log('Error cleaning up empty database entries: ${e.toString()}');
    }
  }
}

extension SyncNotifierHelpers on SyncNotifier {
  Future<SyncedItem> createSyncItem(BaseItemDto response, {SyncedItem? parent}) async {
    final ItemBaseModel item = ItemBaseModel.fromBaseDto(response, ref);

    final syncItem = await getSyncedItem(item.id) ?? await _syncItemData(parent, item, response);

    return syncItem.copyWith(
      fileSize: syncItem.fileSize ?? response.mediaSources?.firstOrNull?.size ?? 0,
      videoFileName: syncItem.videoFileName ?? response.path?.universalBasename ?? "",
    );
  }

  Future<SyncedItem> _syncItemData(SyncedItem? parent, ItemBaseModel item, BaseItemDto response, {Directory? directory}) async {
    final Directory? parentDirectory = parent?.directory;

    directory ??= await Directory(path.joinAll([(parentDirectory ?? saveDirectory)?.path ?? "", item.id])).create(recursive: true);

    File dataFile = File(path.joinAll([directory.path, 'data.json']));
    await dataFile.writeAsString(jsonEncode(response.toJson()));
    final imageData = switch (item) {
      AudioModel _ => _audioImageDataFromParent(parent: parent, directory: directory),
      PhotoModel photo => await saveImageData(photo.thumbnail, directory),
      _ => await saveImageData(item.images, directory),
    };

    SyncedItem syncItem = SyncedItem(
      id: item.id,
      parentId: parent?.id,
      sortName: response.sortName,
      fImages: imageData,
      userId: ref.read(userProvider)?.id ?? "",
      path: directory.path,
      userData: item.userData,
    );
    return syncItem;
  }

  ImagesData? _audioImageDataFromParent({required SyncedItem? parent, required Directory directory}) {
    final parentImages = parent?.fImages;
    final parentDirectory = parent?.directory;

    if (parentImages == null || parentDirectory == null) return null;

    ImageData? rebasePath(ImageData? image) {
      final imagePath = image?.path;
      if (imagePath == null || imagePath.isEmpty) return null;

      final absoluteParentPath = path.join(parentDirectory.path, imagePath);
      final relativePath = path.relative(absoluteParentPath, from: directory.path);

      return image?.copyWith(path: relativePath);
    }

    return parentImages.copyWith(
      primary: () => rebasePath(parentImages.primary),
      logo: () => rebasePath(parentImages.logo),
      backDrop: () => (parentImages.backDrop ?? []).map((image) => rebasePath(image)).whereType<ImageData>().toList(),
    );
  }

  Future<SyncedItem?> syncMovie(
    ItemBaseModel item, {
    bool skipDownload = false,
    TranscodeDownloadModel? transcodeModel,
  }) async {
    final response = await api.usersUserIdItemsItemIdGetBaseItem(
      itemId: item.id,
    );

    final itemBaseModel = response.body;
    if (itemBaseModel == null) return null;

    SyncedItem syncItem = await createSyncItem(itemBaseModel);

    if (!syncItem.directory.existsSync()) return null;

    await _db.insertItem(syncItem);

    await syncFile(syncItem, skipDownload, transcodeModel: transcodeModel);

    return syncItem;
  }

  Future<SyncedItem?> syncAudio(
    AudioModel item, {
    bool skipDownload = false,
    SyncedItem? parent,
    TranscodeMusicDownloadModel? musicTranscodeModel,
  }) async {
    final existingSyncedItem = await getSyncedItem(item.id);
    if (existingSyncedItem != null && existingSyncedItem.videoFile.existsSync()) {
      return existingSyncedItem;
    }

    final response = await api.usersUserIdItemsItemIdGetBaseItem(
      itemId: item.id,
    );

    final itemBaseModel = response.body;
    if (itemBaseModel == null) return null;

    SyncedItem? albumParent = parent;
    if (albumParent == null && itemBaseModel.albumId != null) {
      final albumResponse = await api.usersUserIdItemsItemIdGetBaseItem(
        itemId: itemBaseModel.albumId!,
      );
      if (albumResponse.body != null) {
        SyncedItem? artistItem;
        if (albumResponse.body!.parentId != null) {
          final artistResponse = await api.usersUserIdItemsItemIdGetBaseItem(
            itemId: albumResponse.body!.parentId!,
          );
          if (artistResponse.body != null) {
            artistItem = await createSyncItem(artistResponse.bodyOrThrow);
            await _db.insertItem(artistItem);
          }
        }
        final albumItem = await createSyncItem(albumResponse.bodyOrThrow, parent: artistItem);
        await _db.insertItem(albumItem);
        albumParent = albumItem;
      }
    }

    SyncedItem syncItem = await createSyncItem(itemBaseModel, parent: albumParent);

    if (!syncItem.directory.existsSync()) return null;

    await _db.insertItem(syncItem);

    await syncFile(syncItem, skipDownload, musicTranscodeModel: musicTranscodeModel);

    return syncItem;
  }

  Future<SyncedItem?> syncAlbum(
    AlbumModel item, {
    bool skipDownload = false,
    SyncedItem? parent,
    TranscodeMusicDownloadModel? musicTranscodeModel,
  }) async {
    final response = await api.usersUserIdItemsItemIdGetBaseItem(
      itemId: item.id,
    );

    final itemBaseModel = response.body;
    if (itemBaseModel == null) return null;

    SyncedItem? artistItem = parent;
    if (artistItem == null && itemBaseModel.parentId != null) {
      final artistResponse = await api.usersUserIdItemsItemIdGetBaseItem(
        itemId: itemBaseModel.parentId!,
      );
      if (artistResponse.body != null) {
        artistItem = await createSyncItem(artistResponse.bodyOrThrow);
        await _db.insertItem(artistItem);
      }
    }

    final albumItem = await createSyncItem(itemBaseModel, parent: artistItem);
    if (!albumItem.directory.existsSync()) return null;

    final tracksResponse = await api.itemsGet(
      parentId: item.id,
      includeItemTypes: [BaseItemKind.audio],
      recursive: false,
      enableUserData: true,
      fields: [
        ItemFields.mediastreams,
        ItemFields.mediasources,
        ItemFields.overview,
        ItemFields.path,
        ItemFields.parentid,
        ItemFields.sortname,
      ],
    );

    final tracks = tracksResponse.body?.items ?? [];

    final Map<String, SyncedItem> newItems = {albumItem.id: albumItem};
    final Map<String, SyncedItem> itemsToDownload = {};

    for (var i = 0; i < tracks.length; i++) {
      final track = tracks[i];
      final trackDto = await api.usersUserIdItemsItemIdGetBaseItem(itemId: track.id);
      if (trackDto.body == null) continue;
      final syncedTrack = await createSyncItem(trackDto.bodyOrThrow, parent: albumItem);
      newItems[syncedTrack.id] = syncedTrack;
      if (!await syncedTrack.videoFile.exists()) {
        itemsToDownload[syncedTrack.id] = syncedTrack;
      }
    }

    await _db.insertMultipleEntries(newItems.values.toList());

    if (!skipDownload) {
      for (var i = 0; i < itemsToDownload.length; i++) {
        final track = itemsToDownload.values.elementAt(i);
        syncFile(track, false, musicTranscodeModel: musicTranscodeModel);
      }
    }

    return albumItem;
  }

  Future<SyncedItem?> syncArtist(
    ArtistModel item, {
    bool skipDownload = false,
    TranscodeMusicDownloadModel? musicTranscodeModel,
  }) async {
    final response = await api.usersUserIdItemsItemIdGetBaseItem(
      itemId: item.id,
    );

    final itemBaseModel = response.body;
    if (itemBaseModel == null) return null;

    final artistItem = await createSyncItem(itemBaseModel);
    if (!artistItem.directory.existsSync()) return null;

    final albumsResponse = await api.itemsGet(
      parentId: item.id,
      includeItemTypes: [BaseItemKind.musicalbum],
      recursive: false,
      enableUserData: true,
      fields: [
        ItemFields.mediastreams,
        ItemFields.mediasources,
        ItemFields.overview,
        ItemFields.path,
        ItemFields.parentid,
        ItemFields.sortname,
      ],
    );

    final albums = albumsResponse.body?.items ?? [];

    final Map<String, SyncedItem> newItems = {artistItem.id: artistItem};
    final Map<String, SyncedItem> itemsToDownload = {};

    for (var i = 0; i < albums.length; i++) {
      final album = albums[i];
      final albumDto = await api.usersUserIdItemsItemIdGetBaseItem(itemId: album.id);
      if (albumDto.body == null) continue;
      final syncedAlbum = await createSyncItem(albumDto.bodyOrThrow, parent: artistItem);
      newItems[syncedAlbum.id] = syncedAlbum;

      final tracksResponse = await api.itemsGet(
        parentId: album.id,
        includeItemTypes: [BaseItemKind.audio],
        recursive: false,
        enableUserData: true,
        fields: [
          ItemFields.mediastreams,
          ItemFields.mediasources,
          ItemFields.overview,
          ItemFields.path,
          ItemFields.parentid,
          ItemFields.sortname,
        ],
      );

      final tracks = tracksResponse.body?.items ?? [];

      for (var j = 0; j < tracks.length; j++) {
        final track = tracks[j];
        final trackDto = await api.usersUserIdItemsItemIdGetBaseItem(itemId: track.id);
        if (trackDto.body == null) continue;
        final syncedTrack = await createSyncItem(trackDto.bodyOrThrow, parent: syncedAlbum);
        newItems[syncedTrack.id] = syncedTrack;
        if (!await syncedTrack.videoFile.exists()) {
          itemsToDownload[syncedTrack.id] = syncedTrack;
        }
      }
    }

    await _db.insertMultipleEntries(newItems.values.toList());

    if (!skipDownload) {
      for (var i = 0; i < itemsToDownload.length; i++) {
        final track = itemsToDownload.values.elementAt(i);
        syncFile(track, false, musicTranscodeModel: musicTranscodeModel);
      }
    }

    return artistItem;
  }

  Future<SyncedItem?> syncPlaylist(
    PlaylistModel item, {
    bool skipDownload = false,
    TranscodeMusicDownloadModel? musicTranscodeModel,
  }) async {
    final response = await api.usersUserIdItemsItemIdGetBaseItem(
      itemId: item.id,
    );

    final itemBaseModel = response.body;
    if (itemBaseModel == null) return null;

    final playlistItem = await createSyncItem(itemBaseModel);
    if (!playlistItem.directory.existsSync()) return null;

    await _db.insertItem(playlistItem);

    final tracksResponse = await api.playlistsPlaylistIdItemsGet(
      playlistId: item.id,
      enableUserData: true,
      fields: [
        ItemFields.mediastreams,
        ItemFields.mediasources,
        ItemFields.overview,
        ItemFields.path,
        ItemFields.parentid,
        ItemFields.sortname,
      ],
    );

    final playlistTracks = tracksResponse.body?.items.whereType<AudioModel>().toList() ?? [];

    final childIds = playlistTracks.map((e) => e.id).whereType<String>().toList();

    for (final track in playlistTracks) {
      await syncAudio(track, skipDownload: skipDownload, musicTranscodeModel: musicTranscodeModel);
    }

    await writePlaylistChildrenOverlay(playlistItem, childIds);

    return playlistItem;
  }

  Future<SyncedItem?> syncSeries(
    SeriesModel item, {
    SeasonModel? season,
    EpisodeModel? episode,
    TranscodeDownloadModel? transcodeModel,
  }) async {
    final response = await api.usersUserIdItemsItemIdGetBaseItem(
      itemId: item.id,
    );

    List<SyncedItem> newItems = [];

    SyncedItem seriesItem = await createSyncItem(response.bodyOrThrow);
    newItems.add(seriesItem);
    if (!seriesItem.directory.existsSync()) return null;

    final seasonsResponse = await api.showsSeriesIdSeasonsGet(
      seriesId: item.id,
      isMissing: false,
      enableUserData: true,
      fields: [
        ItemFields.mediastreams,
        ItemFields.mediasources,
        ItemFields.overview,
        ItemFields.mediasourcecount,
        ItemFields.airtime,
        ItemFields.datecreated,
        ItemFields.datelastmediaadded,
        ItemFields.datelastrefreshed,
        ItemFields.sortname,
        ItemFields.seasonuserdata,
        ItemFields.externalurls,
        ItemFields.genres,
        ItemFields.parentid,
        ItemFields.path,
        ItemFields.chapters,
        ItemFields.trickplay,
      ],
    );

    final seasons = seasonsResponse.body?.items ?? [];

    for (var i = 0; i < seasons.length; i++) {
      final newSeason = seasons[i];
      final syncedSeason = await createSyncItem(newSeason, parent: seriesItem);
      newItems.add(syncedSeason);
      final episodesResponse = await api.showsSeriesIdEpisodesGet(
        isMissing: false,
        enableUserData: true,
        fields: [
          ItemFields.mediastreams,
          ItemFields.mediasources,
          ItemFields.overview,
          ItemFields.mediasourcecount,
          ItemFields.airtime,
          ItemFields.datecreated,
          ItemFields.datelastmediaadded,
          ItemFields.datelastrefreshed,
          ItemFields.sortname,
          ItemFields.seasonuserdata,
          ItemFields.externalurls,
          ItemFields.genres,
          ItemFields.parentid,
          ItemFields.path,
          ItemFields.chapters,
          ItemFields.trickplay,
        ],
        seasonId: newSeason.id,
        seriesId: seriesItem.id,
      );

      final episodes = episodesResponse.body?.items?.where((ep) => ep.seasonId == newSeason.id).toList() ?? [];

      newItems.addAll(await Future.wait(episodes.map((ep) => createSyncItem(ep, parent: syncedSeason))));
    }

    await _db.insertMultipleEntries(newItems);

    if (episode != null) {
      final target = newItems.firstWhereOrNull((entry) => entry.id == episode.id);
      if (target != null) await syncFile(target, false, transcodeModel: transcodeModel);
    } else if (season != null) {
      final children = await getChildren(season.id);
      await queueDownloads(children.where((entry) => entry.itemModel is EpisodeModel), transcodeModel: transcodeModel);
    }

    return seriesItem;
  }

  Future<SyncedItem?> syncPhotoAlbum(String? albumId, {PhotoModel? photo}) async {
    if (albumId == null || albumId.isEmpty) return null;

    final albumResponse = await api.usersUserIdItemsItemIdGetBaseItem(itemId: albumId);
    final albumDto = albumResponse.body;
    if (albumDto == null) return null;

    final albumSyncItem = await createSyncItem(albumDto);
    if (!albumSyncItem.directory.existsSync()) return null;

    final List<String> photoIds;
    if (photo != null) {
      photoIds = [photo.id];
    } else {
      final childrenResponse = await api.itemsGet(
        parentId: albumId,
        includeItemTypes: [
          BaseItemKind.photo,
          BaseItemKind.video,
        ],
        recursive: true,
      );
      photoIds = childrenResponse.body?.items.whereType<PhotoModel>().map((e) => e.id).toList() ?? [];
    }

    final Map<String, SyncedItem> newItems = {albumSyncItem.id: albumSyncItem};
    final Map<String, SyncedItem> itemsToDownload = {};

    for (final photoId in photoIds) {
      final photoResponse = await api.usersUserIdItemsItemIdGetBaseItem(itemId: photoId);
      final photoDto = photoResponse.body;
      if (photoDto == null) continue;
      final photoSyncItem = _withPhotoFileName(await createSyncItem(photoDto, parent: albumSyncItem), photoDto);
      newItems[photoSyncItem.id] = photoSyncItem;
      if (!await photoSyncItem.videoFile.exists()) {
        itemsToDownload[photoSyncItem.id] = photoSyncItem;
      }
    }

    await _db.insertMultipleEntries(newItems.values.toList());

    for (final photoItem in itemsToDownload.values) {
      syncPhotoFile(photoItem);
    }

    return albumSyncItem;
  }

  SyncedItem _withPhotoFileName(SyncedItem item, BaseItemDto dto) {
    if (item.videoFileName?.isNotEmpty == true) return item;
    final container = dto.container?.split(',').firstOrNull?.trim();
    final extension = container?.isNotEmpty == true ? container! : (dto.type == BaseItemKind.video ? 'mp4' : 'jpg');
    return item.copyWith(videoFileName: '${item.id}.$extension');
  }

  Future<bool?> syncPhotoFile(SyncedItem photoItem) async {
    if (photoItem.videoFile.existsSync()) return true;

    final user = ref.read(userProvider);
    if (user == null || user.id != photoItem.userId) return null;
    final serverUrl = ref.read(serverUrlProvider);

    final fileName = photoItem.videoFileName;
    if (fileName == null || fileName.isEmpty) return null;

    try {
      final currentTask = ref.read(downloadTasksProvider(photoItem.id));
      if (currentTask.task != null) {
        await ref.read(backgroundDownloaderProvider).cancelTaskWithId(currentTask.id);
      }

      await photoItem.directory.create(recursive: true);

      if (!_matchesDownloadAccount(user, serverUrl)) return null;
      final downloadTask = DownloadTask(
        taskId: photoItem.id,
        metaData: jellyId,
        url: buildServerUrl(ref, pathSegments: ['Items', photoItem.id, 'Download']),
        directory: photoItem.directory.path,
        filename: fileName,
        updates: Updates.statusAndProgress,
        baseDirectory: BaseDirectory.root,
        headers: user.credentials.header(ref),
        requiresWiFi: ref.read(clientSettingsProvider.select((value) => value.requireWifi)),
        retries: 3,
        allowPause: true,
      );

      return await ref.read(backgroundDownloaderProvider.notifier).enqueueDownload(downloadTask);
    } catch (_) {
      log('Offline photo download could not be queued.');
      return null;
    }
  }
}
