import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chopper/chopper.dart';
import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/credentials_model.dart';
import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/items/episode_model.dart';
import 'package:fladder/models/items/media_streams_model.dart';
import 'package:fladder/models/items/movie_model.dart';
import 'package:fladder/models/items/season_model.dart';
import 'package:fladder/models/items/series_model.dart';
import 'package:fladder/models/playback/offline_playback_model.dart';
import 'package:fladder/models/playback/playback_model.dart';
import 'package:fladder/models/settings/video_player_settings.dart';
import 'package:fladder/models/syncing/sync_item.dart';
import 'package:fladder/models/syncing/sync_settings_model.dart';
import 'package:fladder/profiles/default_profile.dart';
import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/captured_playback_reporting_provider.dart';
import 'package:fladder/providers/connectivity_provider.dart' as connectivity;
import 'package:fladder/providers/service_provider.dart';
import 'package:fladder/providers/settings/video_player_settings_provider.dart';
import 'package:fladder/providers/sync_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as path;

import 'support/playback_test_ref.dart';

class _Downloads extends StateNotifier<SyncSettingsModel>
    implements SyncNotifier {
  _Downloads() : super(SyncSettingsModel());

  final rows = <String, SyncedItem>{};
  Completer<SyncedItem?>? pendingLookup;

  @override
  Future<SyncedItem?> getSyncedItem(String? id) async {
    if (pendingLookup case final lookup?) return lookup.future;
    return rows[id];
  }

  @override
  Future<List<SyncedItem>> getSiblings(SyncedItem item) async => rows.values
      .where((row) => item.parentId != null && row.parentId == item.parentId)
      .toList();

  @override
  Future<List<SyncedItem>> getNestedChildren(SyncedItem? item) async {
    if (item == null) return [];
    final children = rows.values
        .where((row) => row.parentId == item.id)
        .toList();
    final descendants = await Future.wait(children.map(getNestedChildren));
    return [...children, ...descendants.expand((items) => items)];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CountingService extends JellyService {
  _CountingService(Ref ref, this.transport) : super(ref, transport);

  final JellyfinOpenApi transport;
  int detailRequests = 0;

  @override
  JellyfinOpenApi get api => transport;

  @override
  Future<Response<ItemBaseModel>> usersUserIdItemsItemIdGet({String? itemId}) {
    detailRequests++;
    return super.usersUserIdItemsItemIdGet(itemId: itemId);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late _Downloads downloads;
  late _CountingService service;
  late List<http.Request> requests;
  late JellyfinOpenApi transport;
  late _FixtureUser user;

  JellyfinOpenApi disconnectedTransport() => JellyfinOpenApi.create(
    baseUrl: Uri.https('fixture.invalid'),
    httpClient: MockClient((request) async {
      requests.add(request);
      throw const SocketException('synthetic network unavailable');
    }),
  );

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('jms-offline-playback-');
    addTearDown(() => temp.delete(recursive: true));
    downloads = _Downloads();
    requests = [];
    transport = disconnectedTransport();
    addTearDown(transport.client.dispose);
  });

  PlaybackModelHelper helper({
    required bool offline,
    bool captureAccount = false,
  }) {
    final account = AccountModel(
      name: 'Synthetic',
      id: 'user',
      avatar: '',
      lastUsed: DateTime(2026),
      credentials: CredentialsModel(
        token: 'synthetic',
        url: 'https://fixture.invalid',
      ),
    );
    final container = ProviderContainer.test(
      overrides: [
        jellyApiProvider.overrideWith(
          () => _TestApi((ref) => service = _CountingService(ref, transport)),
        ),
        userProvider.overrideWith(() => user = _FixtureUser(account)),
        capturedPlaybackApiFactoryProvider.overrideWithValue(
          (_) => disconnectedTransport(),
        ),
        syncProvider.overrideWith((ref) => downloads),
        connectivity.offlineStateProvider.overrideWithValue(offline),
        connectivity.connectivityStatusProvider.overrideWithValue(
          offline
              ? connectivity.ConnectionState.offline
              : connectivity.ConnectionState.wifi,
        ),
        videoPlayerSettingsProvider.overrideWith(
          (ref) => VideoPlayerSettingsProviderNotifier(ref)
            ..applyRestoredSettings(
              VideoPlayerSettingsModel(playerOptions: PlayerOptions.libMPV),
            ),
        ),
        videoProfileProvider.overrideWith(
          (ref) => defaultProfile(PlayerOptions.libMPV),
        ),
      ],
    );
    container.read(jellyApiProvider);
    if (captureAccount) return container.read(playbackModelHelper);
    return PlaybackModelHelper(ref: playbackTestRef(container));
  }

  Future<SyncedItem> save(
    ItemBaseModel item, {
    String? parentId,
    bool complete = true,
  }) async {
    final directory = await Directory(path.join(temp.path, item.id)).create();
    final row = SyncedItem(
      id: item.id,
      parentId: parentId,
      userId: 'user',
      path: directory.path,
      videoFileName: 'video.mkv',
      itemModel: item,
    );
    if (complete) await row.videoFile.writeAsBytes([0]);
    if (item is EpisodeModel) {
      await row.dataFile.writeAsString(
        jsonEncode(
          BaseItemDto(
            id: item.id,
            name: item.name,
            type: BaseItemKind.episode,
            seriesId: item.parentId,
            parentIndexNumber: item.season,
            indexNumber: item.episode,
            locationType: LocationType.filesystem,
          ).toJson(),
        ),
      );
    }
    return downloads.rows[item.id] = row;
  }

  MovieModel movie() => MovieModel.fromBaseDto(
    const BaseItemDto(
      id: 'movie',
      name: 'Downloaded movie',
      type: BaseItemKind.movie,
    ),
    null,
  );

  EpisodeModel episode(String id, int season, int number) =>
      EpisodeModel.fromBaseDto(
        BaseItemDto(
          id: id,
          name: id,
          type: BaseItemKind.episode,
          seriesId: 'series',
          parentIndexNumber: season,
          indexNumber: number,
          locationType: LocationType.filesystem,
        ),
        null,
      );

  test('known offline movie plays without looking up remote details', () async {
    final item = movie();
    final row = await save(item);

    final model = await helper(offline: true).createPlaybackModel(null, item);

    expect(model, isA<OfflinePlaybackModel>());
    expect(model?.media?.url, row.videoFile.path);
    expect(service.detailRequests, 0);
    expect(requests, isEmpty);
  });

  test('known offline episode plays without reaching the server', () async {
    final item = episode('episode', 1, 1);
    final row = await save(item);

    final model = await helper(offline: true).createPlaybackModel(null, item);

    expect(model, isA<OfflinePlaybackModel>());
    expect(model?.media?.url, row.videoFile.path);
    expect(service.detailRequests, 0);
    expect(requests, isEmpty);
  });

  test('offline selection rejects missing or deleting downloads', () async {
    final item = movie();
    final row = await save(item, complete: false);
    final playback = helper(offline: true);

    expect(await playback.createPlaybackModel(null, item), isNull);
    await row.videoFile.writeAsBytes([0]);
    downloads.rows[item.id] = row.copyWith(markedForDelete: true);
    expect(await playback.createPlaybackModel(null, item), isNull);
    expect(service.detailRequests, 0);
    expect(requests, isEmpty);
  });

  test(
    'an account switch discards the previous account download lookup',
    () async {
      final item = movie();
      final row = await save(item);
      final lookup = downloads.pendingLookup = Completer<SyncedItem?>();
      final playback = helper(offline: true, captureAccount: true);

      final result = playback.createPlaybackModel(null, item);
      user.switchAccount();
      lookup.complete(row);

      expect(await result, isNull);
      expect(service.detailRequests, 0);
      expect(requests, isEmpty);
    },
  );

  test(
    'failed remote details use the saved local track metadata without negotiating playback over HTTP',
    () async {
      final remoteItem = movie();
      final localItem = remoteItem.copyWith(
        mediaStreams: MediaStreamsModel(
          versionStreams: [
            VersionStreamModel(
              name: 'Downloaded version',
              id: 'local',
              index: 0,
              videoStreams: [],
              audioStreams: [],
              subStreams: [],
              defaultAudioStreamIndex: null,
              defaultSubStreamIndex: null,
            ),
          ],
        ),
      );
      final row = await save(localItem);

      final model = await helper(
        offline: false,
      ).createPlaybackModel(null, remoteItem);

      expect(model, isA<OfflinePlaybackModel>());
      expect(model?.media?.url, row.videoFile.path);
      expect(model?.mediaStreams?.currentVersionStream?.id, 'local');
      expect(requests.map((request) => request.method), ['GET']);
    },
  );

  test(
    'offline series lists only completed episodes and honors the season',
    () async {
      final series = SeriesModel.fromBaseDto(
        const BaseItemDto(
          id: 'series',
          name: 'Downloaded series',
          type: BaseItemKind.series,
        ),
        null,
      );
      await save(series, complete: false);
      for (final number in [1, 2]) {
        final season = SeasonModel.fromBaseDto(
          BaseItemDto(
            id: 'season-$number',
            name: 'Season $number',
            seriesId: series.id,
            type: BaseItemKind.season,
            indexNumber: number,
          ),
          null,
        );
        await save(season, parentId: series.id, complete: false);
        await save(
          episode('downloaded-$number', number, 2),
          parentId: season.id,
        );
      }
      await save(
        episode('partial', 1, 1),
        parentId: 'season-1',
        complete: false,
      );
      final deleted = await save(
        episode('deleted', 1, 3),
        parentId: 'season-1',
      );
      downloads.rows[deleted.id] = deleted.copyWith(markedForDelete: true);
      helper(offline: true);

      final response = await service.showsSeriesIdEpisodesGet(
        seriesId: series.id,
      );

      expect(response.body?.items?.map((item) => item.id), [
        'downloaded-1',
        'downloaded-2',
      ]);
      expect(response.body?.totalRecordCount, 2);
      final season = await service.showsSeriesIdEpisodesGet(
        seriesId: series.id,
        season: 2,
        seasonId: 'season-2',
      );
      expect(season.body?.items?.map((item) => item.id), ['downloaded-2']);
      expect(requests, isEmpty);
    },
  );

  test(
    'known offline season selects an actual file from that season',
    () async {
      final season = SeasonModel.fromBaseDto(
        const BaseItemDto(
          id: 'season-2',
          name: 'Season 2',
          seriesId: 'series',
          indexNumber: 2,
          type: BaseItemKind.season,
        ),
        null,
      );
      await save(season, parentId: 'series', complete: false);
      await save(episode('other-season', 1, 1), parentId: 'season-1');
      await save(
        episode('partial', 2, 1),
        parentId: season.id,
        complete: false,
      );
      final row = await save(episode('downloaded', 2, 2), parentId: season.id);

      final model = await helper(
        offline: true,
      ).createPlaybackModel(null, season);

      expect(model, isA<OfflinePlaybackModel>());
      expect(model?.item.id, 'downloaded');
      expect(model?.media?.url, row.videoFile.path);
      expect(requests, isEmpty);
    },
  );
}

class _TestApi extends JellyApi {
  _TestApi(this.create);

  final JellyService Function(Ref ref) create;

  @override
  JellyService build() => create(ref);
}

class _FixtureUser extends User {
  _FixtureUser(this.account);

  final AccountModel account;

  @override
  AccountModel build() => account;

  void switchAccount() => state = account.copyWith(id: 'other-user');
}
