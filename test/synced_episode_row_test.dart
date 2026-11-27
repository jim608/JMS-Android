import 'dart:math' as math;

import 'package:background_downloader/background_downloader.dart';
import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/l10n/generated/app_localizations.dart';
import 'package:fladder/localization_delegates.dart';
import 'package:fladder/models/items/episode_model.dart';
import 'package:fladder/models/syncing/sync_item.dart';
import 'package:fladder/providers/sync/sync_provider_helpers.dart';
import 'package:fladder/screens/syncing/sync_child_item.dart';
import 'package:fladder/screens/syncing/sync_widgets.dart';
import 'package:fladder/screens/syncing/widgets/sync_file_button.dart';
import 'package:fladder/screens/syncing/widgets/synced_episode_item.dart';
import 'package:fladder/util/localization_helper.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout_model.dart';
import 'package:fladder/util/poster_defaults.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _phone = AdaptiveLayoutModel(
  viewSize: ViewSize.phone,
  layoutMode: LayoutMode.single,
  inputDevice: InputDevice.touch,
  platform: TargetPlatform.android,
  isDesktop: false,
  posterDefaults: PosterDefaults(size: 240, ratio: .55),
  controller: {},
  sideBarWidth: 0,
  topBarHeight: 0,
  statusBarHeight: 0,
);

void main() {
  testWidgets('download status text stays legible on its tinted background', (tester) async {
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: const Scaffold(
              body: SyncLabel(status: TaskStatus.complete, label: '已完成同步'),
            ),
          ),
        ),
      );
      final text = tester.widget<Text>(find.text('已完成同步')).style!.color!.computeLuminance();
      final container = tester.widget<Container>(
        find.descendant(of: find.byType(SyncLabel), matching: find.byType(Container)),
      );
      final fill = (container.decoration! as BoxDecoration).color!.computeLuminance();
      expect((math.max(text, fill) + .05) / (math.min(text, fill) + .05), greaterThanOrEqualTo(4.5));
    }
  });

  testWidgets('large text leaves the episode number and download button visible on a narrow phone', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 844);
    addTearDown(tester.view.reset);
    final episode = EpisodeModel.fromBaseDto(
      const BaseItemDto(
        id: 'episode-3',
        name: '藥師少女的獨語：宮廷之謎與失落的藥方',
        type: BaseItemKind.episode,
        parentIndexNumber: 1,
        indexNumber: 3,
      ),
      null,
    );
    final row = SyncedItem(id: episode.id, userId: 'fixture', itemModel: episode);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          locale: const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: FladderLocalizations.localizationsDelegates,
          home: MediaQuery(
            data: const MediaQueryData(size: Size(320, 844), textScaler: TextScaler.linear(2)),
            child: AdaptiveLayout(
              data: _phone,
              child: Scaffold(
                body: ListView(
                  padding: const EdgeInsets.all(20),
                  children: [SyncedEpisodeItem(episode: episode, syncedItem: row)],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final tile = find.byType(SyncedEpisodeItem);
    final title = tester.getRect(find.text(episode.name));
    final number = tester.getRect(find.text(episode.seasonEpisodeLabel(tester.element(tile).localized)));
    expect(title.bottom, lessThanOrEqualTo(number.top));
    expect(number.bottom, lessThan(240));
    expect(tester.getRect(tile).height, lessThan(220));
    expect(find.byType(SyncFileButton).hitTestable(), findsOneWidget);
    expect(find.textContaining('- bytes'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an updated sync row shows and downloads the same episode', (tester) async {
    SyncedItem episode(int number) {
      final id = 'episode-$number';
      final model = EpisodeModel.fromBaseDto(
        BaseItemDto(id: id, name: id, type: BaseItemKind.episode, parentIndexNumber: 1, indexNumber: number),
        null,
      );
      return SyncedItem(id: id, userId: 'fixture', itemModel: model);
    }

    final rows = [episode(20), episode(1)];
    final selected = ValueNotifier(rows.first);
    addTearDown(selected.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [for (final row in rows) syncedItemProvider(row.itemModel).overrideWith((ref) => Stream.value(row))],
        child: MaterialApp(
          localizationsDelegates: FladderLocalizations.localizationsDelegates,
          home: AdaptiveLayout(
            data: _phone,
            child: Scaffold(
              body: ValueListenableBuilder<SyncedItem>(
                valueListenable: selected,
                builder: (_, row, _) => ChildSyncWidget(syncedChild: row),
              ),
            ),
          ),
        ),
      ),
    );
    for (final row in rows) {
      selected.value = row;
      await tester.pumpAndSettle();
      expect(find.text(row.id), findsOneWidget);
      expect(tester.widget<SyncFileButton>(find.byType(SyncFileButton)).syncedItem.id, row.id);
    }
  });
}
