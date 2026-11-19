import 'package:material_ui/material_ui.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/providers/settings/home_settings_provider.dart';

class SettingsLabelDivider extends ConsumerWidget {
  final String label;
  const SettingsLabelDivider({required this.label, super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final classic = ref.watch(classicInterfaceProvider);
    final theme = Theme.of(context);
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Text(
          label,
          style: (classic ? theme.textTheme.titleMedium : theme.textTheme.titleLarge)?.copyWith(
            fontWeight: FontWeight.bold,
            color: classic ? theme.colorScheme.primary : theme.colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}
