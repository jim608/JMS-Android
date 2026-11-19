import 'package:material_ui/material_ui.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_plus/iconsax_plus.dart';

import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/util/item_base_model/play_item_helpers.dart';
import 'package:fladder/util/localization_helper.dart';

class BannerPlayButton extends ConsumerWidget {
  final ItemBaseModel item;
  const BannerPlayButton({super.key, required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Align(
      alignment: AlignmentDirectional.bottomEnd,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: SizedBox.square(
          dimension: 48,
          child: Stack(
            fit: StackFit.expand,
            children: [
              IconButton.filled(
                tooltip: item.playButtonLabel(context.localized),
                style: IconButton.styleFrom(
                  foregroundColor: Colors.white,
                  backgroundColor: const Color(0xD01B2027),
                  side: const BorderSide(color: Colors.white38),
                  shape: const CircleBorder(),
                ),
                onPressed: () => item.play(context, ref),
                icon: const Icon(IconsaxPlusBold.play, size: 22),
              ),
              if (item.progress > 0)
                ExcludeSemantics(
                  child: IgnorePointer(
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: CircularProgressIndicator(
                        value: (item.progress / 100).clamp(0, 1),
                        padding: EdgeInsets.zero,
                        strokeWidth: 3,
                        strokeCap: StrokeCap.round,
                        color: Colors.white,
                        backgroundColor: Colors.transparent,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
