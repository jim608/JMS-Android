import 'package:flutter/material.dart';

import 'package:fladder/screens/video_player/components/syncplay_dialog.dart';
import 'package:fladder/widgets/navigation_scaffold/components/navigation_button.dart';
import 'package:fladder/widgets/shared/custom_tooltip.dart';
import 'package:fladder/widgets/shared/syncplay_home_entry.dart';

/// A regular side navigation action backed by the existing home room flow.
class SyncPlayNavigationButton extends StatelessWidget {
  const SyncPlayNavigationButton({
    this.expanded = false,
    this.tooltipPosition = TooltipPosition.right,
    super.key,
  });

  final bool expanded;
  final TooltipPosition tooltipPosition;

  @override
  Widget build(BuildContext context) {
    final title = SyncPlayStrings.of(context).title;
    return SyncPlayHomeEntry(
      builder: (context, onPressed) => CustomTooltip(
        position: tooltipPosition,
        tooltipContent: expanded
            ? null
            : Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(title,
                      style: Theme.of(context).textTheme.titleSmall),
                ),
              ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: NavigationButton(
            label: title,
            icon: Icon(Icons.group_outlined,
                semanticLabel: expanded ? null : title),
            selectedIcon: const Icon(Icons.group),
            horizontal: true,
            expanded: expanded,
            onPressed: onPressed,
          ),
        ),
      ),
    );
  }
}
