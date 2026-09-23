import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fladder/providers/seerr_api_provider.dart';
import 'package:fladder/providers/seerr_link_provider.dart';
import 'package:fladder/providers/seerr_dashboard_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/screens/seerr/seerr_support_text.dart';
import 'package:fladder/seerr/seerr_connection.dart';
import 'package:fladder/seerr/seerr_source.dart';

Future<void> openSeerrAccountLink(BuildContext context, WidgetRef ref) async {
  final account = ref.read(userProvider);
  if (account == null) return;
  if (account.seerrCredentials?.linkedServerId != account.credentials.serverId ||
      account.seerrCredentials?.serverUrl != jmsSeerrSource) {
    final consent = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
              title: Text(seerrText(context, 'Link my Seerr account', '連動我的點片帳號')),
              content: SingleChildScrollView(
                  child: Text(
                      '${seerrText(context, 'Confirm this Jellyfin belongs to this Seerr service. Only this server/account will be linked. Existing API keys/custom credentials will not be used. No administrator impersonation.\n\n', '請確認這個 Jellyfin 確實屬於下列點片服務。只綁定本伺服器／帳號；既有 API Key 與自訂授權不會用於連動，不以管理員代點。\n\n')}${account.credentials.serverName}\n${Uri.tryParse(account.credentials.url)?.origin ?? "—"}\n→ $jmsSeerrSource')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialogContext, false),
                    child: Text(seerrText(context, 'Cancel', '取消'))),
                FilledButton(
                    onPressed: () => Navigator.pop(dialogContext, true),
                    child: Text(seerrText(context, 'Confirm same service', '確認同一服務並連動')))
              ],
            ));
    if (consent != true || !context.mounted || ref.read(userProvider)?.sameIdentity(account) != true) return;
    ref.read(userProvider.notifier).bindSeerrAccount(jmsSeerrSource);
  }
  await ref.read(seerrLinkProvider.notifier).ensure(manual: true);
  if (!context.mounted || ref.read(userProvider)?.sameIdentity(account) != true) return;
  final status = ref.read(seerrLinkProvider);
  if (status == 'needs_auth' || status == 'session_expired') {
    await showDialog<void>(context: context, builder: (_) => const _SeerrReauthenticate());
  }
  if (context.mounted && ref.read(seerrLinkProvider) == 'connected') {
    await ref.read(seerrDashboardProvider.notifier).fetchDashboard();
  }
}

class SeerrLinkPanel extends ConsumerStatefulWidget {
  const SeerrLinkPanel({super.key});
  @override
  ConsumerState<SeerrLinkPanel> createState() => _SeerrLinkPanelState();
}

class _SeerrLinkPanelState extends ConsumerState<SeerrLinkPanel> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (mounted) ref.read(seerrLinkProvider.notifier).ensure();
    });
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(seerrLinkProvider);
    final diagnostic = ref.watch(seerrDiagnosticProvider);
    final labels = {
      'connected': seerrText(context, 'Connected as your Jellyfin user', '已以本人 Jellyfin 身分連接'),
      'connecting': seerrText(context, 'Connecting request service (playback unaffected)', '正在連接點片服務（不影響播放）'),
      'binding_required': seerrText(context, 'Confirm service binding once', '首次使用請確認服務綁定'),
      'needs_auth': seerrText(context, 'One-time native verification required', '需要一次原生重新驗證')
    };
    return Card(
        child: ListTile(
            leading: Icon(status == 'connected' ? Icons.verified_user : Icons.link),
            title: Text(seerrText(context, 'My request service', '我的點片服務')),
            subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(labels[status] ?? seerrError(context, SeerrFailure(status))),
              if (diagnostic != null) const SeerrDiagnosticButton(),
            ]),
            trailing: status == 'connecting'
                ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator())
                : TextButton(
                    onPressed: () => openSeerrAccountLink(context, ref),
                    child: Text(seerrText(context, 'Connect', '連接／核對')))));
  }
}

class SeerrDiagnosticButton extends ConsumerWidget {
  const SeerrDiagnosticButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final diagnostic = ref.watch(seerrDiagnosticProvider);
    if (diagnostic == null) return const SizedBox.shrink();
    return TextButton.icon(
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: diagnostic.report));
          if (context.mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(seerrText(context, 'Connection diagnostic copied', '已複製連線診斷'))));
          }
        },
        icon: const Icon(Icons.copy),
        label: Text(seerrText(context, 'Copy connection diagnostic', '複製連線診斷')));
  }
}

class _SeerrReauthenticate extends ConsumerStatefulWidget {
  const _SeerrReauthenticate();
  @override
  ConsumerState<_SeerrReauthenticate> createState() => _SeerrReauthenticateState();
}

class _SeerrReauthenticateState extends ConsumerState<_SeerrReauthenticate> {
  final password = TextEditingController();
  bool busy = false;
  late final account = ref.read(userProvider)!;
  @override
  void dispose() {
    password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(seerrText(context, 'Verify existing Jellyfin account', '驗證目前 Jellyfin 帳號')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('${account.name}\n$jmsSeerrSource'),
          Text(seerrText(
              context,
              'Your Jellyfin login and drafts stay intact. Password is used once, not saved. No administrator key.',
              '保留 Jellyfin 登入與草稿。密碼僅用於本次已確認服務的驗證，不保存，不使用管理員金鑰。')),
          TextField(
              controller: password,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              enabled: !busy,
              decoration: InputDecoration(labelText: seerrText(context, 'Jellyfin password', 'Jellyfin 密碼'))),
          if (busy) const LinearProgressIndicator(),
          Text(seerrError(context, SeerrFailure(ref.watch(seerrLinkProvider)))),
        ]),
        actions: [
          TextButton(
              onPressed: busy ? null : () => Navigator.pop(context), child: Text(seerrText(context, 'Cancel', '取消'))),
          FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      if (ref.read(userProvider)?.sameIdentity(account) != true) return;
                      setState(() => busy = true);
                      await ref
                          .read(seerrLinkProvider.notifier)
                          .ensure(username: account.name, password: password.text, manual: true);
                      if (!mounted) return;
                      password.clear();
                      setState(() => busy = false);
                      if (ref.read(seerrLinkProvider) == 'connected') Navigator.pop(context);
                    },
              child: Text(seerrText(context, 'Verify', '驗證')))
        ],
      );
}
