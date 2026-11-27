import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:chopper/chopper.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/credentials_model.dart';
import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/items/item_shared_models.dart';
import 'package:fladder/models/items/media_segments_model.dart';
import 'package:fladder/models/items/media_streams_model.dart';
import 'package:fladder/models/items/season_model.dart';
import 'package:fladder/models/items/series_model.dart';
import 'package:fladder/models/items/trick_play_model.dart';
import 'package:fladder/models/syncing/database_item.dart';
import 'package:fladder/models/syncing/sync_item.dart';
import 'package:fladder/models/syncing/sync_settings_model.dart';
import 'package:fladder/models/syncing/transcode_download_model.dart';
import 'package:fladder/models/syncing/transcode_music_download_model.dart';
import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/connectivity_provider.dart';
import 'package:fladder/providers/service_provider.dart';
import 'package:fladder/providers/settings/client_settings_provider.dart';
import 'package:fladder/providers/sync/background_download_provider.dart';
import 'package:fladder/providers/sync/sync_provider_media.dart';
import 'package:fladder/providers/sync_provider.dart';
import 'package:fladder/providers/user_provider.dart';

class _FixtureUser extends User {
  @override
  AccountModel? build() => null;

  void setAccount(AccountModel account) => state = account;
}

class _FixtureConnectivity extends ConnectivityStatus {
  @override
  ConnectionState build() => ConnectionState.wifi;
  void disconnect() => state = ConnectionState.offline;
}

class _FixtureJellyApi extends JellyApi {
  _FixtureJellyApi(this.service);
  final JellyService service;

  @override
  JellyService build() => service;
}

class _FixtureBackgroundDownloader extends BackgroundDownloader {
  _FixtureBackgroundDownloader(this.downloader);
  final FileDownloader downloader;

  @override
  FileDownloader build() => downloader;
}

class _Notifier extends SyncNotifier {
  _Notifier(super.ref, super.mobileDirectory, this.database) : super(database: database);

  final AppDatabase database;

  @override
  set state(SyncSettingsModel value) {}

  @override
  Future<int> updateItem(SyncedItem item) => database.insertItem(item);
}

class _QueueProbe extends _Notifier {
  _QueueProbe(super.ref, super.mobileDirectory, super.database, this.onItem);
  final Future<void> Function(SyncedItem) onItem;

  @override
  Future<void> syncSyncedItem(SyncedItem item, {
    TranscodeDownloadModel? transcodeModel,
    TranscodeMusicDownloadModel? musicTranscodeModel,
  }) => onItem(item);
}

class _FixturePaths extends PathProviderPlatform {
  _FixturePaths(this.path);
  final String path;

  @override
  Future<String?> getTemporaryPath() async => path;

  @override
  Future<String?> getApplicationSupportPath() async => path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

class _Downloader extends Fake implements FileDownloader {
  _Downloader(this.events);
  final List<String> events;
  final enqueuedIds = <String>[];
  DownloadTask? downloadTask;

  @override
  Future<bool> enqueue(Task task) async {
    enqueuedIds.add(task.taskId);
    downloadTask = task as DownloadTask;
    events.add('media');
    return true;
  }

  @override
  Future<bool> cancelAll({Iterable<Task>? tasks, String? group}) async => true;

  @override
  Future<bool> cancelTaskWithId(String taskId) async => true;
}

class _SeasonApi extends _Api {
  final firstRequest = Completer<void>();
  final allowFirst = Completer<void>();

  @override
  Future<Response<PlaybackInfoResponse>> itemsItemIdPlaybackInfoPost({
    required String? itemId,
    required PlaybackInfoDto? body,
  }) async {
    if (itemId == 'ep1') {
      firstRequest.complete();
      await allowFirst.future;
    }
    return super.itemsItemIdPlaybackInfoPost(itemId: itemId, body: body);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final children = switch (invocation.memberName) {
      #showsSeriesIdSeasonsGet => [details['season']!],
      #showsSeriesIdEpisodesGet => [details['ep2']!, details['ep1']!],
      _ => null,
    };
    if (children == null) return super.noSuchMethod(invocation);
    return Future.value(Response(http.Response('', 200), BaseItemDtoQueryResult(items: children)));
  }

