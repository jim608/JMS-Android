import 'package:flutter/material.dart';

import 'package:collection/collection.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:iconsax_plus/iconsax_plus.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.enums.swagger.dart';
import 'package:fladder/models/collection_types.dart';
import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/items/item_shared_models.dart';
import 'package:fladder/models/recommended_model.dart';
import 'package:fladder/models/view_model.dart';
import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/service_provider.dart';
import 'package:fladder/providers/views_provider.dart';
import 'package:fladder/util/localization_helper.dart';

part 'library_screen_provider.freezed.dart';
part 'library_screen_provider.g.dart';

enum LibraryViewType {
  recommended,
  favourites,
  genres;

  const LibraryViewType();

  String label(BuildContext context) => switch (this) {
        LibraryViewType.recommended => context.localized.recommended,
        LibraryViewType.favourites => context.localized.favorites,
        LibraryViewType.genres => context.localized.genre(2),
      };

  IconData get icon => switch (this) {
        LibraryViewType.recommended => IconsaxPlusLinear.star,
        LibraryViewType.favourites => IconsaxPlusLinear.heart,
        LibraryViewType.genres => IconsaxPlusLinear.hierarchy_3,
      };

  IconData get iconSelected => switch (this) {
        LibraryViewType.recommended => IconsaxPlusBold.star,
        LibraryViewType.favourites => IconsaxPlusBold.heart,
        LibraryViewType.genres => IconsaxPlusBold.hierarchy_3,
      };
}

@Freezed(fromJson: false, toJson: false, copyWith: true)
abstract class LibraryScreenModel with _$LibraryScreenModel {
  factory LibraryScreenModel({
    @Default([]) List<ViewModel> views,
    ViewModel? selectedViewModel,
    @Default({LibraryViewType.recommended, LibraryViewType.favourites}) Set<LibraryViewType> viewType,
    @Default([]) List<RecommendedModel> recommendations,
    @Default([]) List<RecommendedModel> genres,
    @Default([]) List<ItemBaseModel> favourites,
  }) = _LibraryScreenModel;
}

@Riverpod(keepAlive: true)
class LibraryScreen extends _$LibraryScreen {
  late final JellyService api = ref.read(jellyApiProvider);
  int _generation = 0;

  @override
  LibraryScreenModel build() {
    ref.onDispose(() => _generation++);
    return LibraryScreenModel();
  }

  Future<void> fetchAllLibraries({bool refreshViews = false}) async {
    final generation = ++_generation;
    final cached = ref.read(viewsProvider).views;
    final loaded = refreshViews || cached.isEmpty ? await ref.read(viewsProvider.notifier).fetchLibraryList() : cached;
    if (generation != _generation) return;
    final views = loaded ?? state.views;
    final previousId = state.selectedViewModel?.id;
    final selected = views.firstWhereOrNull((view) => view.id == previousId) ?? views.firstOrNull;
    final changed = selected?.id != previousId;
    state = state.copyWith(
      views: views,
      selectedViewModel: selected,
      recommendations: changed ? [] : state.recommendations,
      favourites: changed ? [] : state.favourites,
      genres: changed ? [] : state.genres,
    );
    if (selected != null) await _loadLibrary(selected, generation);
  }

  Future<void> selectLibrary(ViewModel viewModel) async {
    final generation = ++_generation;
    if (viewModel.id != state.selectedViewModel?.id) {
      state = state.copyWith(
        selectedViewModel: viewModel,
        recommendations: [],
        favourites: [],
        genres: [],
      );
    }
    await _loadLibrary(viewModel, generation);
  }

  Future<void> setViewType(Set<LibraryViewType> type) async {
    state = state.copyWith(viewType: type);
  }

  Future<void> _loadLibrary(ViewModel viewModel, int generation) async {
    if (generation == _generation && state.viewType.contains(LibraryViewType.recommended)) {
      await _loadRecommendations(viewModel, generation);
    }
    if (generation == _generation && state.viewType.contains(LibraryViewType.favourites)) {
      await _loadFavourites(viewModel, generation);
    }
    if (generation == _generation && state.viewType.contains(LibraryViewType.genres)) {
      await _loadGenres(viewModel, generation);
    }
  }

