import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/providers/syncplay_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/services/syncplay/syncplay_models.dart';
import 'package:fladder/services/syncplay/syncplay_prebuffer.dart';
import 'package:fladder/widgets/shared/controller_navigation.dart';

/// Consume held-controller repeats locally before Flutter's default shortcuts.
/// The shared app navigation continues to handle the initial activation.
class SyncPlayKeyGuard extends StatelessWidget {
  const SyncPlayKeyGuard({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onKeyEvent: (_, event) =>
        event is KeyRepeatEvent &&
            const <LogicalKeyboardKey>[
              LogicalKeyboardKey.gameButtonA,
              LogicalKeyboardKey.gameButtonB,
              LogicalKeyboardKey.select,
              LogicalKeyboardKey.enter,
              LogicalKeyboardKey.space,
              LogicalKeyboardKey.escape,
            ].contains(event.logicalKey)
        ? KeyEventResult.handled
        : KeyEventResult.ignored,
    child: child,
  );
}

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
        context: context,
        builder: (_) => const SyncPlayDialog(),
      ),
    );
  }
}

class SyncPlayDialog extends ConsumerStatefulWidget {
  const SyncPlayDialog({super.key, this.joinFromHome = false});

  final bool joinFromHome;

  @override
  ConsumerState<SyncPlayDialog> createState() => _SyncPlayDialogState();
}

class _SyncPlayDialogState extends ConsumerState<SyncPlayDialog> {
  bool _opening = true;
  bool _closing = false;
  bool _startingJoin = false;
  bool _allowPop = false;
  int? _homeTicket;
  String? _lastCode;
  late final SyncPlayNotifier _notifier;

  @override
  void initState() {
    super.initState();
    _notifier = ref.read(syncPlayProvider.notifier);
    Future.microtask(_refreshPermission);
  }

  Future<void> _refreshPermission() async {
    if (!mounted || _closing) return;
    setState(() => _opening = true);
    await _notifier.refreshPermission();
    if (mounted) setState(() => _opening = false);
  }

  Future<void> _join(String code) async {
    if (_closing || _startingJoin) return;
    if (!widget.joinFromHome) return _notifier.joinRoom(code);
    setState(() => _startingJoin = true);
    try {
      final oldTicket = _homeTicket;
      if (oldTicket != null) {
        await _notifier.cancelHomeJoin(oldTicket);
        if (!mounted || _closing) return;
      }
      _lastCode = code;
      setState(() => _homeTicket = _notifier.beginHomeJoin(code));
    } finally {
      if (mounted) setState(() => _startingJoin = false);
    }
  }

  Future<void> _leave() async {
    final ticket = _homeTicket;
    if (ticket != null) {
      await _notifier.cancelHomeJoin(ticket);
      if (mounted) setState(() => _homeTicket = null);
    } else {
      await _notifier.leaveRoom();
    }
  }

  Future<void> _reconnect() async {
    if (_closing || _startingJoin) return;
    if (!widget.joinFromHome) return _notifier.reconnect();
    setState(() => _homeTicket = _notifier.beginHomeReconnect());
  }

  Future<void> _close() async {
    if (_closing) return;
    setState(() => _closing = true);
    final ticket = _homeTicket;
    if (ticket != null) await _notifier.cancelHomeJoin(ticket);
    if (!mounted) return;
    setState(() {
      _homeTicket = null;
      _allowPop = true;
    });
    Navigator.of(context).pop();
  }

