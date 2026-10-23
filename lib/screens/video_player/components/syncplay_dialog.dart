import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/providers/syncplay_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/services/syncplay/syncplay_models.dart';

class SyncPlayButton extends ConsumerWidget {
  const SyncPlayButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final room = ref.watch(syncPlayProvider).room;
    final strings = SyncPlayStrings.of(context);
    return IconButton(
      tooltip: strings.title,
      isSelected: room.group != null,
      icon: const Icon(Icons.group_outlined),
      selectedIcon: const Icon(Icons.group),
      onPressed: () => showDialog<void>(
          context: context, builder: (_) => const SyncPlayDialog()),
    );
  }
}

class SyncPlayDialog extends ConsumerStatefulWidget {
  const SyncPlayDialog({super.key});

  @override
  ConsumerState<SyncPlayDialog> createState() => _SyncPlayDialogState();
}

class _SyncPlayDialogState extends ConsumerState<SyncPlayDialog> {
  bool _opening = true;

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      if (!mounted) return;
      await ref.read(syncPlayProvider.notifier).refreshPermission();
      if (mounted) setState(() => _opening = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(syncPlayProvider);
    ref.watch(
        userProvider.select((account) => account?.policy?.syncPlayAccess));
    ref.watch(playBackModel);
    ref.watch(videoPlayerProvider);
    final notifier = ref.read(syncPlayProvider.notifier);
    return SyncPlayRoomPanel(
      state: state,
      supported: notifier.supported,
      canJoin: !_opening && notifier.canJoin,
      canCreate: !_opening && notifier.canCreate,
      checkingPermission: _opening || notifier.permissionChecking,
      permissionKnown: !_opening && notifier.permissionKnown,
      createRoom: notifier.createRoom,
      joinRoom: notifier.joinRoom,
      leaveRoom: notifier.leaveRoom,
      reconnect: notifier.reconnect,
    );
  }
}

/// Presentation-only panel, so permission, pending and mobile states can be
/// exercised without opening a socket or changing real viewing history.
class SyncPlayRoomPanel extends StatefulWidget {
  const SyncPlayRoomPanel({
    super.key,
    required this.state,
    required this.supported,
    required this.canJoin,
    required this.canCreate,
    required this.createRoom,
    required this.joinRoom,
    required this.leaveRoom,
    required this.reconnect,
    this.checkingPermission = false,
    this.permissionKnown = true,
  });
  final SyncPlayViewState state;
  final bool supported;
  final bool canJoin;
  final bool canCreate;
  final Future<void> Function() createRoom;
  final Future<void> Function(String) joinRoom;
  final Future<void> Function() leaveRoom;
  final Future<void> Function() reconnect;
  final bool checkingPermission;
  final bool permissionKnown;

  @override
  State<SyncPlayRoomPanel> createState() => _SyncPlayRoomPanelState();
}

