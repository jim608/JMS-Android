import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:auto_route/auto_route.dart';
import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.enums.swagger.dart';
import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/models/collection_types.dart';
import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/library_filters_model.dart';
import 'package:fladder/models/library_search/library_search_options.dart';
import 'package:fladder/models/media_playback_model.dart';
import 'package:fladder/models/settings/home_settings_model.dart';
import 'package:fladder/providers/connectivity_provider.dart';
import 'package:fladder/providers/dashboard_mode_provider.dart';
import 'package:fladder/providers/dashboard_provider.dart';
import 'package:fladder/providers/home_saved_filters_provider.dart';
import 'package:fladder/providers/jellyfin_websocket_provider.dart';
import 'package:fladder/providers/library_filters_provider.dart';
import 'package:fladder/providers/music_dashboard_provider.dart';
import 'package:fladder/providers/settings/client_settings_provider.dart';
import 'package:fladder/providers/settings/home_settings_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/providers/views_provider.dart';
import 'package:fladder/routes/auto_router.gr.dart';
import 'package:fladder/screens/dashboard/home_banner_widget.dart';
import 'package:fladder/screens/dashboard/music_dashboard_screen.dart';
import 'package:fladder/screens/home_screen.dart';
import 'package:fladder/screens/shared/media/poster_row.dart';
import 'package:fladder/screens/shared/nested_scaffold.dart';
import 'package:fladder/screens/shared/nested_sliver_appbar.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/focus_provider.dart';
import 'package:fladder/util/list_padding.dart';
import 'package:fladder/util/localization_helper.dart';
import 'package:fladder/util/sliver_list_padding.dart';
import 'package:fladder/widgets/navigation_scaffold/components/background_image.dart';
import 'package:fladder/widgets/shared/pinch_poster_zoom.dart';
import 'package:fladder/widgets/shared/poster_size_slider.dart';
import 'package:fladder/widgets/shared/pull_to_refresh.dart';

