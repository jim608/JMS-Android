import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fladder/models/settings/client_settings_model.dart';
import 'package:fladder/models/settings/video_player_settings.dart';
import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/util/settings_backup.dart';
import 'package:fladder/util/settings_backup_files.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Map<String, dynamic> client() => ClientSettingsModel.defaultModel().toJson();
  Map<String, dynamic> player() => VideoPlayerSettingsModel().toJson();
  List<int> document(Object? settings, {Object? version = 1}) =>
      utf8.encode(jsonEncode({'schemaVersion': version, 'settings': settings}));

  test('export round trip contains exactly 20 permitted preferences, never secrets', () {
    final backup = SettingsBackup.capture(
        {...client(), 'syncPath': 'private-location', 'token': 'secret', 'serverUrl': 'private-server'},
        {...player(), 'audioDevice': 'private-device', 'playerOptions': 'secret-backend', 'signer': 'private-key'});
    final text = utf8.decode(backup.encode());
    for (final secret in ['private-', 'secret', 'token', 'serverUrl', 'syncPath', 'audioDevice', 'signer']) {
      expect(text.contains(secret), false);
    }
    final decoded = SettingsBackup.parse(backup.encode());
    expect(decoded.settings.values.fold<int>(0, (count, fields) => count + fields.length), 20);
    expect(decoded.settings, backup.settings);
    expect(decoded.changes(client(), player()), isEmpty);
  });
  test('schema, unknown fields, wrong types, bounds and malformed content are rejected', () {
    final invalid = [
      document({
        'client': {'themeMode': 'dark'}
      }, version: 2),
      document({
        'client': {'themeMode': 'dark'}
      }, version: 1.0),
      document({
        'client': {'token': 'forbidden'}
      }),
      document({
        'update': {'owner': 'forbidden'}
      }),
      document({
        'player': {'ambientIntensity': 1.01}
      }),
      document({
        'player': {'ambientSpread': -1}
      }),
      document({
        'player': {'ambientBlur': 'true'}
      }),
      document({
        'player': {'videoFit': 'unknown'}
      }),
      document({
        'client': {'posterSize': null}
      }),
      document({'client': []}),
      document({}),
      utf8.encode('{broken'),
      [255, 254],
      List.filled(SettingsBackup.maxBytes + 1, 0),
    ];
    for (final bytes in invalid) {
      expect(() => SettingsBackup.parse(bytes), throwsA(isA<SettingsBackupFailure>()));
    }
  });
  test('preview and merge preserve non-exported settings', () {
    final backup = SettingsBackup.parse(document({
      'player': {'ambientIntensity': 0.95},
      'client': {'themeMode': 'dark'}
    }));
    final original = {...player(), 'useLibass': false, 'internalVolume': 67.0, 'audioDevice': 'keep-private'};
    expect(backup.merge('player', original)['useLibass'], false);
    expect(backup.merge('player', original)['audioDevice'], 'keep-private');
    expect(backup.merge('player', original)['internalVolume'], 67);
    expect(backup.changes(client(), original).map((change) => change.field), ['ambientIntensity', 'themeMode']);
    expect(ClientSettingsModel.fromJson(backup.merge('client', client())).themeMode.name, 'dark');
    expect(VideoPlayerSettingsModel.fromJson(backup.merge('player', original)).ambientIntensity, 0.95);
  });
  test('single-value restore preserves login/update keys and normal edits survive reopening', () async {
    SharedPreferences.setMockInitialValues({
      'loginCredentialsKey': ['account-sentinel'],
      'jms.update.prerelease': true,
      'clientSettings': jsonEncode(client()),
      'videoPlayerSettings': jsonEncode(player()),
    });
    final preferences = await SharedPreferences.getInstance();
    final store = SettingsBundleStore(preferences);
    await store.replace({...client(), 'amoledBlack': true}, {...player(), 'ambientIntensity': 0.94});
    final helper = SharedHelper(sharedPreferences: preferences);
    expect(helper.clientSettings.amoledBlack, true);
    expect(helper.videoPlayerSettings.ambientIntensity, 0.94);
    expect(preferences.getStringList('loginCredentialsKey'), ['account-sentinel']);
    expect(preferences.getBool('jms.update.prerelease'), true);
    expect(preferences.getString('clientSettings'), jsonEncode(client()));
    helper.videoPlayerSettings = helper.videoPlayerSettings.copyWith(ambientSpread: 0.44);
    await helper.saveClientSettings(helper.clientSettings.copyWith(posterSize: 0.75));
    final reopened = SharedHelper(sharedPreferences: await SharedPreferences.getInstance());
    expect(reopened.videoPlayerSettings.ambientIntensity, 0.94);
    expect(reopened.videoPlayerSettings.ambientSpread, 0.44);
    expect(reopened.clientSettings.posterSize, 0.75);
  });
  for (final existing in [false, true]) {
    test('failed persistence rolls back the complete bundle (existing=$existing)', () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      if (existing) {
        await SettingsBundleStore(preferences).replace(client(), player());
      }
      final original = preferences.getString(SettingsBundleStore.key);
      var writes = 0;
      final failing = SettingsBundleStore(preferences, writer: (value) async {
        writes++;
        if (value == null) {
          await preferences.remove(SettingsBundleStore.key);
        } else {
          await preferences.setString(SettingsBundleStore.key, value);
        }
        return writes > 1;
      });
      await expectLater(failing.replace({...client(), 'amoledBlack': true}, player()),
          throwsA(isA<SettingsBackupFailure>().having((error) => error.code, 'code', 'write')));
      expect(preferences.getString(SettingsBundleStore.key), original);
      expect(writes, 2);
    });
  }
  test('unrecoverable storage failure is explicit, not reported as restored', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final store = SettingsBundleStore(preferences, writer: (_) async => false);
    await expectLater(store.replace(client(), player()),
        throwsA(isA<SettingsBackupFailure>().having((error) => error.code, 'code', 'rollback')));
  });
  test('bounded read rejects oversized stream and cancels it', () async {
    var cancelled = false;
    final controller = StreamController<List<int>>(onCancel: () {
      cancelled = true;
    });
    final read = SettingsBackupFiles.readLimited(controller.stream);
    controller.add(List.filled(SettingsBackup.maxBytes + 1, 0));
    await expectLater(read, throwsA(isA<SettingsBackupFailure>()));
    expect(cancelled, true);
    await controller.close();
  });
}
