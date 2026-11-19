import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/screens/shared/media/banner_play_button.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/fladder_image.dart';
import 'package:fladder/util/focus_provider.dart';
import 'package:fladder/util/item_base_model/item_base_model_extensions.dart';
import 'package:fladder/util/localization_helper.dart';
import 'package:fladder/util/themes_data.dart';
import 'package:fladder/widgets/shared/ensure_visible.dart';
import 'package:fladder/widgets/shared/item_actions.dart';
import 'package:fladder/widgets/shared/modal_bottom_sheet.dart';

class CarouselBanner extends ConsumerStatefulWidget {
  final PageController? controller;
  final List<ItemBaseModel> items;
  final double maxHeight;
  final bool useClassicStyle;
  const CarouselBanner({
    this.controller,
    required this.items,
    this.maxHeight = 250,
    this.useClassicStyle = false,
    super.key,
  });

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _CarouselBannerState();
}

class _CarouselBannerState extends ConsumerState<CarouselBanner> {
  final carouselController = CarouselController();
  bool showControls = false;

  @override
  void dispose() {
    carouselController.dispose();
    super.dispose();
  }

  void _pageBy(double distance) {
    final position = carouselController.position;
    final target = (position.pixels + distance).clamp(position.minScrollExtent, position.maxScrollExtent);
    if (MediaQuery.disableAnimationsOf(context)) {
      position.jumpTo(target);
    } else {
      position.animateTo(target, duration: const Duration(milliseconds: 250), curve: Curves.easeOutCubic);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pointer = AdaptiveLayout.inputDeviceOf(context) == InputDevice.pointer;
    final classic = widget.useClassicStyle;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: widget.maxHeight),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          if (width <= 0 || constraints.maxHeight <= 0) return const SizedBox.shrink();
          final cardWidth = classic
              ? (constraints.maxHeight * 2.1)
                    .clamp(250.0, math.max(251.0, MediaQuery.sizeOf(context).shortestSide * 0.75))
                    .toDouble()
              : math.min(width * 0.90, constraints.maxHeight * 1.85);
          final extent = widget.items.length == 1 ? width : math.min(width, cardWidth);
          final canPage = pointer && widget.items.length > 1 && widget.items.length * extent > width;
          return MouseRegion(
            onEnter: (_) => setState(() => showControls = true),
            onExit: (_) {
              if (showControls) setState(() => showControls = false);
            },
            child: Padding(
              padding: EdgeInsets.only(top: AdaptiveLayout.of(context).isDesktop ? 6 : 10),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CarouselView.builder(
                    controller: carouselController,
                    itemExtent: extent,
                    itemCount: widget.items.length,
                    itemBuilder: (context, index) => _buildCard(widget.items[index], cardWidth),
                  ),
                  if (canPage && showControls)
                    Align(
                      alignment: classic ? Alignment.center : AlignmentDirectional.topEnd,
                      child: Padding(
                        padding: classic
                            ? const EdgeInsets.symmetric(horizontal: 16)
                            : const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                        child: Row(
                          mainAxisSize: classic ? MainAxisSize.max : MainAxisSize.min,
                          mainAxisAlignment: classic ? MainAxisAlignment.spaceBetween : MainAxisAlignment.start,
                          spacing: 4,
                          children: [
                            IconButton.filledTonal(
                              tooltip: MaterialLocalizations.of(context).previousPageTooltip,
                              onPressed: () => _pageBy(-extent),
                              icon: const Icon(Icons.chevron_left),
                            ),
                            IconButton.filledTonal(
                              tooltip: MaterialLocalizations.of(context).nextPageTooltip,
                              onPressed: () => _pageBy(extent),
                              icon: const Icon(Icons.chevron_right),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildCard(ItemBaseModel item, double cardWidth) {
    final classic = widget.useClassicStyle;
    final border = BorderRadius.circular(classic ? 18 : 20);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        elevation: classic ? 3 : 0,
        shape: RoundedRectangleBorder(
          borderRadius: border,
          side: classic ? const BorderSide(color: Color(0x1AFFFFFF)) : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final showCaption = constraints.maxWidth >= 156;
            final spacious = constraints.maxWidth >= 480;
            final inset = spacious && !classic ? 24.0 : 16.0;
            final text = Theme.of(context).textTheme;
            final titleStyle = classic
                ? text.headlineMedium
                : (spacious ? text.headlineMedium : text.headlineSmall)?.copyWith(
                    fontWeight: FontWeight.w700,
                    height: 1.16,
                  );
            final label = item.label(context.localized);
            final subtitle = label == null || label.isEmpty || label == item.title ? item.subText : label;
            final input = AdaptiveLayout.inputDeviceOf(context);
            return FocusButton(
              borderRadius: border,
              onTap: () => item.navigateTo(context),
              onFocusChanged: (focused) {
                if (focused) this.context.ensureVisible();
              },
              onLongPress: input == InputDevice.pointer
                  ? null
                  : () => showBottomSheetPill(
                      context: context,
                      item: item,
                      content: (scrollContext, scrollController) => ListView(
                        shrinkWrap: true,
                        controller: scrollController,
                        children: item.generateActions(context, ref).listTileItems(scrollContext, useIcons: true),
                      ),
                    ),
              onSecondaryTapDown: input == InputDevice.touch
                  ? null
                  : (details) {
                      final offset = details.globalPosition;
                      showMenu(
                        context: context,
                        position: RelativeRect.fromLTRB(offset.dx, offset.dy, offset.dx, offset.dy),
                        items: item.generateActions(context, ref).popupMenuItems(useIcons: true),
                      );
                    },
              child: Stack(
                fit: StackFit.expand,
                children: [
                  FladderImage(image: item.bannerImage),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: classic
                          ? LinearGradient(
                              begin: AlignmentDirectional.bottomStart,
                              end: Alignment.topCenter,
                              colors: [
                                ThemesData.of(context).dark.colorScheme.primaryContainer.withValues(
                                  alpha: (constraints.maxWidth / cardWidth).clamp(0, 1),
                                ),
                                Colors.transparent,
                              ],
                            )
                          : const LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              stops: [0.20, 0.62, 1],
                              colors: [Colors.transparent, Color(0x780A1018), Color(0xF0090E16)],
                            ),
                    ),
                  ),
                  if (showCaption)
                    Align(
                      alignment: AlignmentDirectional.bottomStart,
                      child: Padding(
                        padding: EdgeInsetsDirectional.fromSTEB(
                          inset,
                          8,
                          classic ? math.max(76.0, constraints.maxWidth * 0.2) : 76,
                          inset,
                        ),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: classic ? double.infinity : 600),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Flexible(
                                child: Text(
                                  item.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: titleStyle?.copyWith(color: Colors.white),
                                ),
                              ),
                              if (subtitle != null && subtitle.isNotEmpty && subtitle != item.title)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    subtitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: classic
                                        ? text.titleMedium?.copyWith(color: Colors.white)
                                        : text.bodyMedium?.copyWith(color: const Color(0xE6FFFFFF)),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    )
                  else
                    Semantics(label: item.title),
                ],
              ),
              overlays: [
                if (showCaption)
                  ExcludeFocus(
                    child: BannerPlayButton(item: item, useClassicStyle: classic),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