@RoutePage()
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({
    super.key,
  });

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  late final Timer _refreshTimer;
  late final AppLifecycleListener _lifecycleListener;
  bool _visible = true;
  final GlobalKey<RefreshIndicatorState> _refreshIndicatorKey = GlobalKey<RefreshIndicatorState>();

  final textController = TextEditingController();

  final selectedPoster = ValueNotifier<ItemBaseModel?>(null);


  @override
  void initState() {
    super.initState();
    _lifecycleListener = AppLifecycleListener(onResume: _refreshOnReturn);
    _refreshTimer = Timer.periodic(const Duration(minutes: 2), (timer) {
      if (!_canRefresh) return;
      if (!ref.read(jellyfinWebSocketConnectedProvider)) {
        _refresh();
      } else if (!ref.read(musicDashboardModeProvider)) {
        ref.read(dashboardProvider.notifier).refreshLiveTV();
      }
    });
  }

  void _refresh() {
    ref.read(musicDashboardModeProvider)
        ? ref.read(musicDashboardProvider.notifier).fetchMusicHome(silent: true)
        : ref.read(dashboardProvider.notifier).refreshLoadedSections();
  }

  void _refreshOnReturn() {
    if (_canRefresh) _refresh();
  }

  bool get _canRefresh {
    final appInForeground = WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    final videoFullScreen = ref.read(mediaPlaybackProvider).state == VideoPlayerState.fullScreen;
    return _visible && appInForeground && !videoFullScreen;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = context.watchRouter.topRoute.name == DashboardRoute.name;
    final entered = visible && !_visible;
    _visible = visible;
    if (entered) Future.microtask(_refreshOnReturn);
  }

  @override
  void dispose() {
    _refreshTimer.cancel();
    _lifecycleListener.dispose();
    super.dispose();
  }

  Future<void> _refreshHome() async {
    if (!mounted) return;
    await ref.read(userProvider.notifier).updateInformation();
    if (mounted) await ref.read(dashboardProvider.notifier).refreshDashboard();
  }

  @override
  Widget build(BuildContext context) {
    return _buildDashboard(context);
  }

  Widget _buildDashboard(BuildContext context) {
    if (ref.watch(musicDashboardModeProvider)) {
      return const MusicDashboardScreen();
    }

    final padding = AdaptiveLayout.adaptivePadding(context);
    final bannerType = ref.watch(homeSettingsProvider.select((value) => value.homeBanner));
    final dashboardData = ref.watch(dashboardProvider);
    final views = ref.watch(viewsProvider);
    final savedFilters = ref.watch(libraryFiltersByKeyProvider(FilterSortKey.dashboard));
    final homeSettings = ref.watch(homeSettingsProvider);
    final homeBanner = ref.watch(homeSettingsProvider.select((value) => value.homeBanner)) != HomeBanner.hide;
    final resumeVideo = dashboardData.resumeVideo;
    final resumeAudio = dashboardData.resumeAudio;
    final resumeBooks = dashboardData.resumeBooks;
    final tvChannels = dashboardData.activePrograms;

    final dashboardSorting = ref.watch(userProvider.select((value) => value?.userSettings?.dashboardSorting)) ??
        DashboardSorting.defaultSorting;

    final allResume = [...resumeVideo, ...resumeAudio, ...resumeBooks].toList();

    final homeCarouselItems = switch (homeSettings.carouselSettings) {
      HomeCarouselSettings.nextUp => dashboardData.nextUp,
      HomeCarouselSettings.combined => [...allResume, ...dashboardData.nextUp],
      HomeCarouselSettings.cont => allResume,
    };

    final showsBanner = homeBanner && homeCarouselItems.isNotEmpty;

    final loadedSections = dashboardData.loadedSections;
    final visibleSections = homeBanner && !loadedSections.contains(DashboardSorting.nextUp)
        ? <DashboardSorting>[]
        : dashboardSorting.entries
            .where((entry) => entry.value)
            .map((entry) => entry.key)
            .takeWhile(loadedSections.contains)
            .toList();

    final viewSize = AdaptiveLayout.viewSizeOf(context);

    final useTVExpandedLayout = ref.watch(clientSettingsProvider.select((value) => value.useTVExpandedLayout));

    return NestedScaffold(
      background: ValueListenableBuilder<ItemBaseModel?>(
        valueListenable: selectedPoster,
        builder: (_, value, _) {
          return BackgroundImage(
            images: (value != null
                    ? [value]
                    : [
                        ...homeCarouselItems,
                        ...dashboardData.nextUp,
                        ...allResume,
                      ])
                .map((e) => e.images)
                .nonNulls
                .toList(),
          );
        },
      ),
      body: PullToRefresh(
        refreshKey: _refreshIndicatorKey,
        contextRefresh: false,
        displacement: 80 + MediaQuery.of(context).viewPadding.top,
        onRefresh: () async => await _refreshHome(),
        child: (context) => PinchPosterZoom(
          scaleDifference: (difference) => ref.read(clientSettingsProvider.notifier).addPosterSize(difference),
          child: CustomScrollView(
            controller: AdaptiveLayout.scrollOf(context, HomeTabs.dashboard),
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              if (bannerType != HomeBanner.detailedBanner) const DefaultSliverTopBadding(),
              if (viewSize == ViewSize.phone)
                NestedSliverAppBar(
                  route: LibrarySearchRoute(),
                  parent: context,
                ),
              if (showsBanner) ...{
                SliverToBoxAdapter(
                  child: Padding(
                    padding: AdaptiveLayout.adaptivePadding(
                      context,
                      horizontalPadding: 0,
                    ),
                    child: HomeBannerWidget(
                      posters: homeCarouselItems,
                      onSelect: (poster) => selectedPoster.value = poster,
                    ),
                  ),
                ),
              },
              if (AdaptiveLayout.of(context).isDesktop)
                const SliverToBoxAdapter(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      PosterSizeWidget(),
                    ],
                  ),
                ),
              ...[
                for (final section in visibleSections)
                  ...switch (section) {
                    DashboardSorting.liveTV => [
                        if (tvChannels.isNotEmpty)
                          PosterRow(
                            contentPadding: padding,
                            tvMode: useTVExpandedLayout,
                            label: context.localized.activeTvChannels,
                            collectionAspectRatio: 0.55,
                            onLabelClick: () {
                              return LiveTvRoute().navigate(context);
                            },
                            posters: tvChannels,
                          ),
                      ],
                    DashboardSorting.nextUp => [
                        if (resumeVideo.isNotEmpty &&
                            (homeSettings.nextUp == HomeNextUp.cont || homeSettings.nextUp == HomeNextUp.separate))
                          PosterRow(
                            tvMode: useTVExpandedLayout,
                            contentPadding: padding,
                            label: context.localized.dashboardContinueWatching,
                            posters: resumeVideo,
                          ),
                        if (resumeAudio.isNotEmpty &&
                            (homeSettings.nextUp == HomeNextUp.cont || homeSettings.nextUp == HomeNextUp.separate))
                          PosterRow(
                            tvMode: useTVExpandedLayout,
                            contentPadding: padding,
                            label: context.localized.dashboardContinueListening,
                            posters: resumeAudio,
                          ),
                        if (resumeBooks.isNotEmpty &&
                            (homeSettings.nextUp == HomeNextUp.cont || homeSettings.nextUp == HomeNextUp.separate))
                          PosterRow(
                            tvMode: useTVExpandedLayout,
                            contentPadding: padding,
                            label: context.localized.dashboardContinueReading,
                            posters: resumeBooks,
                          ),
                        if (dashboardData.nextUp.isNotEmpty &&
                            (homeSettings.nextUp == HomeNextUp.nextUp || homeSettings.nextUp == HomeNextUp.separate))
                          PosterRow(
                            tvMode: useTVExpandedLayout,
                            contentPadding: padding,
                            label: context.localized.nextUp,
                            posters: dashboardData.nextUp,
                          ),
                        if ([...allResume, ...dashboardData.nextUp].isNotEmpty &&
                            homeSettings.nextUp == HomeNextUp.combined)
                          PosterRow(
                            tvMode: useTVExpandedLayout,
                            contentPadding: padding,
                            label: context.localized.dashboardContinue,
                            posters: [...allResume, ...dashboardData.nextUp],
                          ),
                      ],
                    DashboardSorting.recentlyAdded => [
                        ...views.dashboardViews
                            .where(
                              (element) =>
                                  element.recentlyAdded.isNotEmpty && element.collectionType != CollectionType.livetv,
                            )
                            .map(
                              (view) => PosterRow(
                                tvMode: useTVExpandedLayout,
                                contentPadding: padding,
                                label: context.localized.dashboardRecentlyAdded(view.name),
                                collectionAspectRatio: view.collectionType.aspectRatio,
                                onLabelClick: () {
                                  if (view.collectionType == CollectionType.livetv) {
                                    return LiveTvRoute().navigate(context);
                                  }
                                  return context.router.push(
                                    LibrarySearchRoute(
                                      parentId: [view.id],
                                      types: switch (view.collectionType) {
                                        CollectionType.tvshows => {
                                            FladderItemType.episode: true,
                                          },
                                        _ => {},
                                      },
                                      sortingOptions: switch (view.collectionType) {
                                        CollectionType.books ||
                                        CollectionType.boxsets ||
                                        CollectionType.folders ||
                                        CollectionType.music =>
                                          SortingOptions.dateLastContentAdded,
                                        _ => SortingOptions.dateAdded,
                                      },
                                      sortOrder: SortingOrder.descending,
                                      recursive: true,
                                    ),
                                  );
                                },
                                posters: view.recentlyAdded,
                              ),
                            ),
                      ],
                    DashboardSorting.filters => [
                        for (final filter in savedFilters)
                          HomeSavedFilterRow(
                            key: ValueKey(filter.id),
                            filter: filter,
                            contentPadding: padding,
                            tvMode: useTVExpandedLayout,
                          ),
                      ],
                  },
              ]
                  .nonNulls
                  .toList()
                  .mapIndexed(
                    (index, child) => SliverToBoxAdapter(
                      child: FocusProvider(
                        autoFocus: !showsBanner && index == 0,
                        child: child,
                      ),
                    ),
                  )
                  .toList()
                  .addInBetween(
                    const SliverToBoxAdapter(
                      child: SizedBox(height: 16),
                    ),
                  ),
              const DefaultSliverBottomPadding(),
            ],
          ),
        ),
      ),
    );
  }
}

