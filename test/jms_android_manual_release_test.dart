import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fladder/util/update_checker.dart';
import 'package:fladder/util/update_source.dart';

const androidSource = UpdateSource(owner: 'jim608', repo: 'JMS-Android');
const manualTag = 'test-0.11.1-jms.46-syncplay-hdr-test.20261024';
const stableTag = 'v0.11.1-jms.47';
const testApk =
    'JMS-Android-TEST-0.11.1-jms.46-syncplay-hdr-test.20261024-2049-arm64-v8a.apk';
const currentDevice = UpdateDevice('com.jim608.jms', 2049, 35, ['arm64-v8a']);

Map<String, dynamic> asset(String tag, String name, int size) => {
      'name': name,
      'state': 'uploaded',
      'size': size,
      'browser_download_url':
          'https://github.com/${androidSource.identity}/releases/download/$tag/$name',
    };

Map<String, dynamic> metadata() => {
      'schemaVersion': 1,
      'applicationId': 'com.jim608.jms',
      'platform': 'android',
      'versionName': '0.11.1-jms.47',
      'versionCode': 2050,
      'minSdk': 24,
      'abis': ['arm64-v8a'],
      'sourceCommit': 'a' * 40,
      'apk': {
        'name': 'JMS-0.11.1-jms.47-arm64-v8a.apk',
        'size': 100,
        'sha256': 'b' * 64,
      },
      'source': {
        'name': 'JMS-0.11.1-jms.47-source.zip',
        'size': 200,
        'sha256': 'c' * 64,
      },
    };

Map<String, dynamic> manualRelease() => {
      'draft': false,
      'prerelease': true,
      'tag_name': manualTag,
      'published_at': '2026-10-24T01:00:00Z',
      'assets': [
        asset(manualTag, testApk, 98276365),
        asset(manualTag, 'JMS-Application-Source-8ee653a24217.zip', 1),
        asset(manualTag, 'JMS-Third-Party-Sources-20261024.tar.gz', 1),
        asset(manualTag, 'JMS-native-materials.zip', 1),
      ],
    };

Map<String, dynamic> stableRelease(Map<String, dynamic> value) => {
      'draft': false,
      'prerelease': false,
      'tag_name': stableTag,
      'published_at': '2026-10-24T02:00:00Z',
      'assets': [
        asset(stableTag, 'update.json', 1000),
        asset(stableTag, value['apk']['name'], value['apk']['size']),
        asset(stableTag, value['source']['name'], value['source']['size']),
      ],
    };

UpdateChecker checker(List<Map<String, dynamic>> releases,
    Map<String, Map<String, dynamic>> manifests, List<Uri> requests) {
  return UpdateChecker(
    source: androidSource,
    client: MockClient((request) async {
      requests.add(request.url);
      if (request.url.host == 'api.github.com') {
        return http.Response(jsonEncode(releases), 200);
      }
      expect(request.url.pathSegments.last, 'update.json');
      final value = manifests[request.url.pathSegments[4]];
      expect(value, isNotNull, reason: 'A manual .dev APK is never fetched');
      return http.Response(jsonEncode(value), 200);
    }),
  );
}

void main() {
  test('four-asset Android manual .dev TEST cannot poison supported stable',
      () async {
    for (final manualFirst in [true, false]) {
      final value = metadata();
      final manual = manualRelease();
      expect((manual['assets'] as List).length, 4);
      final stable = stableRelease(value);
      final requests = <Uri>[];
      final updater = checker(manualFirst ? [manual, stable] : [stable, manual],
          {stableTag: value}, requests);
      addTearDown(updater.close);
      final result = await updater.check(currentDevice, prerelease: true);
      expect(result.status, UpdateStatus.available);
      expect(result.release?.manifest.versionCode, 2050);
      expect(result.release?.manifest.assetName,
          'JMS-0.11.1-jms.47-arm64-v8a.apk');
      expect(
          requests
              .where((uri) => uri.host == 'github.com')
              .map((uri) => uri.pathSegments[4]),
          [stableTag]);
    }
  });

  test('Android manual exception never swallows a declared production contract',
      () async {
    for (final kind in [
      'manifest-present',
      'production-apk-present',
      'different-manual-tag',
      'bad-production-hash',
    ]) {
      final manual = manualRelease();
      final value = metadata();
      if (kind == 'manifest-present') {
        (manual['assets'] as List).add(asset(manualTag, 'update.json', 1000));
      } else if (kind == 'production-apk-present') {
        (manual['assets'] as List)
            .add(asset(manualTag, 'JMS-production.apk', 100));
      } else if (kind == 'different-manual-tag') {
        manual['tag_name'] = 'test-0.11.1-jms.46-unrecognized-test.20261024';
      } else if (kind == 'bad-production-hash') {
        value['apk']['sha256'] = 'not-a-hash';
      }
      final updater = checker([
        manual,
        stableRelease(value)
      ], {
        stableTag: value,
        manualTag: {...metadata(), 'schemaVersion': 0},
      }, []);
      addTearDown(updater.close);
      expect((await updater.check(currentDevice, prerelease: true)).status,
          UpdateStatus.incomplete,
          reason: kind);
    }
  });
}
