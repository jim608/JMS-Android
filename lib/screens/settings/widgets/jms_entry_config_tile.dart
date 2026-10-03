import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/providers/auth_provider.dart';
import 'package:fladder/providers/diagnostics_provider.dart';
import 'package:fladder/providers/jms_entry_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/routes/auto_router.gr.dart';
import 'package:fladder/screens/seerr/seerr_support_text.dart';
import 'package:fladder/services/jms_entry_discovery.dart';
import 'package:fladder/util/jms_service_config.dart';

String jmsEntryErrorText(BuildContext context, JmsEntryError? error) {
  final (english, chinese) = switch (error) {
    JmsEntryError.tls => ('The HTTPS certificate could not be verified.', 'HTTPS 憑證無法驗證，請修正網站憑證後重試。'),
    JmsEntryError.timeout => (
        'The entry request timed out. Retry or connect directly to Jellyfin.',
        '入口讀取逾時，請重試或選擇直接連線 Jellyfin。'
      ),
    JmsEntryError.invalidJson || JmsEntryError.invalidConfig => (
        'The entry configuration is invalid. Retry after it is corrected.',
        '入口設定格式、欄位或服務網址無效，請修正設定後重試。'
      ),
    JmsEntryError.redirect => (
        'The entry redirects to another address. Use its HTTPS entry directly.',
        '入口設定發生重新導向，請直接輸入正確的 HTTPS 入口。'
      ),
    JmsEntryError.responseTooLarge => ('The entry response exceeds the size limit.', '入口設定回應超過大小限制。'),
    JmsEntryError.notJellyfin => (
        'No entry configuration or confirmed Jellyfin service was found.',
        '找不到入口設定，也無法確認這是真正的 Jellyfin 服務。'
      ),
    JmsEntryError.invalidEntry => ('Enter a valid website or Jellyfin address.', '請輸入有效的網站入口或 Jellyfin 網址。'),
    _ => ('The entry is unavailable. Retry or connect directly to Jellyfin.', '入口暫時無法讀取，請重試或選擇直接連線 Jellyfin。'),
  };
  return seerrText(context, english, chinese);
}

Future<bool> confirmJmsEntryServices(BuildContext context, JmsServiceConfig config, {bool newJellyfin = false}) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(seerrText(context, 'Confirm service changes', '確認服務來源變更')),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(seerrText(context, 'Jellyfin', 'Jellyfin')),
            SelectableText(config.baseUrl),
            const SizedBox(height: 12),
            const Text('Seerr'),
            SelectableText(config.seerrBaseUrl ?? seerrText(context, 'Not configured', '未設定')),
            const SizedBox(height: 12),
            Text(seerrText(context, 'Diagnostics', '診斷接收端')),
            SelectableText(config.diagnosticsEndpoint ?? seerrText(context, 'Not configured', '未設定')),
            const SizedBox(height: 12),
            Text(seerrText(
                context,
                newJellyfin
                    ? 'Sign in again to the new Jellyfin service. Saved accounts remain available.'
                    : 'Changed Seerr sources require identity confirmation. Manual settings remain unchanged.',
                newJellyfin ? '新的 Jellyfin 來源需要重新登入；原有帳號資料會保留。' : 'Seerr 來源變更後須重新確認本人身分；手動設定會保留。')),
            Text(seerrText(context, 'A new diagnostics receiver requires new consent.', '更換診斷接收端後，須重新同意回報。')),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false), child: Text(seerrText(context, 'Cancel', '取消'))),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(seerrText(context, 'Use these services', '使用這些服務'))),
        ],
      ),
    ) ??
    false;

class JmsEntryConfigTile extends ConsumerStatefulWidget {
  const JmsEntryConfigTile({super.key});

  @override
  ConsumerState<JmsEntryConfigTile> createState() => _JmsEntryConfigTileState();
}

class _JmsEntryConfigTileState extends ConsumerState<JmsEntryConfigTile> {
  bool loading = false;