class HomeSavedFilterRow extends ConsumerWidget {
  const HomeSavedFilterRow({
    required this.filter,
    required this.contentPadding,
    required this.tvMode,
    super.key,
  });

  final LibraryFiltersModel filter;
  final EdgeInsets contentPadding;
  final bool tvMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = context.localized;
    if (ref.watch(offlineStateProvider)) return _status(context, strings.offline);

    final preview = homeSavedFilterPreviewProvider(filter.id);
    final result = ref.watch(preview);
    return result.when(
      skipLoadingOnRefresh: result.hasValue,
      data: (posters) => posters.isEmpty
          ? _status(context, strings.jmsSavedFilterNoPreview)
          : PosterRow(
              label: filter.name,
              posters: posters,
              contentPadding: contentPadding,
              tvMode: tvMode,
              onLabelClick: () => filter.navigateTo(context),
            ),
      loading: () => _status(context, strings.loading),
      error: (_, _) => _status(context, strings.somethingWentWrong, onRetry: () => ref.invalidate(preview)),
    );
  }

  Widget _status(BuildContext context, String text, {VoidCallback? onRetry}) {
    return Padding(
      padding: contentPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextButton.icon(
            onPressed: () => filter.navigateTo(context),
            iconAlignment: IconAlignment.end,
            icon: const Icon(Icons.chevron_right),
            label: Text(filter.name),
          ),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [
              Semantics(liveRegion: true, child: Text(text)),
              if (onRetry != null) TextButton(onPressed: onRetry, child: Text(context.localized.retry)),
            ],
          ),
        ],
      ),
    );
  }
}
