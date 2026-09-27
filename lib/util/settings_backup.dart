import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

class SettingsBackupFailure implements Exception {
  final String code;
  const SettingsBackupFailure(this.code);
}

class BackupRule {
  final double? minimum;
  final double? maximum;
  final Set<String>? choices;
  const BackupRule.boolean()
      : minimum = null,
        maximum = null,
        choices = null;
  const BackupRule.number(this.minimum, this.maximum) : choices = null;
  const BackupRule.choice(this.choices)
      : minimum = null,
        maximum = null;

  bool accepts(Object? value) {
    if (choices != null) return value is String && choices!.contains(value);
    if (minimum != null) {
      return value is num && value.isFinite && value >= minimum! && value <= maximum!;
    }
    return value is bool;
  }
}

class BackupChange {
  final String field;
  final Object? before;
  final Object? after;
  const BackupChange(this.field, this.before, this.after);
}

class SettingsBackup {
  static const maxBytes = 64 * 1024;
  static const rules = {
    'client': {
      'themeMode': BackupRule.choice({'system', 'light', 'dark'}),
      'amoledBlack': BackupRule.boolean(),
      'deriveColorsFromItem': BackupRule.boolean(),
      'dynamicPosterColors': BackupRule.boolean(),
      'blurPlaceHolders': BackupRule.boolean(),
      'blurUpcomingEpisodes': BackupRule.boolean(),
      'posterSize': BackupRule.number(0.5, 1.5),
      'backgroundImage': BackupRule.choice({'disabled', 'enabled', 'blurred'}),
      'enableBlurEffects': BackupRule.boolean(),
    },
    'player': {
      'videoFit': BackupRule.choice({'fill', 'contain', 'cover', 'fitWidth', 'fitHeight', 'none', 'scaleDown'}),
      'fillScreen': BackupRule.boolean(),
      'nextVideoType': BackupRule.choice({'off', 'static', 'smart'}),
      'enableSpeedBoost': BackupRule.boolean(),
      'speedBoostRate': BackupRule.number(1, 4),
      'enableDoubleTapSeek': BackupRule.boolean(),
      'enableEdgeGestures': BackupRule.boolean(),
      'reverseEdgeGestures': BackupRule.boolean(),
      'ambientBlur': BackupRule.boolean(),
      'ambientIntensity': BackupRule.number(0, 1),
      'ambientSpread': BackupRule.number(0, 1),
    },
  };

  final Map<String, Map<String, dynamic>> settings;
  SettingsBackup._(this.settings);

  static SettingsBackup capture(Map<String, dynamic> client, Map<String, dynamic> player) {
    final current = {'client': client, 'player': player};
    final document = {
      'schemaVersion': 1,
      'settings': {
        for (final group in rules.entries)
          group.key: {
            for (final field in group.value.keys) field: current[group.key]![field],
          },
      },
    };
    return parse(utf8.encode(jsonEncode(document)));
  }

  static SettingsBackup parse(List<int> bytes) {
    if (bytes.length > maxBytes) throw const SettingsBackupFailure('size');
    try {
      final value = jsonDecode(utf8.decode(bytes));
      if (value is! Map<String, dynamic> || value.keys.toSet().difference({'schemaVersion', 'settings'}).isNotEmpty) {
        throw const SettingsBackupFailure('invalid');
      }
      if (value['schemaVersion'] is! int || value['schemaVersion'] != 1) {
        throw const SettingsBackupFailure('version');
      }
      final groups = value['settings'];
      if (groups is! Map<String, dynamic> || groups.isEmpty) {
        throw const SettingsBackupFailure('invalid');
      }
      final result = <String, Map<String, dynamic>>{};
      for (final group in groups.entries) {
        final fields = group.value;
        if (!rules.containsKey(group.key) || fields is! Map<String, dynamic> || fields.isEmpty) {
          throw const SettingsBackupFailure('invalid');
        }
        for (final field in fields.entries) {
          if (rules[group.key]![field.key]?.accepts(field.value) != true) {
            throw const SettingsBackupFailure('invalid');
          }
        }
        result[group.key] = Map.unmodifiable(fields);
      }
      return SettingsBackup._(Map.unmodifiable(result));
    } on SettingsBackupFailure {
      rethrow;
    } catch (_) {
      throw const SettingsBackupFailure('invalid');
    }
  }

  Uint8List encode() => Uint8List.fromList(
      utf8.encode(const JsonEncoder.withIndent('  ').convert({'schemaVersion': 1, 'settings': settings})));

  Map<String, dynamic> merge(String group, Map<String, dynamic> current) => {
        ...jsonDecode(jsonEncode(current)) as Map<String, dynamic>,
        ...?settings[group],
      };

  List<BackupChange> changes(Map<String, dynamic> client, Map<String, dynamic> player) {
    final current = {'client': client, 'player': player};
    return [
      for (final group in settings.entries)
        for (final field in group.value.entries)
          if (current[group.key]![field.key] != field.value)
            BackupChange(field.key, current[group.key]![field.key], field.value),
    ];
  }
}

class SettingsBundleStore {
  static const key = 'jms.settings.bundle.v1';
  final SharedPreferences preferences;
  final Future<bool> Function(String?)? writer;
  SettingsBundleStore(this.preferences, {this.writer});

  Map<String, dynamic>? _read() {
    final raw = preferences.getString(key);
    if (raw == null) return null;
    try {
      final value = jsonDecode(raw);
      if (value is Map<String, dynamic> &&
          value['schemaVersion'] == 1 &&
          value['client'] is Map &&
          value['player'] is Map) {
        return value;
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  Map<String, dynamic>? section(String group) {
    final value = _read()?[group];
    return value == null ? null : Map<String, dynamic>.from(value as Map);
  }

  Future<bool> writeSection(String group, Map<String, dynamic> value, String legacyKey) {
    final bundle = _read();
    if (bundle == null) {
      return preferences.setString(legacyKey, jsonEncode(value));
    }
    return preferences.setString(key, jsonEncode({...bundle, group: value}));
  }

  Future<bool> _write(String? value) => writer != null
      ? writer!(value)
      : value == null
          ? preferences.remove(key)
          : preferences.setString(key, value);

  Future<void> replace(Map<String, dynamic> client, Map<String, dynamic> player) async {
    final previous = preferences.getString(key);
    final value = jsonEncode({'schemaVersion': 1, 'client': client, 'player': player});
    try {
      if (!await _write(value)) throw const SettingsBackupFailure('write');
    } catch (_) {
      var restored = false;
      try {
        restored = await _write(previous);
      } catch (_) {
        restored = false;
      }
      throw SettingsBackupFailure(restored ? 'write' : 'rollback');
    }
  }
}
