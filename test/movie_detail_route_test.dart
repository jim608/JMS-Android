import 'package:auto_route/auto_route.dart';
import 'package:chopper/chopper.dart';
import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/l10n/generated/app_localizations.dart';
import 'package:fladder/localization_delegates.dart';
import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/items/media_streams_model.dart';
import 'package:fladder/models/items/movie_model.dart';
import 'package:fladder/models/syncing/sync_item.dart';
import 'package:fladder/models/syncing/sync_settings_model.dart';
import 'package:fladder/providers/items/movies_details_provider.dart';
import 'package:fladder/providers/settings/home_settings_provider.dart';
import 'package:fladder/providers/sync_provider.dart';
import 'package:fladder/routes/auto_router.gr.dart';
import 'package:fladder/routes/nested_details_screen.dart';
import 'package:fladder/screens/shared/media/components/media_play_button.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout_model.dart';
import 'package:fladder/util/poster_defaults.dart';
import 'package:fladder/widgets/shared/enum_selection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _FixtureMovieDetails extends MovieDetails {
  _FixtureMovieDetails(this.movie);

  final MovieModel movie;

  @override
  MovieModel build(String arg) => movie;

  @override
  Future<Response?> fetchDetails(ItemBaseModel item) async => null;
}

class _NoDownloads extends StateNotifier<SyncSettingsModel>
    implements SyncNotifier {
  _NoDownloads() : super(SyncSettingsModel());

  @override
  Future<SyncedItem?> getSyncedItem(String? id) async => null;

  @override
  Stream<SyncedItem?> watchItem(String id) => Stream.value(null);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final classic in [false, true]) {
    testWidgets(
      'phone opens a movie with playback controls, classic=$classic',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(360, 780);
        addTearDown(tester.view.reset);
        final movie =
            MovieModel.fromBaseDto(
              const BaseItemDto(
                id: 'movie',
                name: '海邊電影院',
                type: BaseItemKind.movie,
                overview: '電影簡介',
              ),
              null,
            ).copyWith(
              mediaStreams: MediaStreamsModel(
                versionStreams: [
                  VersionStreamModel(
                    name: '修復版',
                    index: 0,
                    defaultAudioStreamIndex: 1,
                    defaultSubStreamIndex: -1,
                    videoStreams: [],
                    audioStreams: [
                      AudioStreamModel.no(index: 1, displayTitle: '國語'),
                    ],
                    subStreams: [],
                  ),
                ],
              ),
            );
        final router = RootStackRouter.build(
          routes: [
            NamedRouteDef(
              name: 'TestHome',
              path: '/',
              builder: (context, _) => Scaffold(
                body: TextButton(
                  onPressed: () =>
                      DetailsRoute(id: movie.id, item: movie).push(context),
                  child: const Text('Open movie'),
                ),
              ),
            ),
            NamedRouteDef(
              name: DetailsRoute.name,
              path: '/details',
              builder: (_, route) {
                final args = route.argsAs<DetailsRouteArgs>();
                return DetailsScreen(id: args.id, item: args.item);
              },
            ),
          ],
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          router.dispose();
        });
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              movieDetailsProvider(
                movie.id,
              ).overrideWith(() => _FixtureMovieDetails(movie)),
              classicInterfaceProvider.overrideWithValue(classic),
              syncProvider.overrideWith((_) => _NoDownloads()),
            ],
            child: MaterialApp.router(
              theme: ThemeData.dark(),
              locale: const Locale.fromSubtags(
                languageCode: 'zh',
                scriptCode: 'Hant',
              ),
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates:
                  FladderLocalizations.localizationsDelegates,
              routerConfig: router.config(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(padding: const EdgeInsets.only(top: 28, bottom: 20)),
                child: AdaptiveLayout(
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
                    statusBarHeight: 28,
                  ),
                  child: child!,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open movie'));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text('海邊電影院').hitTestable(), findsOneWidget);
        expect(find.byType(MediaPlayButton).hitTestable(), findsOneWidget);
        expect(find.byType(EnumBox), findsNWidgets(classic ? 3 : 2));

        await tester.tap(find.byType(BackButtonIcon));
        await tester.pumpAndSettle();
        expect(find.text('Open movie'), findsOneWidget);
      },
    );
  }
}
