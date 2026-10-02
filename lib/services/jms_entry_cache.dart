import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:fladder/util/jms_service_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Local, per-entry addresses. This key prefix is excluded from settings export.
final class JmsEntryCache {
  JmsEntryCache(this._preferences);

  static const keyPrefix = 'jms.entry.cache.v1.';
  final SharedPreferences _preferences;

  static String keyFor(Uri entry) =>
      '$keyPrefix${sha256.convert(utf8.encode(normalizeJmsEntry(entry.toString()).toString()))}';

  Future<JmsServiceConfig?> read(Uri entry) async {
    try {
      final normalized = normalizeJmsEntry(entry.toString());
      final text = _preferences.getString(keyFor(normalized));
      if (text == null || utf8.encode(text).length > 8192) return null;
      final value = jsonDecode(text);
      if (value is! Map<String, dynamic> ||
          value.keys
              .any((key) => !{'version', 'entry', 'config'}.contains(key)) ||
          value['version'] != 1 ||
          value['entry'] != normalized.toString() ||
          value['config'] is! Map<String, dynamic>) {
        return null;
      }
      final config = value['config'] as Map<String, dynamic>;
      if (normalized.scheme == 'http') {
        final direct = JmsServiceConfig.direct(normalized);
        return config.keys.every((key) => direct.toJson().containsKey(key)) &&
                config['baseUrl'] == direct.baseUrl &&
                config['seerrBaseUrl'] == null &&
                config['diagnosticsEndpoint'] == null
            ? direct
            : null;
      }
      return JmsServiceConfig.fromJson(config);
    } catch (_) {
      // Corrupt preferences must neither change login state nor erase old data.
      return null;
    }
  }

  /// Call only after the UI confirms the service configuration.
  Future<bool> write(Uri entry, JmsServiceConfig config) async {
    try {
      final normalized = normalizeJmsEntry(entry.toString());
      if (normalized.scheme == 'http' &&
          config != JmsServiceConfig.direct(normalized)) {
        return false;
      }
      if (normalized.scheme == 'https') {
        JmsServiceConfig.fromJson(config.toJson());
      }
      final record = jsonEncode({
        'version': 1,
        'entry': normalized.toString(),
        'config': config.toJson(),
      });
      return await _preferences.setString(keyFor(normalized), record);
    } catch (_) {
      return false;
    }
  }

  Future<bool> remove(Uri entry) async {
    try {
      return await _preferences.remove(keyFor(entry));
    } catch (_) {
      return false;
    }
  }
}
