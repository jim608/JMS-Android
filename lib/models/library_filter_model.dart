import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:freezed_annotation/freezed_annotation.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.enums.swagger.dart';
import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/items/item_shared_models.dart';
import 'package:fladder/models/library_search/library_search_options.dart';
import 'package:fladder/routes/auto_router.gr.dart';
import 'package:fladder/util/map_bool_helper.dart';

part 'library_filter_model.freezed.dart';
part 'library_filter_model.g.dart';

@Freezed(copyWith: true)
abstract class LibraryFilterModel with _$LibraryFilterModel {
  const LibraryFilterModel._();

  const factory LibraryFilterModel({
    @Default("") String searchQuery,
    @Default({}) Map<String, bool> genres,
    @Default({
      ItemFilter.isplayed: false,
      ItemFilter.isunplayed: false,
      ItemFilter.isresumable: false,
    })
    @Default({})
    Map<ItemFilter, bool> itemFilters,
    @StudioEncoder() @Default({}) Map<Studio, bool> studios,
    @Default({}) Map<String, bool> tags,
    @Default({}) Map<int, bool> years,
    @Default({}) Map<String, bool> officialRatings,
    @Default({
      FladderItemType.audio: false,
      FladderItemType.boxset: false,
      FladderItemType.book: false,
      FladderItemType.collectionFolder: false,
      FladderItemType.episode: false,
      FladderItemType.folder: false,
      FladderItemType.movie: false,
      FladderItemType.musicAlbum: false,
      FladderItemType.musicVideo: false,
      FladderItemType.photo: false,
      FladderItemType.person: false,
      FladderItemType.photoAlbum: false,
      FladderItemType.series: false,
      FladderItemType.video: false,
    })
    Map<FladderItemType, bool> types,
    @Default(SortingOptions.sortName) SortingOptions sortingOption,
    @Default(SortingOrder.ascending) SortingOrder sortOrder,
    bool? favourites,
    @Default(true) bool hideEmptyShows,
    @Default(false) bool? recursive,
    @Default(GroupBy.none) GroupBy groupBy,
    @Default(false) bool isDefault,
  }) = _LibraryFilterModel;

  bool get hasActiveFilters => this != defaultFilter;

  LibraryFilterModel loadModel(LibraryFilterModel model, {bool keepSavedValues = false}) {
    Map<T, bool> merge<T>(Map<T, bool> options, Map<T, bool> saved) =>
        keepSavedValues ? {...options.setAll(false), ...saved} : options.replaceMap(saved);

    return copyWith(
      searchQuery: model.searchQuery,
      genres: merge(genres, model.genres),
      itemFilters: merge(itemFilters, model.itemFilters),
      studios: merge(studios, model.studios),
      tags: merge(tags, model.tags),
      years: merge(years.setAll(false), model.years),
      officialRatings: merge(officialRatings, model.officialRatings),
      types: merge(types, model.types),
      sortingOption: model.sortingOption,
      sortOrder: model.sortOrder,
      favourites: model.favourites,
      hideEmptyShows: model.hideEmptyShows,
      recursive: model.recursive,
      groupBy: model.groupBy,
    );
  }

  factory LibraryFilterModel.fromJson(Map<String, dynamic> json) => _$LibraryFilterModelFromJson(json);

  @override
  bool operator ==(covariant LibraryFilterModel other) {
    if (identical(this, other)) return true;
    return listEquals(other.genres.included, genres.included) &&
        listEquals(other.studios.included, studios.included) &&
        listEquals(other.tags.included, tags.included) &&
        listEquals(other.years.included, years.included) &&
        listEquals(other.officialRatings.included, officialRatings.included) &&
        listEquals(other.types.included, types.included) &&
        listEquals(other.itemFilters.included, itemFilters.included) &&
        other.sortingOption == sortingOption &&
        other.sortOrder == sortOrder &&
        other.favourites == favourites &&
        other.recursive == recursive &&
        other.groupBy == groupBy &&
        other.hideEmptyShows == hideEmptyShows &&
        other.searchQuery == searchQuery;
  }

  @override
  int get hashCode {
    return itemFilters.hashCode ^
        genres.hashCode ^
        studios.hashCode ^
        tags.hashCode ^
        years.hashCode ^
        officialRatings.hashCode ^
        types.hashCode ^
        sortingOption.hashCode ^
        sortOrder.hashCode ^
        favourites.hashCode ^
        recursive.hashCode ^
        groupBy.hashCode ^
        hideEmptyShows.hashCode;
  }

  LibraryFilterModel get defaultFilter => LibraryFilterModel(
        genres: genres.setAll(false),
        tags: tags.setAll(false),
        officialRatings: officialRatings.setAll(false),
        years: years.setAll(false),
        studios: studios.setAll(false),
        itemFilters: itemFilters.setAll(false),
        types: types.setAll(false),
      );

  LibraryFilterModel get removeIfFalse {
    return copyWith(
      genres: genres.removeIfFalse,
      tags: tags.removeIfFalse,
      officialRatings: officialRatings.removeIfFalse,
      years: years.removeIfFalse,
      studios: studios.removeIfFalse,
      itemFilters: itemFilters.removeIfFalse,
      types: types.removeIfFalse,
    );
  }

  LibraryFilterModel clear() {
    return defaultFilter;
  }
}

extension LibraryMapFilter<T> on Map<T, bool> {
  Map<T, bool> get removeIfFalse {
    final newMap = Map<T, bool>.from(this);
    newMap.removeWhere((key, value) => !value);
    return newMap;
  }
}

class StudioEncoder implements JsonConverter<Map<Studio, bool>, String> {
  const StudioEncoder();

  @override
  Map<Studio, bool> fromJson(String json) {
    final decodedMap = jsonDecode(json) as Map<dynamic, dynamic>;
    final studios = decodedMap.map((key, value) => MapEntry(Studio.fromJson(key), value as bool));
    return studios;
  }

  @override
  String toJson(Map<Studio, bool> studios) => jsonEncode(studios.map((key, value) => MapEntry(key.toJson(), value)));
}

extension LibrarySearchRouteExtension on LibrarySearchRoute {
  LibrarySearchRoute withFilter(LibraryFilterModel model) {
    return LibrarySearchRoute(
      parentId: args?.parentId,
      favourites: model.favourites,
      sortOrder: model.sortOrder,
      sortingOptions: model.sortingOption,
      types: model.types,
      genres: model.genres,
      studios: model.studios,
      itemFilters: model.itemFilters,
      tags: model.tags,
      years: model.years,
      recursive: model.recursive,
      isDefault: model.isDefault,
      query: model.searchQuery,
    );
  }
}
