import 'dart:async';

import 'package:chopper/chopper.dart';
import 'package:fladder/fake/fake_jellyfin_open_api.dart';
import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/credentials_model.dart';
import 'package:fladder/models/items/movie_model.dart';
import 'package:fladder/models/library_filter_model.dart';
import 'package:fladder/models/library_search/library_search_model.dart';
import 'package:fladder/models/library_search/library_search_options.dart';
import 'package:fladder/models/syncing/sync_item.dart';
import 'package:fladder/models/syncing/sync_settings_model.dart';
import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/connectivity_provider.dart';
import 'package:fladder/providers/jellyfin_websocket_provider.dart';
import 'package:fladder/providers/library_screen_provider.dart';
import 'package:fladder/providers/library_search_provider.dart';
import 'package:fladder/providers/service_provider.dart';
import 'package:fladder/providers/sync_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/providers/views_provider.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

Response<T> _ok<T>(T body) => Response(http.Response('', 200), body);

MovieModel _movie(String id, [String? name]) =>
    MovieModel.fromBaseDto(BaseItemDto(id: id, name: name ?? id, type: BaseItemKind.movie), null);

class _Api extends JellyApi {
  _Api(this.create);

  final JellyService Function(Ref) create;

  @override
  JellyService build() => create(ref);
}

class _SignedIn extends User {
  @override
  AccountModel build() => AccountModel(
        name: 'Account',
        id: 'account',
        avatar: '',
        lastUsed: DateTime.utc(2026),
        credentials: CredentialsModel(),
      );
}

class _Service implements JellyService {
  final queries = <({int? limit, int? offset, String? query, bool? favourite})>[];
  final requests = <Completer<Response<ServerQueryResult>>>[];
  final sortFields = <List<ItemSortBy>?>[];
  final libraryContent = <({Symbol operation, String? view})>[];
  int viewRequests = 0;
  int latestRequests = 0;
  Completer<Response<BaseItemDtoQueryResult>>? heldViews;
  Completer<Response<List<BaseItemDto>>>? heldLatest;

