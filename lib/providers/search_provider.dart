import 'package:chopper/chopper.dart';
import 'package:fladder/models/search_model.dart';
import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/service_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/util/item_base_model/item_base_model_extensions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final searchProvider = StateNotifierProvider<SearchNotifier, SearchModel>((ref) {
  ref.watch(userProvider.select((user) => (user?.id, user?.credentials.serverId, user?.credentials.url)));
  return SearchNotifier(ref);
});

class SearchNotifier extends StateNotifier<SearchModel> {
  SearchNotifier(this.ref) : super(SearchModel());

  final Ref ref;

  late final JellyService api = ref.read(jellyApiProvider);
  int _generation = 0;
  String? _activeQuery;

  Future<Response?> searchQuery() async {
    final query = state.searchQuery;
    if (query.isEmpty || (state.loading && _activeQuery == query)) return null;
    final generation = ++_generation;
    _activeQuery = query;
    state = state.copyWith(loading: true, hasError: false);
    try {
      final response = await api.itemsGet(recursive: true, searchTerm: query);
      if (!mounted || generation != _generation) return null;
      state = state.copyWith(
        resultCount: response.isSuccessful ? response.body?.totalRecordCount ?? 0 : 0,
        results: response.isSuccessful ? response.body?.items.groupedItems ?? {} : {},
        hasError: !response.isSuccessful,
      );
      return response;
    } catch (_) {
      if (mounted && generation == _generation) {
        state = state.copyWith(hasError: true, resultCount: 0, results: {});
      }
      return null;
    } finally {
      if (mounted && generation == _generation) {
        state = state.copyWith(loading: false);
      }
    }
  }

  void setQuery(String searchQuery) {
    final query = searchQuery.trim();
    if (query == state.searchQuery) return;
    _generation++;
    state = SearchModel(searchQuery: query);
  }

  void clear() {
    _generation++;
    state = SearchModel();
  }
}
