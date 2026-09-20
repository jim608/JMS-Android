import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/models/media_playback_model.dart';
import 'package:fladder/models/settings/client_settings_model.dart';
import 'package:fladder/models/settings/video_player_settings.dart';
import 'package:fladder/providers/settings/client_settings_provider.dart';
import 'package:fladder/providers/settings/video_player_settings_provider.dart';
import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/util/localization_helper.dart';
import 'package:fladder/util/settings_backup.dart';
import 'package:fladder/util/settings_backup_files.dart';

class SettingsBackupTile extends StatelessWidget {
  const SettingsBackupTile({super.key});

  @override
  Widget build(BuildContext context) => ListTile(
        leading: const Icon(Icons.settings_backup_restore),
        title: Text(context.localized.jmsBackupTitle),
        subtitle: Text(context.localized.jmsBackupScope),
        onTap: () =>
            showDialog<void>(context: context, barrierDismissible: false, builder: (_) => const SettingsBackupDialog()),
      );
}

class SettingsBackupDialog extends ConsumerStatefulWidget {
  const SettingsBackupDialog({super.key});

  @override
  ConsumerState<SettingsBackupDialog> createState() => _SettingsBackupDialogState();
}

class _SettingsBackupDialogState extends ConsumerState<SettingsBackupDialog> {
  bool _busy = false;
  bool _previewing = false;
  String? _message;

  Future<void> _run(Future<String> Function() operation) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    String result;
    try {
      result = await operation();
    } on SettingsBackupFailure catch (error) {
      result = error.code;
    } catch (_) {
      result = 'io';
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _previewing = false;
        _message = result;
      });
    }
  }

  Future<String> _export() {
    final backup = SettingsBackup.capture(
        ref.read(clientSettingsProvider).toJson(), ref.read(videoPlayerSettingsProvider).toJson());
    return ref.read(settingsBackupFilesProvider).save(backup.encode());
  }

  Future<String> _restore() async {
    if (ref.read(mediaPlaybackProvider).state != VideoPlayerState.disposed) {
      return 'playing';
    }
    final bytes = await ref.read(settingsBackupFilesProvider).pick();
    if (!mounted || bytes == null) return 'cancelled';
    final backup = SettingsBackup.parse(bytes);
    final beforeClient = ref.read(clientSettingsProvider).toJson();
    final beforePlayer = ref.read(videoPlayerSettingsProvider).toJson();
    final changes = backup.changes(beforeClient, beforePlayer);
    if (changes.isEmpty) return 'unchanged';
    setState(() => _previewing = true);
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.localized.jmsBackupPreview),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(context.localized.jmsBackupScope),
              for (final change in changes)
                ListTile(
                  title: Text(context.localized.jmsBackupField(change.field)),
                  subtitle: Text('${_value(context, change.before)} → ${_value(context, change.after)}'),
                ),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.localized.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(context.localized.jmsBackupApply)),
        ],
      ),
    );
    if (!mounted || accepted != true) return 'cancelled';
    setState(() => _previewing = false);
    if (ref.read(mediaPlaybackProvider).state != VideoPlayerState.disposed) {
      return 'playing';
    }
    if (jsonEncode(beforeClient) != jsonEncode(ref.read(clientSettingsProvider).toJson()) ||
        jsonEncode(beforePlayer) != jsonEncode(ref.read(videoPlayerSettingsProvider).toJson())) {
      return 'stale';
    }
    final client = ClientSettingsModel.fromJson(backup.merge('client', beforeClient));
    final player = VideoPlayerSettingsModel.fromJson(backup.merge('player', beforePlayer));
    final clientNotifier = ref.read(clientSettingsProvider.notifier);
    final playerNotifier = ref.read(videoPlayerSettingsProvider.notifier);
    final storage = SettingsBundleStore(ref.read(sharedPreferencesProvider));
    if (!await clientNotifier.flushForRestore()) {
      throw const SettingsBackupFailure('io');
    }
    await storage.replace(client.toJson(), player.toJson());
    clientNotifier.applyRestoredSettings(client);
    playerNotifier.applyRestoredSettings(player);
    return 'restored';
  }

  String _value(BuildContext context, Object? value) =>
      value is num ? value.toString() : context.localized.jmsBackupValue(value?.toString() ?? 'unset');

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !_busy,
        child: AlertDialog(
          title: Text(context.localized.jmsBackupTitle),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(context.localized.jmsBackupScope),
                const SizedBox(height: 16),
                if (_busy && !_previewing) const LinearProgressIndicator(),
                if (_message != null) Text(context.localized.jmsBackupStatus(_message!)),
                const SizedBox(height: 12),
                FilledButton(
                    onPressed: _busy ? null : () => _run(_export), child: Text(context.localized.jmsBackupExport)),
                TextButton(
                    onPressed: _busy ? null : () => _run(_restore), child: Text(context.localized.jmsBackupImport)),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: Text(context.localized.close))
          ],
        ),
      );
}
