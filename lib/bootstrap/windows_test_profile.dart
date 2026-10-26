import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

import 'package:fladder/util/jms_test_profile_policy.dart';

typedef TestProfileConfigurationLoader = Future<Map<String, Object?>>
    Function();

/// The native runner validates this dedicated namespace before creating an
/// engine. It also carries the same namespace into secondary Flutter engines.
class WindowsTestProfile {
  WindowsTestProfile(String root) : root = path.windows.normalize(root);

  final String root;
  String directory(String name) => path.windows.join(root, name);
  String get config => directory('config');
  String get support => directory('support');
  String get documents => directory('documents');
  String get cache => directory('cache');
  String get temporary => directory('temp');
  String get downloads => directory('downloads');
  String get seerrSessions => directory('seerr-sessions');
  String get preferencesFile =>
      path.windows.join(config, 'shared_preferences.json');

  static String? requestedDirectory(List<String> arguments) {
    String? result;
    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
      String? value;
      if (argument == JmsTestProfilePolicy.profileArgument) {
        if (++index >= arguments.length || arguments[index].startsWith('--')) {
          throw const FormatException(
              '--profile-dir requires an absolute directory');
        }
        value = arguments[index];
      } else if (argument
          .startsWith('${JmsTestProfilePolicy.profileArgument}=')) {
        value =
            argument.substring(JmsTestProfilePolicy.profileArgument.length + 1);
      }
      if (value != null) {
        if (result != null) {
          throw const FormatException('Duplicate --profile-dir');
        }
        validateDirectory(value);
        result = path.windows.normalize(value);
      }
    }
    return result;
  }

  static void validateDirectory(String value) {
    // A local drive path avoids network shares, device paths, relative paths,
    // drive roots, alternate streams and Win32 trailing-dot aliases.
    if (!RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value) ||
        value.contains('\u0000')) {
      throw const FormatException(
          'Test profile must use an absolute local drive directory');
    }
    final normalized = path.windows.normalize(value);
    if (path.windows.equals(normalized, path.windows.rootPrefix(normalized))) {
      throw const FormatException('A drive root cannot be a test profile');
    }
    final parts = value.substring(3).split(RegExp(r'[\\/]'));
    if (parts.any((part) =>
        part == '..' ||
        part == '.' ||
        part.contains(':') ||
        part.endsWith('.') ||
        part.endsWith(' '))) {
      throw const FormatException(
          'Test profile contains an unsafe path component');
    }
  }
}

const _profileChannel = MethodChannel('nl.jknaapen.fladder/test_profile');

Future<Map<String, Object?>> _nativeProfileConfiguration() async {
  final configuration =
      await _profileChannel.invokeMapMethod<String, Object?>('configuration');
  if (configuration == null) {
    throw StateError('Missing native test-profile configuration');
  }
  return configuration;
}

/// Must be the first bootstrap operation, before crash logs, preferences,
/// downloader construction or any application directory lookup.
Future<WindowsTestProfile?> initializeWindowsTestProfile(
  List<String> arguments, {
  bool testBuild = JmsTestProfilePolicy.buildEnabled,
  bool? isWindows,
  TestProfileConfigurationLoader configurationLoader =
      _nativeProfileConfiguration,
}) async {
  final requested = WindowsTestProfile.requestedDirectory(arguments);
  if (!(isWindows ?? (!kIsWeb && Platform.isWindows))) {
    if (!testBuild && requested == null) return null;
    throw StateError('Profile arguments require Windows');
  }
  // Secondary engines inherit the process root through the native bridge,
  // even when their entrypoint has no command-line arguments.
  final configuration = await configurationLoader();
  final root = configuration['root'];
  if (configuration['testBuild'] != testBuild) {
    throw StateError('Native and Dart test-profile configuration do not match');
  }
  if (root == null && !testBuild && requested == null) return null;
  if (root is! String || root.isEmpty) {
    throw StateError('Missing isolated profile root');
  }
  WindowsTestProfile.validateDirectory(root);
  if (requested != null &&
      !path.windows.equals(requested, path.windows.normalize(root))) {
    throw StateError('Native and Dart profile directories do not match');
  }
  final profile = WindowsTestProfile(root);
  // Native startup requires an explicit root. Secondary engines inherit it
  // through this handshake and must not reconstruct a normal user directory.
  final marker =
      File(path.windows.join(profile.root, JmsTestProfilePolicy.markerName));
  if (FileSystemEntity.typeSync(marker.path, followLinks: false) !=
          FileSystemEntityType.file ||
      await marker.readAsString() != JmsTestProfilePolicy.markerContents) {
    throw StateError('The isolated profile marker is missing or invalid');
  }
  for (final name in [
    'config',
    'support',
    'documents',
    'cache',
    'temp',
    'downloads',
    'seerr-sessions'
  ]) {
    if (FileSystemEntity.typeSync(profile.directory(name),
            followLinks: false) !=
        FileSystemEntityType.directory) {
      throw StateError('The isolated profile directory is missing or unsafe');
    }
  }

  JmsTestProfilePolicy.enableRuntimeIsolation();
  final store =
      await TestProfilePreferences.open(File(profile.preferencesFile));
  PathProviderPlatform.instance = TestProfilePathProvider(profile);
  SharedPreferencesStorePlatform.instance = store;
  SharedPreferencesAsyncPlatform.instance = TestProfileAsyncPreferences(store);
  FileDownloader.setDesktopDirectoryPaths(DesktopDirectoryPaths(
    temporary: profile.temporary,
    applicationSupport: profile.support,
    documents: profile.documents,
    applicationCache: profile.cache,
    library: profile.support,
    downloads: profile.downloads,
  ));
  return profile;
}

