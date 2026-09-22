import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auto_route/auto_route.dart';
import 'package:fladder/providers/seerr_api_provider.dart';
import 'package:fladder/providers/seerr_service_provider.dart';
import 'package:fladder/routes/auto_router.gr.dart';
import 'package:fladder/screens/seerr/seerr_support_text.dart';
import 'package:fladder/screens/seerr/seerr_link_panel.dart';
import 'package:fladder/providers/seerr_link_provider.dart';
import 'package:fladder/seerr/seerr_connection.dart';
import 'package:fladder/seerr/seerr_issue_models.dart';
import 'package:fladder/seerr/seerr_models.dart';

Future<void> openSeerrRecords(BuildContext context) =>
    Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute<void>(builder: (_) => const SeerrRecordsScreen()));

class SeerrRecordsScreen extends ConsumerWidget {
  const SeerrRecordsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connected = ref.watch(seerrLinkProvider) == 'connected';
    final service = connected ? ref.watch(seerrApiProvider) : null;
    return DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(
              title: Text(seerrText(context, 'My records', '我的紀錄')),
              bottom: connected ? TabBar(tabs: [
                Tab(text: seerrText(context, 'My requests', '我的申請')),
                Tab(text: seerrText(context, 'My reports', '我的回報'))
              ]) : null),
          body: !connected ? const Center(child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [SeerrLinkPanel()],
          )) : TabBarView(children: [
            _RecordsPage(
                key: ValueKey((service, false)),
                service: service!,
                issues: false),
            _RecordsPage(
                key: ValueKey((service, true)), service: service, issues: true),
          ]),
        ));
  }
}

class _RecordsPage extends StatefulWidget {
  final SeerrService service;
  final bool issues;
  const _RecordsPage({super.key, required this.service, required this.issues});
  @override
  State<_RecordsPage> createState() => _RecordsPageState();
}

