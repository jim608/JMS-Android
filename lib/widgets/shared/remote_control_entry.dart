import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fladder/providers/remote_control_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/services/remote_control/remote_control_models.dart';
import 'package:fladder/services/remote_control/remote_receiver.dart';

class RemoteControlStrings {
  RemoteControlStrings(BuildContext context)
      : zh = Localizations.localeOf(context).languageCode == 'zh';
  final bool zh;
  String text(String chinese, String english) => zh ? chinese : english;
  String get title => text('遠端遙控', 'Remote control');
  String get receiving =>
      text('接受此帳號的遙控', 'Allow this account to control this device');
  String get description => text('先在播放裝置開啟此選項，並讓 JMS 分頁或應用程式保持前景開啟。',
      'Enable this on the playback device and keep its JMS tab or app in the foreground.');
  String get device => text('播放裝置', 'Playback device');
  String get choose => text('選擇播放裝置', 'Choose a playback device');
  String get empty =>
      text('尚無可遙控的同帳號 JMS 裝置。', 'No available JMS devices for this account.');
  String get idle =>
      text('請先在播放裝置開啟影片。', 'Open a video on the playback device first.');
  String get play => text('播放', 'Play');
  String get pause => text('暫停', 'Pause');
  String get position => text('播放進度', 'Playback position');
  String get subtitle => text('字幕', 'Subtitles');
  String get off => text('關閉', 'Off');
  String get refresh => text('重新整理狀態', 'Refresh status');
  String get close => text('關閉面板', 'Close remote control');
  String get waiting =>
      text('已送出，等待播放裝置回報。', 'Sent; waiting for the playback device.');
  String get confirmed => text('播放裝置已確認。', 'Confirmed by the playback device.');
  String get unknown => text('未收到確認，操作結果未明。請先重新整理狀態。',
      'No confirmation received. The result is unknown; refresh status first.');
  String receiverState(RemoteReceiverState state) => switch (state) {
        RemoteReceiverState.disabled =>
          text('此裝置未接受遙控', 'This device is not receiving commands'),
        RemoteReceiverState.connecting => text('正在連線', 'Connecting'),
        RemoteReceiverState.enabled =>
          text('已開啟同帳號遙控', 'Receiving commands from this account'),
        RemoteReceiverState.blocked =>
          text('一起看期間暫停遙控', 'Remote control is paused during SyncPlay'),
        RemoteReceiverState.busy => text('播放器仍在完成上一個操作，遙控暫不可用',
            'The player is finishing an earlier operation; remote control is unavailable'),
        RemoteReceiverState.disconnected =>
          text('裝置已離線，可重新開啟連線', 'Disconnected; enable again to reconnect'),
        RemoteReceiverState.error => text('無法啟用遙控，請確認連線與權限',
            'Unable to enable remote control; check connection and permissions'),
      };
  String failure(RemoteControlFailure error) => switch (error.code) {
        RemoteFailureCode.denied => text('此帳號沒有可用的遙控權限。',
            'Remote control is not permitted for this account.'),
        RemoteFailureCode.stale || RemoteFailureCode.invalidTarget => text(
            '裝置或影片已變更，請重新選擇。', 'The device or video changed. Select it again.'),
        RemoteFailureCode.timeoutUnknown => unknown,
        RemoteFailureCode.unsupported => text('此裝置或字幕目前不支援此操作。',
            'This device or subtitle does not support this action.'),
        _ => text('無法完成遙控操作，請重新整理狀態。',
            'Unable to complete the action. Refresh status.'),
      };
}

Future<void> showRemoteControlDialog(BuildContext context) => showDialog<void>(
    context: context, builder: (_) => const RemoteControlDialog());

