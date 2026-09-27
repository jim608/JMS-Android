import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fladder/jellyfin/jellyfin_open_api.enums.swagger.dart' as jelly;
import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/seerr_api_provider.dart';
import 'package:fladder/providers/seerr_link_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/providers/seerr_service_provider.dart';
import 'package:fladder/providers/seerr/seerr_issue_draft_provider.dart';
import 'package:fladder/screens/crash_screen/crash_screen.dart';
import 'package:fladder/screens/seerr/seerr_support_text.dart';
import 'package:fladder/screens/seerr/seerr_link_panel.dart';
import 'package:fladder/seerr/seerr_connection.dart';
import 'package:fladder/seerr/seerr_issue_models.dart';
import 'package:fladder/seerr/seerr_models.dart';

Future<void> openSeerrReport(BuildContext context, WidgetRef ref,
    {ItemBaseModel? item,
    int? tmdbId,
    bool isTv = false,
    Duration? position,
    String? tracks}) async {
  final content = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
            title: Text(seerrText(context, 'Report a problem', '回報問題')),
            content: Text(seerrText(
                context,
                'Media issues go to your Seerr server after preview. App diagnostics are separate; this does not enable telemetry.',
                '影片問題經預覽確認後送至您的 Seerr；App 診斷獨立處理，不會因此啟用遙測。')),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: Text(
                      seerrText(context, 'JMS app problem', 'JMS 操作／閃退問題'))),
              FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: Text(seerrText(
                      context, 'Video / audio / subtitles', '影片／音訊／字幕問題'))),
            ],
          ));
  if (!context.mounted || content == null) return;
  if (!content) {
    await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
              title: Text(
                  seerrText(context, 'Local App diagnostics', '本機 App 診斷')),
              content: Text(seerrText(
                  context,
                  'Private telemetry and Laya are not configured. No automatic upload. Existing logs may contain sensitive data: inspect before sharing; never attach them to a media issue.',
                  '私人遙測與 Laya 尚未設定，不會自動上傳。既有日誌可能含敏感資料，分享前須檢查；請勿附到影片回報。')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: Text(seerrText(context, 'Close', '關閉'))),
                TextButton(
                    onPressed: () {
                      Navigator.pop(dialogContext);
                      Navigator.of(context, rootNavigator: true).push(
                          MaterialPageRoute<void>(
                              builder: (_) => Scaffold(
                                  appBar: AppBar(
                                      title: Text(seerrText(
                                          context, 'Local logs', '本機日誌'))),
                                  body: const CrashScreen())));
                    },
                    child:
                        Text(seerrText(context, 'View local logs', '查看本機日誌')))
              ],
            ));
    return;
  }
  if (ref.read(userProvider)?.seerrCredentials?.isConfigured != true) {
    await openSeerrAccountLink(context, ref);
    if (!context.mounted) return;
  }
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
      builder: (_) => SeerrReportDialog(
          item: item,
          tmdbId: tmdbId,
          isTv: isTv,
          position: position,
          tracks: tracks));
}

class SeerrReportDialog extends ConsumerStatefulWidget {
  final ItemBaseModel? item;
  final int? tmdbId;
  final bool isTv;
  final Duration? position;
  final String? tracks;
  const SeerrReportDialog(
      {super.key,
      this.item,
      this.tmdbId,
      this.isTv = false,
      this.position,
      this.tracks});
  @override
  ConsumerState<SeerrReportDialog> createState() => _SeerrReportDialogState();
}

class _SeerrReportDialogState extends ConsumerState<SeerrReportDialog> {
  SeerrService get service => ref.read(seerrApiProvider);
  late final account = ref.read(userProvider);
  final message = TextEditingController();
  final season = TextEditingController();
  final episode = TextEditingController();
  final time = TextEditingController();
  SeerrIssueTarget? target;
  SeerrUserModel? user;
  SeerrIssueType type = SeerrIssueType.other;
  bool busy = false;
  bool confirmedNumbering = false;
  bool includeTracks = false;
  bool tv = false;
  String? error;
  int? resolvedTmdb;

  String get draftKey => '${widget.item?.id ?? widget.tmdbId}:${widget.isTv}';
  bool get sameScope => account != null && ref.read(userProvider)?.sameIdentity(account!) == true &&
    ref.read(userProvider)?.seerrCredentials?.serverUrl == account?.seerrCredentials?.serverUrl;

