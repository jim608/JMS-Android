import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fladder/util/update_checker.dart';

import 'jms_windows_update_test.dart'
    show desktopManifest, desktopSource, installerBytes;

const manualTag = 'v0.11.1-jms.46-syncplay-hdr-test.20261024';
const stableTag = 'v0.11.1-jms.47';
const manualZip =
    'JMS-SyncPlay-HDR-Isolated-Test-20261024-8ee653a24217-public-dclean-x64.zip';
const currentDevice = UpdateDevice('com.jim608.jms', 49, 22631, ['x86_64'],
    platform: 'windows-x64');

Map<String, dynamic> asset(String tag, String name, int size) => {
      'name': name,
      'state': 'uploaded',
      'size': size,
      'browser_download_url':
          'https://github.com/${desktopSource.identity}/releases/download/$tag/$name',
    };

Map<String, dynamic> metadata(
    {int code = 50, String version = '0.11.1-jms.47'}) {
  final base = desktopManifest(code: code);
  return {
    ...base,
    'versionName': version,
    'installer': {
      ...Map<String, dynamic>.from(base['installer']),
      'name': 'JMS-Windows-$version-x64-setup.exe',
    },
    'source': {
      ...Map<String, dynamic>.from(base['source']),
      'name': 'JMS-$version-source.zip',
    },
  };
}

Map<String, dynamic> updatableRelease(
    {String tag = stableTag,
    bool prerelease = false,
    Map<String, dynamic>? manifest}) {
  final value = manifest ?? metadata();
  return {
    'tag_name': tag,
    'draft': false,
    'prerelease': prerelease,
    'published_at': '2026-10-24T00:00:00Z',
    'body': 'Synthetic updater contract',
    'assets': [
      asset(tag, 'update.json', 1000),
      asset(tag, value['installer']['name'], installerBytes.length),
      asset(tag, value['source']['name'], value['source']['size']),
    ],
  };
}

Map<String, dynamic> manualRelease(
        {String tag = manualTag, bool prerelease = true}) =>
    {
      'tag_name': tag,
      'draft': false,
      'prerelease': prerelease,
      'published_at': '2026-10-24T01:00:00Z',
      'body': 'Manual isolated test ZIP, without an updater contract',
      // Shape of the published +49: 116 source/license assets and one ZIP.
      'assets': [
        for (var i = 0; i < 116; i++) asset(tag, 'source-material-$i.zip', 100),
        asset(tag, manualZip, 143803260),
      ],
    };

UpdateChecker checker(List<Map<String, dynamic>> releases,
    {Map<String, Map<String, dynamic>>? manifests, List<Uri>? requests}) {
  return UpdateChecker(
    source: desktopSource,
    client: MockClient((request) async {
      requests?.add(request.url);
      if (request.url.host == 'api.github.com') {
        return http.Response(jsonEncode(releases), 200,
            headers: {'content-type': 'application/json'});
      }
      final tag = request.url.pathSegments[4];
      expect(request.url.pathSegments.last, 'update.json');
      final value = (manifests ?? {stableTag: metadata()})[tag];
      expect(value, isNotNull,
          reason: 'Manual ZIP must never be offered/fetched');
      return http.Response(jsonEncode(value), 200,
          headers: {'content-type': 'application/json'});
    }),
  );
}

