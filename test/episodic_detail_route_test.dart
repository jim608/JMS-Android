import 'package:chopper/chopper.dart';
import 'package:fladder/jellyfin/enum_models.dart';
import 'package:fladder/localization_delegates.dart';
import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/items/episode_model.dart';
import 'package:fladder/models/items/item_shared_models.dart';
import 'package:fladder/models/items/media_streams_model.dart';
import 'package:fladder/models/items/overview_model.dart';
import 'package:fladder/models/items/series_model.dart';
import 'package:fladder/models/syncing/sync_settings_model.dart';
import 'package:fladder/models/syncing/sync_item.dart';
import 'package:fladder/providers/items/episode_details_provider.dart';
import 'package:fladder/providers/items/series_details_provider.dart';
import 'package:fladder/providers/settings/home_settings_provider.dart';
import 'package:fladder/providers/sync_provider.dart';
import 'package:fladder/routes/nested_details_screen.dart';
import 'package:fladder/screens/details_screens/components/overview_header.dart';
import 'package:fladder/screens/shared/media/components/media_play_button.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout_model.dart';
import 'package:fladder/util/poster_defaults.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

final _episode = EpisodeModel(
  name: '第一集',
  id: 'episode',
  seriesName: '測試影集',
  season: 1,
  episode: 1,
  episodeEnd: null,
  location: ItemLocation.filesystem,
  dateAired: DateTime(2024, 1, 1),
  overview: const OverviewModel(summary: '集數摘要'),
  parentId: 'series',
  playlistId: null,
  images: null,
  parentImages: null,
  childCount: 0,
  primaryRatio: 1,
  userData: const UserData(progress: 25),
  mediaStreams: MediaStreamsModel(
    versionStreams: [
      VersionStreamModel(
        index: 0,
        name: '修復版',
        defaultAudioStreamIndex: 2,
        defaultSubStreamIndex: -1,
        audioStreams: [AudioStreamModel.no(index: 2, displayTitle: '華語')],
        subStreams: [SubStreamModel.no(index: 7, displayTitle: '繁體中文')],
        videoStreams: [],
      ),
    ],
  ),
);
final _series = SeriesModel(
  name: '測試影集',
  id: 'series',
  originalTitle: 'Series',
  sortName: 'series',
  status: '',
  overview: const OverviewModel(summary: '影集摘要'),
  parentId: 'library',
  playlistId: null,
  images: null,
  childCount: 1,
  primaryRatio: 1,
  userData: const UserData(),
  availableEpisodes: [_episode],
);

class _FakeEpisode extends EpisodeDetailsProvider {
  _FakeEpisode(super.ref) {
    state = EpisodeDetailModel(series: _series, episode: _episode);
  }
  @override
  Future<Response?> fetchDetails(ItemBaseModel item) async => null;
}

class _FakeSeries extends SeriesDetailViewNotifier {
  _FakeSeries(super.ref) {
    state = _series;
  }
  @override
  Future<Response?> fetchDetails(ItemBaseModel item) async => null;
}

class _NoDownloads extends StateNotifier<SyncSettingsModel> implements SyncNotifier {
  _NoDownloads() : super(SyncSettingsModel());

  @override
  Stream<SyncedItem?> watchItem(String id) => Stream.value(null);

  @override
  Future<SyncedItem?> getSyncedItem(String? id) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final item in <ItemBaseModel>[_series, _episode]) {
    for (final classic in [false, true]) {
      testWidgets('populated phone detail shows playback controls for ${item.id}, classic=$classic', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(393, 852);
        addTearDown(tester.view.reset);
        const locale = Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant');
        final container = ProviderContainer(
          overrides: [
            classicInterfaceProvider.overrideWithValue(classic),
            seriesDetailsProvider(_series.id).overrideWith(_FakeSeries.new),
            episodeDetailsProvider(_episode.id).overrideWith(_FakeEpisode.new),
            syncProvider.overrideWith((ref) => _NoDownloads()),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              locale: locale,
              supportedLocales: const [locale],
              localizationsDelegates: FladderLocalizations.localizationsDelegates,
              builder: (_, child) => AdaptiveLayout(
                data: const AdaptiveLayoutModel(
                  viewSize: ViewSize.phone,
                  layoutMode: LayoutMode.single,
                  inputDevice: InputDevice.touch,
                  platform: TargetPlatform.android,
                  isDesktop: false,
                  posterDefaults: PosterDefaults(size: 240, ratio: .55),
                  controller: {},
                  sideBarWidth: 0,
                  topBarHeight: 0,
                  statusBarHeight: 24,
                ),
                child: child!,
              ),
              home: Scaffold(
                body: DetailsScreen(id: item.id, item: item),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(OverviewHeader), findsOneWidget);
        expect(find.byType(MediaPlayButton), findsOneWidget);
        expect(find.byType(ErrorWidget), findsNothing);
        expect(find.text(item.overview.summary, findRichText: true), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      });
    }
  }
}
