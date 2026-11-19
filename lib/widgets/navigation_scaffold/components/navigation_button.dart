import 'package:material_ui/material_ui.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/providers/settings/home_settings_provider.dart';
import 'package:fladder/util/localization_helper.dart';
import 'package:fladder/widgets/navigation_scaffold/components/side_navigation_bar.dart';
import 'package:fladder/widgets/shared/item_actions.dart';

class NavigationButton extends ConsumerStatefulWidget {
  final String? label;
  final Widget selectedIcon;
  final Widget icon;
  final Widget? badge;
  final bool navFocusNode;
  final bool horizontal;
  final bool expanded;
  final Function()? onPressed;
  final Function()? onLongPress;
  final Function(TapDownDetails details)? onSecondaryTapDown;
  final List<ItemAction> trailing;
  final Widget? customIcon;
  final bool selected;
  final Duration duration;
  const NavigationButton({
    required this.label,
    required this.selectedIcon,
    required this.icon,
    this.badge,
    this.navFocusNode = false,
    this.horizontal = false,
    this.expanded = false,
    this.onPressed,
    this.onLongPress,
    this.onSecondaryTapDown,
    this.customIcon,
    this.selected = false,
    this.trailing = const [],
    this.duration = const Duration(milliseconds: 125),
    super.key,
  });

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _NavigationButtonState();
}

class _NavigationButtonState extends ConsumerState<NavigationButton> {
  bool onHover = false;
  bool hasFocus = false;
  @override
  Widget build(BuildContext context) {
    final classic = ref.watch(classicInterfaceProvider);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final foreground = switch ((classic, widget.selected)) {
      (false, true) => colors.onPrimaryContainer,
      (false, false) => colors.onSurfaceVariant,
      (true, true) => widget.expanded ? colors.onPrimary : colors.primary,
      (true, false) => colors.onSurface.withValues(alpha: 0.45),
    };
    final isFocused = onHover || hasFocus;
    final background = widget.selected && (!classic || widget.expanded)
        ? (classic ? colors.primary : colors.primaryContainer)
        : colors.primary.withAlpha(isFocused ? 25 : 0);
    final radius = BorderRadius.circular(classic ? 16 : 12);
    final button = Padding(
      padding: EdgeInsets.symmetric(horizontal: widget.horizontal ? 6 : 0),
      child: InkWell(
        borderRadius: classic ? null : radius,
        focusNode: widget.navFocusNode ? navBarNode : null,
        onHover: (value) => setState(() => onHover = value),
        onFocusChange: (value) => setState(() => hasFocus = value),
        onTap: widget.onPressed,
        onSecondaryTapDown: widget.onSecondaryTapDown,
        onLongPress: widget.onLongPress,
        child: AnimatedContainer(
          duration: widget.duration,
          margin: EdgeInsets.zero,
          padding: EdgeInsets.zero,
          decoration: BoxDecoration(
            color: background,
            borderRadius: radius,
            border: Border.all(
              width: 3.0,
              strokeAlign: BorderSide.strokeAlignInside,
              color: colors.primary.withValues(alpha: (classic ? isFocused : hasFocus) ? 1 : 0),
            ),
          ),
          child: DefaultTextStyle(
            style: (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(
              color: foreground,
              fontWeight: !classic && widget.selected ? FontWeight.w700 : null,
            ),
            child: IconTheme(
              data: IconThemeData(
                color: foreground,
                size: 24,
              ),
              child: ExcludeFocusTraversal(
                child: widget.horizontal
                    ? Padding(
                        padding: widget.customIcon != null
                            ? EdgeInsetsGeometry.zero
                            : const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
                        child: SizedBox(
                          height: widget.customIcon != null ? 60 : 35,
                          child: Row(
                            spacing: 4,
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 250),
                                height: widget.selected ? (classic ? 16 : 20) : 0,
                                margin: const EdgeInsets.only(top: 1.5),
                                width: classic ? 6 : 3,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(8),
                                  color: colors.primary.withValues(
                                    alpha: widget.selected && (!classic || !widget.expanded) ? 1 : 0,
                                  ),
                                ),
                              ),
                              widget.customIcon ??
                                  Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      AnimatedSwitcher(
                                        duration: widget.duration,
                                        child: widget.selected ? widget.selectedIcon : widget.icon,
                                      ),
                                      if (widget.badge != null && !widget.expanded)
                                        Transform.translate(
                                          offset: const Offset(8, -8),
                                          child: widget.badge,
                                        ),
                                    ],
                                  ),
                              const SizedBox(width: 6),
                              if (widget.horizontal && widget.expanded) ...[
                                if (widget.label != null)
                                  Expanded(
                                    child: ConstrainedBox(
                                      constraints: const BoxConstraints(minWidth: 80),
                                      child: Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        crossAxisAlignment: CrossAxisAlignment.center,
                                        children: [
                                          Flexible(
                                            child: Text(
                                              widget.label!,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              softWrap: false,
                                            ),
                                          ),
                                          if (widget.badge != null) widget.badge!,
                                        ],
                                      ),
                                    ),
                                  ),
                                if (widget.trailing.isNotEmpty && onHover)
                                  PopupMenuButton(
                                    tooltip: context.localized.options,
                                    iconColor: foreground,
                                    iconSize: 18,
                                    itemBuilder: (context) => widget.trailing.popupMenuItems(useIcons: true),
                                  )
                              ],
                            ],
                          ),
                        ),
                      )
                    : Padding(
                        padding: widget.customIcon != null ? EdgeInsetsGeometry.zero : const EdgeInsets.all(8),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Row(
                              spacing: 8,
                              children: [
                                widget.customIcon ??
                                    Stack(
                                      alignment: Alignment.center,
                                      children: [
                                        AnimatedSwitcher(
                                          duration: widget.duration,
                                          child: widget.selected ? widget.selectedIcon : widget.icon,
                                        ),
                                        if (widget.badge != null && !widget.expanded)
                                          Transform.translate(
                                            offset: const Offset(8, -8),
                                            child: widget.badge,
                                          ),
                                      ],
                                    ),
                                if (widget.label != null && widget.horizontal && widget.expanded)
                                  Flexible(child: Text(widget.label!))
                              ],
                            ),
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 250),
                              margin: EdgeInsets.only(top: widget.selected ? 4 : 0),
                              height: widget.selected ? 6 : 0,
                              width: widget.selected ? 14 : 0,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                color: Theme.of(context).colorScheme.primary.withValues(alpha: widget.selected ? 1 : 0),
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
    return Semantics(
      selected: widget.selected ? true : null,
      label: widget.horizontal && widget.expanded ? null : widget.label,
      child: button,
    );
  }
}
