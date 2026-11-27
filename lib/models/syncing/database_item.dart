import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart' show mergeSort;
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/items/chapters_model.dart';
import 'package:fladder/models/items/episode_model.dart';
import 'package:fladder/models/items/images_models.dart';
import 'package:fladder/models/items/item_shared_models.dart';
import 'package:fladder/models/items/media_segments_model.dart';
import 'package:fladder/models/items/media_streams_model.dart';
import 'package:fladder/models/items/season_model.dart';
import 'package:fladder/models/items/trick_play_model.dart';
import 'package:fladder/models/syncing/sync_item.dart';
import 'package:fladder/providers/user_provider.dart';

part 'database_item.g.dart';

const _databseName = 'syncedDatabase';

typedef PendingUserData = ({String id, String userId, String? path, String data});

@TableIndex(name: 'database_id', columns: {#userId, #id})
class DatabaseItems extends Table {
  TextColumn get userId => text().withLength(min: 1)();
  TextColumn get id => text().withLength(min: 1)();
  BoolColumn get syncing => boolean().withDefault(const Constant(false))();
  TextColumn get sortName => text().nullable()();
  TextColumn get parentId => text().nullable()();
  TextColumn get path => text().nullable()();
  IntColumn get fileSize => integer().nullable()();
  TextColumn get videoFileName => text().nullable()();
  TextColumn get trickPlayModel => text().nullable()();
  TextColumn get mediaSegments => text().nullable()();
  TextColumn get images => text().nullable()();
  TextColumn get chapters => text().nullable()();
  TextColumn get subtitles => text().nullable()();
  BoolColumn get unSyncedData => boolean().withDefault(const Constant(false))();
  TextColumn get userData => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {userId, id};
}

@DriftDatabase(tables: [DatabaseItems])
class AppDatabase extends _$AppDatabase {
  AppDatabase(this.ref, [QueryExecutor? executor]) : super(executor ?? _openConnection());

  final Ref ref;

  String get userId => ref.read(userProvider.select((value) => value?.id ?? ""));

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(beforeOpen: (details) async {
        if (details.wasCreated) return;
        // Older clients persisted the metadata preparation flag before committing the download tree.
        await (update(databaseItems)..where((row) => row.syncing.equals(true)))
            .write(const DatabaseItemsCompanion(syncing: Value(false)));
      });

  Future<void> clearDatabase() async {
    final dbPath = await getApplicationSupportDirectory();
    final dbFile = File(p.join(dbPath.path, '$_databseName.sqlite'));

    if (await dbFile.exists()) {
      await dbFile.delete(recursive: true);
    }
  }

  Future<List<SyncedItem>> getNestedChildrenRecursive(String rootId) async {
    final currentUserId = userId;
    final allChildren = <SyncedItem>[];
    var currentLevelIds = {rootId};
    final visited = {rootId};

    while (currentLevelIds.isNotEmpty) {
      final nextLevel = await managers.databaseItems
          .filter((f) => f.parentId.isIn(currentLevelIds) & f.userId.equals(currentUserId))
          .get();

      if (nextLevel.isEmpty) break;

      final syncedItems = _orderSeriesChildren(
        nextLevel.where((row) => visited.add(row.id)).map(databaseConverter).toList(),
      );
      allChildren.addAll(syncedItems);
      currentLevelIds = syncedItems.map((e) => e.id).toSet();
    }

    return allChildren;
  }

  Selectable<DatabaseItem> _itemRow(String id) =>
      select(databaseItems)..where((tbl) => tbl.id.equals(id) & tbl.userId.equals(userId));

  Selectable<SyncedItem> getItem(String id) => _itemRow(id).map(databaseConverter);

  Stream<SyncedItem?> watchItem(String id) =>
      _itemRow(id).watchSingleOrNull().distinct().map((row) => row == null ? null : databaseConverter(row));

  Selectable<SyncedItem> get getParentItems =>
      ((select(databaseItems)..where((tbl) => (tbl.parentId.isNull() & tbl.userId.equals(userId))))
            ..orderBy([(t) => OrderingTerm(expression: t.sortName)]))
          .map(databaseConverter);

  Future<List<SyncedItem>> downloadLocations() {
    final items = databaseItems;
    final account = userId;
    return (selectOnly(items)
          ..addColumns([items.id, items.path])
          ..where(items.userId.equals(account)))
        .map((row) => SyncedItem(id: row.read(items.id)!, path: row.read(items.path), userId: account))
        .get();
  }

  Future<List<SyncedItem>> getChildren(String parentId) async {
    final rows = await (select(databaseItems)
          ..where((tbl) => tbl.parentId.equals(parentId) & tbl.userId.equals(userId))
          ..orderBy([(t) => OrderingTerm.asc(t.sortName)]))
        .map(databaseConverter)
        .get();
    return _orderSeriesChildren(rows);
  }

  List<SyncedItem> _orderSeriesChildren(List<SyncedItem> items) {
    ({int season, int episode})? position(SyncedItem item) => switch (item.itemModel) {
          SeasonModel(:final season) => (season: season, episode: -1),
          EpisodeModel(:final season, :final episode) => (season: season, episode: episode),
          _ => null,
        };
    if (items.length < 2 || !items.any((item) => position(item) != null)) return items;
    mergeSort(items, compare: (a, b) {
      final left = position(a);
      final right = position(b);
      if (left == null) return right == null ? 0 : 1;
      if (right == null) return -1;
      final season = left.season.compareTo(right.season);
      if (season != 0) return season;
      final episode = left.episode.compareTo(right.episode);
      if (episode != 0) return episode;
      final title = (a.sortName ?? a.itemModel!.name).compareTo(b.sortName ?? b.itemModel!.name);
      return title != 0 ? title : a.id.compareTo(b.id);
    });
    return items;
  }

  Future<int> insertItem(SyncedItem item) => into(databaseItems).insertOnConflictUpdate(toDataBaseItem(item));

  Future<List<PendingUserData>> pendingUserData(String userId) {
    final items = databaseItems;
    return (selectOnly(items)
          ..addColumns([items.id, items.path, items.userData])
          ..where(items.userId.equals(userId) & items.unSyncedData.equals(true) & items.userData.isNotNull())
          ..orderBy([OrderingTerm.asc(items.sortName)]))
        .map((row) =>
            (id: row.read(items.id)!, userId: userId, path: row.read(items.path), data: row.read(items.userData)!))
        .get();
  }

  Future<int> acknowledgeUserData(PendingUserData pending) => (update(databaseItems)
        ..where((row) =>
            row.id.equals(pending.id) &
            row.userId.equals(pending.userId) &
            row.path.equalsNullable(pending.path) &
            row.unSyncedData.equals(true) &
            row.userData.equals(pending.data)))
      .write(const DatabaseItemsCompanion(unSyncedData: Value(false)));

  Expression<bool> _matchesDownload(DatabaseItems row, SyncedItem item) =>
      row.id.equals(item.id) & row.userId.equals(item.userId) & row.path.equalsNullable(item.path);

  Future<void> refreshMetadata(SyncedItem original, SyncedItem updated) => batch((batch) {
        final fields = toDataBaseItem(updated);
        batch.update(databaseItems, DatabaseItemsCompanion(
          sortName: fields.sortName, images: fields.images, syncing: const Value(false),
        ), where: (row) => _matchesDownload(row, original));
        // A download or offline playback update can finish during the network request.
        if (!original.unSyncedData && updated.userData != original.userData) {
          batch.update(databaseItems, DatabaseItemsCompanion(userData: fields.userData),
              where: (row) => _matchesDownload(row, original) & row.unSyncedData.equals(false) &
                  row.userData.equalsNullable(toDataBaseItem(original).userData.value));
        }
      });

  Future<String?> readTrickPlay(SyncedItem item) => (selectOnly(databaseItems)
        ..addColumns([databaseItems.trickPlayModel])
        ..where(_matchesDownload(databaseItems, item)))
      .map((row) => row.read(databaseItems.trickPlayModel))
      .getSingleOrNull();

  Future<int> saveTrickPlay(SyncedItem item, TrickPlayModel? model, {String? previous}) => (update(databaseItems)
        ..where((row) =>
            _matchesDownload(row, item) &
            (model == null ? const Constant(true) : row.trickPlayModel.equalsNullable(previous))))
      .write(DatabaseItemsCompanion(trickPlayModel: Value(model == null ? null : jsonEncode(model.toJson()))));

  Future<List<SyncedItem>> getNestedChildren(SyncedItem root) async {
    final itemType = root.createItemModel(ref)?.type;

    if (itemType == null) return [];

    final int maxDepth = switch (itemType) {
      FladderItemType.season => 1,
      FladderItemType.series => 2,
      FladderItemType.musicArtist => 2,
      FladderItemType.musicAlbum => 1,
      _ => 0,
    };

    final all = <SyncedItem>[];
    List<SyncedItem> toProcess = [root];

    if (maxDepth == 0) {
      return [];
    }

    for (var i = 0; i < maxDepth; i++) {
      final futures = toProcess.map((item) => getChildren(item.id));
      final resultsList = await Future.wait(futures);

      final children = resultsList.expand((r) => r).toList();

      if (children.isEmpty) break;

      all.addAll(children);
      toProcess = children;
    }

    return all;
  }

  Future<void> insertMultipleEntries(List<SyncedItem> items) async {
    await batch((batch) {
      batch.insertAllOnConflictUpdate(databaseItems, items.map(toDataBaseItem));
    });
  }

  Future<void> deleteAllItems(List<SyncedItem> items) async {
    await batch((batch) {
      for (final item in items) {
        batch.deleteWhere(databaseItems, (row) => _matchesDownload(row, item));
      }
    });
  }

  DatabaseItemsCompanion toDataBaseItem(SyncedItem item) {
    return DatabaseItemsCompanion(
      id: Value(item.id),
      parentId: Value(item.parentId),
      syncing: Value(item.syncing),
      userId: Value(item.userId),
      path: Value(item.path),
      fileSize: Value(item.fileSize),
      sortName: Value(item.sortName),
      videoFileName: Value(item.videoFileName),
      // Preview publication has its own update so stale item metadata cannot replace it.
      mediaSegments: Value(item.mediaSegments != null ? jsonEncode(item.mediaSegments?.toJson()) : null),
      images: Value(item.fImages != null ? jsonEncode(item.fImages?.toJson()) : null),
      chapters: Value(jsonEncode(item.fChapters.map((e) => e.toJson()).toList())),
      subtitles: Value(jsonEncode(item.subtitles.map((e) => e.toJson()).toList())),
      userData: Value(item.userData != null ? jsonEncode(item.userData?.toJson()) : null),
      unSyncedData: Value(item.unSyncedData),
    );
  }

  SyncedItem databaseConverter(DatabaseItem dataItem) {
    final syncedItem = SyncedItem(
      id: dataItem.id,
      userId: dataItem.userId,
      parentId: dataItem.parentId,
      sortName: dataItem.sortName,
      syncing: dataItem.syncing,
      path: dataItem.path,
      fileSize: dataItem.fileSize,
      videoFileName: dataItem.videoFileName,
      fTrickPlayModel:
          dataItem.trickPlayModel != null ? TrickPlayModel.fromJson(jsonDecode(dataItem.trickPlayModel!)) : null,
      mediaSegments:
          dataItem.mediaSegments != null ? MediaSegmentsModel.fromJson(jsonDecode(dataItem.mediaSegments!)) : null,
      fImages: dataItem.images != null ? ImagesData.fromJson(jsonDecode(dataItem.images!)) : null,
      fChapters: (dataItem.chapters != null && dataItem.chapters!.isNotEmpty)
          ? (jsonDecode(dataItem.chapters!) as List).map((e) => Chapter.fromJson(e)).toList()
          : [],
      subtitles: (dataItem.subtitles != null && dataItem.subtitles!.isNotEmpty)
          ? (jsonDecode(dataItem.subtitles!) as List).map((e) => SubStreamModel.fromJson(e)).toList()
          : [],
      userData: dataItem.userData != null ? UserData.fromJson(jsonDecode(dataItem.userData!)) : null,
      unSyncedData: dataItem.unSyncedData,
    );

    return syncedItem.copyWith(
      itemModel: syncedItem.createItemModel(ref),
    );
  }

  static QueryExecutor _openConnection() {
    return driftDatabase(
      name: _databseName,
      native: const DriftNativeOptions(
        databaseDirectory: getApplicationSupportDirectory,
      ),
      web: DriftWebOptions(
        sqlite3Wasm: Uri.parse('sqlite3.wasm'),
        driftWorker: Uri.parse('drift_worker.dart.js'),
      ),
    );
  }
}
