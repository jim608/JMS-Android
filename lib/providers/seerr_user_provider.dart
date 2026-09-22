import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:fladder/providers/seerr_api_provider.dart';
import 'package:fladder/seerr/seerr_models.dart';

part 'seerr_user_provider.g.dart';

@riverpod
class SeerrUser extends _$SeerrUser {
  int _generation = 0;
  @override
  SeerrUserModel? build() {
    ref.watch(seerrApiProvider);
    _generation++;
    ref.onDispose(() => _generation++);
    _fetchUser();
    return null;
  }

  Future<void> _fetchUser() async {
    await refreshUser();
  }

  Future<SeerrUserModel?> refreshUser() async {
    final generation = _generation;
    final api = ref.read(seerrApiProvider);
    try {
      final response = await api.me();
      if (generation != _generation) return null;
      state = response.isSuccessful ? response.body : null;
      return state;
    } catch (_) {
      if (generation == _generation) state = null;
      return null;
    }
  }

  void clearUser() {
    state = null;
  }
}
