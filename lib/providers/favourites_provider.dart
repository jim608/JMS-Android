import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/models/favourites_model.dart';
import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/service_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/util/item_base_model/item_base_model_extensions.dart';

final favouritesProvider = StateNotifierProvider<FavouritesNotifier, FavouritesModel>((ref) {
  ref.watch(userProvider.select((user) => (user?.id, user?.credentials.serverId, user?.credentials.url)));
  return FavouritesNotifier(ref);
});

class FavouritesNotifier extends StateNotifier<FavouritesModel> {
  FavouritesNotifier(this.ref) : super(FavouritesModel());

  final Ref ref;

  late final JellyService api = ref.read(jellyApiProvider);
  int _refreshGeneration = 0;

  bool _isCurrent(int generation) => mounted && generation == _refreshGeneration;

  Future<void> fetchFavourites() async {
    if (!mounted || state.loading) return;
    final generation = ++_refreshGeneration;
    state = state.copyWith(loading: true);
    try {
      if (!_isCurrent(generation)) return;
      await Future.wait([_fetchMediaFavourites(generation), _fetchPeople(generation)]);
    } finally {
      if (_isCurrent(generation)) state = state.copyWith(loading: false);
    }
  }

  Future<void> _fetchMediaFavourites(int generation) async {
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
    final rows = await Future.wait(kinds.map(_fetchType));
    if (_isCurrent(generation)) {
      state = state.copyWith(favourites: rows.expand((row) => row).toList().groupedItems);
    }
  }

  Future<List<ItemBaseModel>> _fetchType(BaseItemKind kind) async {
    return (await api.itemsGet(
          isFavorite: true,
          recursive: true,
          limit: 15,
          enableTotalRecordCount: false,
          fields: [
            ItemFields.overview,
            ItemFields.genres,
            ItemFields.parentid,
          ],
          includeItemTypes: [kind],
          sortOrder: [SortOrder.ascending],
          sortBy: [ItemSortBy.seriessortname, ItemSortBy.sortname, ItemSortBy.datelastcontentadded],
        ))
            .body
            ?.items ??
        [];
  }

  Future<void> _fetchPeople(int generation) async {
    final response = await api.personsGet(
      limit: 20,
      isFavorite: true,
    );
    if (_isCurrent(generation)) {
      final people = [...?response.body]..sort((a, b) {
          final byName = a.name.compareTo(b.name);
          return byName == 0 ? a.id.compareTo(b.id) : byName;
        });
      state = state.copyWith(people: people);
    }
  }

  void setSearch(String value) {
    state = state.copyWith(searchQuery: value);
  }

  void clear() {
    _refreshGeneration++;
    state = FavouritesModel();
  }
}