void main() {
  for (final manualFirst in [true, false]) {
    test(
        '117-asset manual TEST does not poison stable, manualFirst=$manualFirst',
        () async {
      final manual = manualRelease();
      expect((manual['assets'] as List).length, 117);
      final requests = <Uri>[];
      final releases = manualFirst
          ? [manual, updatableRelease()]
          : [updatableRelease(), manual];
      final updater = checker(releases, requests: requests);
      addTearDown(updater.close);
      final result = await updater.check(currentDevice, prerelease: true);
      expect(result.status, UpdateStatus.available);
      expect(result.release?.manifest.versionCode, 50);
      expect(result.release?.manifest.assetName,
          'JMS-Windows-0.11.1-jms.47-x64-setup.exe');
      expect(
          requests
              .where((uri) => uri.host == 'github.com')
              .map((uri) => uri.pathSegments[4]),
          [stableTag]);
    });
  }

  test('normal prerelease updates retain channel filtering and highest version',
      () async {
    const betaTag = 'v0.11.1-jms.48-beta.1';
    final beta = metadata(code: 51, version: '0.11.1-jms.48-beta.1');
    final updater = checker([
      manualRelease(),
      updatableRelease(),
      updatableRelease(tag: betaTag, prerelease: true, manifest: beta),
    ], manifests: {
      stableTag: metadata(),
      betaTag: beta
    });
    addTearDown(updater.close);
    expect(
        (await updater.check(currentDevice)).release?.manifest.versionCode, 50);
    expect(
        (await updater.check(currentDevice, prerelease: true))
            .release
            ?.manifest
            .versionCode,
        51);
  });

  for (final entry in {
    'same': (50, UpdateStatus.current),
    'newer': (51, UpdateStatus.ahead),
  }.entries) {
    test('manual ZIP does not defeat ${entry.key} installed-version guard',
        () async {
      final updater = checker([manualRelease(), updatableRelease()]);
      addTearDown(updater.close);
      final device = UpdateDevice(
          'com.jim608.jms', entry.value.$1, 22631, ['x86_64'],
          platform: 'windows-x64');
      expect((await updater.check(device, prerelease: true)).status,
          entry.value.$2);
    });
  }

  for (final kind in [
    'manifest-present',
    'executable-present',
    'different-tag',
    'stable-flag',
    'zip-not-uploaded',
  ]) {
    test('manual bypass rejects unsupported classification: $kind', () async {
      final release = manualRelease(
          tag: kind == 'different-tag' ? 'v0.11.1-jms.47-beta.1' : manualTag,
          prerelease: kind != 'stable-flag');
      final assets = release['assets'] as List;
      if (kind == 'manifest-present') {
        assets.add(asset(manualTag, 'update.json', 1000));
      } else if (kind == 'executable-present') {
        assets.add(asset(manualTag, 'malformed-setup.EXE', 100));
      } else if (kind == 'zip-not-uploaded') {
        (assets.last as Map)['state'] = 'new';
      }
      final updater = checker([
        release
      ], manifests: {
        manualTag: {...metadata(), 'schemaVersion': 0}
      });
      addTearDown(updater.close);
      expect((await updater.check(currentDevice, prerelease: true)).status,
          UpdateStatus.incomplete);
    });
  }

  for (final kind in [
    'bad-hash',
    'missing-installer',
    'duplicate-manifest',
    'wrong-installer-host',
    'wrong-source-repo',
    'wrong-installer-size',
  ]) {
    test('real updater contract still fails closed: $kind', () async {
      final value = metadata();
      if (kind == 'bad-hash') {
        value['installer']['sha256'] = 'not-a-hash';
      }
      final release = updatableRelease(manifest: value);
      final assets = release['assets'] as List;
      if (kind == 'missing-installer') {
        assets.removeAt(1);
      } else if (kind == 'duplicate-manifest') {
        assets.add(asset(stableTag, 'update.json', 1000));
      } else if (kind == 'wrong-installer-host') {
        assets[1]['browser_download_url'] =
            'https://outside.example.invalid/setup.exe';
      } else if (kind == 'wrong-source-repo') {
        assets[2]['browser_download_url'] =
            'https://github.com/jim608/JMS-Android/releases/download/$stableTag/${assets[2]['name']}';
      } else if (kind == 'wrong-installer-size') {
        assets[1]['size'] = installerBytes.length + 1;
      }
      final updater =
          checker([manualRelease(), release], manifests: {stableTag: value});
      addTearDown(updater.close);
      expect((await updater.check(currentDevice, prerelease: true)).status,
          UpdateStatus.incomplete);
    });
  }

  test('Windows manual release exception does not apply to Android', () async {
    final updater = checker([manualRelease()]);
    addTearDown(updater.close);
    const device = UpdateDevice('com.jim608.jms', 2049, 35, ['arm64-v8a']);
    expect((await updater.check(device, prerelease: true)).status,
        UpdateStatus.incomplete);
  });
}