class RemoteControlEntry extends ConsumerWidget {
  const RemoteControlEntry({this.expanded = false, super.key});
  final bool expanded;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(userProvider) == null) return const SizedBox.shrink();
    final text = RemoteControlStrings(context);
    final enabled =
        ref.watch(remoteControlProvider.select((s) => s.receivingEnabled));
    final icon =
        Icon(enabled ? Icons.connected_tv : Icons.settings_remote_outlined);
    if (expanded) {
      return ListTile(
          leading: icon,
          title: Text(text.title),
          onTap: () => unawaited(showRemoteControlDialog(context)));
    }
    return IconButton(
        tooltip: text.title,
        icon: icon,
        onPressed: () => unawaited(showRemoteControlDialog(context)));
  }
}

class RemoteControlDialog extends ConsumerStatefulWidget {
  const RemoteControlDialog({super.key});
  @override
  ConsumerState<RemoteControlDialog> createState() =>
      _RemoteControlDialogState();
}

class _RemoteControlDialogState extends ConsumerState<RemoteControlDialog> {
  late final RemoteControlNotifier controls;
  RemotePlaybackBinding? _binding;
  String? _deviceId;
  bool? _desiredPaused;
  double? _seekSeconds;
  bool _seeking = false;
  int? _desiredSubtitle;

  @override
  void initState() {
    super.initState();
    controls = ref.read(remoteControlProvider.notifier);
    Future.microtask(() {
      if (mounted) unawaited(controls.startController());
    });
  }

  @override
  void dispose() {
    unawaited(controls.stopController());
    super.dispose();
  }

