import 'package:material_ui/material_ui.dart';

import 'package:auto_route/auto_route.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_plus/iconsax_plus.dart';

import 'package:fladder/models/items/episode_model.dart';
import 'package:fladder/models/syncing/sync_item.dart';
import 'package:fladder/providers/sync/sync_provider_helpers.dart';
import 'package:fladder/providers/sync_provider.dart';
import 'package:fladder/screens/shared/default_alert_dialog.dart';
import 'package:fladder/screens/shared/flat_button.dart';
import 'package:fladder/screens/shared/media/episode_posters.dart';
import 'package:fladder/screens/syncing/sync_widgets.dart';
import 'package:fladder/screens/syncing/widgets/sync_file_button.dart';
import 'package:fladder/screens/syncing/widgets/sync_item_poster.dart';
import 'package:fladder/util/localization_helper.dart';
import 'package:fladder/util/size_formatting.dart';
import 'package:fladder/widgets/shared/icon_button_await.dart';

class SyncedEpisodeItem extends ConsumerWidget {
  const SyncedEpisodeItem({super.key, required this.episode, required this.syncedItem});

  final EpisodeModel episode;
  final SyncedItem syncedItem;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloadTask = ref.watch(downloadTasksProvider(syncedItem.id));
    final hasFile = syncedItem.videoFile.existsSync();
    final size = ref.watch(syncSizeProvider(syncedItem, []));
    return SyncMediaRow(
      poster: SyncItemPoster(
        item: syncedItem,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.3),
          child: FlatButton(
            onTap: () {
              episode.navigateTo(context);
              return context.maybePop();
            },
            child: SizedBox(
              width: 175,
              child: EpisodePoster(episode: episode, actions: [], showLabel: false, isCurrentEpisode: false),
            ),
          ),
        ),
      ),
      information: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        spacing: 4,
        children: [
          Text(
            episode.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Text(
            episode.seasonEpisodeLabel(context.localized),
            style: Theme.of(
              context,
            ).textTheme.bodyLarge?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          if (!hasFile && downloadTask.hasDownload)
            SyncProgressBar(item: syncedItem, task: downloadTask)
          else if ((size ?? 0) > 0)
            SyncLabel(
              label: context.localized.totalSize(size.byteFormat!),
              status: ref.watch(
                syncDownloadStatusProvider(syncedItem, []).select((value) => value?.status ?? TaskStatus.notFound),
              ),
            ),
        ],
      ),
      actions: [
        if (!hasFile && !downloadTask.hasDownload)
          SyncFileButton(syncedItem: syncedItem)
        else if (hasFile)
          IconButtonAwait(
            color: Theme.of(context).colorScheme.error,
            onPressed: () async {
              await showDefaultAlertDialog(
                context,
                context.localized.syncRemoveDataTitle,
                context.localized.syncRemoveDataDesc,
                (context) async {
                  await ref.read(syncProvider.notifier).deleteFullSyncFiles(syncedItem, downloadTask.task);
                  Navigator.pop(context);
                },
                context.localized.delete,
                (context) => Navigator.pop(context),
                context.localized.cancel,
              );
            },
            icon: const Icon(IconsaxPlusLinear.trash),
          ),
      ],
    );
  }
}