class _RecordsPageState extends State<_RecordsPage> {
  final Map<(int, bool), Future<String>> titles = {};
  List<SeerrIssue> issues = [];
  List<SeerrMediaRequest> requests = [];
  SeerrUserModel? user;
  int page = 0;
  int totalPages = 1;
  bool busy = false;
  bool management = false;
  String? error;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      user = await widget.service.issueUser();
      if (!mounted) return;
      if (widget.issues) {
        final response = await widget.service
            .issues(skip: page * 20, management: management);
        if (!mounted) return;
        issues = response.results;
        totalPages = response.pageInfo?.pages ?? 1;
      } else {
        final response =
            await widget.service.myRequests(take: 20, skip: page * 20);
        seerrCheckStatus(response.statusCode);
        if (!mounted) return;
        requests = response.body?.results ?? [];
        if (requests.any((entry) => entry.requestedBy?.id != user?.id)) {
          throw const SeerrFailure('incompatible_filter');
        }
        totalPages = response.body?.pageInfo?.pages ?? 1;
      }
      titles.clear();
    } catch (failure) {
      if (mounted) {
        error = seerrError(context, failure);
        issues = [];
        requests = [];
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<String> title(SeerrMedia? media) =>
      titles.putIfAbsent((media?.tmdbId ?? 0, media?.mediaType == 'tv'),
          () async {
        if (media?.tmdbId == null) return '—';
        try {
          if (media!.mediaType == 'tv') {
            return (await widget.service.tvDetails(tvId: media.tmdbId!))
                    .body
                    ?.name ??
                'TMDB ${media.tmdbId}';
          }
          return (await widget.service.movieDetails(tmdbId: media.tmdbId!))
                  .body
                  ?.title ??
              'TMDB ${media.tmdbId}';
        } catch (_) {
          return 'TMDB ${media?.tmdbId}';
        }
      });

  Widget titleWidget(SeerrMedia? media) => FutureBuilder<String>(
      future: title(media),
      builder: (_, snapshot) =>
          Text(snapshot.data ?? 'TMDB ${media?.tmdbId ?? "—"}'));

  @override
  Widget build(BuildContext context) {
    final requestLabels = [
      seerrText(context, 'Unknown', '未知'),
      seerrText(context, 'Pending approval', '待批准'),
      seerrText(context, 'Approved (not necessarily playable)', '已批准（不代表已可播放）'),
      seerrText(context, 'Declined', '已拒絕'),
      seerrText(context, 'Failed', '失敗'),
      seerrText(context, 'Completed', '已完成')
    ];
    final mediaLabels = [
      seerrText(context, 'Unknown', '未知'),
      seerrText(context, 'Unknown', '未知'),
      seerrText(context, 'Pending', '待處理'),
      seerrText(context, 'Processing', '處理中'),
      seerrText(context, 'Partially available', '部分可用'),
      seerrText(context, 'Available', '可用')
    ];
    return Column(children: [
      if (busy) const LinearProgressIndicator(),
      Row(children: [
        IconButton(
            onPressed: busy ? null : load,
            tooltip: seerrText(context, 'Refresh', '重新整理'),
            icon: const Icon(Icons.refresh)),
        if (error == null) Text('${page + 1} / ${totalPages < 1 ? 1 : totalPages}'),
        if (widget.issues && user?.canManageIssues == true)
          Expanded(
              child: SwitchListTile(
                  title: Text(
                      seerrText(context, 'Manage open reports', '管理待處理回報')),
                  value: management,
                  onChanged: busy
                      ? null
                      : (value) {
                          setState(() {
                            management = value;
                            page = 0;
                          });
                          load();
                        })),
      ]),
      if (error != null)
        Padding(padding: const EdgeInsets.all(16), child: Column(children: [
          Text(error!),
          const SeerrDiagnosticButton(),
        ])),
      Expanded(
          child: RefreshIndicator(
              onRefresh: load,
              child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    if (!busy &&
                        error == null &&
                        issues.isEmpty &&
                        requests.isEmpty)
                      ListTile(
                          title:
                              Text(seerrText(context, 'No records', '尚無紀錄'))),
                    for (final issue in issues)
                      ListTile(
                          title: titleWidget(issue.media),
                          isThreeLine: true,
                          subtitle: Text(
                              '#${issue.id} · ${seerrIssueCategory(context, issue.issueType)} · ${seerrIssueStatus(context, issue.status)}\n${issue.createdAt?.toLocal() ?? "—"}'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () async {
                            await Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                    builder: (_) =>
                                        SeerrIssueScreen(issueId: issue.id)));
                            if (mounted) await load();
                          }),
                    for (final request in requests)
                      ListTile(
                          title: titleWidget(request.media),
                          isThreeLine: true,
                          subtitle: Text(
                              '#${request.id} · ${requestLabels.asMap()[request.status] ?? requestLabels.first}\n${seerrText(context, "Media", "媒體")}: ${mediaLabels.asMap()[request.media?.status] ?? mediaLabels.first}${request.seasons?.isNotEmpty == true ? ' · ${seerrText(context, "Seasons", "季")}: ${request.seasons!.join(", ")}' : ''}'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: request.media?.tmdbId == null
                              ? null
                              : () => context.pushRoute(SeerrDetailsRoute(
                                  mediaType:
                                      request.media?.mediaType ?? 'movie',
                                  tmdbId: request.media!.tmdbId!))),
                  ]))),
      if (error == null) Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        TextButton(
            onPressed: busy || page == 0
                ? null
                : () {
                    page--;
                    load();
                  },
            child: Text(seerrText(context, 'Previous', '上一頁'))),
        TextButton(
            onPressed: busy || page + 1 >= totalPages
                ? null
                : () {
                    page++;
                    load();
                  },
            child: Text(seerrText(context, 'Next', '下一頁'))),
      ]),
    ]);
  }
}

class SeerrIssueScreen extends ConsumerWidget {
  final int issueId;
  const SeerrIssueScreen({super.key, required this.issueId});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.watch(seerrApiProvider);
    return _IssueDetail(
        key: ObjectKey(service), service: service, issueId: issueId);
  }
}

