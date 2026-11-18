import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/library_search/library_search_options.dart';
import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/connectivity_provider.dart';
import 'package:fladder/providers/library_search_provider.dart';
import 'package:fladder/providers/user_provider.dart';

const homeSavedFilterPreviewLimit = 12;

final homeSavedFilterPreviewProvider = FutureProvider.autoDispose.family<List<ItemBaseModel>, String>((ref, id) async {
  final accountAndFilter = ref.watch(userProvider.select((account) => (
        account?.id,
        account?.credentials,
        account?.libraryFilters.firstWhereOrNull((saved) => saved.id == id && saved.showOnHome),
      )));
  final (_, _, saved) = accountAndFilter;
  ref.watch(serverUrlProvider);
  if (saved == null || ref.watch(offlineStateProvider)) return const [];

  final api = ref.watch(jellyApiProvider);
  final filters = saved.filter;
  final parents = <String?>{if (saved.ids.isEmpty) null, ...saved.ids};
  final responses = await Future.wait(parents.map((parentId) => queryLibraryItems(
        api,
        filters,
        parentId: parentId,
        limit: homeSavedFilterPreviewLimit,
        enableTotalRecordCount: false,
        recursive: parentId == null ? true : null,
        includeChildCount: filters.hideEmptyShows,
      )));
  if (responses.any((response) => response == null)) {
    throw StateError('Unable to load saved filter preview');
  }

  final items = <String, ItemBaseModel>{
    for (final response in responses)
      for (final item in response!.items) item.id: item,
  }.values.toList().hideEmptyChildren(filters.hideEmptyShows);
  if (parents.length > 1) {
    if (filters.sortingOption == SortingOptions.random) {
      items.shuffle();
    } else {
      items.sort((a, b) => sortItems(a, b, filters.sortingOption, filters.sortOrder));
    }
  }
  return items.take(homeSavedFilterPreviewLimit).toList();
});