  Future<void> _loadRecommendations(ViewModel viewModel, int generation) async {
    RecommendedModel continueRecommendations = RecommendedModel(name: const Continue(), posters: []);
    RecommendedModel nextUpRecommendations = RecommendedModel(name: const NextUp(), posters: []);
    RecommendedModel latestRecommendations = RecommendedModel(name: const Latest(), posters: []);
    List<RecommendedModel> otherRecommendations = [];

    final resume = await api.usersUserIdItemsResumeGet(
      parentId: viewModel.id,
      limit: 9,
      enableUserData: true,
      fields: [
        ItemFields.overview,
        ItemFields.primaryimageaspectratio,
      ],
      enableImageTypes: [
        ImageType.primary,
        ImageType.banner,
        ImageType.screenshot,
      ],
      mediaTypes: [MediaType.video],
      enableTotalRecordCount: false,
    );
    if (generation != _generation) return;
    continueRecommendations = RecommendedModel(
      name: const Continue(),
      posters: resume.body?.items?.map((e) => ItemBaseModel.fromBaseDto(e, ref)).toList() ?? [],
      type: null,
    );

    if (viewModel.collectionType == CollectionType.movies) {
      final response = await api.moviesRecommendationsGet(
        parentId: viewModel.id,
        categoryLimit: 6,
        fields: [
          ItemFields.overview,
          ItemFields.primaryimageaspectratio,
        ],
        itemLimit: 9,
      );
      if (generation != _generation) return;
      otherRecommendations = (response.body?.map(
                (e) => RecommendedModel.fromBaseDto(e, ref),
              ) ??
              [])
          .toList();
    }

    final nextUp = await api.showsNextUpGet(
      parentId: viewModel.id,
      limit: 9,
      imageTypeLimit: 1,
      fields: [
        ItemFields.mediasourcecount,
        ItemFields.primaryimageaspectratio,
        ItemFields.overview,
      ],
    );
    if (generation != _generation) return;
    final latest = await api.usersUserIdItemsGet(
      parentId: viewModel.id,
      sortBy: [ItemSortBy.datelastcontentadded, ItemSortBy.datecreated, ItemSortBy.sortname],
      sortOrder: [SortOrder.descending],
      limit: 9,
      includeItemTypes: viewModel.collectionType.itemKinds.expand((e) => e.dtoKind).toList(),
    );
    if (generation != _generation) return;
    latestRecommendations = RecommendedModel(
      name: const Latest(),
      posters: latest.body?.items?.map((e) => ItemBaseModel.fromBaseDto(e, ref)).toList() ?? [],
      type: null,
    );

    nextUpRecommendations = RecommendedModel(
      name: const NextUp(),
      posters: nextUp.body?.items?.map((e) => ItemBaseModel.fromBaseDto(e, ref)).toList() ?? [],
      type: null,
    );

    state = state.copyWith(
      recommendations: [
        continueRecommendations,
        nextUpRecommendations,
        latestRecommendations,
        ...otherRecommendations,
      ]..removeWhere((element) => element.posters.isEmpty),
    );
  }

  Future<void> _loadFavourites(ViewModel viewModel, int generation) async {
    final response = await api.itemsGet(
      parentId: viewModel.id,
      isFavorite: true,
      recursive: true,
      limit: 9,
      includeItemTypes: viewModel.collectionType.itemKinds.expand((e) => e.dtoKind).toList(),
      enableImageTypes: [ImageType.primary],
      fields: [
        ItemFields.mediasourcecount,
        ItemFields.primaryimageaspectratio,
        ItemFields.overview,
      ],
      enableTotalRecordCount: false,
    );

    if (generation == _generation) state = state.copyWith(favourites: response.body?.items ?? []);
  }

  Future<void> _loadGenres(ViewModel viewModel, int generation) async {
    final genres = await api.genresGet(
      sortBy: [ItemSortBy.sortname],
      sortOrder: [SortOrder.ascending],
      includeItemTypes:
          viewModel.collectionType == CollectionType.movies ? [BaseItemKind.movie] : [BaseItemKind.series],
      parentId: viewModel.id,
    );
    if (generation != _generation) return;

    final filteredGenres = (genres.body?.items?.map(
              (item) => GenreItems(id: item.id ?? "", name: item.name ?? ""),
            ) ??
            [])
        .toList();

    final futures = filteredGenres.map((genre) {
      return api
          .itemsGet(
        parentId: viewModel.id,
        genreIds: [genre.id],
        limit: 9,
        recursive: true,
        includeItemTypes: viewModel.collectionType.itemKinds.expand((e) => e.dtoKind).toList(),
        enableImageTypes: [ImageType.primary],
        fields: [
          ItemFields.mediasourcecount,
          ItemFields.primaryimageaspectratio,
          ItemFields.overview,
        ],
        sortBy: [ItemSortBy.random],
        enableTotalRecordCount: false,
        imageTypeLimit: 1,
        sortOrder: [SortOrder.ascending],
      )
          .then((response) {
        final items = response.body?.items;
        if (items != null && items.isNotEmpty) {
          return RecommendedModel(name: Other(genre.name), posters: items);
        }
        return null;
      });
    }).toList();

    final results = await Future.wait(futures);

    if (generation != _generation) return;
    state = state.copyWith(
      genres: results.whereType<RecommendedModel>().toList(),
    );
  }

  void clear() {
    _generation++;
    state = LibraryScreenModel();
  }
}
