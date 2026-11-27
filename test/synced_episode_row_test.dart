import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/localization_delegates.dart';
import 'package:fladder/models/items/episode_model.dart';
import 'package:fladder/models/syncing/sync_item.dart';
import 'package:fladder/providers/sync/sync_provider_helpers.dart';
import 'package:fladder/screens/syncing/sync_child_item.dart';
import 'package:fladder/screens/syncing/widgets/sync_file_button.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout_model.dart';
import 'package:fladder/util/poster_defaults.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
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
              statusBarHeight: 0,
            ),
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
