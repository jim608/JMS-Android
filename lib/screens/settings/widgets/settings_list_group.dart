import 'package:material_ui/material_ui.dart';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/providers/settings/home_settings_provider.dart';

List<Widget> settingsListGroup(BuildContext context, Widget? label, List<Widget> children) {
  return [
    if (label != null) SettingsListGroupTitle(label: label),
    ...children.map((e) {
      return SettingsListChild(
        child: e,
        isFirst: e == children.first,
        joinsTitle: label != null,
        isLast: e == children.last,
      );
    }),
  ];
}

class SettingsListGroupTitle extends ConsumerWidget {
  final Widget? label;
  const SettingsListGroupTitle({required this.label, super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(classicInterfaceProvider)) {
      return Padding(padding: const EdgeInsets.fromLTRB(4, 8, 4, 2), child: label);
    }
    final radius = BorderRadius.circular(24);
    final radiusSmall = const Radius.circular(6);
    final color = Theme.of(context).colorScheme.surfaceContainerLow.harmonizeWith(Colors.red);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: color,
        borderRadius: radius.copyWith(bottomLeft: radiusSmall, bottomRight: radiusSmall),
      ),
      child: Padding(padding: const EdgeInsets.symmetric(vertical: 4.0), child: label),
    );
  }
}

class SettingsListChild extends ConsumerWidget {
  final Widget child;
  final bool isFirst;
  final bool joinsTitle;
  final bool isLast;
  const SettingsListChild({
    required this.child,
    this.isFirst = false,
    this.joinsTitle = false,
    this.isLast = false,
    super.key,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final classic = ref.watch(classicInterfaceProvider);
    final scheme = Theme.of(context).colorScheme;
    final exterior = Radius.circular(classic ? 24 : 16);
    final interior = classic ? const Radius.circular(6) : Radius.zero;
    final top = isFirst && !(classic && joinsTitle) ? exterior : interior;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 4, vertical: classic ? 1 : 0.5),
      child: Material(
        color: classic ? scheme.surfaceContainerLow.harmonizeWith(Colors.red) : scheme.surfaceContainer,
        borderRadius: BorderRadius.vertical(top: top, bottom: isLast ? exterior : interior),
        child: child,
      ),
    );
  }
}