  void message(String value) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value)));
    }
  }

  Future<void> reload(JmsEntryBinding binding) async {
    final account = ref.read(userProvider);
    if (account == null || loading) return;
    setState(() => loading = true);
    try {
      final result = await ref.read(jmsEntryDiscoveryProvider).discover(binding.entry.toString());
      if (!mounted || !identical(ref.read(userProvider), account)) return;
      if (!result.isSuccess) {
        message(jmsEntryErrorText(context, result.error));
        return;
      }
      if (result.fromCache) {
        message(seerrText(
            context, 'The entry is unavailable. Your last valid settings remain in use.', '入口暫時無法讀取，目前保留上次有效設定。'));
        return;
      }
      if (result.entry == null) {
        message(seerrText(context, 'The entry no longer provides configuration. Current settings are retained.',
            '入口目前未提供設定，原有服務設定會保留。'));
        return;
      }
      final next = result.config!;
      final newJellyfin = next.baseUrl != binding.config.baseUrl ||
          (result.serverId != null &&
              result.serverId!.replaceAll('-', '').toLowerCase() !=
                  account.credentials.serverId.replaceAll('-', '').toLowerCase());
      final changed = newJellyfin ||
          next.seerrBaseUrl != binding.config.seerrBaseUrl ||
          next.diagnosticsEndpoint != binding.config.diagnosticsEndpoint;
      if (changed && !await confirmJmsEntryServices(context, next, newJellyfin: newJellyfin)) {
        return;
      }
      if (!mounted || !identical(ref.read(userProvider), account)) return;
      if (newJellyfin) {
        // Preserve saved accounts. Never reuse their tokens against a new URL.
        if (!await ref.read(authProvider.notifier).prepareEntryLogin(result)) {
          return;
        }
        if (!mounted) return;
        await context.router.replaceAll([LoginRoute()]);
        return;
      }
      final settings = ref.read(jmsEntrySettingsProvider);
      if (!await settings.accept(result, account.credentials.serverId)) {
        message(seerrText(context, 'Settings could not be saved. Retry.', '無法儲存入口設定，請重試。'));
        return;
      }
      if (!mounted || !identical(ref.read(userProvider), account)) return;
      if (!settings.hasManualSeerr(account) && next.seerrBaseUrl != account.seerrCredentials?.serverUrl) {
        await ref.read(userProvider.notifier).setSeerrServerUrl(next.seerrBaseUrl, serverProvided: true);
        final current = ref.read(userProvider);
        if (current == null || !current.sameIdentity(account)) return;
        await settings.markAutomaticSeerr(current, next.seerrBaseUrl ?? '');
      }
      final active = ref.read(userProvider);
      if (active == null || !active.sameIdentity(account) || active.credentials.url != account.credentials.url) {
        return;
      }
      await ref.read(diagnosticsProvider).activateServer(entryDiagnosticsScope(account), next.diagnosticsEndpoint);
      message(seerrText(context, 'Entry configuration updated.', '入口設定已更新。'));
    } catch (_) {
      if (mounted) {
        message(seerrText(context, 'Entry settings could not be updated. Retry.', '無法更新入口設定，請重試。'));
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(userProvider);
    final binding = account == null ? null : ref.read(jmsEntrySettingsProvider).forAccount(account);
    if (binding == null) return const SizedBox.shrink();
    return ListTile(
      key: const Key('jms-entry-settings'),
      title: Text(seerrText(context, 'Website entry configuration', '網站入口設定')),
      subtitle: Text(seerrText(context, 'Provided by server · view or reload manually', '由伺服器提供 · 可查看或手動重新讀取')),
      trailing: loading
          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.refresh),
      onTap: loading
          ? null
          : () async {
              final action = await showDialog<bool>(
                  context: context,
                  builder: (dialogContext) => AlertDialog(
                        title: Text(seerrText(context, 'Website entry configuration', '網站入口設定')),
                        content: SingleChildScrollView(
                            child: SelectableText(
                                'Entry: ${binding.entry}\n\nJellyfin: ${binding.config.baseUrl}\n\nSeerr: ${binding.config.seerrBaseUrl ?? "—"}\n\n${seerrText(context, "Diagnostics", "診斷")}: ${binding.config.diagnosticsEndpoint ?? "—"}')),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(dialogContext, false),
                              child: Text(seerrText(context, 'Close', '關閉'))),
                          FilledButton(
                              key: const Key('jms-entry-reload'),
                              onPressed: () => Navigator.pop(dialogContext, true),
                              child: Text(seerrText(context, 'Reload', '重新讀取'))),
                        ],
                      ));
              if (action == true && mounted) await reload(binding);
            },
    );
  }
}
