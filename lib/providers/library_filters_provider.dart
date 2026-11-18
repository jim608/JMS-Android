import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/library_filters_model.dart';
import 'package:fladder/providers/user_provider.dart';

part 'library_filters_provider.g.dart';

@riverpod
class LibraryFilters extends _$LibraryFilters {
  @override
  List<LibraryFiltersModel> build(List<String> ids) {
    if (ids.isEmpty) {
      return ref.watch(userLibraryFilters);
    }
    return ref.watch(
      userLibraryFilters.select((filters) => filters.where((filter) => filter.containsSameIds(ids)).toList()),
    );
  }

  void removeFilter(LibraryFiltersModel model) => ref.read(userProvider.notifier).removeFilter(model);

  void saveFilter(LibraryFiltersModel model) => ref.read(userProvider.notifier).saveFilter(model);

  void deleteAllFilters() => ref.read(userProvider.notifier).deleteAllFilters();

  void updateSortOrder(FilterSortKey key, List<String> newOrder) =>
      ref.read(userProvider.notifier).updateFilterSortOrder(key, newOrder);
}

final userLibraryFilters = Provider.autoDispose<List<LibraryFiltersModel>>((ref) {
  return ref.watch(userProvider.select((value) => value?.savedLibraryFilters ?? []));
});

final libraryFiltersByKeyProvider = Provider.family<List<LibraryFiltersModel>, FilterSortKey>((ref, key) {
  final account = ref.watch(userProvider);
  if (account == null) return [];
  return (account.userSettings ?? UserSettings())
      .copyWith(libraryFilters: account.savedLibraryFilters)
      .getFilterSortOrder(key);
});