class _SyncPlayRoomPanelState extends State<SyncPlayRoomPanel> {
  final _code = TextEditingController();
  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = SyncPlayStrings.of(context);
    final room = widget.state.room;
    final pending = widget.checkingPermission ||
        widget.state.busy ||
        const {
          SyncPlayStatus.creating,
          SyncPlayStatus.joining,
          SyncPlayStatus.leaving,
        }.contains(room.status);
    final uncertain = const {
      SyncPlayStatus.unknown,
      SyncPlayStatus.disconnected
    }.contains(room.status);
    final available = widget.supported &&
        widget.permissionKnown &&
        widget.canJoin &&
        !pending;
    final failure = widget.state.failure ?? room.failure;
    return AlertDialog(
      title: Text(s.title),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(s.explanation),
                const SizedBox(height: 16),
                if (!widget.supported) Text(s.unsupported),
                if (!widget.checkingPermission &&
                    widget.permissionKnown &&
                    !widget.canJoin)
                  Text(s.noPermission),
                if (!widget.checkingPermission && !widget.permissionKnown)
                  Text(s.permissionUnknown),
                if (pending) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 12),
                  Text(s.waiting),
                ],
                if (room.group != null) ...[
                  Text(s.roomCode,
                      style: Theme.of(context).textTheme.labelLarge),
                  Row(children: [
                    Expanded(
                        child: SelectableText(
                            room.group!.code ?? room.group!.groupName,
                            style: Theme.of(context).textTheme.headlineMedium)),
                    if (room.group!.code != null)
                      IconButton(
                        tooltip: s.copyCode,
                        icon: const Icon(Icons.copy),
                        onPressed: () => Clipboard.setData(
                            ClipboardData(text: room.group!.code!)),
                      ),
                  ]),
                  Text(s.members(room.group!.participants.length)),
                  const SizedBox(height: 12),
                  Text(room.canControl ? s.connected : s.synchronizing),
                  SyncPlayDiagnosticsPanel(diagnostics: room.diagnostics),
                  const SizedBox(height: 12),
                ],
                if (failure != null) ...[
                  Text(s.failure(failure.code),
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                  const SizedBox(height: 12),
                ],
                if (uncertain) ...[
                  Text(s.uncertain),
                  const SizedBox(height: 8),
                  OutlinedButton(
                      onPressed: available ? widget.reconnect : null,
                      child: Text(s.reconnect)),
                ],
                if (room.group == null && !uncertain) ...[
                  FilledButton.icon(
                    onPressed: available && widget.canCreate
                        ? widget.createRoom
                        : null,
                    icon: const Icon(Icons.group_add_outlined),
                    label: Text(s.create),
                  ),
                  if (widget.canJoin && !widget.canCreate) Text(s.joinOnly),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _code,
                    enabled: available,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(6)
                    ],
                    decoration: InputDecoration(
                        labelText: s.roomCode,
                        hintText: '123456',
                        border: const OutlineInputBorder()),
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) {
                      if (available && _code.text.length == 6) {
                        widget.joinRoom(_code.text);
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: available && _code.text.length == 6
                        ? () => widget.joinRoom(_code.text)
                        : null,
                    child: Text(s.join),
                  ),
                ],
                const SizedBox(height: 12),
                Text(s.codeNotice,
                    style: Theme.of(context).textTheme.bodySmall),
              ]),
        ),
      ),
      actions: [
        if (room.group != null || uncertain)
          TextButton(
            onPressed: pending ? null : widget.leaveRoom,
            child: Text(s.leave),
          ),
        TextButton(
            onPressed: () => Navigator.of(context).pop(), child: Text(s.close)),
      ],
    );
  }
}

class SyncPlayDiagnosticsPanel extends StatelessWidget {
  const SyncPlayDiagnosticsPanel({super.key, required this.diagnostics});

  final SyncPlayDiagnostics diagnostics;

  @override
  Widget build(BuildContext context) {
    final s = SyncPlayStrings.of(context);
    String ms(Duration? value, {bool signed = false}) => value == null
        ? s.noSample
        : '${signed && !value.isNegative ? '+' : ''}${(value.inMicroseconds / 1000).toStringAsFixed(1)} ms';
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text(s.diagnostics),
      children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  '${s.networkRoundTrip}: ${ms(diagnostics.networkRoundTrip)}'),
              Text(
                  '${s.clockOffset}: ${ms(diagnostics.clockOffset, signed: true)}'),
              Text('${s.clockAge}: ${ms(diagnostics.clockSampleAge)}'),
              Text(
                  '${s.playbackDrift}: ${ms(diagnostics.playbackDrift, signed: true)}'),
              Text('${s.driftAge}: ${ms(diagnostics.driftSampleAge)}'),
              Text('${s.corrections}: ${diagnostics.correctionCount}'),
              Text(
                  '${s.lastCorrection}: ${ms(diagnostics.lastCorrection, signed: true)}'),
              const SizedBox(height: 8),
              Text(s.diagnosticsNotice,
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ],
    );
  }
}