  @override
  void initState() {
    super.initState();
    message.text = ref.read(seerrIssueDraftProvider)[draftKey] ?? '';
    final seconds = widget.position?.inSeconds;
    time.text = seconds == null
        ? ''
        : '${(seconds ~/ 3600).toString().padLeft(2, '0')}:${(seconds ~/ 60 % 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
    Future.microtask(load);
  }

  @override
  void dispose() {
    for (final controller in [message, season, episode, time]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> load() async {
    if (!sameScope) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      user = await service.issueUser();
      if (user?.canCreateIssues != true) {
        throw const SeerrFailure('permission_denied');
      }
      tv = widget.isTv;
      resolvedTmdb = widget.tmdbId;
      if (widget.item != null) {
        final api = ref.read(jellyApiProvider);
        final response = await api.usersUserIdItemsItemIdGetBaseItem(
            itemId: widget.item!.id);
        if (response.statusCode != 200 || response.body == null) {
          throw const SeerrFailure('media_not_scanned');
        }
        var media = response.body!;
        tv = {
          jelly.BaseItemKind.series,
          jelly.BaseItemKind.season,
          jelly.BaseItemKind.episode
        }.contains(media.type);
        if (media.type == jelly.BaseItemKind.episode ||
            media.type == jelly.BaseItemKind.season) {
          season.text = (media.type == jelly.BaseItemKind.season
                      ? media.indexNumber
                      : media.parentIndexNumber)
                  ?.toString() ??
              '';
          episode.text = media.type == jelly.BaseItemKind.episode
              ? media.indexNumber?.toString() ?? ''
              : '';
          if (media.seriesId?.isNotEmpty != true) {
            throw const SeerrFailure('media_not_scanned');
          }
          final series = await api.usersUserIdItemsItemIdGetBaseItem(
              itemId: media.seriesId);
          if (series.statusCode != 200 ||
              series.body?.type != jelly.BaseItemKind.series) {
            throw const SeerrFailure('media_not_scanned');
          }
          media = series.body!;
        }
        if (media.type != jelly.BaseItemKind.movie &&
            media.type != jelly.BaseItemKind.series) {
          throw const SeerrFailure('media_not_scanned');
        }
        resolvedTmdb = int.tryParse((media.providerIds ?? {})
                .entries
                .where((entry) => entry.key.toLowerCase() == 'tmdb')
                .firstOrNull
                ?.value ??
            '');
      }
      if (resolvedTmdb == null) throw const SeerrFailure('media_not_scanned');
      final loaded = await service.issueTarget(resolvedTmdb!, tv);
      if (sameScope) target = loaded;
    } catch (failure) {
      if (mounted) error = seerrError(context, failure);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String previewMessage() {
    if (!seerrSafeMessage(message.text)) {
      throw const SeerrFailure('invalid_report');
    }
    if (time.text.isNotEmpty &&
        !RegExp(r'^\d{2,3}:[0-5]\d:[0-5]\d$').hasMatch(time.text)) {
      throw const SeerrFailure('invalid_report');
    }
    if (tv && !confirmedNumbering) throw const SeerrFailure('invalid_report');
    final description = [
      target!.title,
      if (season.text.isNotEmpty) 'Season ${season.text}',
      if (episode.text.isNotEmpty) 'Episode ${episode.text}',
      if (time.text.isNotEmpty) 'Time ${time.text}',
      if (includeTracks && widget.tracks != null) widget.tracks!,
      message.text.trim()
    ].join('\n');
    target!.issueBody(type, description,
        season: season.text.isEmpty ? null : int.tryParse(season.text) ?? -1,
        episode:
            episode.text.isEmpty ? null : int.tryParse(episode.text) ?? -1);
    return description;
  }

  Future<void> send() async {
    if (busy || target == null || !sameScope) return;
    try {
      final description = previewMessage();
      final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
                title: Text(seerrText(context, 'Preview report', '預覽回報')),
                content: SingleChildScrollView(
                    child: Text(
                        '${seerrIssueCategory(context, type.value)}\n$description\n\n${seerrText(context, 'Visible according to your Seerr permissions, not necessarily only to administrators. This is a user observation, not a verified root cause.', '依 Seerr 權限可能供其他使用者查看，不保證只有管理員可見。此為使用者描述，不代表已判定根因。')}')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: Text(seerrText(context, 'Edit', '修改'))),
                  FilledButton(
                      onPressed: () => Navigator.pop(dialogContext, true),
                      child: Text(seerrText(context, 'Send', '確認送出')))
                ],
              ));
      if (confirmed != true || !mounted || !sameScope) return;
      setState(() {
        busy = true;
        error = null;
      });
      final result = await service.reportIssue(target!, type, description,
          season: int.tryParse(season.text),
          episode: int.tryParse(episode.text));
      final readBack = await service.issue(result.id);
      if (readBack.media?.id != target!.mediaInfoId || readBack.createdBy?.id != user?.id || readBack.issueType != type.value) {
        throw const SeerrFailure('invalid_response');
      }
      if (!mounted || !sameScope) return;
      ref.read(seerrIssueDraftProvider.notifier).state = {};
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              '${seerrText(context, 'Report saved', '回報已送出並讀回')} #${result.id}')));
      Navigator.pop(context);
    } catch (failure) {
      if (mounted) setState(() => error = seerrError(context, failure));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(seerrApiProvider);
    return AlertDialog(
      title: Text(seerrText(context, 'Report media problem', '影片問題回報')),
      content: SizedBox(
          width: 540,
          child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (ref.watch(seerrLinkProvider) != 'connected') const SeerrLinkPanel(),
            Text(target?.title ??
                widget.item?.name ??
                'TMDB ${widget.tmdbId ?? "—"}'),
            if (widget.position != null)
              Text(seerrText(
                  context,
                  'Playback continues; this form does not pause, seek or restart it.',
                  '影片繼續播放；表單不暫停、不拖曳、不重播。')),
            if (!sameScope)
              Text(seerrError(context, const SeerrFailure('account_changed'))),
            if (busy) const LinearProgressIndicator(),
            if (error != null)
              Text(error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            TextButton(
                onPressed: busy || !sameScope ? null : load,
                child: Text(seerrText(
                    context, 'Refresh media / permissions', '重新核對媒體／權限'))),
            DropdownButtonFormField<SeerrIssueType>(
                initialValue: type,
                items: SeerrIssueType.values
                    .map((entry) => DropdownMenuItem(
                        value: entry,
                        child: Text(seerrIssueCategory(context, entry.value))))
                    .toList(),
                onChanged:
                    busy ? null : (value) => setState(() => type = value!)),
            if (tv) ...[
              TextField(
                  controller: season,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                      labelText: seerrText(
                          context, 'Season (0 = specials)', '季（0 為特別篇）'))),
              TextField(
                  controller: episode,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                      labelText:
                          seerrText(context, 'Episode (optional)', '集（可留空）'))),
              CheckboxListTile(
                  value: confirmedNumbering,
                  onChanged: (value) =>
                      setState(() => confirmedNumbering = value ?? false),
                  title: Text(seerrText(
                      context,
                      'I checked the series and episode numbering against Seerr; anime/special numbering may differ.',
                      '我已核對 Seerr 影集與季集編號；動畫／特別篇編號可能不同。'))),
            ],
            TextField(
                controller: time,
                decoration: InputDecoration(
                    labelText: seerrText(context, 'Time HH:MM:SS (optional)',
                        '時間 HH:MM:SS（可留空）'))),
            if (widget.tracks != null)
              CheckboxListTile(
                  value: includeTracks,
                  onChanged: (value) =>
                      setState(() => includeTracks = value ?? false),
                  title: Text(seerrText(
                      context, 'Include track language/codec', '附上音軌／字幕語言及格式')),
                  subtitle: Text(widget.tracks!)),
            TextField(
                controller: message,
                maxLength: 1500,
                minLines: 3,
                maxLines: 6,
                decoration: InputDecoration(
                    labelText: seerrText(
                        context,
                        'Description (no URLs, passwords, paths or subtitle text)',
                        '說明（勿含網址、帳密、路徑或字幕原文）'))),
            Text(seerrText(
                context,
                'Drafts remain in memory only. Closing the App or changing accounts/services clears them.',
                '草稿僅留在記憶體；關閉 App、切換帳號或服務即清除。')),
          ]))),
      actions: [
        TextButton(
            onPressed: busy ? null : () => Navigator.pop(context),
            child: Text(seerrText(context, 'Cancel', '取消'))),
        TextButton(
            onPressed: busy || !sameScope
                ? null
                : () {
                    ref.read(seerrIssueDraftProvider.notifier).state = {
                      draftKey: message.text
                          .substring(0, message.text.length.clamp(0, 1500))
                    };
                    Navigator.pop(context);
                  },
            child: Text(seerrText(context, 'Keep draft', '保留草稿'))),
        FilledButton(
            onPressed: busy || target == null || !sameScope ? null : send,
            child: Text(seerrText(context, 'Preview and send', '預覽並送出'))),
      ],
    );
  }
}
