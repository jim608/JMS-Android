import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/providers/auth_provider.dart';
import 'package:fladder/providers/seerr_api_provider.dart';
import 'package:fladder/providers/seerr_link_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/screens/seerr/seerr_link_panel.dart';
import 'package:fladder/screens/seerr/seerr_support_text.dart';
import 'package:fladder/screens/shared/adaptive_dialog.dart';
import 'package:fladder/seerr/seerr_connection.dart';
import 'package:fladder/seerr/seerr_source.dart';

Future<void> showSeerrConnectionDialog(BuildContext context) {
  return showDialogAdaptive(
    context: context,
    builder: (context) => const SeerrConnectionDialog(),
  );
}

class SeerrConnectionDialog extends ConsumerStatefulWidget {
  const SeerrConnectionDialog({super.key});

  @override
  ConsumerState<SeerrConnectionDialog> createState() =>
      _SeerrConnectionDialogState();
}

class _SeerrConnectionDialogState extends ConsumerState<SeerrConnectionDialog> {
  final passwordController = TextEditingController();
  late final TextEditingController apiKeyController;
  final headerNameController = TextEditingController();
  final headerValueController = TextEditingController();
  bool processing = false;
  bool showAdvanced = false;
  String? localError;

  @override
  void initState() {
    super.initState();
    apiKeyController = TextEditingController(
        text: ref.read(userProvider)?.seerrCredentials?.apiKey ?? '');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(ref.read(authProvider.notifier).beginSeerrSession());
      }
    });
  }

  @override
  void dispose() {
    passwordController.dispose();
    apiKeyController.dispose();
    headerNameController.dispose();
    headerValueController.dispose();
    super.dispose();
  }

  void _saveAdvanced() {
    if (processing || ref.read(userProvider) == null) return;
    final previous = ref.read(userProvider)!.seerrCredentials;
    final headers = Map<String, String>.of(previous?.customHeaders ?? const {});
    final name = headerNameController.text.trim();
    if (name.isNotEmpty) {
      headers[name] = headerValueController.text;
      headerNameController.clear();
      headerValueController.clear();
    }
    ref
        .read(userProvider.notifier)
        .setSeerrApiKey(apiKeyController.text.trim());
    ref.read(userProvider.notifier).setSeerrCustomHeaders(headers);
    setState(() => localError = null);
  }

  void _removeHeader(String name) {
    final headers = Map<String, String>.of(
        ref.read(userProvider)?.seerrCredentials?.customHeaders ?? const {});
    headers.remove(name);
    ref.read(userProvider.notifier).setSeerrCustomHeaders(headers);
  }

  String _statusLabel(String status) => switch (status) {
        'connected' => seerrText(context, 'Connected', '已連接'),
        'connecting' => seerrText(context, 'Connecting', '連接中'),
        'needs_auth' ||
        'session_missing' ||
        'session_expired' ||
        'authentication_failed' =>
          seerrText(context, 'Verify your Jellyfin account', '需要重新驗證'),
        'service_unavailable' =>
          seerrText(context, 'Service unavailable', '服務不可用'),
        'binding_required' =>
          seerrText(context, 'Confirm Jellyseerr account link', '確認點片帳號連結'),
        _ => seerrError(context, SeerrFailure(status)),
      };

  Future<void> _testConnection() async {
    if (processing) return;
    setState(() {
      processing = true;
      localError = null;
    });
    try {
      await ref.read(authProvider.notifier).beginSeerrSession(manual: true);
    } catch (_) {
      if (mounted) localError = _statusLabel('service_unavailable');
    } finally {
      if (mounted) setState(() => processing = false);
    }
  }

  Future<void> _verify() async {
    if (processing || passwordController.text.isEmpty) return;
    final account = ref.read(userProvider);
    if (account == null) return;
    setState(() {
      processing = true;
      localError = null;
    });
    try {
      final pending = ref.read(authProvider.notifier).beginSeerrSession(
          username: account.name,
          password: passwordController.text,
          manual: true);
      passwordController.clear();
      await pending;
    } catch (_) {
      if (mounted) localError = _statusLabel('service_unavailable');
    } finally {
      passwordController.clear();
      if (mounted) setState(() => processing = false);
    }
  }

  Future<void> _logout() async {
    if (processing) return;
    final account = ref.read(userProvider);
    if (account == null) return;
    setState(() {
      processing = true;
      localError = null;
    });
    try {
      if (ref.read(seerrLinkProvider) == 'connected' &&
          account.seerrCredentials?.serverUrl == jmsSeerrSource &&
          account.seerrCredentials?.linkedServerId ==
              account.credentials.serverId) {
        try {
          await ref.read(seerrApiProvider).logout();
        } catch (_) {}
      }
      if (ref.read(userProvider)?.sameIdentity(account) == true) {
        await ref.read(userProvider.notifier).setSeerrSessionCookie('');
        ref.invalidate(seerrLinkProvider);
      }
    } finally {
      if (mounted) setState(() => processing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(userProvider);
    final status = ref.watch(seerrLinkProvider);
    final credentials = account?.seerrCredentials;
    final needsVerification = {
      'needs_auth',
      'session_missing',
      'session_expired',
      'authentication_failed'
    }.contains(status);
    final bound = account != null &&
        credentials?.serverUrl == jmsSeerrSource &&
        credentials?.linkedServerId == account.credentials.serverId;
    final oldSource = credentials?.serverUrl;

    return AlertDialog(
      title: Text(seerrText(context, 'Jellyseerr', 'Jellyseerr')),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${seerrText(context, 'Service', '服務')}：$jmsSeerrSource'),
              const SizedBox(height: 8),
              Text(
                  '${seerrText(context, 'Account', '帳號')}：${account?.name ?? '—'}'),
              const SizedBox(height: 8),
              Text(
                  '${seerrText(context, 'Status', '狀態')}：${_statusLabel(status)}'),
              if (localError != null) ...[
                const SizedBox(height: 8),
                Text(localError!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
              const SeerrDiagnosticButton(),
              if (status == 'binding_required' && account != null) ...[
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: processing
                      ? null
                      : () => openSeerrAccountLink(context, ref),
                  child: Text(seerrText(
                      context, 'Link my Jellyfin account', '連結我的 Jellyfin 帳號')),
                ),
              ],
              if (needsVerification && account != null) ...[
                const SizedBox(height: 12),
                Text(seerrText(
                    context, 'Verify Jellyfin account', '驗證 Jellyfin 帳號')),
                Text(account.name),
                TextField(
                  controller: passwordController,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  enabled: !processing,
                  decoration: InputDecoration(
                      labelText: seerrText(
                          context, 'Jellyfin password', 'Jellyfin 密碼')),
                  onSubmitted: (_) => _verify(),
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: processing ? null : _verify,
                  child: Text(seerrText(context, 'Verify', '重新驗證')),
                ),
              ],
              if (account != null) ...[
                const SizedBox(height: 12),
                TextButton(
                  key: const Key('seerr-advanced-settings'),
                  onPressed: () => setState(() => showAdvanced = !showAdvanced),
                  child: Text(seerrText(context, 'Advanced settings', '進階設定')),
                ),
                if (showAdvanced) ...[
                  Text(seerrText(
                      context,
                      'Existing API keys and custom headers remain saved but are not used for your Jellyfin session.',
                      '既有 API Key 與自訂標頭保留，但不會用於 Jellyfin 本人 Session。')),
                  TextField(
                    key: const Key('seerr-maintenance-api-key'),
                    controller: apiKeyController,
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: seerrText(
                          context,
                          'Maintenance API key (not for personal sign-in)',
                          '維護用 API Key（非本人登入）'),
                    ),
                  ),
                  for (final name
                      in credentials?.customHeaders.keys ?? <String>[])
                    Row(children: [
                      Expanded(child: Text(name)),
                      IconButton(
                        onPressed: () => _removeHeader(name),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ]),
                  TextField(
                    controller: headerNameController,
                    decoration: InputDecoration(
                      labelText: seerrText(context, 'Header name', '標頭名稱'),
                    ),
                  ),
                  TextField(
                    controller: headerValueController,
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: seerrText(context, 'Header value', '標頭內容'),
                    ),
                  ),
                  TextButton(
                    onPressed: _saveAdvanced,
                    child: Text(seerrText(
                        context, 'Save maintenance settings', '儲存維護設定')),
                  ),
                  if (oldSource?.isNotEmpty == true &&
                      oldSource != jmsSeerrSource)
                    Text(seerrText(
                        context,
                        'The previous custom service remains saved. Editing its URL is disabled in personal sign-in; linking this JMS service requires explicit confirmation.',
                        '先前的自訂服務設定仍保留。')),
                ],
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: processing || account == null ? null : _testConnection,
          child: Text(seerrText(context, 'Test connection', '測試連線')),
        ),
        if (bound)
          TextButton(
            onPressed: processing ? null : _logout,
            child: Text(
                seerrText(context, 'Log out of request service', '登出點片服務')),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(seerrText(context, 'Close', '關閉')),
        ),
      ],
    );
  }
}
