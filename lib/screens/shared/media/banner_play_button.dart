import 'package:material_ui/material_ui.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_plus/iconsax_plus.dart';
import 'package:square_progress_indicator/square_progress_indicator.dart';

import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/util/item_base_model/play_item_helpers.dart';
import 'package:fladder/util/localization_helper.dart';

class BannerPlayButton extends ConsumerWidget {
  final ItemBaseModel item;
  final bool useClassicStyle;
  const BannerPlayButton({super.key, required this.item, this.useClassicStyle = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = (item.progress / 100).clamp(0.0, 1.0);
    const classicShape = RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12)));
    final button = SizedBox.square(
      dimension: 48,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (useClassicStyle)
            ExcludeSemantics(
              child: SquareProgressIndicator(
                value: progress,
                borderRadius: 12,
                strokeWidth: 12,
                strokeAlign: SquareStrokeAlign.center,
                strokeCap: StrokeCap.round,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          IconButton.filled(
            tooltip: item.playButtonLabel(context.localized),
            style: useClassicStyle
                ? IconButton.styleFrom(
                    shape: classicShape,
                    foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
                    backgroundColor: Colors.transparent,
                  )
                : IconButton.styleFrom(
                    foregroundColor: Colors.white,
                    backgroundColor: const Color(0xD01B2027),
                    side: const BorderSide(color: Colors.white38),
                    shape: const CircleBorder(),
                  ),
            onPressed: () => item.play(context, ref),
            icon: Icon(IconsaxPlusBold.play, size: useClassicStyle ? 30 : 22),
          ),
          if (!useClassicStyle && progress > 0)
            ExcludeSemantics(
              child: IgnorePointer(
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: CircularProgressIndicator(
                    value: progress,
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
    );
    return Align(
      alignment: AlignmentDirectional.bottomEnd,
      child: Padding(
        padding: EdgeInsets.all(useClassicStyle ? 8 : 12),
        child: useClassicStyle
            ? Opacity(
                opacity: 0.9,
                child: Card(shape: classicShape, child: button),
              )
            : button,
      ),
    );
  }
}