  static String _time(double seconds) {
    final total = seconds.isFinite ? seconds.floor().clamp(0, 86400000) : 0;
    return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(remoteControlProvider);
    final state = view.controller;
    final target = state.target;
    final strings = RemoteControlStrings(context);
    if (_deviceId != target?.id || _binding != target?.binding) {
      _deviceId = target?.id;
      _binding = target?.binding;
      _desiredPaused = null;
      _desiredSubtitle = null;
      _seekSeconds = null;
      _seeking = false;
    }
    if (_desiredPaused == target?.paused) _desiredPaused = null;
    if (_desiredSubtitle == target?.subtitleIndex) _desiredSubtitle = null;
    final reported = (target?.positionTicks ?? 0) / 10000000;
    final duration = (target?.durationTicks ?? 0) / 10000000;
    if (_seeking &&
        _seekSeconds != null &&
        (reported - _seekSeconds!).abs() < 1.5) {
      _seekSeconds = null;
      _seeking = false;
    }
    if (const {RemoteCommandStatus.unknown, RemoteCommandStatus.failed}
        .contains(state.status)) {
      _desiredPaused = null;
      _desiredSubtitle = null;
      _seekSeconds = null;
      _seeking = false;
    }
    final targetValue = state.targets.any((device) => device.id == target?.id)
        ? target?.id
        : null;
    final canControl = target?.canControl == true;
    final options = state.subtitles;
    final chosenSubtitle = _desiredSubtitle ?? target?.subtitleIndex;
    final subtitleValue =
        chosenSubtitle == -1 || options.any((o) => o.index == chosenSubtitle)
            ? chosenSubtitle
            : null;
    final failure = view.failure ?? state.failure;
    return AlertDialog(
      title: Row(children: [
        const Icon(Icons.settings_remote_outlined),
        const SizedBox(width: 10),
        Expanded(child: Text(strings.title))
      ]),
      contentPadding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: Text(strings.receiving),
                    subtitle: Text(strings.description),
                    value: view.receivingEnabled,
                    onChanged: (value) =>
                        unawaited(controls.setReceiving(value))),
                Semantics(
                    liveRegion: true,
                    child: Text(strings.receiverState(view.receiverStatus),
                        style: Theme.of(context).textTheme.bodySmall)),
                const Divider(height: 28),
                DropdownButtonFormField<String>(
                    key: ValueKey('remote-target-$targetValue'),
                    initialValue: targetValue,
                    isExpanded: true,
                    decoration: InputDecoration(labelText: strings.device),
                    hint: Text(strings.choose),
                    items: state.targets
                        .map((device) => DropdownMenuItem(
                            value: device.id,
                            child: Text(device.name,
                                overflow: TextOverflow.ellipsis)))
                        .toList(),
                    onChanged: state.targets.isEmpty
                        ? null
                        : (id) => unawaited(controls.selectTarget(state.targets
                            .where((device) => device.id == id)
                            .firstOrNull))),
                if (state.refreshing) const LinearProgressIndicator(),
                if (state.targets.isEmpty)
                  Padding(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      child: Text(strings.empty)),
                if (target != null && !canControl)
                  Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(strings.idle)),
                const SizedBox(height: 16),
                FilledButton.icon(
                    icon: Icon((_desiredPaused ?? target?.paused ?? true)
                        ? Icons.play_arrow
                        : Icons.pause),
                    label: Text((_desiredPaused ?? target?.paused ?? true)
                        ? strings.play
                        : strings.pause),
                    onPressed: !canControl
                        ? null
                        : () {
                            final paused =
                                !(_desiredPaused ?? target?.paused ?? true);
                            setState(() => _desiredPaused = paused);
                            unawaited(controls.dispatch(paused
                                ? const RemoteAction.pause()
                                : const RemoteAction.play()));
                          }),
                const SizedBox(height: 12),
                Text(strings.position),
                Semantics(
                    label: strings.position,
                    child: Slider(
                        min: 0,
                        max: duration > 0 ? duration : 1,
                        value: (_seekSeconds ?? reported)
                            .clamp(0, duration > 0 ? duration : 1)
                            .toDouble(),
                        semanticFormatterCallback: _time,
                        onChanged: canControl && target!.canSeek && duration > 0
                            ? (value) => setState(() {
                                  _seekSeconds = value;
                                  _seeking = false;
                                })
                            : null,
                        onChangeEnd:
                            canControl && target!.canSeek && duration > 0
                                ? (value) {
                                    setState(() {
                                      _seekSeconds = value;
                                      _seeking = true;
                                    });
                                    unawaited(controls.dispatch(
                                        RemoteAction.seek(Duration(
                                            microseconds:
                                                (value * 1000000).round()))));
                                  }
                                : null)),
                Text('${_time(reported)} / ${_time(duration)}',
                    textAlign: TextAlign.center),
                const SizedBox(height: 16),
                DropdownButtonFormField<int>(
                    key: ValueKey((
                      _deviceId,
                      _binding?.itemId,
                      _binding?.mediaSourceId,
                      _binding?.playbackId,
                      subtitleValue
                    )),
                    initialValue: subtitleValue,
                    isExpanded: true,
                    decoration: InputDecoration(labelText: strings.subtitle),
                    items: [
                      DropdownMenuItem(value: -1, child: Text(strings.off)),
                      ...options.map((track) => DropdownMenuItem(
                          value: track.index,
                          child: Text(
                              '${track.label}${track.language?.isNotEmpty == true ? ' (${track.language})' : ''}',
                              overflow: TextOverflow.ellipsis)))
                    ],
                    onChanged: canControl
                        ? (index) {
                            if (index == null) return;
                            setState(() => _desiredSubtitle = index);
                            unawaited(controls
                                .dispatch(RemoteAction.subtitle(index)));
                          }
                        : null),
                const SizedBox(height: 14),
                Semantics(
                    liveRegion: true,
                    child: Text(failure != null
                        ? strings.failure(failure)
                        : switch (state.status) {
                            RemoteCommandStatus.pending ||
                            RemoteCommandStatus.accepted =>
                              strings.waiting,
                            RemoteCommandStatus.confirmed => strings.confirmed,
                            RemoteCommandStatus.unknown => strings.unknown,
                            _ => '',
                          })),
              ]))),
      actions: [
        TextButton.icon(
            onPressed: () => unawaited(controls.refresh()),
            icon: const Icon(Icons.refresh),
            label: Text(strings.refresh)),
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(strings.close))
      ],
    );
  }
}
