import 'package:material_ui/material_ui.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/settings/home_settings_model.dart';
import 'package:fladder/providers/settings/home_settings_provider.dart';
import 'package:fladder/screens/shared/media/carousel_banner.dart';
import 'package:fladder/screens/shared/media/detailed_banner.dart';
import 'package:fladder/screens/shared/media/media_banner.dart';
import 'package:fladder/screens/shared/media/tv_slider_banner.dart';

class HomeBannerWidget extends ConsumerWidget {
  final List<ItemBaseModel> posters;
  final Function(ItemBaseModel selected) onSelect;

  const HomeBannerWidget({
    required this.posters,
    required this.onSelect,
    super.key,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bannerType = ref.watch(homeSettingsProvider.select((settings) => settings.homeBanner));
    final useClassicStyle = ref.watch(classicInterfaceProvider);
    final shortestSide = MediaQuery.sizeOf(context).shortestSide;
    final maxHeight = (shortestSide * 0.6).clamp(125.0, 375.0);

    return switch (bannerType) {
      HomeBanner.carousel => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CarouselBanner(
              items: posters,
              maxHeight: useClassicStyle
                  ? maxHeight
                  : (shortestSide * 0.8).clamp(240.0, 400.0) +
                      (MediaQuery.textScalerOf(context).scale(48) - 48).clamp(0.0, 120.0),
              useClassicStyle: useClassicStyle,
            ),
            SizedBox(height: !useClassicStyle && posters.length > 1 ? 8 : 24),
          ],
        ),
      HomeBanner.banner => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: MediaBanner(
            items: posters,
            maxHeight: maxHeight,
            useClassicStyle: useClassicStyle,
          ),
        ),
      HomeBanner.detailedBanner => DetailedBanner(
          posters: posters,
          onSelect: onSelect,
        ),
      HomeBanner.tvSliderBanner => TVSliderBanner(
          items: posters,
          onSelect: onSelect,
          maxHeight: maxHeight,
        ),
      _ => const SizedBox.shrink(),
    };
  }
}
