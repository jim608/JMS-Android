import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/providers/update_provider.dart';
import 'package:fladder/util/localization_helper.dart';
import 'package:fladder/util/update_checker.dart';

class SettingsUpdateInformation extends ConsumerWidget {
  const SettingsUpdateInformation({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (kIsWeb) return const SizedBox.shrink();
    final updates = ref.watch(updateProvider);
    final labels = context.localized;
    final release = updates.latestRelease;
    final configured = updates.checker.source.configured;
    final canAct = updates.ready && !updates.busy && !updates.blocked;
    final hasRelease = release != null && !updates.deferred;
    final installReady = updates.hasVerifiedDownload;
    final needsPermission = updates.status == UpdateStatus.permissionRequired;
    final manualPackage = updates.failure == 'packageChannel';

    Future<void> install() async {
      if (release!.manifest.windows) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(labels.jmsDesktopUpdateInstallTitle),
            content: Text(labels.jmsDesktopUpdateInstallHint),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(labels.cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(labels.jmsUpdateInstall),
              ),
            ],
          ),
        );
        if (confirmed != true || !context.mounted) return;
      }
      await updates.install(
          openPermission: needsPermission, expectedRelease: release);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(),
        ListTile(
          leading: const Icon(Icons.system_update),
          title: Text(updates.platform == 'linux-x64'
              ? labels.jmsLinuxUpdateTitle
              : updates.bridge.isDesktop
                  ? labels.jmsDesktopUpdateTitle
                  : labels.jmsUpdateTitle),
          subtitle: Text(configured
              ? updates.checker.source.identity
              : labels.jmsUpdateState('unconfigured')),
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
          onChanged:
              updates.ready && !updates.busy ? updates.setPrerelease : null,
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(labels.jmsUpdateState(updates.status.name)),
              if (updates.checkWarning != null) ...[
                Text(labels.jmsUpdateState(updates.checkWarning!.name)),
                Text(labels.jmsUpdateVerifiedLocalAvailable),
              ],
              if (updates.failure != null)
                Text(manualPackage
                    ? labels.jmsLinuxPackageChannelHint
                    : labels.jmsUpdateFailure(updates.failure!)),
              if (updates.blocked)
                Text(labels.jmsUpdateState('playbackBlocked')),
              const SizedBox(height: 8),
              if (!hasRelease)
                FilledButton.icon(
                  key: const ValueKey('update-primary-check'),
                  onPressed: canAct ? () => updates.check() : null,
                  icon: const Icon(Icons.refresh),
                  label: Text(labels.jmsUpdateCheck),
                )
              else ...[
                OutlinedButton.icon(
                  onPressed: canAct ? () => updates.check() : null,
                  icon: const Icon(Icons.refresh),
                  label: Text(labels.jmsUpdateCheck),
                ),
                const SizedBox(height: 12),
                Text('${release.version} (${release.manifest.versionCode})',
                    style: Theme.of(context).textTheme.titleMedium),
                Text(
                    '${release.published.toLocal().toString().split(".").first} · '
                    '${(release.manifest.size / (1024 * 1024)).toStringAsFixed(1)} MiB'),
                if (release.changelog.isNotEmpty)
                  ExpansionTile(
                    key: const ValueKey('update-release-notes'),
                    title: Text(labels.jmsUpdateReleaseNotes),
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: SelectableText(release.changelog),
                      ),
                    ],
                  ),
                if (updates.status == UpdateStatus.downloading) ...[
                  LinearProgressIndicator(value: updates.progress),
                  Text('${(updates.progress * 100).toStringAsFixed(0)}%'),
                  TextButton(
                    key: const ValueKey('update-cancel-download'),
                    onPressed: updates.cancel,
                    child: Text(labels.cancel),
                  ),
                ] else ...[
                  if (needsPermission) Text(labels.jmsUpdatePermissionHint),
                  if (!manualPackage)
                    FilledButton(
                      key: ValueKey(installReady
                          ? 'update-primary-install'
                          : 'update-primary-download'),
                      onPressed: canAct
                          ? installReady
                              ? install
                              : updates.download
                          : null,
                      child: Text(installReady
                          ? needsPermission
                              ? labels.jmsUpdatePermission
                              : labels.jmsUpdateInstall
                          : updates.status == UpdateStatus.downloadFailed ||
                                  updates.status == UpdateStatus.cancelled
                              ? labels.jmsUpdateRetryDownload
                              : labels.jmsUpdateDownload),
                    ),
                  Wrap(spacing: 8, children: [
                    TextButton(
                      onPressed: updates.busy ? null : updates.later,
                      child: Text(labels.jmsUpdateLater),
                    ),
                    TextButton(
                      onPressed: updates.busy ? null : updates.skip,
                      child: Text(labels.jmsUpdateSkip),
                    ),
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
