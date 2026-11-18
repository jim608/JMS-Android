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
import 'package:fladder/models/items/trick_play_model.dart';
import 'package:fladder/models/syncing/database_item.dart';
import 'package:fladder/models/syncing/sync_item.dart';
import 'package:fladder/models/syncing/sync_settings_model.dart';
import 'package:fladder/models/syncing/transcode_download_model.dart';
import 'package:fladder/models/syncing/transcode_music_download_model.dart';
import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/connectivity_provider.dart';
import 'package:fladder/providers/service_provider.dart';
import 'package:fladder/providers/sync/background_download_provider.dart';
import 'package:fladder/providers/sync/sync_provider_media.dart';
import 'package:fladder/providers/sync_provider.dart';
import 'package:fladder/providers/user_provider.dart';

class _Subscription<T> extends Fake implements ProviderSubscription<T> {}

class _FixtureRef extends Fake implements Ref {
  @override
  final container = ProviderContainer();
  final values = <Object, Object?>{};
  void Function(Object)? onRead;

  @override
  T read<T>(ProviderListenable<T> provider) {
    onRead?.call(provider);
    if (values.containsKey(provider)) return values[provider] as T;
    if (T == String) return ((values[userProvider] as AccountModel?)?.id ?? '') as T;
    if (T == TranscodeDownloadModel) return TranscodeDownloadModel.fromDefaults() as T;
    if (T == TranscodeMusicDownloadModel) return const TranscodeMusicDownloadModel() as T;
    if (T == bool) return false as T;
    return container.read(provider);
  }

  @override
  ProviderSubscription<T> listen<T>(
    ProviderListenable<T> provider,
    void Function(T? previous, T next) listener, {
    void Function(Object, StackTrace)? onError,
    bool fireImmediately = false,
  }) =>
      _Subscription<T>();
}

class _Notifier extends SyncNotifier {
  _Notifier(super.ref, super.mobileDirectory, this.database) : super(database: database);

  final AppDatabase database;

  @override
  set state(SyncSettingsModel value) {}

  @override
  Future<int> updateItem(SyncedItem item) => database.insertItem(item);
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
  DownloadTask? downloadTask;

  @override
  Future<bool> enqueue(Task task) async {
    downloadTask = task as DownloadTask;
    events.add('media');
    return true;
  }

  @override
  Future<bool> cancelAll({Iterable<Task>? tasks, String? group}) async => true;

  @override
  Future<bool> cancelTaskWithId(String taskId) async => true;
}

class _Api extends Fake implements JellyService {
  _Api({this.manifestRequested, this.pendingManifest});

  final Completer<void>? manifestRequested;
  final Future<Response<TrickPlayModel>?>? pendingManifest;

  @override
  Future<Response<PlaybackInfoResponse>> itemsItemIdPlaybackInfoPost({
    required String? itemId,
    required PlaybackInfoDto? body,
  }) async =>
      Response(
        http.Response('', 200),
        const PlaybackInfoResponse(mediaSources: [MediaSourceInfo(id: 'source', supportsDirectPlay: true)]),
      );

  @override
  Future<Response<MediaSegmentsModel>?> mediaSegmentsGet({required String id}) async => null;

