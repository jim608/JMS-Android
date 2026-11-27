import 'dart:async';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart' as api;
import 'package:fladder/localization_delegates.dart';
import 'package:fladder/models/items/album_model.dart';
import 'package:fladder/models/items/audio_model.dart';
import 'package:fladder/models/items/episode_model.dart';
import 'package:fladder/models/items/images_models.dart';
import 'package:fladder/models/items/series_model.dart';
import 'package:fladder/models/syncing/sync_item.dart';
import 'package:fladder/models/syncing/sync_settings_model.dart';
import 'package:fladder/providers/connectivity_provider.dart' as network;
import 'package:fladder/providers/sync/sync_provider_helpers.dart';
import 'package:fladder/providers/sync_provider.dart';
import 'package:fladder/screens/shared/fladder_notification_overlay.dart';
import 'package:fladder/screens/syncing/sync_item_details.dart';
import 'package:fladder/screens/syncing/widgets/sync_status_overlay.dart';
import 'package:fladder/screens/syncing/widgets/synced_audio_item.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout_model.dart';
import 'package:fladder/util/fladder_image.dart';
import 'package:fladder/util/localization_helper.dart';
import 'package:fladder/util/poster_defaults.dart';
import 'package:fladder/widgets/shared/pull_to_refresh.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:transparent_image/transparent_image.dart';

class _AlbumArt extends ImageData {
  _AlbumArt(String id) : super(key: id);
  @override
  final imageProvider = MemoryImage(kTransparentImage);
}

class _Downloads extends StateNotifier<SyncSettingsModel> implements SyncNotifier {
  _Downloads() : super(SyncSettingsModel());

  final rows = StreamController<SyncedItem?>.broadcast();
  var refreshResult = Completer<SyncedItem>();
  var children = <SyncedItem>[];
  final albums = <String, Completer<SyncedItem?>>{};

  @override
  Future<SyncedItem?> getSyncedItem(String? id) => albums.putIfAbsent(id!, Completer<SyncedItem?>.new).future;

  @override
  Stream<SyncedItem?> watchItem(String id) => rows.stream.where((item) => item?.id == id);

  @override
  Future<List<SyncedItem>> getChildrenForItem(SyncedItem item) async => children;

  @override
  Future<List<SyncedItem>> getNestedChildren(SyncedItem? item) async => children;

  @override
  Future<SyncedItem> refreshSyncItem(SyncedItem item) => refreshResult.future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('an offline track uses its current parent album for missing artwork', (tester) async {
    final downloads = _Downloads();
    addTearDown(downloads.rows.close);
    final audio = AudioModel.fromBaseDto(const api.BaseItemDto(id: 'song', name: '海邊'), null);
    final row = SyncedItem(id: audio.id, userId: 'viewer', parentId: 'album-A', itemModel: audio);
    final selected = ValueNotifier(row);
    addTearDown(selected.dispose);
    SyncedItem album(String id) {
      final model = AlbumModel.fromBaseDto(
        api.BaseItemDto(id: id),
        null,
      ).copyWith(images: ImagesData(primary: _AlbumArt(id)));
      return SyncedItem(id: id, userId: row.userId, itemModel: model);
    }

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          syncProvider.overrideWith((_) => downloads),
          syncedItemProvider(audio).overrideWith((_) => const Stream.empty()),
        ],
        child: MaterialApp(
          localizationsDelegates: FladderLocalizations.localizationsDelegates,
          home: Scaffold(
            body: ValueListenableBuilder<SyncedItem>(
              valueListenable: selected,
              builder: (_, item, _) => SyncedAudioItem(audio: audio, syncedItem: item),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(downloads.albums.keys, ['album-A']);
    selected.value = row.copyWith(parentId: 'album-B');
    await tester.pump();
    downloads.albums['album-B']!.complete(album('album-B'));
    await tester.pump();
    await tester.pump();
    expect(tester.widget<FladderImage>(find.byType(FladderImage)).image?.key, 'album-B');
    downloads.albums['album-A']!.complete(album('album-A'));
    await tester.pump();
    expect(tester.widget<FladderImage>(find.byType(FladderImage)).image?.key, 'album-B');
  });

  testWidgets('open download details follow local metadata and can close during refresh', (tester) async {
    final downloads = _Downloads();
    final series = SeriesModel.fromBaseDto(const api.BaseItemDto(id: 'series', name: '海邊的故事'), null);
    final item = SyncedItem(id: series.id, userId: 'viewer', syncing: true, itemModel: series);
    addTearDown(downloads.rows.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          syncProvider.overrideWith((_) => downloads),
          network.connectivityStatusProvider.overrideWithValue(network.ConnectionState.offline),
        ],
        child: MaterialApp(
          localizationsDelegates: FladderLocalizations.localizationsDelegates,
          builder: (_, child) => AdaptiveLayout(
            data: const AdaptiveLayoutModel(
              viewSize: ViewSize.phone,
              layoutMode: LayoutMode.single,
              inputDevice: InputDevice.touch,
              platform: TargetPlatform.android,
              isDesktop: false,
              posterDefaults: PosterDefaults(size: 240, ratio: .55),
              controller: {},
              sideBarWidth: 0,
              topBarHeight: 0,
              statusBarHeight: 28,
            ),
            child: child!,
          ),
          home: Scaffold(body: SyncItemDetails(syncItem: item)),
        ),
      ),
    );
    await tester.pump();
    final localized = tester.element(find.byType(SyncItemDetails)).localized;
    expect(find.text(series.name).hitTestable(), findsOneWidget);
    expect(find.bySemanticsLabel(localized.syncOverlaySyncing), findsOneWidget);
    final finished = item.copyWith(syncing: false);
    downloads.rows.add(finished);
    await tester.pump();
    await tester.pump();
    expect(tester.widget<SyncStatusOverlay>(find.byType(SyncStatusOverlay)).syncedItem.syncing, isFalse);
    expect(find.bySemanticsLabel(localized.syncOverlaySyncing), findsNothing);
    final episode = EpisodeModel.fromBaseDto(
      const api.BaseItemDto(id: 'episode-one', name: '新的第一集', indexNumber: 1, parentIndexNumber: 1),
      null,
    );
    downloads.children = [SyncedItem(id: episode.id, parentId: series.id, userId: item.userId, itemModel: episode)];
    expect(find.text(episode.name), findsNothing);
    final refreshChildren = tester.widget<PullToRefresh>(find.byType(PullToRefresh)).onRefresh!();
    downloads.refreshResult.complete(finished);
    await refreshChildren;
    await tester.pump();
    await tester.pump();
    expect(find.text(episode.name), findsWidgets);
    downloads.refreshResult = Completer<SyncedItem>();
    final failed = tester.widget<PullToRefresh>(find.byType(PullToRefresh)).onRefresh!();
    downloads.refreshResult.completeError(StateError('offline'));
    await failed;
    await tester.pump();
    expect(find.text(localized.unableToSyncItem(series.name)), findsOneWidget);
    expect(find.text(series.name).hitTestable(), findsOneWidget);
    FladderSnack().clearAll();
    downloads.refreshResult = Completer<SyncedItem>();
    final pending = tester.widget<PullToRefresh>(find.byType(PullToRefresh)).onRefresh!();
    await tester.pumpWidget(const SizedBox.shrink());
    downloads.refreshResult.complete(item.copyWith(syncing: false));
    await pending;
    expect(tester.takeException(), isNull);
  });
}