class TestProfilePathProvider extends PathProviderPlatform {
  TestProfilePathProvider(this.profile);
  final WindowsTestProfile profile;
  @override
  Future<String?> getTemporaryPath() async => profile.temporary;
  @override
  Future<String?> getApplicationSupportPath() async => profile.support;
  @override
  Future<String?> getLibraryPath() async => profile.support;
  @override
  Future<String?> getApplicationDocumentsPath() async => profile.documents;
  @override
  Future<String?> getApplicationCachePath() async => profile.cache;
  @override
  Future<String?> getDownloadsPath() async => profile.downloads;
  @override
  Future<String?> getExternalStoragePath() async => profile.documents;
  @override
  Future<List<String>?> getExternalCachePaths() async => [profile.cache];
  @override
  Future<List<String>?> getExternalStoragePaths(
          {StorageDirectory? type}) async =>
      [profile.documents];
}

/// Reuses the platform interface's in-memory semantics while persisting only
/// inside the explicitly validated test config directory.
class TestProfilePreferences extends InMemorySharedPreferencesStore {
  TestProfilePreferences._(this.file, Map<String, Object> values)
      : super.withData(values);
  final File file;
  Future<void> _writes = Future.value();

  static Future<TestProfilePreferences> open(File file) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw StateError('Unsafe isolated preferences file');
    }
    final values = <String, Object>{};
    if (type == FileSystemEntityType.file) {
      try {
        final decoded =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        for (final entry in decoded.entries) {
          final value = entry.value;
          if (value is bool ||
              value is String ||
              value is int ||
              value is double) {
            values[entry.key] = value as Object;
          } else if (value is List &&
              value.every((element) => element is String)) {
            values[entry.key] = value.cast<String>();
          } else {
            throw const FormatException();
          }
        }
      } catch (_) {
        throw StateError('Invalid isolated preferences file');
      }
    }
    return TestProfilePreferences._(file, values);
  }

  Future<bool> _persist() async {
    _writes = _writes.then((_) async {
      final values = await super.getAllWithParameters(
          GetAllParameters(filter: PreferencesFilter(prefix: '')));
      final pending = File(
          '${file.path}.tmp.$pid.${DateTime.now().microsecondsSinceEpoch}');
      try {
        await pending.writeAsString(jsonEncode(values), flush: true);
        await pending.rename(file.path);
      } finally {
        if (await pending.exists()) await pending.delete();
      }
    });
    await _writes;
    return true;
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    await super.setValue(valueType, key, value);
    return _persist();
  }

  @override
  Future<bool> remove(String key) async {
    await super.remove(key);
    return _persist();
  }

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) async {
    await super.clearWithParameters(parameters);
    return _persist();
  }
}

final class TestProfileAsyncPreferences extends SharedPreferencesAsyncPlatform {
  TestProfileAsyncPreferences(this.store);
  final TestProfilePreferences store;
  Future<Object?> _get(String key) async => (await store.getAllWithParameters(
      GetAllParameters(filter: PreferencesFilter(prefix: ''))))[key];
  @override
  Future<void> setString(
          String key, String value, SharedPreferencesOptions options) async =>
      store.setValue('String', key, value);
  @override
  Future<void> setBool(
          String key, bool value, SharedPreferencesOptions options) async =>
      store.setValue('Bool', key, value);
  @override
  Future<void> setDouble(
          String key, double value, SharedPreferencesOptions options) async =>
      store.setValue('Double', key, value);
  @override
  Future<void> setInt(
          String key, int value, SharedPreferencesOptions options) async =>
      store.setValue('Int', key, value);
  @override
  Future<void> setStringList(String key, List<String> value,
          SharedPreferencesOptions options) async =>
      store.setValue('StringList', key, value);
  @override
  Future<String?> getString(
          String key, SharedPreferencesOptions options) async =>
      await _get(key) as String?;
  @override
  Future<bool?> getBool(String key, SharedPreferencesOptions options) async =>
      await _get(key) as bool?;
  @override
  Future<double?> getDouble(
          String key, SharedPreferencesOptions options) async =>
      await _get(key) as double?;
  @override
  Future<int?> getInt(String key, SharedPreferencesOptions options) async =>
      await _get(key) as int?;
  @override
  Future<List<String>?> getStringList(
          String key, SharedPreferencesOptions options) async =>
      await _get(key) as List<String>?;
  @override
  Future<void> clear(ClearPreferencesParameters parameters,
          SharedPreferencesOptions options) async =>
      store.clearWithParameters(ClearParameters(
          filter: PreferencesFilter(
              prefix: '', allowList: parameters.filter.allowList)));
  @override
  Future<Map<String, Object>> getPreferences(
          GetPreferencesParameters parameters,
          SharedPreferencesOptions options) =>
      store.getAllWithParameters(GetAllParameters(
          filter: PreferencesFilter(
              prefix: '', allowList: parameters.filter.allowList)));
  @override
  Future<Set<String>> getKeys(GetPreferencesParameters parameters,
          SharedPreferencesOptions options) async =>
      (await getPreferences(parameters, options)).keys.toSet();
}