  @override
  Future<Response<TrickPlayModel>?> getTrickPlay({
    required ItemBaseModel? item,
    int? width,
    required Ref ref,
  }) async {
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
  late _FixtureRef ref;
  late _Notifier notifier;
  late SyncedItem item;
  late AppDatabase database;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('jms-offline-test-');
    ref = _FixtureRef()..values[userProvider] = null;
    database = AppDatabase(ref, NativeDatabase.memory());
    notifier = _Notifier(ref, directory, database);
    item = SyncedItem(id: 'movie', userId: 'user', path: directory.path, videoFileName: 'movie.mkv');
  });

  tearDown(() async {
    notifier.dispose();
    await database.close();
    ref.container.dispose();
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
    final downloader = _Downloader(events);
    ref.values.addAll({
      jellyApiProvider: api ?? _Api(),
      backgroundDownloaderProvider: downloader,
      serverUrlProvider: 'https://fixture.invalid',
      userProvider: AccountModel(
        name: 'Synthetic',
        id: 'user',
        avatar: '',
        lastUsed: DateTime(2026),
        credentials: CredentialsModel.internal(token: 'synthetic', url: 'https://fixture.invalid'),
      ),
    });
    await item.dataFile.writeAsString('{"Id":"movie","Name":"Synthetic movie","Type":"Movie","MediaType":"Video"}');
    return downloader;
  }

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
    final current = ref.values[userProvider] as AccountModel;
    ref.values[userProvider] = current.copyWith(id: second.userId);

    await database.deleteAllItems([item.copyWith(path: '${directory.path}-old')]);
    ref.values[userProvider] = current;
    expect(await notifier.getSyncedItem(item.id), isNotNull);
    ref.values[userProvider] = current.copyWith(id: second.userId);

    await database.deleteAllItems([item]);
    expect((await notifier.getSyncedItem(second.id))?.userId, second.userId);
    ref.values[userProvider] = current;
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

    ref.values[serverUrlProvider] = 'https://other-fixture.invalid';
    final scopeChecked = Completer<void>();
    ref.onRead = (provider) {
      if (provider == serverUrlProvider && !scopeChecked.isCompleted) scopeChecked.complete();
    };
    manifest.complete(await _Api().getTrickPlay(item: null, ref: ref));
    await scopeChecked.future.timeout(const Duration(seconds: 2));

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
        isTrue);
    await (() async {
      while (await database.readTrickPlay(item) == initial) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    })()
        .timeout(const Duration(seconds: 2));
    await notifier.cancelSyncTasks([downloader.downloadTask!]);

    final saved = (await notifier.getSyncedItem(item.id))!;
    expect(await File(saved.trickPlayModel!.images.single).readAsString(), 'new preview');
    expect(await old.exists(), isFalse);
    expect(await unrelated.exists(), isTrue);
    expect(await legacy.readAsString(), 'legacy');
  });

  void activate(String id, String server) {
    final url = 'https://$server.fixture.invalid/jellyfin';
    ref.values.addAll({
      serverUrlProvider: url,
      connectivityStatusProvider: ConnectionState.wifi,
      userProvider: AccountModel(
          name: id,
          id: id,
          avatar: '',
          lastUsed: DateTime(2026),
          credentials: CredentialsModel.internal(token: 'token-$server', url: url, serverId: server)),
    });
  }

  Future<SyncedItem> pending(String id, String account, String server, int ticks) async {
    final itemFolder = await Directory(path.join(directory.path, '$server-$id')).create();
    final pending = SyncedItem(
        id: id,
        userId: account,
        path: itemFolder.path,
        sortName: id,
        unSyncedData: true,
        userData: UserData(playbackPositionTicks: ticks));
    await pending.dataFile
        .writeAsString(jsonEncode(BaseItemDto(id: id, serverId: server, name: id, type: BaseItemKind.movie).toJson()));
    await database.insertItem(pending);
    return pending;
  }

  test('held replay cannot cross account and the new account can sync before it completes', () async {
    activate('account-a', 'server-a');
    await pending('first', 'account-a', 'server-a', 10);
    await pending('second', 'account-a', 'server-a', 20);
    await pending('first', 'account-b', 'server-b', 30);
    final called = <(String, String, int)>[];
    final oldStarted = Completer<void>();
    final oldResponse = Completer<http.Response>();
    await http.runWithClient(() async {
      final old = notifier.updateSyncStates();
      await oldStarted.future.timeout(const Duration(seconds: 2));
      activate('account-b', 'server-b');
      await notifier.updateSyncStates();
      final callsBeforeOldResponse = called.toList();
      oldResponse.complete(http.Response('{}', 200));
      await old;

      expect(callsBeforeOldResponse,
          [('server-a.fixture.invalid', 'account-a', 10), ('server-b.fixture.invalid', 'account-b', 30)]);
      expect(called, callsBeforeOldResponse);
      expect((await notifier.getSyncedItem('first'))?.unSyncedData, isFalse);
      activate('account-a', 'server-a');
      expect((await notifier.getSyncedItem('first'))?.unSyncedData, isTrue);
      expect((await notifier.getSyncedItem('second'))?.unSyncedData, isTrue);
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
            }));
  });

  test('replay holds foreign and unverified server data and refuses redirects', () async {
    activate('same-id', 'server-b');
    await pending('a-old-server-item', 'same-id', 'server-a', 10);
    await pending('b-unverified-item', 'same-id', '', 20);
    await pending('c-current-server-item', 'same-id', 'server-b', 30);
    final requested = <http.Request>[];
    await http.runWithClient(
        notifier.updateSyncStates,
        () => MockClient((request) async {
              requested.add(request);
              return http.Response('', 307, headers: {'location': 'https://redirect.fixture.invalid/UserData'});
            }));

    expect(requested.single.url.host, 'server-b.fixture.invalid');
    expect(requested.single.url.pathSegments, ['jellyfin', 'UserItems', 'c-current-server-item', 'UserData']);
    expect(requested.single.followRedirects, isFalse);
    expect((await notifier.getSyncedItem('a-old-server-item'))?.unSyncedData, isTrue);
    expect((await notifier.getSyncedItem('b-unverified-item'))?.unSyncedData, isTrue);
    expect((await notifier.getSyncedItem('c-current-server-item'))?.unSyncedData, isTrue);
  });

  test('acknowledging older offline data preserves a newer edit', () async {
    activate('account-a', 'server-a');
    final original = await pending('movie', 'account-a', 'server-a', 10);
    final called = <int>[];
    final postStarted = Completer<void>();
    final firstResponse = Completer<http.Response>();
    await http.runWithClient(() async {
      final replay = notifier.updateSyncStates();
      await postStarted.future.timeout(const Duration(seconds: 2));
      await database
          .insertItem(original.copyWith(userData: const UserData(playbackPositionTicks: 20), sortName: 'New metadata'));
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
            }));
  });

  test('startup preserves a download partial before downloader tasks are restored', () async {
    final previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FixturePaths(directory.path);
    addTearDown(() => PathProviderPlatform.instance = previous);
    final partial = await File(path.join(directory.path, 'com.bbflight.background_downloader-resume-partial'))
        .writeAsString('resumable bytes');
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
