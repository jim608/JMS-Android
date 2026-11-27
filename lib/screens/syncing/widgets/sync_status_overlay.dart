import 'package:material_ui/material_ui.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_plus/iconsax_plus.dart';

import 'package:fladder/models/syncing/sync_item.dart';
import 'package:fladder/providers/sync_provider.dart';
import 'package:fladder/util/list_padding.dart';
import 'package:fladder/util/localization_helper.dart';

class SyncStatusOverlay extends ConsumerWidget {
  final SyncedItem syncedItem;
  final Widget child;
  const SyncStatusOverlay({required this.syncedItem, required this.child, super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final deleting = ref.watch(syncProvider.select(
          (state) => state.items.where((item) => item.id == syncedItem.id).firstOrNull?.markedForDelete,
        )) ??
        syncedItem.markedForDelete;
    return Stack(
      children: [
        child,
        if (deleting)
          Positioned.fill(
            child: Card(
              elevation: 0,
              semanticContainer: false,
              color: Colors.black.withValues(alpha: 0.6),
              child: Row(
                mainAxisSize: MainAxisSize.max,
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  CircularProgressIndicator(
                    strokeCap: StrokeCap.round,
                    valueColor: AlwaysStoppedAnimation(Theme.of(context).colorScheme.error),
                  ),
                  Text(context.localized.syncOverlayDeleting),
                  const Icon(IconsaxPlusLinear.trash)
                ].addPadding(const EdgeInsets.symmetric(horizontal: 16)),
              ),
            ),
          ),
      ],
    );
  }
}
