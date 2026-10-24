import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/providers/home_preferences_provider.dart';
import 'package:fladder/screens/settings/settings_list_tile.dart';
import 'package:fladder/screens/shared/fladder_notification_overlay.dart';
import 'package:fladder/theme.dart';
import 'package:fladder/util/localization_helper.dart';
import 'package:fladder/widgets/shared/filled_button_await.dart';

class HomePreferencesEditor extends ConsumerWidget {
  const HomePreferencesEditor({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preferences = ref.watch(homePreferencesProvider);
    final hasChanges = ref.watch(homePreferencesProvider.notifier).hasChanges;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        borderRadius: FladderTheme.largeShape.borderRadius,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsListTileCheckbox(
            label: Text(context.localized.hidePlayedInLatestTitle),
            subLabel: Text(context.localized.hidePlayedInLatestDescription),
            value: preferences.hidePlayedInLatest,
            onChanged: (value) {
              ref.read(homePreferencesProvider.notifier).setHidePlayedInLatest(value ?? false);
            },
          ),
          SettingsListTile(
            label: Row(
              spacing: 16,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                FilledButtonAwait(
                  onPressed: hasChanges
                      ? () async {
                          ref.read(homePreferencesProvider.notifier).revert();
                        }
                      : null,
                  child: Text(context.localized.cancel),
                ),
                FilledButtonAwait(
                  onPressed: hasChanges
                      ? () async {
                          await FladderSnack.showResponse(
                            ref.read(homePreferencesProvider.notifier).save(),
                            successTitle: context.localized.saved,
                          );
                        }
                      : null,
                  child: Text(context.localized.save),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
