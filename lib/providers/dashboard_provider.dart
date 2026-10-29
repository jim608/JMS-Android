import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.enums.swagger.dart';
import 'package:fladder/models/home_model.dart';
import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/items/channel_model.dart';
import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/live_tv_provider.dart';
import 'package:fladder/providers/service_provider.dart';
import 'package:fladder/providers/settings/client_settings_provider.dart';
import 'package:fladder/providers/views_provider.dart';
import 'package:fladder/util/list_extensions.dart';

final dashboardProvider = StateNotifierProvider<DashboardNotifier, HomeModel>((ref) {
  return DashboardNotifier(ref);
});

class DashboardNotifier extends StateNotifier<HomeModel> {
  DashboardNotifier(this.ref) : super(HomeModel());

  final Ref ref;

  late final JellyService api = ref.read(jellyApiProvider);
  int _refreshGeneration = 0;

  Future<void> fetchNextUpAndResume() async {
    if (!mounted || state.loading) return;
    final generation = ++_refreshGeneration;
    state = state.copyWith(loading: true);
    try {
      final refreshed = await _fetchRows(generation);
      if (refreshed != null && _isCurrentRefresh(generation)) {
        state = refreshed.copyWith(loading: false);
      }
    } finally {
      // A retired request must not unlock a newer refresh after clear().
      if (_isCurrentRefresh(generation) && state.loading) {
        state = state.copyWith(loading: false);
      }
    }
  }

  bool _isCurrentRefresh(int generation) => mounted && generation == _refreshGeneration;

  Future<HomeModel?> _fetchRows(int generation) async {
    if (!_isCurrentRefresh(generation)) return null;
    // Keep the displayed rows intact until every sequential request succeeds.
    var refreshed = state;
    final viewTypes =
        ref.read(viewsProvider.select((value) => value.dashboardViews)).map((e) => e.collectionType).toSet().toList();
    final limit = 16;

    final imagesToFetch = {
      ImageType.logo,
      ImageType.thumb,
      ImageType.primary,
      ImageType.backdrop,
      ImageType.banner,
    }.toList();

    final fieldsToFetch = {
      ItemFields.parentid,
      ItemFields.mediastreams,
      ItemFields.mediasources,
      ItemFields.candelete,
      ItemFields.candownload,
      ItemFields.primaryimageaspectratio,
      ItemFields.overview,
      ItemFields.airtime,
    };

    if (viewTypes.containsAny([CollectionType.livetv])) {
      final response = await api.liveTvChannelsGet(limit: limit);
      if (!_isCurrentRefresh(generation)) return null;
      List<ChannelModel> channels = response.body?.items?.map((e) => ChannelModel.fromBaseDto(e, ref)).toList() ?? [];

      channels = await Future.wait(
        channels.map(
          (e) async {
            final programs = await ref.read(liveTvProvider.notifier).fetchProgramsForChannel(e);
            return e.copyChannelWith(
              programs: programs,
            );
          },
        ),
      );
      if (!_isCurrentRefresh(generation)) return null;

      refreshed = refreshed.copyWith(activePrograms: channels);
    } else {
      refreshed = refreshed.copyWith(activePrograms: []);
    }

    if (viewTypes.containsAny([CollectionType.movies, CollectionType.tvshows])) {
      final resumeVideoResponse = await api.usersUserIdItemsResumeGet(
        enableImageTypes: imagesToFetch,
        fields: fieldsToFetch.toList(),
        mediaTypes: [MediaType.video],
        enableTotalRecordCount: false,
        limit: limit,
      );
      if (!_isCurrentRefresh(generation)) return null;

      refreshed = refreshed.copyWith(
        resumeVideo: resumeVideoResponse.body?.items?.map((e) => ItemBaseModel.fromBaseDto(e, ref)).toList(),
      );
    }

    if (viewTypes.contains(CollectionType.music)) {
      final resumeAudioResponse = await api.usersUserIdItemsResumeGet(
        enableImageTypes: imagesToFetch,
        fields: fieldsToFetch.toList(),
        mediaTypes: [MediaType.audio],
        enableTotalRecordCount: false,
        limit: limit,
      );
      if (!_isCurrentRefresh(generation)) return null;

      refreshed = refreshed.copyWith(
        resumeAudio: resumeAudioResponse.body?.items?.map((e) => ItemBaseModel.fromBaseDto(e, ref)).toList(),
      );
    }

    if (viewTypes.contains(CollectionType.books)) {
      final resumeBookResponse = await api.usersUserIdItemsResumeGet(
        enableImageTypes: imagesToFetch,
        fields: fieldsToFetch.toList(),
        mediaTypes: [MediaType.book],
        enableTotalRecordCount: false,
        limit: limit,
      );
      if (!_isCurrentRefresh(generation)) return null;

      refreshed = refreshed.copyWith(
        resumeBooks: resumeBookResponse.body?.items?.map((e) => ItemBaseModel.fromBaseDto(e, ref)).toList(),
      );
    }

    final nextResponse = await api.showsNextUpGet(
      nextUpDateCutoff: DateTime.now().subtract(
          ref.read(clientSettingsProvider.select((value) => value.nextUpDateCutoff ?? const Duration(days: 28)))),
      fields: fieldsToFetch.toList(),
      enableImageTypes: imagesToFetch,
      imageTypeLimit: 1,
    );
    if (!_isCurrentRefresh(generation)) return null;

    final next = nextResponse.body?.items
            ?.map(
              (e) => ItemBaseModel.fromBaseDto(e, ref),
            )
            .toList() ??
        [];

    return refreshed.copyWith(nextUp: next);
  }

  void clear() {
    _refreshGeneration++;
    state = HomeModel();
  }
}
