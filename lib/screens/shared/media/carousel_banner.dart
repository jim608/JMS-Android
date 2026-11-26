import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/screens/shared/media/banner_play_button.dart';
import 'package:fladder/screens/shared/media/components/media_play_button.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/fladder_image.dart';
import 'package:fladder/util/focus_provider.dart';
import 'package:fladder/util/humanize_duration.dart';
import 'package:fladder/util/item_base_model/item_base_model_extensions.dart';
import 'package:fladder/util/item_base_model/play_item_helpers.dart';
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
  final _pages = PageController(keepPage: false);
  PageController get _pageController => widget.controller ?? _pages;
  late int _page = _pageController.initialPage;
  bool showControls = false;

  @override
  void didUpdateWidget(CarouselBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller || oldWidget.useClassicStyle != widget.useClassicStyle) {
      _page = _pageController.initialPage;
    }
    _page = _page.clamp(0, math.max(0, widget.items.length - 1));
  }

  @override
  void dispose() {
    carouselController.dispose();
    _pages.dispose();
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
    if (widget.items.isEmpty) return const SizedBox.shrink();
    if (!widget.useClassicStyle) return _buildSpotlight(context);
    final pointer = AdaptiveLayout.inputDeviceOf(context) == InputDevice.pointer;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: widget.maxHeight),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          if (width <= 0 || constraints.maxHeight <= 0) return const SizedBox.shrink();
          final cardWidth = (constraints.maxHeight * 2.1)
              .clamp(250.0, math.max(251.0, MediaQuery.sizeOf(context).shortestSide * 0.75))
              .toDouble();
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
                      alignment: Alignment.center,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          mainAxisSize: MainAxisSize.max,
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
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

  void _goToPage(int index) {
    if (MediaQuery.disableAnimationsOf(context)) {
      _pageController.jumpToPage(index);
    } else {
      _pageController.animateToPage(index, duration: const Duration(milliseconds: 250), curve: Curves.easeOutCubic);
    }
  }

  Widget _buildSpotlight(BuildContext context) {
    final strings = MaterialLocalizations.of(context);
    final count = widget.items.length;
    final current = _page.clamp(0, count - 1);
    final next = current + 1 < count ? widget.items[current + 1] : null;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(10, 6, 10, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: widget.maxHeight - 6,
            child: PageView.builder(
              controller: _pageController,
              allowImplicitScrolling: true,
              onPageChanged: (page) => setState(() => _page = page),
              itemCount: count,
              itemBuilder: (context, index) => _buildCard(widget.items[index]),
            ),
          ),
          if (count > 1)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  IconButton(
                    tooltip: strings.previousPageTooltip,
                    onPressed: current == 0 ? null : () => _goToPage(current - 1),
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Text(
                    '${strings.formatDecimal(current + 1)} / ${strings.formatDecimal(count)}',
                    textDirection: TextDirection.ltr,
                    semanticsLabel: strings.tabLabel(tabIndex: current + 1, tabCount: count),
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  Expanded(
                    child: Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: Tooltip(
                        message: strings.nextPageTooltip,
                        child: TextButton.icon(
                          onPressed: next == null ? null : () => _goToPage(current + 1),
                          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                          iconAlignment: IconAlignment.end,
                          icon: const Icon(Icons.chevron_right),
                          label: next == null
                              ? const SizedBox.shrink()
                              : Text(next.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCard(ItemBaseModel item, [double? classicWidth]) {
    final classic = classicWidth != null;
    final border = BorderRadius.circular(classic ? 18 : 20);
    return Padding(
      padding: classic ? const EdgeInsets.symmetric(horizontal: 6) : EdgeInsets.zero,
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
            final wide = constraints.maxWidth >= 720;
            final text = Theme.of(context).textTheme;
            final label = item.label(context.localized);
            final subtitle = label == null || label.isEmpty || label == item.title ? item.subText : label;
            final input = AdaptiveLayout.inputDeviceOf(context);
            final details = FocusButton(
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
                  if (classic || !wide)
                    FladderImage(image: item.bannerImage)
                  else
                    PositionedDirectional(
                      start: constraints.maxWidth * 0.32,
                      end: 0,
                      top: 0,
                      bottom: 0,
                      child: FladderImage(image: item.bannerImage),
                    ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: classic
                          ? LinearGradient(
                              begin: AlignmentDirectional.bottomStart,
                              end: Alignment.topCenter,
                              colors: [
                                ThemesData.of(context).dark.colorScheme.primaryContainer.withValues(
                                  alpha: (constraints.maxWidth / classicWidth).clamp(0, 1),
                                ),
                                Colors.transparent,
                              ],
                            )
                          : wide
                          ? const LinearGradient(
                              begin: AlignmentDirectional.centerStart,
                              end: AlignmentDirectional.centerEnd,
                              stops: [0.32, 0.46, 0.65],
                              colors: [Color(0xFF14171D), Color(0xEA14171D), Color(0x0014171D)],
                            )
                          : const LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              stops: [0.16, 0.49, 0.78],
                              colors: [Color(0x0014171D), Color(0xB314171D), Color(0xFF14171D)],
                            ),
                    ),
                  ),
                  if (classic && showCaption)
                    Align(
                      alignment: AlignmentDirectional.bottomStart,
                      child: Padding(
                        padding: EdgeInsetsDirectional.fromSTEB(16, 8, math.max(76.0, constraints.maxWidth * 0.2), 16),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Flexible(
                              child: Text(
                                item.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: text.headlineMedium?.copyWith(color: Colors.white),
                              ),
                            ),
                            if (subtitle != null && subtitle.isNotEmpty && subtitle != item.title)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: text.titleMedium?.copyWith(color: Colors.white),
                                ),
                              ),
                          ],
                        ),
                      ),
                    )
                  else
                    Semantics(label: item.title),
                ],
              ),
              overlays: [
                if (classic && showCaption) ExcludeFocus(child: BannerPlayButton(item: item, useClassicStyle: true)),
              ],
            );
            if (classic) return details;
            return Stack(
              fit: StackFit.expand,
              children: [
                MergeSemantics(child: details),
                _SpotlightCaption(
                  item: item,
                  subtitle: subtitle,
                  wide: wide,
                  size: constraints.biggest,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SpotlightCaption extends ConsumerWidget {
  const _SpotlightCaption({
    required this.item,
    required this.subtitle,
    required this.size,
    required this.wide,
  });

  final ItemBaseModel item;
  final String? subtitle;
  final Size size;
  final bool wide;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final scaler = MediaQuery.textScalerOf(context);
    final inset = wide ? 32.0 : 18.0;
    final headingSize = wide ? (size.width * 0.042).clamp(32.0, 48.0) : 28.0;
    final metadata = <String>{
      item.type.label(context.localized),
      if (subtitle != null && subtitle!.isNotEmpty && subtitle != item.title) subtitle!,
      if (item.overview.runTime.humanize case final String duration) duration,
    }.join('  ·  ');
    final summary = item.overview.summary.trim();
    final showSummary =
        wide &&
        summary.isNotEmpty &&
        size.height >= 2 * inset + scaler.scale(headingSize) * 2.2 + scaler.scale(16) * 5 + 80;
    return Align(
      alignment: wide ? AlignmentDirectional.centerStart : AlignmentDirectional.bottomStart,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: wide ? math.min(size.width * 0.49, 620) : size.width),
        child: Padding(
          padding: EdgeInsets.all(inset),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IgnorePointer(
                child: Text(
                  metadata,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.labelLarge?.copyWith(color: Colors.white70),
                ),
              ),
              const SizedBox(height: 6),
              Flexible(
                child: IgnorePointer(
                  child: Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.headlineMedium?.copyWith(
                      fontSize: headingSize,
                      fontWeight: FontWeight.w700,
                      height: 1.12,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
              if (showSummary)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: IgnorePointer(
                    child: Text(
                      summary,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyMedium?.copyWith(color: Colors.white70),
                    ),
                  ),
                ),
              SizedBox(height: wide ? 20 : 12),
              MergeSemantics(
                child: MediaPlayButton(
                  item: item,
                  autofocusOnDpad: false,
                  showRestartOption: false,
                  onPressed: (_) => item.play(context, ref),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
