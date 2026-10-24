import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/screens/video_player/components/syncplay_dialog.dart';

/// The home entry is available before a player or a playback model exists.
class SyncPlayHomeEntry extends ConsumerStatefulWidget {
  const SyncPlayHomeEntry({super.key, this.onPressed});

  final VoidCallback? onPressed;

  @override
  ConsumerState<SyncPlayHomeEntry> createState() => _SyncPlayHomeEntryState();
}

class _SyncPlayHomeEntryState extends ConsumerState<SyncPlayHomeEntry> {
  bool _opening = false;

  Future<void> _open() async {
    if (_opening) return;
    final account = ref.read(userProvider);
    setState(() => _opening = true);
    try {
      final ready = await showDialog<bool>(
        context: context,
        builder: (_) => const SyncPlayDialog(joinFromHome: true),
      );
      if (!mounted || ready != true) return;
      final currentAccount = ref.read(userProvider);
      if (account == null ||
          currentAccount?.id != account.id ||
          currentAccount?.credentials != account.credentials) {
        return;
      }
      await ref.read(videoPlayerProvider.notifier).openPlayer(context);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = SyncPlayStrings.of(context);
    return SyncPlayKeyGuard(
        child: SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 16, 8),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilledButton.tonalIcon(
            style: FilledButton.styleFrom(
              minimumSize: const Size(48, 48),
              visualDensity: VisualDensity.standard,
            ),
            onPressed: widget.onPressed ?? _open,
            icon: const Icon(Icons.group_outlined),
            label: Text(strings.title),
          ),
        ),
      ),
    ));
  }
}
