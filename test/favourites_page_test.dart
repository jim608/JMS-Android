import 'dart:async';

import 'package:chopper/chopper.dart';
import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/items/movie_model.dart';
import 'package:fladder/models/items/person_model.dart';
import 'package:fladder/models/items/series_model.dart';
import 'package:fladder/models/view_model.dart';
import 'package:fladder/models/views_model.dart';
import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/favourites_provider.dart';
import 'package:fladder/providers/jellyfin_websocket_provider.dart';
import 'package:fladder/providers/service_provider.dart';
import 'package:fladder/providers/views_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

Response<T> _ok<T>(T body) => Response(http.Response('', 200), body);

class _Api extends JellyApi {
  _Api(this.service);

  final JellyService service;

  @override
  JellyService build() => service;
}

class _Views extends ViewsNotifier {
  _Views(super.ref, int count) {
    final views = [
      for (var i = 0; i < count; i++)
        ViewModel(
          name: 'Synthetic library $i',
          id: 'library-$i',
          serverId: 'synthetic',
          dateCreated: DateTime.utc(2026),
          canDelete: false,
          canDownload: false,
          parentId: '',
          collectionType: CollectionType.movies,
          playAccess: PlayAccess.full,
          recentlyAdded: const [],
          imageData: null,
          childCount: 0,
          path: null,
        ),
    ];
    state = ViewsModel(views: views, dashboardViews: views.skip(1).toList());
  }
}

class _Service implements JellyService {
  final mediaRequests = <Map<Symbol, dynamic>>[];
  final peopleRequests = <Map<Symbol, dynamic>>[];
  Completer<void>? mediaGate;
  String label = 'account';

  @override
  dynamic noSuchMethod(Invocation call) {
    switch (call.memberName) {
      case #itemsGet:
        return _media(call.namedArguments);
      case #personsGet:
        peopleRequests.add(call.namedArguments);
        return Future.value(_ok(<ItemBaseModel>[
          PersonModel.fromBaseDto(BaseItemDto(id: '$label-person', name: 'Actor', type: BaseItemKind.person), null),
        ]));
      default:
        throw UnsupportedError('Unexpected operation ${call.memberName}');
    }
  }

  Future<Response<ServerQueryResult>> _media(Map<Symbol, dynamic> args) async {
    mediaRequests.add(args);
    final currentLabel = label;
    await mediaGate?.future;
    final parentId = args[#parentId] as String?;
    final kind = (args[#includeItemTypes] as List<BaseItemKind>).single;
    final limit = args[#limit] as int;
    final items = switch (kind) {
      BaseItemKind.movie => <ItemBaseModel>[
          if (parentId == null || parentId == 'library-0')
            MovieModel.fromBaseDto(
              BaseItemDto(id: '$currentLabel-hidden', name: 'A from a library hidden on Home', type: kind),
              null,
            ),
          for (var i = 10; i < 27; i++)
            MovieModel.fromBaseDto(BaseItemDto(id: '$currentLabel-movie-$i', name: 'Movie $i', type: kind), null),
        ],
      BaseItemKind.series => <ItemBaseModel>[
          SeriesModel.fromBaseDto(BaseItemDto(id: '$currentLabel-series', name: 'Series', type: kind), null)
        ],
      _ => <ItemBaseModel>[],
    };
    return _ok(ServerQueryResult(items: items.take(limit).toList()));
  }
}

ProviderContainer _container(_Service service, int libraries) => ProviderContainer(overrides: [
      jellyApiProvider.overrideWith(() => _Api(service)),
      jellyfinWebSocketProvider.overrideWith((_) => const Stream.empty()),
      viewsProvider.overrideWith((ref) => _Views(ref, libraries)),
    ]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final libraries in [2, 12]) {
    test('dedicated favourites includes hidden-from-home titles across $libraries libraries', () async {
      final service = _Service();
      final container = _container(service, libraries);
      addTearDown(container.dispose);
      final views = container.read(viewsProvider);
      expect(views.views.first.id, 'library-0');
      expect(views.dashboardViews.where((view) => view.id == 'library-0'), isEmpty);

      await container.read(favouritesProvider.notifier).fetchFavourites();

      const kinds = [
        BaseItemKind.movie,
        BaseItemKind.episode,
        BaseItemKind.series,
        BaseItemKind.video,
        BaseItemKind.photo,
        BaseItemKind.book,
        BaseItemKind.photoalbum,
        BaseItemKind.musicalbum,
        BaseItemKind.audio,
      ];
      expect(service.mediaRequests.map((request) => request[#includeItemTypes]), kinds.map((kind) => [kind]).toList());
      for (final request in service.mediaRequests) {
        expect(request[#parentId], isNull);
        expect(request[#recursive], isTrue);
        expect(request[#isFavorite], isTrue);
        expect(request[#limit], 15);
        expect(request[#enableTotalRecordCount], isFalse);
        expect(request[#sortOrder], [SortOrder.ascending]);
        expect(request[#sortBy], [ItemSortBy.seriessortname, ItemSortBy.sortname, ItemSortBy.datelastcontentadded]);
      }
      expect(service.peopleRequests.single[#isFavorite], isTrue);
      expect(service.peopleRequests.single[#limit], 20);
      final favourites = container.read(favouritesProvider);
      expect(favourites.favourites.keys, [FladderItemType.movie, FladderItemType.series]);
      expect(favourites.favourites[FladderItemType.movie]!.map((item) => item.id),
          ['account-hidden', for (var i = 10; i < 24; i++) 'account-movie-$i']);
      expect(favourites.people.single.id, 'account-person');
    });
  }

  test('a concurrent refresh leaves loading set and does not enqueue a second batch', () async {
    final service = _Service()..mediaGate = Completer();
    final container = _container(service, 2);
    addTearDown(container.dispose);
    final notifier = container.read(favouritesProvider.notifier);
    final first = notifier.fetchFavourites();
    await notifier.fetchFavourites();
    expect(container.read(favouritesProvider).loading, isTrue);
    expect(service.mediaRequests, hasLength(9));
    service.mediaGate!.complete();
    await first;
    expect(container.read(favouritesProvider).loading, isFalse);
  });

  test('clearing an old account while refreshing cannot publish old rows or unlock a new refresh', () async {
    final olderGate = Completer<void>();
    final newerGate = Completer<void>();
    final service = _Service()
      ..label = 'old'
      ..mediaGate = olderGate;
    final container = _container(service, 2);
    addTearDown(container.dispose);
    final notifier = container.read(favouritesProvider.notifier);
    final older = notifier.fetchFavourites();

    notifier.clear();
    service
      ..label = 'new'
      ..mediaGate = newerGate;
    final newer = notifier.fetchFavourites();
    olderGate.complete();
    await older;
    expect(container.read(favouritesProvider).favourites, isEmpty);
    expect(container.read(favouritesProvider).loading, isTrue);

    newerGate.complete();
    await newer;
    final favourites = container.read(favouritesProvider);
    expect(favourites.favourites[FladderItemType.movie]!.first.id, 'new-hidden');
    expect(favourites.people.single.id, 'new-person');
    expect(favourites.loading, isFalse);
  });
}
