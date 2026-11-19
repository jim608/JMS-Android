import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:auto_route/auto_route.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_plus/iconsax_plus.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.enums.swagger.dart' as jelly;
import 'package:fladder/models/collection_types.dart';
import 'package:fladder/models/library_filter_model.dart';
import 'package:fladder/models/recommended_model.dart';
import 'package:fladder/models/view_model.dart';
import 'package:fladder/providers/library_screen_provider.dart';
import 'package:fladder/providers/settings/client_settings_provider.dart';
import 'package:fladder/providers/settings/home_settings_provider.dart';
import 'package:fladder/routes/auto_router.gr.dart';
import 'package:fladder/screens/home_screen.dart';
import 'package:fladder/screens/metadata/refresh_metadata.dart';
import 'package:fladder/screens/shared/media/poster_row.dart';
import 'package:fladder/screens/shared/nested_scaffold.dart';
import 'package:fladder/screens/shared/nested_sliver_appbar.dart';
import 'package:fladder/theme.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/fladder_image.dart';
import 'package:fladder/util/focus_provider.dart';
import 'package:fladder/util/localization_helper.dart';
import 'package:fladder/util/sliver_list_padding.dart';
import 'package:fladder/widgets/navigation_scaffold/components/background_image.dart';
import 'package:fladder/widgets/shared/button_group.dart';
import 'package:fladder/widgets/shared/horizontal_list.dart';
import 'package:fladder/widgets/shared/item_actions.dart';
import 'package:fladder/widgets/shared/pull_to_refresh.dart';