class _IssueDetail extends StatefulWidget {
  final SeerrService service;
  final int issueId;
  const _IssueDetail({super.key, required this.service, required this.issueId});
  @override
  State<_IssueDetail> createState() => _IssueDetailState();
}

class _IssueDetailState extends State<_IssueDetail> {
  final message = TextEditingController();
  SeerrIssue? issue;
  SeerrUserModel? user;
  String title = '';
  String? error;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    run();
  }

  @override
  void dispose() {
    message.dispose();
    super.dispose();
  }

  Future<void> run([Future<void> Function()? mutation]) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (mutation != null) await mutation();
      final currentUser = await widget.service.issueUser();
      final loaded = await widget.service.issue(widget.issueId);
      if (!currentUser.canManageIssues &&
          !currentUser.hasPermission(SeerrPermission.viewIssues) &&
          loaded.createdBy?.id != currentUser.id) {
        throw const SeerrFailure('permission_denied');
      }
      final media = loaded.media;
      String loadedTitle = 'TMDB ${media?.tmdbId ?? "—"}';
      if (media?.tmdbId != null) {
        loadedTitle = media?.mediaType == 'tv'
            ? (await widget.service.tvDetails(tvId: media!.tmdbId!))
                    .body
                    ?.name ??
                loadedTitle
            : (await widget.service.movieDetails(tmdbId: media!.tmdbId!))
                    .body
                    ?.title ??
                loadedTitle;
      }
      if (!mounted) return;
      issue = loaded;
      user = currentUser;
      title = loadedTitle;
    } catch (failure) {
      if (mounted) error = seerrError(context, failure);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canComment = user?.canManageIssues == true ||
        (user?.canCreateIssues == true && issue?.createdBy?.id == user?.id);
    return Scaffold(
        appBar: AppBar(
            title: Text(
                '${seerrText(context, "Report", "回報")} #${widget.issueId}'),
            actions: [
              IconButton(
                  onPressed: busy ? null : () => run(),
                  icon: const Icon(Icons.refresh))
            ]),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          if (busy) const LinearProgressIndicator(),
          if (error != null)
            Text(error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          if (issue != null) ...[
            Text(
                '${seerrIssueCategory(context, issue!.issueType)} · ${seerrIssueStatus(context, issue!.status)}'),
            Text(
                '${issue!.createdAt?.toLocal() ?? "—"} → ${issue!.updatedAt?.toLocal() ?? "—"}'),
            if (issue!.problemSeason != null)
              Text(
                  '${seerrText(context, "Season / episode", "季／集")}: ${issue!.problemSeason} / ${issue!.problemEpisode ?? "—"}'),
            const Divider(),
            for (final comment in issue!.comments)
              ListTile(
                  title: Text(comment.message ?? ''),
                  subtitle: Text(
                      '${comment.user?.label ?? "—"} · ${comment.createdAt?.toLocal() ?? "—"}')),
            if (canComment) ...[
              TextField(
                  controller: message,
                  maxLength: 1500,
                  minLines: 2,
                  maxLines: 5,
                  decoration: InputDecoration(
                      labelText: seerrText(
                          context,
                          'Add information (no secrets or URLs)',
                          '補充說明（勿含機密或網址）'))),
              FilledButton(
                  onPressed: busy
                      ? null
                      : () => run(() async {
                            await widget.service
                                .addIssueComment(widget.issueId, message.text);
                            if (mounted) message.clear();
                          }),
                  child: Text(seerrText(context, 'Send comment', '送出留言'))),
            ],
            if (user?.canManageIssues == true)
              OutlinedButton(
                  onPressed: busy
                      ? null
                      : () => run(() async {
                            await widget.service.changeIssueStatus(
                                widget.issueId, issue!.status != 2);
                          }),
                  child: Text(issue!.status == 2
                      ? seerrText(context, 'Reopen', '重新開啟')
                      : seerrText(context, 'Mark resolved', '標記已解決'))),
          ],
        ]));
  }
}
