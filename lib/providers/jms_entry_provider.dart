import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/seerr_credentials_model.dart';
import 'package:fladder/seerr/seerr_source.dart';
import 'package:fladder/providers/diagnostics_provider.dart';
import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/services/jms_entry_cache.dart';
import 'package:fladder/services/jms_entry_discovery.dart';
import 'package:fladder/util/jms_service_config.dart';

String _serverUrl(String value) => value.replaceAll(RegExp(r'/+$'), '');
String _serverId(String value) => value.replaceAll('-', '').toLowerCase();

String entryServerScope(String url, String id) => '${_serverId(id)}|${_serverUrl(url)}';

String entryDiagnosticsScope(AccountModel account) =>
    '${entryServerScope(account.credentials.url, account.credentials.serverId)}|${account.id}';

String _key(String value) => sha256.convert(utf8.encode(value)).toString();

class JmsEntryBinding {
  const JmsEntryBinding(this.entry, this.serverId, this.config);

  final Uri entry;
  final String serverId;
  final JmsServiceConfig config;
  String get scope => entryServerScope(config.baseUrl, serverId);
}

/// Local-only, proved server bindings. Never part of an account or settings export.
class JmsEntrySettings {
  JmsEntrySettings(this.preferences);

  static const bindingPrefix = 'jms.entry.binding.v1.';
  static const manualPrefix = 'jms.entry.manual-seerr.v1.';
  static const automaticPrefix = 'jms.entry.automatic-seerr.v1.';
  final SharedPreferences preferences;

  String _accountKey(AccountModel account) =>
      _key('${entryServerScope(account.credentials.url, account.credentials.serverId)}|${account.id}');

  JmsEntryBinding? forServer(String url, String serverId) {
    if (serverId.isEmpty || url.isEmpty) return null;
    try {
      final raw = preferences.getString('$bindingPrefix${_key(entryServerScope(url, serverId))}');
      if (raw == null) return null;
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final entry = JmsEntryDiscovery.normalizeEntry(json['entry'] as String);
      final config = JmsServiceConfig.fromJson(Map<String, dynamic>.from(json['config'] as Map));
      final binding = JmsEntryBinding(entry, json['serverId'] as String, config);
      if (entry.scheme != 'https' || binding.scope != entryServerScope(url, serverId)) {
        return null;
      }
      return binding;
    } catch (_) {
      return null;
    }
  }

  JmsEntryBinding? forAccount(AccountModel account) => forServer(account.credentials.url, account.credentials.serverId);

  Future<bool> accept(JmsEntryResolution resolution, String serverId) async {
    final entry = resolution.entry;
    final config = resolution.config;
    if (!resolution.isSuccess || entry == null || config == null) return true;
    if (entry.scheme != 'https' || serverId.isEmpty) return false;
    final binding = JmsEntryBinding(entry, serverId, config);
    try {
      // Discovery never writes. Only a proved/confirmed connection reaches here.
      if (!await JmsEntryCache(preferences).write(entry, config)) return false;
      return await preferences.setString(
          '$bindingPrefix${_key(binding.scope)}',
          jsonEncode({
            'entry': entry.toString(),
            'serverId': serverId,
            'config': config.toJson(),
          }));
    } catch (_) {
      return false;
    }
  }

  bool hasManualSeerr(AccountModel account) {
    final key = _accountKey(account);
    if (preferences.getBool('$manualPrefix$key') == true) return true;
    final source = account.seerrCredentials?.serverUrl ?? '';
    return source.isNotEmpty && preferences.getString('$automaticPrefix$key') != source;
  }

  bool isServerProvided(AccountModel account) => !hasManualSeerr(account) && forAccount(account) != null;

  Future<void> markManualSeerr(AccountModel account) async {
    await preferences.setBool('$manualPrefix${_accountKey(account)}', true);
  }

  Future<void> markAutomaticSeerr(AccountModel account, String source) async {
    final key = _accountKey(account);
    await preferences.setString('$automaticPrefix$key', source);
    await preferences.remove('$manualPrefix$key');
  }

  SeerrCredentialsModel effectiveSeerrCredentials(AccountModel? account, {String? configuredSource}) {
    if (account == null) return const SeerrCredentialsModel();
    if (hasManualSeerr(account)) {
      return account.seerrCredentials ?? const SeerrCredentialsModel();
    }
    final binding = forAccount(account);
    if (binding == null) {
      return effectiveJmsSeerrCredentials(account.seerrCredentials, configuredSource: configuredSource);
    }
    final source = binding.config.seerrBaseUrl ?? '';
    if (source.isEmpty) return const SeerrCredentialsModel();
    final saved = account.seerrCredentials;
    if (saved != null && _serverUrl(saved.serverUrl) == source) return saved;
    return SeerrCredentialsModel(serverUrl: source);
  }

  Future<AccountModel> configureNewAccount(AccountModel account, {bool manual = false, String? manualSource}) async {
    if (manual) {
      await markManualSeerr(account);
      return account.copyWith(
          seerrCredentials:
              (manualSource?.isNotEmpty ?? false) ? SeerrCredentialsModel(serverUrl: manualSource!) : null);
    }
    final binding = forAccount(account);
    if (binding == null || hasManualSeerr(account)) return account;
    final source = binding.config.seerrBaseUrl ?? '';
    await markAutomaticSeerr(account, source);
    return account.copyWith(seerrCredentials: source.isEmpty ? null : SeerrCredentialsModel(serverUrl: source));
  }
}

final jmsEntryDiscoveryProvider = Provider<JmsEntryDiscovery>((ref) {
  final discovery = JmsEntryDiscovery(cache: JmsEntryCache(ref.read(sharedPreferencesProvider)));
  ref.onDispose(discovery.close);
  return discovery;
});

final jmsEntrySettingsProvider = Provider<JmsEntrySettings>((ref) {
  final settings = JmsEntrySettings(ref.read(sharedPreferencesProvider));
  void activate(AccountModel? account) {
    final binding = account == null ? null : settings.forAccount(account);
    if (kIsWeb && binding == null) return;
    unawaited(ref
        .read(diagnosticsProvider)
        .activateServer(account == null ? null : entryDiagnosticsScope(account), binding?.config.diagnosticsEndpoint));
  }

  ref.listen<AccountModel?>(userProvider, (previous, next) {
    if (previous?.credentials.url != next?.credentials.url ||
        previous?.credentials.serverId != next?.credentials.serverId ||
        previous?.id != next?.id) {
      activate(next);
    }
  });
  final current = ref.read(userProvider);
  if (current != null) {
    var active = true;
    ref.onDispose(() => active = false);
    Future.microtask(() {
      if (!active) return;
      final latest = ref.read(userProvider);
      if (latest != null && entryDiagnosticsScope(latest) == entryDiagnosticsScope(current)) {
        activate(latest);
      }
    });
  }
  return settings;
});