  void _ready(int? ticket) {
    if (ticket == null || ticket != _homeTicket) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _closing ||
          ticket != _homeTicket ||
          ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      if (!_notifier.consumeHomeJoin(ticket)) return;
      setState(() {
        _homeTicket = null;
        _allowPop = true;
      });
      Navigator.of(context).pop(true);
    });
  }

  @override
  void dispose() {
    final ticket = _homeTicket;
    if (ticket != null) unawaited(_notifier.cancelHomeJoin(ticket));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(syncPlayProvider);
    final account = ref.watch(userProvider);
    if (!widget.joinFromHome) {
      ref.watch(playBackModel);
      ref.watch(videoPlayerProvider);
    } else {
      _ready(state.readyHomeJoin);
    }
    return SyncPlayKeyGuard(
      child: PopScope(
        canPop: _allowPop || _homeTicket == null,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) unawaited(_close());
        },
        child: ControllerNavigation(
          onBack: () => unawaited(_close()),
          child: SyncPlayRoomPanel(
            state: state,
            supported: widget.joinFromHome || _notifier.supported,
            canJoin:
                !_opening &&
                (widget.joinFromHome
                    ? _notifier.canJoinFromHome
                    : _notifier.canJoin),
            canCreate: !widget.joinFromHome && !_opening && _notifier.canCreate,
            checkingPermission: _opening || _notifier.permissionChecking,
            permissionKnown: !_opening && _notifier.permissionKnown,
            signedIn:
                account != null &&
                account.credentials.token.isNotEmpty &&
                account.credentials.deviceId.isNotEmpty,
            joinFromHome: widget.joinFromHome,
            closing: _closing,
            transitioning: _startingJoin,
            createRoom: _notifier.createRoom,
            joinRoom: _join,
            leaveRoom: _leave,
            reconnect: _reconnect,
            refreshPermission: _refreshPermission,
            retry: widget.joinFromHome && _lastCode != null
                ? () => _join(_lastCode!)
                : null,
            close: _close,
          ),
        ),
      ),
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
    this.signedIn = true,
    this.joinFromHome = false,
    this.closing = false,
    this.transitioning = false,
    this.refreshPermission,
    this.retry,
    this.close,
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
  final bool signedIn;
  final bool joinFromHome;
  final bool closing;
  final bool transitioning;
  final Future<void> Function()? refreshPermission;
  final Future<void> Function()? retry;
  final Future<void> Function()? close;

  @override
  State<SyncPlayRoomPanel> createState() => _SyncPlayRoomPanelState();
}

