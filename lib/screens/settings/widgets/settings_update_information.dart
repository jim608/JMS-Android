import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/providers/update_provider.dart';
import 'package:fladder/util/localization_helper.dart';
import 'package:fladder/util/update_checker.dart';

class SettingsUpdateInformation extends ConsumerWidget {
  const SettingsUpdateInformation({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final updates = ref.watch(updateProvider);
    final labels = context.localized;
    final release = updates.latestRelease;
    final configured = updates.checker.source.configured;
    final canDownload = !updates.busy && !updates.blocked;
    final installReady = const {
      UpdateStatus.downloaded,
      UpdateStatus.permissionRequired,
      UpdateStatus.installPending,
      UpdateStatus.installCancelled,
      UpdateStatus.installBlocked,
    }.contains(updates.status);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(),
        ListTile(
          leading: const Icon(Icons.system_update),
          title: Text(labels.jmsUpdateTitle),
          subtitle: Text(configured ? updates.checker.source.identity : labels.jmsUpdateState('unconfigured')),
        ),
        SwitchListTile(
          title: Text(labels.autoCheckForUpdates),
          subtitle: Text(labels.jmsUpdateAutoHint),
          value: updates.automatic,
          onChanged: updates.ready ? updates.setAutomatic : null,
        ),
        SwitchListTile(
          title: Text(labels.jmsUpdatePrerelease),
          value: updates.prerelease,
          onChanged: updates.ready && !updates.busy ? updates.setPrerelease : null,
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(labels.jmsUpdateState(updates.status.name)),
              if (updates.failure != null) Text(labels.jmsUpdateFailure(updates.failure!)),
              if (updates.blocked) Text(labels.jmsUpdateState('playbackBlocked')),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: updates.ready && !updates.busy && !updates.blocked ? () => updates.check() : null,
                icon: const Icon(Icons.refresh),
                label: Text(labels.jmsUpdateCheck),
              ),
              if (release != null && !updates.deferred) ...[
                const SizedBox(height: 12),
                Text('${release.version} (${release.manifest.versionCode})',
                    style: Theme.of(context).textTheme.titleMedium),
                Text('${release.published.toLocal().toString().split(".").first} · '
                    '${(release.manifest.size / (1024 * 1024)).toStringAsFixed(1)} MiB'),
                SelectableText(release.changelog),
                if (updates.status == UpdateStatus.downloading) ...[
                  LinearProgressIndicator(value: updates.progress),
                  Text('${(updates.progress * 100).toStringAsFixed(0)}%'),
                  TextButton(onPressed: updates.cancel, child: Text(labels.cancel)),
                ] else ...[
                  FilledButton(
                    onPressed: canDownload ? updates.download : null,
                    child: Text(labels.jmsUpdateDownload),
                  ),
                  if (installReady)
                    FilledButton.tonal(
                      onPressed: canDownload ? () => updates.install() : null,
                      child: Text(labels.jmsUpdateInstall),
                    ),
                  if (updates.status == UpdateStatus.permissionRequired) ...[
                    Text(labels.jmsUpdatePermissionHint),
                    TextButton(
                      onPressed: canDownload ? () => updates.install(openPermission: true) : null,
                      child: Text(labels.jmsUpdatePermission),
                    ),
                  ],
                  Wrap(spacing: 8, children: [
                    TextButton(onPressed: updates.later, child: Text(labels.jmsUpdateLater)),
                    TextButton(onPressed: updates.skip, child: Text(labels.jmsUpdateSkip)),
                  ]),
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }
}