@RoutePage()
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({
    super.key,
  });

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> with SingleTickerProviderStateMixin {
  final GlobalKey<RefreshIndicatorState>? refreshKey = GlobalKey();

  bool refreshing = false;
  bool _initialRefresh = true;

  Future<void> _refresh(Future<void> Function() load) async {
    if (refreshing) return;
    setState(() => refreshing = true);
    try {
      await load();
    } finally {
      if (mounted) setState(() => refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(libraryScreenProvider, (previous, next) {
      final selected = next.selectedViewModel;
      if (selected != null && (previous?.viewType.length ?? 0) < next.viewType.length) {
        _refresh(() => ref.read(libraryScreenProvider.notifier).selectLibrary(selected));
      }
    });
    final libraryScreenState = ref.watch(libraryScreenProvider);
    final views = libraryScreenState.views;
    final recommendations = libraryScreenState.recommendations;
    final favourites = libraryScreenState.favourites;
    final selectedView = libraryScreenState.selectedViewModel;
    final viewTypes = libraryScreenState.viewType;
    final genres = libraryScreenState.genres;
    final padding = AdaptiveLayout.adaptivePadding(context);
    final classic = ref.watch(classicInterfaceProvider);

    final useTVExpandedLayout = ref.watch(clientSettingsProvider.select((value) => value.useTVExpandedLayout));

    return NestedScaffold(
      background: BackgroundImage(
        items: [
          ...recommendations.expand((e) => e.posters),
          ...favourites,
        ],
      ),
      body: PullToRefresh(
        refreshOnStart: true,
        contextRefresh: false,
        refreshKey: refreshKey,
        onRefresh: () => _refresh(() {
          final refreshViews = !_initialRefresh;
          _initialRefresh = false;
          return ref.read(libraryScreenProvider.notifier).fetchAllLibraries(refreshViews: refreshViews);
        }),
        child: (context) => AnimatedOpacity(
          opacity: refreshing ? 0.75 : 1.0,
          duration: const Duration(milliseconds: 175),
          child: SizedBox.expand(
            child: CustomScrollView(
              controller: AdaptiveLayout.scrollOf(context, HomeTabs.library),
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                const DefaultSliverTopBadding(),
                if (AdaptiveLayout.viewSizeOf(context) == ViewSize.phone)
                  NestedSliverAppBar(
                    route: LibrarySearchRoute(),
                    parent: context,
                  ),
                if (views.isNotEmpty)
                  SliverToBoxAdapter(
                    child: LibraryRow(
                      padding: padding,
                      views: views,
                      modern: !classic,
                      selectedView: libraryScreenState.selectedViewModel,
                      onSelected: (view) =>
                          _refresh(() => ref.read(libraryScreenProvider.notifier).selectLibrary(view)),
                    ),
                  ),
                if (selectedView != null)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 24, bottom: 16),
                      child: !classic && AdaptiveLayout.viewSizeOf(context) == ViewSize.phone
                          ? Padding(
                              padding: padding,
                              child: Row(
                                spacing: 4,
                                children: [
                                  Expanded(
                                    child: FilledButton.icon(
                                      onPressed: () =>
                                          context.pushRoute(LibrarySearchRoute(parentId: [selectedView.id])),
                                      icon: const Icon(IconsaxPlusLinear.search_normal),
                                      label: Text(
                                        "${context.localized.search} ${selectedView.name}",
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                                  PopupMenuButton<LibraryViewType>(
                                    tooltip: context.localized.filter(2),
                                    icon: const Icon(Icons.tune),
                                    itemBuilder: (context) => [
                                      for (final type in LibraryViewType.values)
                                        CheckedPopupMenuItem(
                                          value: type,
                                          checked: viewTypes.contains(type),
                                          child: Text(type.label(context)),
                                        ),
                                    ],
                                    onSelected: (type) => ref
                                        .read(libraryScreenProvider.notifier)
                                        .setViewType(
                                          viewTypes.contains(type)
                                              ? ({...viewTypes}..remove(type))
                                              : {...viewTypes, type},
                                        ),
                                  ),
                                  IconButton(
                                    tooltip: context.localized.scanLibrary,
                                    onPressed: () => showRefreshPopup(context, selectedView.id, selectedView.name),
                                    icon: const Icon(IconsaxPlusLinear.refresh),
                                  ),
                                ],
                              ),
                            )
                          : SizedBox(
                        height: 40,
                        child: ListView(
                          padding: padding,
                          shrinkWrap: true,
                          scrollDirection: Axis.horizontal,
                          children: [
                            FilledButton.tonalIcon(
                              onPressed: () => context.pushRoute(LibrarySearchRoute(parentId: [selectedView.id])),
                              label: Text("${context.localized.search} ${selectedView.name}..."),
                              icon: const Icon(IconsaxPlusLinear.search_normal),
                            ),
                            const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 4.0),
                              child: VerticalDivider(),
                            ),
                            ExpressiveButtonGroup(
                              multiSelection: true,
                              options: LibraryViewType.values
                                  .map((element) => ButtonGroupOption(
                                      value: element,
                                      icon: Icon(element.icon),
                                      selected: Icon(element.iconSelected),
                                      child: Text(
                                        element.label(context),
                                      )))
                                  .toList(),
                              selectedValues: viewTypes,
                              onSelected: (value) => ref.read(libraryScreenProvider.notifier).setViewType(value),
                            ),
                            const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 4.0),
                              child: VerticalDivider(),
                            ),
                            ElevatedButton.icon(
                              onPressed: () => showRefreshPopup(context, selectedView.id, selectedView.name),
                              label: Text(context.localized.scanLibrary),
                              icon: const Icon(IconsaxPlusLinear.refresh),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (viewTypes.isEmpty)
                  SliverFillRemaining(
                    child: Center(child: Text(context.localized.noResults)),
                  ),
                if (viewTypes.contains(LibraryViewType.recommended) && recommendations.isNotEmpty) ...[
                  ...recommendations.where((element) => element.posters.isNotEmpty).map(
                    (element) {
                      return SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8.0),
                          child: PosterRow(
                            tvMode: useTVExpandedLayout,
                            contentPadding: padding,
                            posters: element.posters,
                            collectionAspectRatio: element.name is Continue ? 1.2 : null,
                            imagePriority: element.name is Continue
                                ? const [jelly.ImageType.thumb, jelly.ImageType.backdrop, jelly.ImageType.primary]
                                : null,
                            label: element.type != null
                                ? "${element.type?.label(context.localized)} - ${element.name.label(context.localized)}"
                                : element.name.label(context.localized),
                          ),
                        ),
                      );
                    },
                  ),
                ],
                if (viewTypes.contains(LibraryViewType.favourites) && favourites.isNotEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8.0),
                      child: PosterRow(
                        tvMode: useTVExpandedLayout,
                        contentPadding: padding,
                        onLabelClick: () => context.pushRoute(
                          LibrarySearchRoute(
                            parentId: [libraryScreenState.selectedViewModel?.id ?? ""],
                          ).withFilter(
                            const LibraryFilterModel(
                              favourites: true,
                              recursive: true,
                            ),
                          ),
                        ),
                        posters: favourites,
                        label: context.localized.favorites,
                      ),
                    ),
                  ),
                if (viewTypes.contains(LibraryViewType.genres) && genres.isNotEmpty) ...[
                  ...genres.where((element) => element.posters.isNotEmpty).map(
                        (element) => SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8.0),
                            child: PosterRow(
                              tvMode: useTVExpandedLayout,
                              contentPadding: padding,
                              posters: element.posters,
                              onLabelClick: () => context.pushRoute(
                                LibrarySearchRoute(
                                  parentId: [libraryScreenState.selectedViewModel?.id ?? ""],
                                ).withFilter(
                                  LibraryFilterModel(
                                    recursive: true,
                                    genres: {(element.name as Other).customLabel: true},
                                  ),
                                ),
                              ),
                              label: element.type != null
                                  ? "${element.type?.label(context.localized)} - ${element.name.label(context.localized)}"
                                  : element.name.label(context.localized),
                            ),
                          ),
                        ),
                      )
                ],
                const DefaultSliverBottomPadding(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class LibraryRow extends ConsumerWidget {
  const LibraryRow({
    super.key,
    required this.views,
    this.selectedView,
    required this.padding,
    this.onSelected,
    this.onLongPress,
    this.viewActions,
    this.enableImageCache = true,
    this.modern = false,
  });

  final List<ViewModel> views;
  final ViewModel? selectedView;
  final EdgeInsets padding;
  final FutureOr Function(ViewModel selected)? onSelected;
  final FutureOr Function(ViewModel selected)? onLongPress;
  final List<ItemActionButton> Function(ViewModel item)? viewActions;
  final bool enableImageCache;
  final bool modern;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return HorizontalList(
      label: context.localized.library(views.length),
      items: views,
      height: modern ? 112 + 2 * (MediaQuery.textScalerOf(context).scale(16) - 16).clamp(0.0, 80.0) : 155,
      autoFocus: true,
      startIndex: selectedView != null ? views.indexOf(selectedView!) : null,
      contentPadding: padding,
      itemBuilder: (context, index) {
        final view = views[index];
        final isSelected = selectedView == view;
        final List<ItemActionButton> combinedViewActions = [
          ItemActionButton(
            label: Text(context.localized.search),
            icon: const Icon(IconsaxPlusLinear.search_normal),
            action: () => context.pushRoute(LibrarySearchRoute(parentId: [view.id])),
          ),
          ItemActionButton(
            label: Text(context.localized.scanLibrary),
            icon: const Icon(IconsaxPlusLinear.refresh),
            action: () => showRefreshPopup(context, view.id, view.name),
          ),
          ...?viewActions?.call(view),
        ];
        Widget focusCard(Widget child) => FocusButton(
          key: Key(view.id),
          onTap: isSelected ? null : () => onSelected?.call(view),
          onLongPress: onLongPress != null
              ? () => onLongPress?.call(view)
              : () => context.pushRoute(LibrarySearchRoute(parentId: [view.id])),
          onSecondaryTapDown: (details) async {
            Offset localPosition = details.globalPosition;
            RelativeRect position = RelativeRect.fromLTRB(
              localPosition.dx,
              localPosition.dy,
              localPosition.dx,
              localPosition.dy,
            );
            await showMenu(
              context: context,
              position: position,
              items: combinedViewActions.popupMenuItems(useIcons: true),
            );
          },
          child: child,
        );
        if (modern) {
          final scheme = Theme.of(context).colorScheme;
          final hasImage = view.imageData?.primary != null;
          return MergeSemantics(
            child: Semantics(
              button: true,
              selected: isSelected,
              child: focusCard(
                Container(
                  width: AdaptiveLayout.viewSizeOf(context) == ViewSize.phone ? 172 : 224,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: isSelected ? scheme.secondaryContainer : scheme.surfaceContainerHigh,
                    borderRadius: FladderTheme.smallShape.borderRadius,
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (hasImage) ...[
                        FladderImage(image: view.imageData?.primary, fit: BoxFit.cover, cachedImage: enableImageCache),
                        const DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Colors.transparent, Color(0xEA101316)],
                            ),
                          ),
                        ),
                      ] else
                        PositionedDirectional(
                          top: 12,
                          start: 14,
                          child: Icon(
                            view.collectionType.icon,
                            color: isSelected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant,
                          ),
                        ),
                      if (isSelected)
                        PositionedDirectional(
                          top: 8,
                          end: 8,
                          child: CircleAvatar(
                            radius: 12,
                            backgroundColor: scheme.primary,
                            child: Icon(Icons.check, size: 16, color: scheme.onPrimary),
                          ),
                        ),
                      PositionedDirectional(
                        start: 14,
                        end: 12,
                        bottom: 10,
                        child: Text(
                          view.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: hasImage
                                ? Colors.white
                                : isSelected
                                ? scheme.onSecondaryContainer
                                : scheme.onSurface,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            focusCard(
              AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: FladderTheme.smallShape.borderRadius,
                  border: Border.all(
                    color: Theme.of(context).colorScheme.primary.withValues(alpha: isSelected ? 1.0 : 0.0),
                    width: isSelected ? 3 : 0,
                  ),
                ),
                clipBehavior: Clip.hardEdge,
                width: 200,
                child: ClipRRect(
                  borderRadius: FladderTheme.smallShape.borderRadius,
                  child: AspectRatio(
                    aspectRatio: 1.60,
                    child: FladderImage(
                      image: view.imageData?.primary,
                      fit: BoxFit.cover,
                      cachedImage: enableImageCache,
                      placeHolder: Center(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          spacing: 8,
                          children: [
                            Icon(view.collectionType.icon),
                            Text(
                              view.name,
                              style: Theme.of(context).textTheme.titleMedium,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Row(
              spacing: 8,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (isSelected)
                  Container(
                    height: 12,
                    width: 12,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                Text(
                  view.name,
                  style: Theme.of(context).textTheme.titleMedium,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.start,
                )
              ],
            )
          ],
        );
      },
    );
  }
}