class _SyncPlayRoomPanelState extends State<SyncPlayRoomPanel> {
  final _code = TextEditingController();
  final _cancelFocus = FocusNode(debugLabel: 'SyncPlay cancel');
  bool _actionPending = false;
  @override
  void dispose() {
    _code.dispose();
    _cancelFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = SyncPlayStrings.of(context);
    final room = widget.state.room;
    final recoveryActive = widget.state.recoveryActive;
    final pending =
        widget.closing ||
        widget.transitioning ||
        widget.checkingPermission ||
        widget.state.preparingPlayback ||
        widget.state.busy ||
        const {
          SyncPlayStatus.creating,
          SyncPlayStatus.joining,
          SyncPlayStatus.leaving,
        }.contains(room.status);
    final actionPending =
        widget.state.busy ||
        widget.state.preparingPlayback ||
        widget.transitioning;
    if (actionPending != _actionPending) {
      _actionPending = actionPending;
      if (actionPending) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !widget.closing) _cancelFocus.requestFocus();
        });
      }
    }
    final uncertain = const {
      SyncPlayStatus.unknown,
      SyncPlayStatus.disconnected,
    }.contains(room.status);
    final available =
        widget.signedIn &&
        widget.supported &&
        widget.permissionKnown &&
        widget.canJoin &&
        !pending;
    final failure = widget.state.failure ?? room.failure;
    final temporaryFailure = const {
      SyncPlayFailureCode.timeoutUnknown,
      SyncPlayFailureCode.disconnected,
      SyncPlayFailureCode.clock,
      SyncPlayFailureCode.server,
    }.contains(failure?.code);
    final canCancelRecovery =
        recoveryActive &&
        !widget.closing &&
        !widget.transitioning &&
        !widget.checkingPermission &&
        !widget.state.busy &&
        !widget.state.preparingPlayback &&
        room.status != SyncPlayStatus.leaving;
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
              if (!widget.signedIn) Text(s.signIn),
              if (!widget.supported) Text(s.unsupported),
              if (widget.signedIn &&
                  !widget.checkingPermission &&
                  widget.permissionKnown &&
                  !widget.canJoin)
                Text(s.noPermission),
              if (widget.signedIn &&
                  !widget.checkingPermission &&
                  !widget.permissionKnown) ...[
                Text(s.permissionUnknown),
                if (widget.refreshPermission != null)
                  OutlinedButton(
                    onPressed: widget.refreshPermission,
                    child: Text(s.retryPermission),
                  ),
              ],
              if (pending) ...[
                const LinearProgressIndicator(),
                const SizedBox(height: 12),
                Text(
                  recoveryActive
                      ? s.recovering
                      : widget.state.preparingPlayback
                      ? s.loadingVideo
                      : widget.closing
                      ? s.cancelling
                      : s.waiting,
                ),
              ],
              if (room.group != null) ...[
                Text(s.roomCode, style: Theme.of(context).textTheme.labelLarge),
                Row(
                  children: [
                    Expanded(
                      child: SelectableText(
                        room.group!.code ?? room.group!.groupName,
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                    ),
                    if (room.group!.code != null)
                      IconButton(
                        tooltip: s.copyCode,
                        icon: const Icon(Icons.copy),
                        onPressed: () => Clipboard.setData(
                          ClipboardData(text: room.group!.code!),
                        ),
                      ),
                  ],
                ),
                Text(s.members(room.group!.participants.length)),
                const SizedBox(height: 12),
                if (!uncertain) Text(s.roomConfirmation(room)),
                const SizedBox(height: 8),
                SyncPlayLocalBufferPanel(
                  room: room,
                  prebuffer: widget.state.prebuffer,
                ),
                SyncPlayDiagnosticsPanel(diagnostics: room.diagnostics),
                const SizedBox(height: 12),
              ],
              if (failure != null && !(recoveryActive && temporaryFailure)) ...[
                Text(
                  s.failure(failure.code),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                const SizedBox(height: 12),
                if (!pending && !uncertain && widget.retry != null)
                  OutlinedButton(onPressed: widget.retry, child: Text(s.retry)),
              ],
              if (uncertain) ...[
                Semantics(
                  liveRegion: true,
                  child: Text(
                    recoveryActive
                        ? s.recovering
                        : widget.state.recoveryExhausted
                        ? s.recoveryPaused
                        : s.uncertain,
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: available && !recoveryActive
                      ? widget.reconnect
                      : null,
                  child: Text(s.reconnect),
                ),
              ],
              if (room.group == null && !uncertain) ...[
                if (!widget.joinFromHome)
                  FilledButton.icon(
                    onPressed: available && widget.canCreate
                        ? widget.createRoom
                        : null,
                    icon: const Icon(Icons.group_add_outlined),
                    label: Text(s.create),
                  ),
                if (widget.joinFromHome)
                  Text(s.createFromVideo)
                else if (widget.canJoin && !widget.canCreate)
                  Text(s.joinOnly),
                const SizedBox(height: 16),
                TextField(
                  controller: _code,
                  enabled: available,
                  autofocus: widget.joinFromHome,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(6),
                  ],
                  decoration: InputDecoration(
                    labelText: s.roomCode,
                    hintText: '123456',
                    border: const OutlineInputBorder(),
                  ),
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
              Text(s.codeNotice, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ),
      actions: [
        if (room.group != null || uncertain)
          TextButton(
            onPressed: pending && !canCancelRecovery ? null : widget.leaveRoom,
            child: Text(s.leave),
          ),
        TextButton(
          focusNode: _cancelFocus,
          onPressed: widget.closing
              ? null
              : widget.close ?? () async => Navigator.of(context).pop(),
          child: Text(widget.joinFromHome && pending ? s.cancel : s.close),
        ),
      ],
    );
  }
}

/// Local measurements only: no participant names or estimates about peers.
class SyncPlayLocalBufferPanel extends StatelessWidget {
  const SyncPlayLocalBufferPanel({
    super.key,
    required this.room,
    this.prebuffer,
  });
  final SyncPlayControllerState room;
  final SyncPlayPrebufferDecision? prebuffer;

  @override
  Widget build(BuildContext context) {
    final s = SyncPlayStrings.of(context);
    // A current unknown/stale decision must not resurrect an older number.
    final ahead = prebuffer != null ? prebuffer!.ahead : room.bufferedAhead;
    final target = prebuffer != null
        ? prebuffer!.target
        : room.targetBufferedAhead;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          liveRegion: true,
          child: Text(
            s.localPlaybackStatus(room, prebuffer),
            key: const ValueKey('syncplay-local-status'),
          ),
        ),
        Text(
          s.localBuffer(ahead, target),
          key: const ValueKey('syncplay-local-buffer'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (prebuffer?.byteBudgetLimited == true)
          Text(s.bufferBudget, style: Theme.of(context).textTheme.bodySmall),
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
                '${s.networkRoundTrip}: ${ms(diagnostics.networkRoundTrip)}',
              ),
              Text(
                '${s.clockOffset}: ${ms(diagnostics.clockOffset, signed: true)}',
              ),
              Text('${s.clockAge}: ${ms(diagnostics.clockSampleAge)}'),
              Text(
                '${s.playbackDrift}: ${ms(diagnostics.playbackDrift, signed: true)}',
              ),
              Text('${s.driftAge}: ${ms(diagnostics.driftSampleAge)}'),
              Text('${s.corrections}: ${diagnostics.correctionCount}'),
              Text(
                '${s.lastCorrection}: ${ms(diagnostics.lastCorrection, signed: true)}',
              ),
              const SizedBox(height: 8),
              Text(
                s.diagnosticsNotice,
                style: Theme.of(context).textTheme.bodySmall,
              ),
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
  String get signIn => zh
      ? '請先登入 Jellyfin，再輸入房間碼。'
      : 'Sign in to Jellyfin before entering a room code.';
  String get createFromVideo => zh
      ? '輸入房間碼即可加入。建立新房間請先選擇影片。'
      : 'Enter a room code to join. To create a room, choose a video first.';
  String get loadingVideo =>
      zh ? '正在以你的帳號載入房間影片…' : 'Loading the room video with your account…';
  String get cancelling =>
      zh ? '正在取消並確認離房…' : 'Cancelling and confirming departure…';
  String get cancel => zh ? '取消' : 'Cancel';
  String get retry => zh ? '重新加入並載入' : 'Rejoin and reload';
  String get retryPermission => zh ? '重新檢查權限' : 'Check permission again';
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
      ? '目前無法確認此帳號的 SyncPlay 權限，請檢查連線後再試。'
      : 'Unable to confirm SyncPlay permission. Check the connection and try again.';
  String get waiting => zh ? '正在等待伺服器確認…' : 'Waiting for server confirmation…';
  String get roomCode => zh ? '6 位房間碼' : 'Six-digit room code';
  String get copyCode => zh ? '複製房間碼' : 'Copy room code';
  String members(int count) => zh ? '房間內 $count 人' : '$count participants';
  String get connected => zh
      ? '已連線，播放控制會同步至房間。'
      : 'Connected. Playback controls are synchronized with the room.';
  String get synchronizing =>
      zh ? '正在同步房間狀態與時間…' : 'Synchronizing room state and time…';
  String roomConfirmation(SyncPlayControllerState room) {
    if (!room.connected ||
        room.membershipFreshness == SyncPlayMembershipFreshness.uncertain) {
      return zh
          ? '房間狀態尚未確認，請重新連線確認。'
          : 'Room membership is unconfirmed. Reconnect to check.';
    }
    return switch (room.membershipFreshness) {
      SyncPlayMembershipFreshness.unverified =>
        zh
            ? '等待確認房間狀態；人數為最近取得的房間資料。'
            : 'Room confirmation is pending; the participant count is from the last room snapshot.',
      SyncPlayMembershipFreshness.stale =>
        zh
            ? '房間確認已過期；人數為上次資料，請重新連線確認。'
            : 'Room confirmation is out of date; the participant count is from the last snapshot. Reconnect to check.',
      SyncPlayMembershipFreshness.uncertain => uncertain,
      SyncPlayMembershipFreshness.confirmed =>
        room.canControl ? connected : synchronizing,
    };
  }

  String localBuffer(Duration? ahead, Duration? target) {
    String amount(Duration? value) => value == null || value.isNegative
        ? (zh ? '未知' : 'Unknown')
        : '${(value.inMicroseconds / Duration.microsecondsPerSecond).toStringAsFixed(1)} ${zh ? '秒' : 's'}';
    return zh
        ? '本機可播放緩衝：${amount(ahead)} · 目標 ${amount(target)}'
        : 'Ahead on this player: ${amount(ahead)} · target ${amount(target)}';
  }

  String get bufferBudget =>
      zh ? '已依本機快取預算調整目標。' : 'Target adjusted to the local cache budget.';

  String localPlaybackStatus(
    SyncPlayControllerState room,
    SyncPlayPrebufferDecision? prebuffer,
  ) {
    switch (room.waitParticipation) {
      case SyncPlayWaitParticipation.ignoring:
        return zh
            ? '正在確認本機獨立等待狀態…'
            : 'Confirming whether the room can continue without this player…';
      case SyncPlayWaitParticipation.ignored:
        return zh
            ? '本機正在準備追上房間；房間不再等待本機。'
            : 'Preparing to catch up locally; the room continues without waiting for this player.';
      case SyncPlayWaitParticipation.recovering:
        return zh ? '本機正在追上房間…' : 'This player is catching up with the room…';
      case SyncPlayWaitParticipation.ignoredRecovered:
        return zh
            ? '本機已追上；房間仍不等待本機。'
            : 'Caught up locally; the room still continues without waiting for this player.';
      case SyncPlayWaitParticipation.unsupported:
        return zh
            ? '伺服器無法讓本機獨立等待。'
            : 'The server cannot let this player wait independently.';
      case SyncPlayWaitParticipation.uncertain:
        return zh
            ? '尚未確認本機等待狀態，請重新連線確認。'
            : 'This player’s waiting status is unconfirmed. Reconnect to check.';
      case SyncPlayWaitParticipation.following:
        break;
    }
    return switch (prebuffer?.status) {
      SyncPlayPrebufferStatus.fallbackReady =>
        zh
            ? '本機可跟隨播放；緩衝量仍未知。'
            : 'This player can follow playback; the buffer amount is still unknown.',
      SyncPlayPrebufferStatus.stale =>
        zh
            ? '本機緩衝樣本已過期，等待重新量測…'
            : 'Local buffer sample is out of date; waiting for a new measurement…',
      SyncPlayPrebufferStatus.preparing ||
      SyncPlayPrebufferStatus.playerWaiting =>
        zh ? '本機播放器準備中…' : 'Preparing this player…',
      SyncPlayPrebufferStatus.needsBuffer =>
        zh ? '本機預緩衝中…' : 'Prebuffering on this player…',
      SyncPlayPrebufferStatus.unknown =>
        zh ? '尚未取得本機緩衝量測…' : 'Local buffer measurements are not available yet…',
      SyncPlayPrebufferStatus.timedOut =>
        zh
            ? '本機等待已達上限，正在確認後續同步…'
            : 'Local waiting reached its limit; checking how to continue…',
      SyncPlayPrebufferStatus.ready =>
        zh ? '本機可跟隨播放。' : 'This player can follow playback.',
      null =>
        room.mediaReady == true
            ? (zh ? '本機可跟隨播放。' : 'This player can follow playback.')
            : room.mediaReady == false
            ? (zh ? '等待本機播放器就緒…' : 'Waiting for this player to be ready…')
            : (zh
                  ? '尚未取得本機緩衝狀態…'
                  : 'Local buffer status is not available yet…'),
    };
  }

  String get uncertain => zh ? '房間狀態尚未確認。' : 'Room state is unconfirmed.';
  String get recovering => zh ? '正在重新確認房間…' : 'Checking room connection…';
  String get recoveryPaused => zh ? '自動重連已暫停。' : 'Automatic reconnect paused.';
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
    SyncPlayFailureCode.noGroup =>
      zh
          ? '找不到這個房間，請確認房間碼與 Jellyfin 伺服器。'
          : 'Room not found. Check the code and Jellyfin server.',
    SyncPlayFailureCode.ambiguousCode =>
      zh
          ? '房間碼重複，請房間建立者更換房間碼。'
          : 'Multiple rooms use this code. Ask the creator to choose another code.',
    SyncPlayFailureCode.denied =>
      zh
          ? '伺服器拒絕此操作，請確認帳號及影片權限。'
          : 'The server denied the action. Check account and media permissions.',
    SyncPlayFailureCode.timeoutUnknown =>
      zh
          ? '伺服器確認逾時，請重新連線確認房間狀態。'
          : 'Confirmation timed out. Reconnect to check the room state.',
    SyncPlayFailureCode.disconnected =>
      zh ? '連線已中斷，請重新連線。' : 'Connection lost. Please reconnect.',
    SyncPlayFailureCode.clock =>
      zh
          ? '尚未完成時間同步，請稍候或重新連線。'
          : 'Clock synchronization is incomplete. Wait or reconnect.',
    SyncPlayFailureCode.player =>
      zh
          ? '無法載入房間影片，請確認觀看權限與播放器。'
          : 'Unable to load the room video. Check media permission and the player.',
    _ =>
      zh
          ? '無法完成操作，請確認房間狀態後再試。'
          : 'Unable to complete the action. Check the room state before trying again.',
  };
}
