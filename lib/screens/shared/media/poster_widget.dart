import 'package:material_ui/material_ui.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_plus/iconsax_plus.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.enums.swagger.dart' as jelly;
import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/items/album_model.dart';
import 'package:fladder/models/items/artist_model.dart';
import 'package:fladder/models/items/item_shared_models.dart';
import 'package:fladder/providers/settings/home_settings_provider.dart';
import 'package:fladder/screens/shared/media/components/poster_image.dart';
import 'package:fladder/theme.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/focus_provider.dart';
import 'package:fladder/util/item_base_model/item_base_model_extensions.dart';
import 'package:fladder/util/item_base_model/play_item_helpers.dart';
import 'package:fladder/util/localization_helper.dart';
import 'package:fladder/widgets/shared/clickable_text.dart';
import 'package:fladder/widgets/shared/item_actions.dart';

class PosterWidget extends ConsumerWidget {
  final ItemBaseModel poster;
  final Widget? subTitle;
  final bool? selected;
  final int maxLines;
  final double? aspectRatio;
  final bool inlineTitle;
  final bool underTitle;
  final Set<ItemActions> excludeActions;
  final List<ItemAction> otherActions;
  final Function(String id, UserData? newData)? onUserDataChanged;
  final Function(ItemBaseModel newItem)? onItemUpdated;
  final Function(ItemBaseModel oldItem)? onItemRemoved;
  final Function(VoidCallback action, ItemBaseModel item)? onPressed;
  final List<jelly.ImageType>? imagePriority;
  final Function(bool focus)? onFocusChanged;
  final bool showSyncStatus;

  const PosterWidget({
    required this.poster,
    this.subTitle,
    this.maxLines = 3,
    this.selected,
    this.aspectRatio,
    this.inlineTitle = false,
    this.underTitle = true,
    this.excludeActions = const {},
    this.otherActions = const [],
    this.onUserDataChanged,
    this.onItemUpdated,
    this.onItemRemoved,
    this.onPressed,
    this.imagePriority,
    this.onFocusChanged,
    this.showSyncStatus = false,
    super.key,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final classic = ref.watch(classicInterfaceProvider);
    final text = Theme.of(context).textTheme;
    final opacity = classic ? 0.65 : 0.82;
    final metadataStyle = classic
        ? text.titleSmall?.copyWith(fontWeight: FontWeight.bold)
        : text.bodySmall?.copyWith(fontWeight: FontWeight.w500, height: 1.35);
    final showTitles = !inlineTitle && underTitle;
    final subText = showTitles ? poster.subText ?? '' : '';
    final shortText = showTitles && maxLines > 1 ? poster.subTextShort(context.localized) ?? '' : '';
    final firstLine = subText.isNotEmpty ? subText : shortText;
    final secondLine = subText.isNotEmpty && (classic || subText != shortText) ? shortText : '';
    final hasFirstLine = subTitle != null || firstLine.isNotEmpty;
    final metadataLines = (hasFirstLine ? 1 : 0) + (secondLine.isNotEmpty ? 1 : 0);
    final subtitleClick = switch (poster) {
      AlbumModel album => () {
        album.parentBaseModel.navigateTo(context);
      },
      _ => null,
    };
    return AspectRatio(
      aspectRatio: aspectRatio ?? AdaptiveLayout.poster(context).ratio,
      child: Column(
        mainAxisSize: MainAxisSize.max,
        children: [
          Expanded(
            child: PosterImage(
              poster: poster,
              selected: selected,
              playVideo: (value) async => await poster.play(context, ref),
              inlineTitle: inlineTitle,
              excludeActions: excludeActions,
              otherActions: otherActions,
              onUserDataChanged: (newData) => onUserDataChanged?.call(poster.id, newData),
              onItemRemoved: onItemRemoved,
              onItemUpdated: onItemUpdated,
              onPressed: onPressed,
              imagePriority: imagePriority,
              onFocusChanged: onFocusChanged,
              showSyncStatus: showSyncStatus,
            ),
          ),
          if (showTitles)
            ExcludeFocus(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Flexible(
                    child: Padding(
                      padding: EdgeInsets.only(top: classic ? 0 : 6),
                      child: ClickableText(
                        onTap: AdaptiveLayout.inputDeviceOf(context) == InputDevice.pointer
                            ? () => switch (poster) {
                                ArtistModel artist => artist.navigateTo(context),
                                AlbumModel album => album.navigateTo(context),
                                _ => poster.parentBaseModel.navigateTo(context),
                              }
                            : null,
                        text: poster.title,
                        maxLines: !classic && maxLines - metadataLines >= 2 ? 2 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleMedium?.copyWith(
                          fontWeight: classic ? FontWeight.bold : FontWeight.w600,
                          height: classic ? null : 1.22,
                        ),
                      ),
                    ),
                  ),
                  if (classic || hasFirstLine)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        if (subTitle != null) ...[Flexible(child: subTitle!)],
                        if (classic || firstLine.isNotEmpty)
                          Flexible(
                            child: ClickableText(
                              onTap: subtitleClick,
                              opacity: opacity,
                              text: firstLine,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: metadataStyle,
                            ),
                          ),
                      ],
                    ),
                  if (classic || secondLine.isNotEmpty)
                    Flexible(
                      child: ClickableText(
                        opacity: opacity,
                        text: secondLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: metadataStyle,
                      ),
                    ),
                ].take(maxLines).toList(),
              ),
            ),
        ],
      ),
    );
  }
}

class PosterPlaceHolder extends StatelessWidget {
  final Function() onTap;
  final double aspectRatio;
  const PosterPlaceHolder({required this.onTap, required this.aspectRatio, super.key});

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: aspectRatio,
      child: FractionallySizedBox(
        alignment: Alignment.topCenter,
        heightFactor: 1,
        child: FocusButton(
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: FladderTheme.defaultShape.borderRadius,
              color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.1),
            ),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  spacing: 8,
                  children: [
                    const Icon(IconsaxPlusLinear.more_square, size: 46),
                    Text(context.localized.showMore, style: Theme.of(context).textTheme.labelMedium),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