  @override
  Future<Response<TrickPlayModel>?> getTrickPlay({required ItemBaseModel? item, int? width, required Ref ref}) async => null;
}

class _Api extends Fake implements JellyService {
  _Api({this.manifestRequested, this.pendingManifest});

  final Completer<void>? manifestRequested;
  final Future<Response<TrickPlayModel>?>? pendingManifest;
  final details = <String, BaseItemDto>{};
  final requestedDetails = <String>[];

  @override
  Future<Response<BaseItemDto>> usersUserIdItemsItemIdGetBaseItem({String? itemId}) async {
    requestedDetails.add(itemId!);
    return Response(http.Response('', 200), details[itemId]!);
  }

  @override
  Future<Response<PlaybackInfoResponse>> itemsItemIdPlaybackInfoPost({
    required String? itemId,
    required PlaybackInfoDto? body,
  }) async => Response(
    http.Response('', 200),
    const PlaybackInfoResponse(mediaSources: [MediaSourceInfo(id: 'source', supportsDirectPlay: true)]),
  );

  @override
  Future<Response<MediaSegmentsModel>?> mediaSegmentsGet({required String id}) async => null;

  @override
  Future<Response<TrickPlayModel>?> getTrickPlay({required ItemBaseModel? item, int? width, required Ref ref}) async {
    manifestRequested?.complete();
    if (pendingManifest case final pending?) return pending;
    return Response(
      http.Response('', 200),
      TrickPlayModel(
        width: 10,
        height: 10,
        tileWidth: 1,
        tileHeight: 1,
        thumbnailCount: 1,
        interval: const Duration(seconds: 5),
        images: ['https://fixture.invalid/tile.jpg'],
      ),
    );
  }
}

SubStreamModel _subtitle(int index) => SubStreamModel(
  name: 'Chinese',
  id: 'track-$index',
  title: 'Chinese',
  displayTitle: 'Chinese',
  language: 'chi',
  codec: 'ass',
  url: 'https://fixture.invalid/subtitle/$index',
  isDefault: false,
  isExternal: true,
  index: index,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late ProviderContainer container;
  late Ref ref;
  late _Notifier notifier;
  late SyncedItem item;
  late AppDatabase database;
  late _Api service;
  late _Downloader downloadFixture;

  void setAccount(AccountModel account) => (container.read(userProvider.notifier) as _FixtureUser).setAccount(account);
  void setServer(String serverUrl) => container.read(serverUrlProvider.notifier).state = serverUrl;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('jms-offline-test-');
    service = _Api();
    downloadFixture = _Downloader([]);
    container = ProviderContainer(
      overrides: [
        userProvider.overrideWith(_FixtureUser.new),
        connectivityStatusProvider.overrideWith(_FixtureConnectivity.new),
        serverUrlProvider.overrideWith((ref) => null),
        jellyApiProvider.overrideWith(() => _FixtureJellyApi(service)),
        backgroundDownloaderProvider.overrideWith(() => _FixtureBackgroundDownloader(downloadFixture)),
      ],
    );
    final fixture = Provider<_Notifier>((providerRef) {
      ref = providerRef;
      database = AppDatabase(ref, NativeDatabase.memory());
      return _Notifier(ref, directory, database);
    });
    notifier = container.read(fixture);
    item = SyncedItem(id: 'movie', userId: 'user', path: directory.path, videoFileName: 'movie.mkv');
  });

  tearDown(() async {
    notifier.dispose();
    container.dispose();
    await database.close();
    await directory.delete(recursive: true);
  });

  test('same-label offline subtitles keep separate contents', () async {
    final tracks = await http.runWithClient(
      () => notifier.saveExternalSubtitles([_subtitle(4), _subtitle(7)], item),
      () => MockClient((request) async => http.Response(request.url.pathSegments.last, 200)),
    );

    expect(tracks.map((track) => track.url).toSet(), hasLength(2));
    expect(await File(tracks.first.url!).readAsString(), '4');
    expect(await File(tracks.last.url!).readAsString(), '7');
  });

  Future<_Downloader> prepareSync(List<String> events, {_Api? api}) async {
    downloadFixture = _Downloader(events);
    service = api ?? _Api();
    setServer('https://fixture.invalid');
    setAccount(
      AccountModel(
        name: 'Synthetic',
        id: 'user',
        avatar: '',
        lastUsed: DateTime(2026),
        credentials: CredentialsModel(token: 'synthetic', url: 'https://fixture.invalid'),
      ),
    );
    await item.dataFile.writeAsString('{"Id":"movie","Name":"Synthetic movie","Type":"Movie","MediaType":"Video"}');
    return downloadFixture;
  }

  test('metadata preparation publishes no partial root before the caller commits', () async {
    await prepareSync([]);
    await container.read(clientSettingsProvider.notifier).setSyncPath(directory.path);
    const dto = BaseItemDto(id: 'track', name: 'Track', type: BaseItemKind.audio, path: '/library/track.flac');
    final prepared = await notifier.createSyncItem(dto);
    expect(await prepared.dataFile.exists(), isTrue);
    expect(await notifier.getSyncedItem('track'), isNull);
    await database.insertItem(prepared.copyWith(fileSize: null, videoFileName: null));
    final retried = await notifier.createSyncItem(dto);
    await database.insertItem(retried);
    final committed = await notifier.getSyncedItem('track');
    expect(committed?.syncing, isFalse);
    expect(committed?.videoFileName, 'track.flac');
  });

  test('metadata recovery on reopen clears abandoned flags and preserves the download', () async {
    await database.close();
    final file = File(path.join(directory.path, 'old.sqlite'));
    database = AppDatabase(ref, NativeDatabase(file));
    final saved = item.copyWith(syncing: true, unSyncedData: true, fileSize: 3);
    await saved.videoFile.writeAsBytes([1, 2, 3]);
    await database.insertItem(saved);
    await database.close();
    database = AppDatabase(ref, NativeDatabase(file));
    final row = await database.select(database.databaseItems).getSingle();
    expect(row.syncing, isFalse);
    expect(row.unSyncedData, isTrue);
    expect(row.fileSize, 3);
    expect(row.path, saved.path);
    expect(row.videoFileName, saved.videoFileName);
    expect(await saved.videoFile.readAsBytes(), [1, 2, 3]);
  });

  test('metadata for child rows is not decoded when refreshing the downloads root list', () async {
    await prepareSync([]);
    final child = item.copyWith(id: 'child', parentId: item.id, path: path.join(directory.path, 'child'));
    await child.directory.create();
    await child.dataFile.writeAsString('{');
    await database.insertMultipleEntries([item, child]);
    await notifier.refresh();
  });

  test('watching one download skips unrelated episode writes and reports its own changes', () async {
    await prepareSync([]);
    await database.insertItem(item);
    final events = <String?>[];
    final first = Completer<void>();
    final edited = Completer<void>();
    final removed = Completer<void>();
    final subscription = notifier.watchItem(item.id).listen((row) {
      final label = row == null ? null : row.sortName ?? 'initial';
      events.add(label);
      if (!first.isCompleted) first.complete();
      if (label == 'updated' && !edited.isCompleted) edited.complete();
      if (row == null && !removed.isCompleted) removed.complete();
    });
    try {
      await first.future;
      await database.insertItem(item.copyWith(id: 'unrelated', parentId: 'season'));
      await database.getItem('unrelated').watchSingle().first;
      await database.insertItem(item.copyWith(sortName: 'updated'));
      await edited.future;
      await database.deleteAllItems([item]);
      await removed.future;
      expect(events, ['initial', 'updated', null]);
    } finally {
      await subscription.cancel();
    }
  });

  test('download details and playback siblings use season and episode numbers from saved metadata', () async {
    await prepareSync([]);
    for (final (id, parent, season, episode, title) in [
      ('s10', 'show', 10, null, 'A'),
      ('s2', 'show', 2, null, 'B'),
      ('s0', 'show', 0, null, 'Z'),
      ('e20', 's2', 2, 20, 'A'),
      ('e1', 's2', 2, 1, 'Z'),
      ('e10', 's2', 2, 10, 'B'),
      ('e2b', 's2', 2, 2, 'C'),
      ('e2a', 's2', 2, 2, 'C'),
      ('special', 's0', 0, 1, 'Z'),
      ('later', 's10', 10, 1, 'A'),
    ]) {
      final saved = SyncedItem(
        id: id,
        parentId: parent,
        userId: 'user',
        path: path.join(directory.path, id),
        sortName: title,
      );
      await saved.directory.create();
      final metadata = BaseItemDto(
        id: id,
        name: title,
        type: episode == null ? BaseItemKind.season : BaseItemKind.episode,
        indexNumber: episode ?? season,
        parentIndexNumber: episode == null ? null : season,
      );
      await saved.dataFile.writeAsString(jsonEncode(metadata.toJson()));
      await database.insertItem(saved);
    }
    final series = SyncedItem(id: 'show', userId: 'user');
    final seasons = await notifier.getChildrenForItem(series);
    expect(seasons.map((entry) => entry.id), ['s0', 's2', 's10']);
    const episodeIds = ['e1', 'e2a', 'e2b', 'e10', 'e20'];
    final season = seasons[1];
    final episodes = await notifier.getNestedChildren(season);
    expect(episodes.map((entry) => entry.id), episodeIds);
    expect((await notifier.getSiblings(episodes.last)).map((entry) => entry.id), episodeIds);
    expect(
      (await notifier.getNestedChildren(series)).map((entry) => entry.id),
      ['s0', 's2', 's10', 'special', ...episodeIds, 'later'],
    );
  });

  test('a circular cached parent link cannot include the root in its descendants', () async {
    await prepareSync([]);
    final series = SyncedItem(id: 'show', parentId: 'season', userId: 'user');
    final season = SyncedItem(id: 'season', parentId: 'show', userId: 'user');
    await database.insertMultipleEntries([series, season]);
    final children = await notifier.getNestedChildren(series).timeout(const Duration(seconds: 2));
    expect(children.map((entry) => entry.id), ['season']);
  });

  test('a season waits for episode one to enqueue before a faster second episode', () async {
    final api = _SeasonApi();
    final downloader = await prepareSync([], api: api);
    const show = BaseItemDto(id: 'show', name: 'Series', type: BaseItemKind.series);
    const season = BaseItemDto(id: 'season', name: 'Season', type: BaseItemKind.season, parentId: 'show', indexNumber: 1);
    for (final dto in [
      show, season,
      for (final n in [2, 1])
        BaseItemDto(id: 'ep$n', name: 'Episode $n', type: BaseItemKind.episode, seasonId: 'season',
            parentId: 'season', parentIndexNumber: 1, indexNumber: n, path: '/library/$n.mkv'),
    ]) {
      api.details[dto.id!] = dto;
      final saved = SyncedItem(id: dto.id!, parentId: dto.parentId, userId: 'user', path: path.join(directory.path, dto.id));
      await saved.directory.create();
      await saved.dataFile.writeAsString(jsonEncode(dto.toJson()));
      await database.insertItem(saved);
    }
    final pending = notifier.syncSeries(SeriesModel.fromBaseDto(show, null), season: SeasonModel.fromBaseDto(season, null));
    try {
      await api.firstRequest.future.timeout(const Duration(seconds: 2));
      expect(downloader.enqueuedIds, isEmpty);
    } finally {
      api.allowFirst.complete();
      await pending;
    }
    expect(downloader.enqueuedIds, ['ep1', 'ep2']);
  });

  test('a download batch continues after a failure and stops at an account change', () async {
    await prepareSync([]);
    final account = container.read(userProvider)!;
    final calls = <String>[];
    final failure = StateError('first row');
    final probe = _QueueProbe(ref, directory, database, (row) async {
      calls.add(row.id);
      if (row.id == 'first') throw failure;
      if (row.id == 'second') {
        setAccount(account.copyWith(id: 'other-user'));
        setAccount(account);
      }
    });
    try {
      final batch = [for (final id in ['first', 'second', 'third']) item.copyWith(id: id)];
      await expectLater(probe.queueDownloads(batch), throwsA(same(failure)));
      expect(calls, ['first', 'second']);
    } finally {
      probe.dispose();
    }
  });

  test('the main file enters the queue before an optional thumbnail failure', () async {
    final events = <String>[];
    final downloader = await prepareSync(events);
    final thumbnailStarted = Completer<void>();
    final result = await http.runWithClient(
      () => notifier.syncFile(item, false).then<Object?>((value) => value, onError: (Object error) => error),
      () => MockClient((request) async {
        events.add('thumbnail');
        thumbnailStarted.complete();
        throw http.ClientException('synthetic thumbnail failure', request.url);
      }),
    );

    await thumbnailStarted.future.timeout(const Duration(seconds: 2));
    expect(events, ['media', 'thumbnail']);
    expect(result, isTrue);
    await notifier.cancelSyncTasks([downloader.downloadTask!]);
    expect(await item.trickPlayDirectory.list().toList(), isEmpty);
  });

  test('cancel does not wait for a thumbnail response or publish its late bytes', () async {
    final downloader = await prepareSync([]);
    final thumbnailStarted = Completer<void>();
    final thumbnail = Completer<http.Response>();
    final clientClosed = Completer<void>();
    final result = await http.runWithClient(
      () => notifier.syncFile(item, false),
      () => _ClosingMockClient((request) {
        thumbnailStarted.complete();
        return Future.any([
          thumbnail.future,
          clientClosed.future.then<http.Response>((_) => throw http.ClientException('closed', request.url)),
        ]);
      }, clientClosed),
    );

    expect(result, isTrue);
    await thumbnailStarted.future.timeout(const Duration(seconds: 2));
    await notifier.cancelSyncTasks([downloader.downloadTask!]).timeout(const Duration(seconds: 1));
    expect(clientClosed.isCompleted, isTrue);
    thumbnail.complete(http.Response('late', 200));
    expect(await item.trickPlayDirectory.list().toList(), isEmpty);
  });

  test('refreshing a series preserves each download and its pending playback position', () async {
    await prepareSync([]);
    await container.read(clientSettingsProvider.notifier).setSyncPath(directory.path);
    const show = BaseItemDto(id: 'show', name: 'Series', type: BaseItemKind.series);
    const episode = BaseItemDto(id: 'ep', name: 'Episode', type: BaseItemKind.episode, seriesId: 'show',
        parentIndexNumber: 1, indexNumber: 2, sortName: 'New title');
    service.details.addAll({'show': show, 'ep': episode});
    await http.runWithClient(() async {
      final parent = (await notifier.createSyncItem(show)).copyWith(
        userData: UserData(playbackPositionTicks: 900, lastPlayed: DateTime.utc(2026, 11, 27)),
      );
      final child = (await notifier.createSyncItem(episode, parent: parent)).copyWith(
        userData: UserData(playbackPositionTicks: 250, lastPlayed: DateTime.utc(2026, 11, 26)),
        unSyncedData: true, subtitles: [_subtitle(2)], videoFileName: 'local.mkv',
      );
      await database.insertMultipleEntries([parent, child]);
      await notifier.refreshSyncItem(parent);
      final saved = (await notifier.getSyncedItem('ep'))!;
      expect(saved.userData?.playbackPositionTicks, 250);
      expect(saved.subtitles.single.index, 2);
      expect(saved.videoFileName, 'local.mkv');
      expect(saved.unSyncedData, isTrue);
      expect(service.requestedDetails, ['show', 'ep']);
      (container.read(connectivityStatusProvider.notifier) as _FixtureConnectivity).disconnect();
      service.requestedDetails.clear();
      await notifier.refreshSyncItem(parent);
      expect(service.requestedDetails, isEmpty);
    }, () => MockClient((_) async => http.Response('', 404)));
  });

  test('late metadata never undoes a newer download, pending progress or deletion', () async {
    await prepareSync([]);
    final original = item.copyWith(userData: const UserData(playbackPositionTicks: 10));
    final downloaded = original.copyWith(
      videoFileName: 'encoded.mkv', subtitles: [_subtitle(5)], unSyncedData: true,
      userData: const UserData(playbackPositionTicks: 100),
    );
    await database.insertItem(downloaded);
    final metadata = original.copyWith(sortName: 'Updated title', userData: const UserData(playbackPositionTicks: 20));
    await database.refreshMetadata(original, metadata);
    final saved = (await notifier.getSyncedItem(item.id))!;
    expect(saved.sortName, 'Updated title');
    expect(saved.videoFileName, 'encoded.mkv');
    expect(saved.subtitles.single.index, 5);
    expect(saved.userData?.playbackPositionTicks, 100);
    await database.deleteAllItems([saved]);
    await database.refreshMetadata(original, metadata);
    expect(await notifier.getSyncedItem(item.id), isNull);
  });

  test('unrelated metadata updates preserve a committed preview', () async {
    await prepareSync([]);
    await database.insertItem(item);
    final preview = (await _Api().getTrickPlay(item: null, ref: ref))!.body!;
    expect(await database.saveTrickPlay(item, preview), 1);

    await database.insertItem(item.copyWith(sortName: 'Changed'));
    await database.insertMultipleEntries([item.copyWith(sortName: 'Changed again')]);

    final saved = (await notifier.getSyncedItem(item.id))!;
    expect(saved.sortName, 'Changed again');
    expect(saved.fTrickPlayModel?.toJson(), preview.toJson());
    expect(await database.saveTrickPlay(item, preview), 0);
  });

  test('deletion remains scoped to the captured account and path', () async {
    await prepareSync([]);
    final second = item.copyWith(userId: 'other-user');
    await database.insertMultipleEntries([item, second]);
    final current = container.read(userProvider)!;
    setAccount(current.copyWith(id: second.userId));

    await database.deleteAllItems([item.copyWith(path: '${directory.path}-old')]);
    setAccount(current);
    expect(await notifier.getSyncedItem(item.id), isNotNull);
    setAccount(current.copyWith(id: second.userId));

    await database.deleteAllItems([item]);
    expect((await notifier.getSyncedItem(second.id))?.userId, second.userId);
    setAccount(current);
    expect(await notifier.getSyncedItem(item.id), isNull);
  });

  test('changing server with the same user ID discards a held preview manifest', () async {
    final manifestRequested = Completer<void>();
    final manifest = Completer<Response<TrickPlayModel>?>();
    final api = _Api(manifestRequested: manifestRequested, pendingManifest: manifest.future);
    await prepareSync([], api: api);
    var tiles = 0;

    final result = await http.runWithClient(
      () => notifier.syncFile(item, false),
      () => MockClient((request) async {
        tiles++;
        return http.Response('wrong account', 200);
      }),
    );
    expect(result, isTrue);
    await manifestRequested.future.timeout(const Duration(seconds: 2));

    setServer('https://other-fixture.invalid');
    manifest.complete(await _Api().getTrickPlay(item: null, ref: ref));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(tiles, 0);
    expect(await item.trickPlayDirectory.exists(), isFalse);
    expect(await database.readTrickPlay(item), isNull);
  });

  test('a successful thumbnail repair replaces only the previous generated cache', () async {
    final downloader = await prepareSync([]);
    await database.insertItem(item);
    final root = await item.trickPlayDirectory.create();
    final old = await root.createTemp('tiles-');
    final unrelated = await root.createTemp('tiles-');
    final legacy = await File(path.join(root.path, 'tile_0.jpg')).writeAsString('legacy');
    final oldRelative = path.relative(path.join(old.path, 'tile_0.jpg'), from: directory.path);
    final model = (await _Api().getTrickPlay(item: null, ref: ref))!.body!;
    expect(await database.saveTrickPlay(item, model.copyWith(images: [oldRelative])), 1);
    final initial = await database.readTrickPlay(item);

    expect(
      await http.runWithClient(
        () => notifier.syncFile(item, false),
        () => MockClient((request) async => http.Response('new preview', 200)),
      ),
      isTrue,
    );
    await (() async {
      while (await database.readTrickPlay(item) == initial) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    })().timeout(const Duration(seconds: 2));
    await notifier.cancelSyncTasks([downloader.downloadTask!]);

    final saved = (await notifier.getSyncedItem(item.id))!;
    expect(await File(saved.trickPlayModel!.images.single).readAsString(), 'new preview');
    expect(await old.exists(), isFalse);
    expect(await unrelated.exists(), isTrue);
    expect(await legacy.readAsString(), 'legacy');
  });

  void activate(String id, String server) {
    final url = 'https://$server.fixture.invalid/jellyfin';
    setServer(url);
    setAccount(
      AccountModel(
        name: id,
        id: id,
        avatar: '',
        lastUsed: DateTime(2026),
        credentials: CredentialsModel(token: 'token-$server', url: url, serverId: server),
      ),
    );
  }

  Future<SyncedItem> pending(String id, String account, String server, int ticks) async {
    final itemFolder = await Directory(path.join(directory.path, '$server-$id')).create();
    final pending = SyncedItem(
      id: id,
      userId: account,
      path: itemFolder.path,
      sortName: id,
      unSyncedData: true,
      userData: UserData(playbackPositionTicks: ticks),
    );
    await pending.dataFile.writeAsString(
      jsonEncode(BaseItemDto(id: id, serverId: server, name: id, type: BaseItemKind.movie).toJson()),
    );
    await database.insertItem(pending);
    return pending;
  }

  test('held replay cannot cross account and the new account can sync before it completes', () async {
    await pending('first', 'account-a', 'server-a', 10);
    await pending('second', 'account-a', 'server-a', 20);
    await pending('first', 'account-b', 'server-b', 30);
    final called = <(String, String, int)>[];
    final oldStarted = Completer<void>();
    final oldResponse = Completer<http.Response>();
    await http.runWithClient(
      () async {
        activate('account-a', 'server-a');
        final old = notifier.updateSyncStates();
        await oldStarted.future.timeout(const Duration(seconds: 2));
        activate('account-b', 'server-b');
        await notifier.updateSyncStates();
        final callsBeforeOldResponse = called.toList();
        oldResponse.complete(http.Response('{}', 200));
        await old;

        expect(callsBeforeOldResponse, [
          ('server-a.fixture.invalid', 'account-a', 10),
          ('server-b.fixture.invalid', 'account-b', 30),
        ]);
        expect(called, callsBeforeOldResponse);
        expect((await notifier.getSyncedItem('first'))?.unSyncedData, isFalse);
        expect((await database.pendingUserData('account-a')).map((row) => row.id), ['first', 'second']);
      },
      () => MockClient((request) async {
        final ticks = (jsonDecode(request.body) as Map)['PlaybackPositionTicks'] as int;
        expect(request.headers['authorization'], contains('Token="token-${request.url.host.split('.').first}"'));
        expect(request.url.pathSegments.first, 'jellyfin');
        expect(request.followRedirects, isFalse);
        called.add((request.url.host, request.url.queryParameters['userId']!, ticks));
        if (called.length == 1) {
          oldStarted.complete();
          return oldResponse.future;
        }
        return http.Response('{}', 200);
      }),
    );
  });

  test('replay holds foreign and unverified server data and refuses redirects', () async {
    await pending('a-old-server-item', 'same-id', 'server-a', 10);
    await pending('b-unverified-item', 'same-id', '', 20);
    await pending('c-current-server-item', 'same-id', 'server-b', 30);
    final requested = <http.Request>[];
    await http.runWithClient(
      () {
        activate('same-id', 'server-b');
        return notifier.updateSyncStates();
      },
      () => MockClient((request) async {
        requested.add(request);
        return http.Response('', 307, headers: {'location': 'https://redirect.fixture.invalid/UserData'});
      }),
    );

    expect(requested.single.url.host, 'server-b.fixture.invalid');
    expect(requested.single.url.pathSegments, ['jellyfin', 'UserItems', 'c-current-server-item', 'UserData']);
    expect(requested.single.followRedirects, isFalse);
    expect((await notifier.getSyncedItem('a-old-server-item'))?.unSyncedData, isTrue);
    expect((await notifier.getSyncedItem('b-unverified-item'))?.unSyncedData, isTrue);
    expect((await notifier.getSyncedItem('c-current-server-item'))?.unSyncedData, isTrue);
  });

  test('acknowledging older offline data preserves a newer edit', () async {
    final original = await pending('movie', 'account-a', 'server-a', 10);
    final called = <int>[];
    final postStarted = Completer<void>();
    final firstResponse = Completer<http.Response>();
    await http.runWithClient(
      () async {
        activate('account-a', 'server-a');
        final replay = notifier.updateSyncStates();
        await postStarted.future.timeout(const Duration(seconds: 2));
        await database.insertItem(
          original.copyWith(userData: const UserData(playbackPositionTicks: 20), sortName: 'New metadata'),
        );
        firstResponse.complete(http.Response('{}', 200));
        await replay;

        final saved = (await notifier.getSyncedItem('movie'))!;
        expect(saved.userData?.playbackPositionTicks, 20);
        expect(saved.sortName, 'New metadata');
        expect(saved.unSyncedData, isTrue);
      },
      () => MockClient((request) async {
        called.add((jsonDecode(request.body) as Map)['PlaybackPositionTicks'] as int);
        if (called.length == 1) {
          postStarted.complete();
          return firstResponse.future;
        }
        return http.Response('{}', 503);
      }),
    );
  });

  test('startup preserves a download partial before downloader tasks are restored', () async {
    final previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FixturePaths(directory.path);
    addTearDown(() => PathProviderPlatform.instance = previous);
    final partial = await File(
      path.join(directory.path, 'com.bbflight.background_downloader-resume-partial'),
    ).writeAsString('resumable bytes');
    final task = DownloadTask(taskId: 'FIXTURE_PAUSED_DOWNLOAD', url: 'https://fixture.invalid/movie.mkv');
    final storage = LocalStorePersistentStorage();
    await storage.initialize();
    await storage.storeResumeData(ResumeData(task, partial.path, await partial.length(), 'FAKE_ETAG'));
    await storage.retrieveAllResumeData();
    final startup = SyncNotifier(ref, directory, database: database);
    addTearDown(startup.dispose);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final resume = (await storage.retrieveResumeData(task.taskId))!;
    expect(resume.tempFilepath, partial.path);
    expect(await File(resume.tempFilepath).length(), resume.requiredStartByte);
    expect(await File(resume.tempFilepath).readAsString(), 'resumable bytes');
  });
}

class _ClosingMockClient extends MockClient {
  _ClosingMockClient(super.fn, this.closed);
  final Completer<void> closed;

  @override
  void close() {
    closed.complete();
    super.close();
  }
}