class SyncPlayStrings {
  const SyncPlayStrings(this.zh);
  final bool zh;
  static SyncPlayStrings of(BuildContext context) =>
      SyncPlayStrings(Localizations.localeOf(context).languageCode == 'zh');
  String get title => zh ? '一起看' : 'Watch together';
  String get explanation => zh
      ? '朋友各自登入同一台 Jellyfin，輸入 6 位房間碼，一起同步播放、暫停與跳轉。'
      : 'Sign in to the same Jellyfin with your own accounts. Use a six-digit room code to synchronize playback, pause and seeking.';
  String get unsupported => zh
      ? '請先開啟線上影片。一起看目前支援內建播放器，不支援離線、音樂、直播或外部 Native 播放器。'
      : 'Open an online video first. Watch together supports the built-in player; offline, music, live TV and external Native players are not supported.';
  String get noPermission => zh
      ? '此帳號尚未開啟 SyncPlay 權限，請聯絡 Jellyfin 管理者。'
      : 'This account needs SyncPlay permission from the Jellyfin administrator.';
  String get permissionUnknown => zh
      ? '目前無法確認此帳號的 SyncPlay 權限，請檢查連線後重新開啟此視窗。'
      : 'Unable to confirm SyncPlay permission. Check the connection and reopen this dialog.';
  String get waiting => zh ? '正在等待伺服器確認…' : 'Waiting for server confirmation…';
  String get roomCode => zh ? '6 位房間碼' : 'Six-digit room code';
  String get copyCode => zh ? '複製房間碼' : 'Copy room code';
  String members(int count) => zh ? '房間內 $count 人' : '$count participants';
  String get connected => zh
      ? '已連線，播放控制會同步至房間。'
      : 'Connected. Playback controls are synchronized with the room.';
  String get synchronizing =>
      zh ? '正在同步房間狀態與時間…' : 'Synchronizing room state and time…';
  String get uncertain => zh
      ? '目前無法確認房間狀態。請重新連線確認，避免重複建立房間。'
      : 'Room state is unconfirmed. Reconnect to check before creating another room.';
  String get reconnect => zh ? '重新連線並確認' : 'Reconnect and check';
  String get create => zh ? '以目前影片建立房間' : 'Create room with this video';
  String get join => zh ? '加入房間' : 'Join room';
  String get joinOnly => zh
      ? '此帳號可加入房間，無法建立房間。'
      : 'This account may join rooms but cannot create them.';
  String get leave => zh ? '離開房間' : 'Leave room';
  String get close => zh ? '關閉' : 'Close';
  String get diagnostics => zh ? '同步診斷' : 'Sync diagnostics';
  String get noSample => zh ? '尚無可用樣本' : 'No current sample';
  String get networkRoundTrip => zh ? '網路往返估計' : 'Estimated network round trip';
  String get clockOffset => zh ? '伺服器時間差' : 'Server clock offset';
  String get clockAge => zh ? '時間樣本年齡（檢查時）' : 'Clock sample age (at check)';
  String get playbackDrift => zh ? '本機播放誤差' : 'Local playback drift';
  String get driftAge => zh ? '誤差樣本年齡（檢查時）' : 'Drift sample age (at check)';
  String get corrections => zh ? '播放校正次數' : 'Playback corrections';
  String get lastCorrection => zh ? '最近校正目標量' : 'Last requested correction';
  String get diagnosticsNotice => zh
      ? '播放誤差正值表示本機落後伺服器播放目標，負值表示超前；這不是朋友裝置之間的實測誤差。資料於播放與時間同步檢查時更新；檢查發現緩衝、暫停或斷線時，不顯示舊誤差。資料只在本機記憶體中，不會上傳。'
      : 'Positive drift means this player is behind the server target; negative means ahead. This is not a measured difference between friends’ devices. Snapshots update on playback and clock checks; old drift is hidden when checks find buffering, paused or disconnected playback. Data stays in local memory and is not uploaded.';
  String get codeNotice => zh
      ? '房間碼用來尋找房間，不是密碼。同一伺服器有權限的使用者仍可能從其他客戶端看到房間；每人只能播放自己帳號有權限的影片。'
      : 'The code locates a room; it is not a password. Other authorized users on the server may see the room in other clients. Each participant needs their own permission to play the video.';
  String failure(SyncPlayFailureCode code) => switch (code) {
        SyncPlayFailureCode.invalidCode =>
          zh ? '請輸入 6 位數字房間碼。' : 'Enter a six-digit room code.',
        SyncPlayFailureCode.noGroup => zh
            ? '找不到這個房間，請確認房間碼與 Jellyfin 伺服器。'
            : 'Room not found. Check the code and Jellyfin server.',
        SyncPlayFailureCode.ambiguousCode => zh
            ? '房間碼重複，請房間建立者更換房間碼。'
            : 'Multiple rooms use this code. Ask the creator to choose another code.',
        SyncPlayFailureCode.denied => zh
            ? '伺服器拒絕此操作，請確認帳號及影片權限。'
            : 'The server denied the action. Check account and media permissions.',
        SyncPlayFailureCode.timeoutUnknown => zh
            ? '伺服器確認逾時，請重新連線確認房間狀態。'
            : 'Confirmation timed out. Reconnect to check the room state.',
        SyncPlayFailureCode.disconnected =>
          zh ? '連線已中斷，請重新連線。' : 'Connection lost. Please reconnect.',
        SyncPlayFailureCode.clock => zh
            ? '尚未完成時間同步，請稍候或重新連線。'
            : 'Clock synchronization is incomplete. Wait or reconnect.',
        SyncPlayFailureCode.player => zh
            ? '無法載入房間影片，請確認觀看權限與播放器。'
            : 'Unable to load the room video. Check media permission and the player.',
        _ => zh
            ? '無法完成操作，請確認房間狀態後再試。'
            : 'Unable to complete the action. Check the room state before trying again.',
      };
}
