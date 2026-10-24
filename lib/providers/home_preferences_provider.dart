import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/models/api_result.dart';
import 'package:fladder/models/home_preferences_model.dart';
import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/service_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/providers/views_provider.dart';

final homePreferencesProvider = StateNotifierProvider<HomePreferencesNotifier, HomePreferencesModel>((ref) {
  return HomePreferencesNotifier(ref);
});

class HomePreferencesNotifier extends StateNotifier<HomePreferencesModel> {
  HomePreferencesNotifier(this.ref) : super(const HomePreferencesModel());

  final Ref ref;

  late final JellyService api = ref.read(jellyApiProvider);

  Future<void> load() async {
    final userConfig = ref.read(userProvider)?.userConfiguration;
    state = state.copyWith(
      hidePlayedInLatest: userConfig?.hidePlayedInLatest ?? false,
      loading: false,
    );
  }

  void setHidePlayedInLatest(bool value) {
    state = state.copyWith(hidePlayedInLatest: value);
  }

  Future<ApiResult<dynamic>> save() async {
    try {
      await _saveWatchedContentPreference();
      await ref.read(userProvider.notifier).updateInformation();
      await ref.read(viewsProvider.notifier).fetchViews();
      return ApiResult.success(null);
    } catch (e) {
      return ApiResult.failure(ApiError(message: e.toString()));
    }
  }

  bool get hasChanges {
    final currentConfig = ref.read(userProvider)?.userConfiguration;
    if (currentConfig == null) return false;
    return (currentConfig.hidePlayedInLatest ?? false) != state.hidePlayedInLatest;
  }

  Future<void> _saveWatchedContentPreference() async {
    final currentConfig = ref.read(userProvider)?.userConfiguration;
    if (currentConfig == null) return;

    // Keep saved library order, exclusions and grouping intact.
    final updated = currentConfig.copyWith(hidePlayedInLatest: state.hidePlayedInLatest);
    await api.updateUserConfiguration(updated);
  }

  void revert() {
    load();
  }
}