  @override
  dynamic noSuchMethod(Invocation call) {
    final args = call.namedArguments;
    final request = call.memberName;
    switch (request) {
      case #usersUserIdViewsGet:
        viewRequests++;
        if (heldViews != null) return heldViews!.future;
        return Future.value(_ok(const BaseItemDtoQueryResult(items: [
          BaseItemDto(id: 'movies', name: 'Movies', collectionType: CollectionType.movies),
          BaseItemDto(id: 'shows', name: 'Shows', collectionType: CollectionType.tvshows),
        ])));
      case #usersUserIdItemsLatestGet:
        latestRequests++;
        if (heldLatest != null) return heldLatest!.future;
        return Future.value(_ok(<BaseItemDto>[]));
      case #usersUserIdItemsResumeGet:
      case #showsNextUpGet:
      case #usersUserIdItemsGet:
        libraryContent.add((operation: request, view: args[#parentId] as String?));
        return Future.value(_ok(const BaseItemDtoQueryResult()));
      case #moviesRecommendationsGet:
        libraryContent.add((operation: request, view: args[#parentId] as String?));
        return Future.value(_ok(<RecommendationDto>[]));
      case #itemsGet:
        if (args[#parentId] != null && args[#isFavorite] == true) {
          libraryContent.add((operation: request, view: args[#parentId] as String?));
          return Future.value(_ok(ServerQueryResult(items: [])));
        }
        sortFields.add(args[#sortBy] as List<ItemSortBy>?);
        queries.add((
          limit: args[#limit] as int?,
          offset: args[#startIndex] as int?,
          query: args[#searchTerm] as String?,
          favourite: args[#isFavorite] as bool?,
        ));
        final requestFuture = Completer<Response<ServerQueryResult>>();
        requests.add(requestFuture);
        return requestFuture.future;
      default:
        throw UnsupportedError('Unexpected operation ${call.memberName}');
    }
  }

  void complete(int index, String id, int? total) {
    requests[index].complete(_ok(ServerQueryResult(items: [_movie(id)], totalRecordCount: total)));
  }
}

class _Downloads extends StateNotifier<SyncSettingsModel> implements SyncNotifier {
  _Downloads(List<SyncedItem> items) : super(SyncSettingsModel(items: items));

  @override
  Future<List<SyncedItem>> getNestedChildren(SyncedItem? item) async => [];

  @override
  dynamic noSuchMethod(Invocation call) => super.noSuchMethod(call);
}

const _search = ValueKey('synthetic-library-search');
Future<void> _nextTurn() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final favourite in [false, true]) {
    test('global ${favourite ? 'favourites' : 'search'} loads bounded pages and stops at the total', () async {
      final api = _Service();
      final container = ProviderContainer(overrides: [jellyApiProvider.overrideWith(() => _Api((_) => api))]);
      addTearDown(container.dispose);
      final provider = librarySearchProvider(_search);
      container.listen(provider, (_, _) {});
      final notifier = container.read(provider.notifier);

      final first = notifier.initRefresh(
        parentIds: [],
        filters: LibraryFilterModel(searchQuery: favourite ? '' : 'test', favourites: favourite ? true : null),
      );
      await _nextTurn();
      expect(api.queries.single,
          (limit: 500, offset: 0, query: favourite ? null : 'test', favourite: favourite ? true : null));
      api.complete(0, 'a', 2);
      await first;

      final second = notifier.loadMore();
      expect(api.queries.last.offset, 1);
      api.complete(1, 'b', 2);
      await second;
      expect(container.read(provider).posters.map((item) => item.id), ['a', 'b']);
      expect(container.read(provider).totalItemCount, 2);
      await notifier.loadMore();
      expect(api.queries, hasLength(2));
    });
  }

  test('an old global search result cannot replace a newer search', () async {
    final api = _Service();
    final container = ProviderContainer(overrides: [jellyApiProvider.overrideWith(() => _Api((_) => api))]);
    addTearDown(container.dispose);
    final provider = librarySearchProvider(_search);
    container.listen(provider, (_, _) {});
    final notifier = container.read(provider.notifier);
    final older = notifier.initRefresh(parentIds: [], filters: const LibraryFilterModel(searchQuery: 'old'));
    await _nextTurn();
    notifier.setSearch('new');
    final newer = notifier.initRefresh(parentIds: []);
    await _nextTurn();
    api.complete(1, 'new', 1);
    await newer;
    api.complete(0, 'old', 1);
    await older;
    expect(container.read(provider).posters.single.id, 'new');
  });

  test('global Random advances through stable server pages and keeps every item', () async {
    final api = _Service();
    final container = ProviderContainer(overrides: [jellyApiProvider.overrideWith(() => _Api((_) => api))]);
    addTearDown(container.dispose);
    final provider = librarySearchProvider(_search);
    container.listen(provider, (_, _) {});
    final notifier = container.read(provider.notifier);
    final first = notifier.initRefresh(
      parentIds: [],
      filters: const LibraryFilterModel(searchQuery: 'test', sortingOption: SortingOptions.random),
    );
    await _nextTurn();
    api.requests.first.complete(_ok(ServerQueryResult(items: [_movie('a'), _movie('b')], totalRecordCount: 4)));
    await first;
    final second = notifier.loadMore();
    api.requests.last.complete(_ok(ServerQueryResult(items: [_movie('c'), _movie('d')], totalRecordCount: 4)));
    await second;
    expect(api.sortFields, List.filled(2, [ItemSortBy.sortname, ItemSortBy.datecreated]));
    expect(api.queries.map((query) => query.offset), [0, 2]);
    expect(container.read(provider).posters.map((item) => item.id), unorderedEquals(['a', 'b', 'c', 'd']));
  });

  test('offline search matches the keyword, then slices the results with the full filtered total', () async {
    final downloads = [
      SyncedItem(id: 'a', userId: 'u', itemModel: _movie('a', 'Alpha One')),
      SyncedItem(id: 'b', userId: 'u', itemModel: _movie('b', 'Alpha Two')),
      SyncedItem(id: 'c', userId: 'u', itemModel: _movie('c', 'Beta')),
    ];
    final container = ProviderContainer(overrides: [
      offlineStateProvider.overrideWithValue(true),
      syncProvider.overrideWith((_) => _Downloads(downloads)),
      jellyApiProvider.overrideWith(() => _Api((ref) => JellyService(ref, FakeJellyfinOpenApi()))),
    ]);
    addTearDown(container.dispose);
    final api = container.read(jellyApiProvider);

    final result = (await api.itemsGet(searchTerm: ' ALPHA ', startIndex: 1, limit: 1)).body!;
    expect(result.items, hasLength(1));
    expect(result.items.single.name, startsWith('Alpha'));
    expect(result.startIndex, 1);
    expect(result.totalRecordCount, 2);
    final empty = (await api.itemsGet(searchTerm: 'CHANGING KEYWORD')).body!;
    expect(empty.items, isEmpty);
    expect(empty.totalRecordCount, 0);
  });

  test('library entry reuses already loaded views, and switching fetches only the selected library', () async {
    final api = _Service();
    final container = ProviderContainer(overrides: [
      jellyApiProvider.overrideWith(() => _Api((_) => api)),
      jellyfinWebSocketProvider.overrideWith((_) => const Stream.empty()),
    ]);
    addTearDown(container.dispose);
    await container.read(viewsProvider.notifier).fetchViews();

    final library = container.read(libraryScreenProvider.notifier);
    await library.fetchAllLibraries();
    final shows = container.read(libraryScreenProvider).views.last;
    api.libraryContent.clear();
    await library.selectLibrary(shows);

    expect(api.viewRequests, 1);
    expect(api.latestRequests, 0);
    expect(api.libraryContent.map((entry) => entry.view), List.filled(4, 'shows'));

    await library.fetchAllLibraries(refreshViews: true);
    expect(api.viewRequests, 2);
    expect(api.latestRequests, 0);
    expect(container.read(libraryScreenProvider).selectedViewModel?.id, 'shows');
  });

  test('pending dashboard and library metadata cannot publish after signing out', () async {
    final api = _Service()..heldLatest = Completer();
    final container = ProviderContainer(overrides: [
      jellyApiProvider.overrideWith(() => _Api((_) => api)),
      jellyfinWebSocketProvider.overrideWith((_) => const Stream.empty()),
      userProvider.overrideWith(_SignedIn.new),
    ]);
    addTearDown(container.dispose);
    final views = container.read(viewsProvider.notifier);
    final library = container.read(libraryScreenProvider.notifier);
    await views.fetchViews();
    final dashboard = views.fetchRecentlyAdded();
    await _nextTurn();
    expect(api.latestRequests, 2);
    api.heldViews = Completer();
    final picker = library.fetchAllLibraries(refreshViews: true);
    views.clear();
    library.clear();

    api.heldLatest!.complete(_ok(const [
      BaseItemDto(id: 'old-latest', name: 'Old account latest', type: BaseItemKind.movie),
    ]));
    api.heldViews!.complete(_ok(const BaseItemDtoQueryResult(items: [
      BaseItemDto(id: 'old', name: 'Old account', collectionType: CollectionType.movies),
    ])));
    await dashboard;
    await picker;
    expect(container.read(viewsProvider).views, isEmpty);
    expect(container.read(libraryScreenProvider).views, isEmpty);
    expect(api.libraryContent, isEmpty);
  });
}
