import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import 'package:fladder/models/settings/home_settings_model.dart';
import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';

final homeSettingsProvider = StateNotifierProvider<HomeSettingsNotifier, HomeSettingsModel>((ref) {
  return HomeSettingsNotifier(ref);
});

// Keep the original banner preference key so existing interface choices survive upgrades.
final classicInterfaceProvider = Provider<bool>((ref) => ref.watch(
      homeSettingsProvider.select((settings) => settings.useClassicBannerStyle),
    ));

class HomeSettingsNotifier extends StateNotifier<HomeSettingsModel> {
  HomeSettingsNotifier(this.ref) : super(HomeSettingsModel.defaultModel());

  final Ref ref;

  @override
  set state(HomeSettingsModel value) {
    super.state = value;
    ref.read(sharedUtilityProvider).homeSettings = value;
  }

  HomeSettingsModel update(HomeSettingsModel Function(HomeSettingsModel currentState) value) => state = value(state);

  void setLayoutModes(Set<LayoutMode> set) => state = state.copyWith(screenLayouts: set);

  void setViewSize(Set<ViewSize> set) => state = state.copyWith(layoutStates: set);
}
