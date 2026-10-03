import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/providers/discord_presence_provider.dart';
import 'package:fladder/util/localization_helper.dart';

class SettingsDiscordPresence extends ConsumerStatefulWidget {
  const SettingsDiscordPresence({super.key});

  @override
  ConsumerState<SettingsDiscordPresence> createState() =>
      _SettingsDiscordPresenceState();
}

class _SettingsDiscordPresenceState
    extends ConsumerState<SettingsDiscordPresence> {
  bool _confirming = false;

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(discordPresenceSettingsProvider);
    if (!settings.supported) return const SizedBox.shrink();
    final labels = context.localized;
    final canChange = settings.hasAccount && !settings.busy && !_confirming;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          key: const ValueKey('discord-presence-enabled'),
          title: Text(labels.jmsDiscordTitle),
          subtitle: Text(settings.hasAccount
              ? labels.jmsDiscordHint
              : labels.jmsDiscordAccountRequired),
          value: settings.enabled,
          onChanged: canChange
              ? (value) => _changeSetting(settings, value, shareTitle: false)
              : null,
        ),
        SwitchListTile(
          key: const ValueKey('discord-presence-share-title'),
          title: Text(labels.jmsDiscordShareTitle),
          subtitle: Text(labels.jmsDiscordShareTitleHint),
          value: settings.shareTitle,
          onChanged: canChange && (settings.enabled || settings.shareTitle)
              ? (value) => _changeSetting(settings, value, shareTitle: true)
              : null,
        ),
        ListTile(
          key: const ValueKey('discord-presence-status'),
          leading: const Icon(Icons.info_outline),
          title: Text(!settings.enabled
              ? labels.jmsDiscordInactive
              : switch (settings.status) {
                  DiscordConnectionState.disconnected =>
                    labels.jmsDiscordDisconnected,
                  DiscordConnectionState.connecting =>
                    labels.jmsDiscordConnecting,
                  DiscordConnectionState.connected =>
                    labels.jmsDiscordConnected,
                  DiscordConnectionState.error => labels.jmsDiscordError,
                }),
        ),
      ],
    );
  }

  Future<void> _changeSetting(DiscordPresenceSettings settings, bool value,
      {required bool shareTitle}) async {
    if (_confirming || settings.busy || !settings.hasAccount) return;
    final scope = settings.activeScope;
    final labels = context.localized;
    if (value) {
      setState(() => _confirming = true);
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(shareTitle
              ? labels.jmsDiscordShareTitle
              : labels.jmsDiscordTitle),
          content: Text(shareTitle
              ? labels.jmsDiscordTitleConsent
              : labels.jmsDiscordConsent),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(labels.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(labels.jmsDiscordConfirm),
            ),
          ],
        ),
      );
      if (!mounted) return;
      setState(() => _confirming = false);
      if (accepted != true) return;
    }
    if (!mounted ||
        !identical(ref.read(discordPresenceSettingsProvider), settings) ||
        settings.activeScope != scope ||
        !settings.supported ||
        !settings.hasAccount ||
        settings.busy ||
        (shareTitle && value && !settings.enabled)) {
      return;
    }
    final saved = shareTitle
        ? await settings.setShareTitle(value)
        : await settings.setEnabled(value);
    if (!saved && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(labels.jmsDiscordSaveError)),
      );
    }
  }
}
