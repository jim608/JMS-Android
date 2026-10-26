import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:fladder/providers/update_provider.dart';
import 'package:fladder/providers/settings/client_settings_provider.dart';
import 'package:fladder/util/localization_helper.dart';
import 'package:fladder/util/update_checker.dart';
import 'package:fladder/util/flatpak_update_capability.dart';
import 'package:fladder/util/flatpak_update_controller.dart';
import 'package:fladder/services/flatpak_update_portal.dart';

class SettingsUpdateInformation extends ConsumerWidget {
  const SettingsUpdateInformation({super.key, this.openExternalLink});

  @visibleForTesting
  final Future<bool> Function(Uri)? openExternalLink;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (kIsWeb) return const SizedBox.shrink();
    final updates = ref.watch(updateProvider);
    final labels = context.localized;
    if (updates.bridge.flatpakManaged) {
      final flatpak = ref.watch(flatpakUpdateProvider);
      final capability = flatpak.capability;
      final automatic = ref.watch(
          clientSettingsProvider.select((value) => value.checkForUpdates));
      String text(String en, String zh) =>
          Localizations.localeOf(context).languageCode == 'zh' ? zh : en;
      String? status() => switch (flatpak.phase) {
            FlatpakUpdatePhase.idle => null,
            FlatpakUpdatePhase.checking => labels.jmsUpdateState('checking'),
            FlatpakUpdatePhase.manual => text(
                'A JMS update source has not been confirmed.',
                '尚未確認可用的 JMS 更新來源。'),
            FlatpakUpdatePhase.available => labels.jmsUpdateState('available'),
            FlatpakUpdatePhase.current => labels.jmsUpdateState('current'),
            FlatpakUpdatePhase.updating => text(
                'Flatpak is installing the update. JMS will keep running.',
                'Flatpak 正在安裝更新，JMS 會繼續執行。'),
            FlatpakUpdatePhase.noUpdate => text(
                'Flatpak reported no update to install.',
                'Flatpak 回報沒有可安裝的更新。'),
            FlatpakUpdatePhase.restartRequired => flatpak.restartDeferred
                ? text(
                    'The update is installed. Reopen JMS after playback and the watch room have ended.',
                    '更新已安裝。請在播放與一起看結束後，重新開啟 JMS。')
                : text('The update is installed. Reopen JMS to use it.',
                    '更新已安裝，請重新開啟 JMS 使用新版。'),
            FlatpakUpdatePhase.outcomeUnknown => text(
                'The update result is unconfirmed. Check the software center before trying another installation.',
                '更新結果尚未確認。請先由軟體中心確認，避免重複安裝。'),
            FlatpakUpdatePhase.unsupported => text(
                'In-app Flatpak updates are unavailable here. Use the software center or a newer installer.',
                '此環境無法在 App 內更新 Flatpak。請使用軟體中心或新版安裝檔。'),
            FlatpakUpdatePhase.failed => flatpak.failure ==
                    FlatpakPortalFailureCode.permissionChange
                ? text(
                    'This update changes permissions. Review it in the software center.',
                    '此更新會變更權限，請由軟體中心確認。')
                : labels.somethingWentWrong,
          };

      Future<void> confirmUpdate() async {
        final target = flatpak.candidate?.remoteCommit;
        if (!flatpak.canRequestUpdate || target == null) return;
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(labels.jmsUpdateInstall),
            content: Text(text(
                'Install the update from this app’s configured Flatpak source? JMS will not close or restart automatically.',
                '要從此 App 已設定的 Flatpak 來源安裝更新嗎？JMS 不會自動關閉或重新啟動。')),
            actions: [
              TextButton(
                key: const ValueKey('flatpak-update-cancel-confirmation'),
                autofocus: true,
                style: TextButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    visualDensity: VisualDensity.standard),
                onPressed: () => Navigator.pop(context, false),
                child: Text(labels.cancel),
              ),
              TextButton(
                key: const ValueKey('flatpak-update-accept-confirmation'),
                style: TextButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    visualDensity: VisualDensity.standard),
                onPressed: () => Navigator.pop(context, true),
                child: Text(labels.jmsUpdateInstall),
              ),
            ],
          ),
        );
        if (confirmed != true || !context.mounted) return;
        await flatpak.requestUpdate(
            userConfirmed: true, expectedRemoteCommit: target);
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Divider(),
          ListTile(
            key: ValueKey('flatpak-update-${capability.code.name}'),
            leading: const Icon(Icons.system_update),
            title: Text(labels.jmsFlatpakUpdateTitle),
          ),
          SwitchListTile(
            key: const ValueKey('flatpak-auto-check'),
            title: Text(labels.autoCheckForUpdates),
            value: automatic,
            onChanged: (enabled) => ref
                .read(clientSettingsProvider.notifier)
                .update(
                    (settings) => settings.copyWith(checkForUpdates: enabled)),
          ),
          if (!capability.canRequestPortalCheck)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                  text(
                      'Use the software center or a newer installer if no update source is available.',
                      '沒有可用更新來源時，請使用軟體中心或新版安裝檔。'),
                  key: const ValueKey('flatpak-update-instructions')),
            ),
          if (status() case final message?)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(message,
                  key: ValueKey('flatpak-phase-${flatpak.phase.name}')),
            ),
          if (flatpak.phase == FlatpakUpdatePhase.updating)
            Padding(
              padding: const EdgeInsets.all(12),
              child: LinearProgressIndicator(
                  value: flatpak.progress == null
                      ? null
                      : flatpak.progress! / 100),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Wrap(
                spacing: 12,
                children: [
                  TextButton.icon(
                    key: const ValueKey('flatpak-check-update'),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      visualDensity: VisualDensity.standard,
                    ),
                    onPressed: flatpak.canCheck ? flatpak.check : null,
                    icon: const Icon(Icons.refresh),
                    label: Text(labels.jmsUpdateCheck),
                  ),
                  if (flatpak.canRequestUpdate)
                    TextButton.icon(
                      key: const ValueKey('flatpak-confirm-update'),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(48, 48),
                        visualDensity: VisualDensity.standard,
                      ),
                      onPressed: confirmUpdate,
                      icon: const Icon(Icons.system_update),
                      label: Text(labels.jmsUpdateInstall),
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: const ValueKey('flatpak-open-releases'),
                style: TextButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  visualDensity: VisualDensity.standard,
                ),
                onPressed: () async {
                  try {
                    final opened = await (openExternalLink?.call(
                          FlatpakUpdateCapability.manualDownloads,
                        ) ??
                        launchUrl(
                          FlatpakUpdateCapability.manualDownloads,
                          mode: LaunchMode.externalApplication,
                        ));
                    if (opened || !context.mounted) return;
                  } catch (_) {
                    if (!context.mounted) return;
                  }
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(labels.somethingWentWrong)),
                    );
                  }
                },
                icon: const Icon(Icons.open_in_new),
                label: Text(labels.latestReleases),
              ),
            ),
          ),
        ],
      );
    }
    final release = updates.latestRelease;
    final configured = updates.checker.source.configured;
    final canAct = updates.ready && !updates.busy && !updates.blocked;
    final canCheck = updates.supported && !updates.busy && !updates.blocked;
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
          leading: Icon(updates.bridge.isDesktop
              ? Icons.desktop_windows
              : Icons.system_update),
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
          onChanged: updates.settingsReady ? updates.setAutomatic : null,
        ),
        SwitchListTile(
          title: Text(labels.jmsUpdatePrerelease),
          value: updates.prerelease,
          onChanged: updates.settingsReady && !updates.busy
              ? updates.setPrerelease
              : null,
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
                  onPressed: canCheck ? () => updates.check() : null,
                  icon: const Icon(Icons.refresh),
                  label: Text(labels.jmsUpdateCheck),
                )
              else ...[
                OutlinedButton.icon(
                  onPressed: canCheck ? () => updates.check() : null,
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
