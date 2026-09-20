import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fladder/util/brand.dart';
import 'package:fladder/util/update_checker.dart';
import 'package:fladder/util/update_controller.dart';
import 'package:fladder/util/update_source.dart';

const source = UpdateSource(owner: 'fixture-owner', repo: 'jms-fixture');
const device = UpdateDevice('com.jim608.jms', 2005, 35, ['arm64-v8a']);
Map<String, dynamic> manifest({int code = 2006}) => {
      'schemaVersion': 1,
      'applicationId': 'com.jim608.jms',
      'versionName': '0.11.1-jms.6',
      'versionCode': code,
      'minSdk': 24,
      'abis': ['arm64-v8a'],
      'sourceCommit': 'a' * 40,
      'apk': {'name': 'JMS.apk', 'size': 100, 'sha256': 'b' * 64},
      'source': {'name': 'JMS-source.zip', 'size': 200, 'sha256': 'c' * 64},
    };
Map<String, dynamic> asset(String name, int size) => {
      'name': name,
      'size': size,
      'state': 'uploaded',
      'browser_download_url': 'https://github.com/fixture-owner/jms-fixture/releases/download/v6/$name',
    };
Map<String, dynamic> release({bool draft = false, bool prerelease = false}) => {
      'draft': draft,
      'prerelease': prerelease,
      'tag_name': 'v6',
      'published_at': '2026-09-19T00:00:00Z',
      'body': '測試更新',
      'assets': [asset('update.json', 1000), asset('JMS.apk', 100), asset('JMS-source.zip', 200)],
    };
UpdateChecker checker({List<dynamic>? releases, Map<String, dynamic>? metadata, int apiStatus = 200}) => UpdateChecker(
    source: source,
    client: MockClient((request) async => http.Response(
          request.url.host == 'api.github.com'
              ? jsonEncode(releases ?? [release()])
              : jsonEncode(metadata ?? manifest()),
          request.url.host == 'api.github.com' ? apiStatus : 200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        )));

class FakeBridge extends AndroidUpdateBridge {
  int downloads = 0;
  int installs = 0;
  bool permissionAllowed = true;
  String? downloadError;
  Completer<void>? downloadPending;
  int installedCode = 2005;
  @override
  Future<UpdateDevice> device() async => UpdateDevice('com.jim608.jms', installedCode, 35, ['arm64-v8a']);
  @override
  Future<void> setAllowed(bool allowed) async {}
  @override
  Future<void> cancel() async {
    if (downloadPending != null && !downloadPending!.isCompleted) {
      downloadPending!.completeError(PlatformException(code: 'cancelled'));
    }
  }

  @override
  Future<void> download(ReleaseInfo release) async {
    downloads++;
    if (downloadError != null) throw PlatformException(code: downloadError!);
    if (downloadPending != null) await downloadPending!.future;
  }

  @override
  Future<bool> canInstall() async => permissionAllowed;
  @override
  Future<void> permission() async {}
  @override
  Future<String> install() async {
    installs++;
    return 'installCancelled';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('unconfigured does not contact platform or upstream', () async {
    final updater = UpdateChecker(client: MockClient((_) async => throw StateError('network forbidden')));
    expect((await updater.check(device)).status, UpdateStatus.unconfigured);
    expect(Brand.applicationId, 'com.jim608.jms');
    updater.close();
  });
  test('reject upstream and untrusted redirects', () {
    expect(const UpdateSource(owner: 'DonutWare', repo: 'Fladder').valid, false);
    for (final url in [
      'http://release-assets.githubusercontent.com/a',
      'https://evil.test/a',
      'https://release-assets.githubusercontent.com.evil.test/a',
      'https://user@objects.githubusercontent.com/a'
    ]) {
      expect(UpdateSource.allowedRedirect(Uri.parse(url)), false);
    }
    expect(
        UpdateSource.allowedRedirect(Uri.parse('https://release-assets.githubusercontent.com/a?sig=redacted')), true);
  });
  for (final entry in {2004: UpdateStatus.current, 2005: UpdateStatus.current, 2006: UpdateStatus.available}.entries) {
    test('integer version comparison ${entry.key}', () async {
      final updater = checker(metadata: manifest(code: entry.key));
      expect((await updater.check(device)).status, entry.value);
      updater.close();
    });
  }
  test('no releases and draft/prerelease excluded', () async {
    for (final releases in [
      [],
      [release(draft: true)],
      [release(prerelease: true)]
    ]) {
      final updater = checker(releases: releases);
      expect((await updater.check(device)).status, UpdateStatus.noRelease);
      updater.close();
    }
    final updater = checker(releases: [release(prerelease: true)]);
    expect((await updater.check(device, prerelease: true)).status, UpdateStatus.available);
    updater.close();
  });
  for (final entry in {
    401: UpdateStatus.sourceUnavailable,
    404: UpdateStatus.sourceUnavailable,
    403: UpdateStatus.sourceUnavailable,
    429: UpdateStatus.rateLimited,
    503: UpdateStatus.network
  }.entries) {
    test('API status ${entry.key}', () async {
      final updater = checker(apiStatus: entry.key);
      expect((await updater.check(device)).status, entry.value);
      updater.close();
    });
  }
  test('rate limiting blocks repeated requests', () async {
    var requests = 0;
    final updater = UpdateChecker(
        source: source,
        client: MockClient((_) async {
          requests++;
          return http.Response('', 429, headers: {'retry-after': '3600'});
        }));
    await updater.check(device);
    await updater.check(device);
    expect(requests, 1);
    updater.close();
  });
  test('403 distinguishes rate-limit headers from permission failure', () async {
    for (final headers in [
      {'x-ratelimit-remaining': '0'},
      {'retry-after': '120'},
      {'x-ratelimit-remaining': '50'},
    ]) {
      final updater =
          UpdateChecker(source: source, client: MockClient((_) async => http.Response('', 403, headers: headers)));
      final limited = headers['x-ratelimit-remaining'] == '0' || headers.containsKey('retry-after');
      expect((await updater.check(device)).status, limited ? UpdateStatus.rateLimited : UpdateStatus.sourceUnavailable);
      expect(updater.retryAfter != null, limited);
      updater.close();
    }
  });
  test('invalid JSON and timeout are distinct', () async {
    final invalid = UpdateChecker(source: source, client: MockClient((_) async => http.Response('{', 200)));
    expect((await invalid.check(device)).status, UpdateStatus.incomplete);
    invalid.close();
    final timeout = UpdateChecker(
        source: source,
        timeout: const Duration(milliseconds: 5),
        client: MockClient((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 25));
          return http.Response('[]', 200);
        }));
    expect((await timeout.check(device)).status, UpdateStatus.network);
    timeout.close();
  });
  test('ETag uses cached JSON on 304', () async {
    var requests = 0;
    final updater = UpdateChecker(
        source: source,
        client: MockClient((request) async {
          requests++;
          if (requests == 1) return http.Response('[]', 200, headers: {'etag': '"fixture"'});
          expect(request.headers['If-None-Match'], '"fixture"');
          return http.Response('', 304);
        }));
    expect((await updater.check(device)).status, UpdateStatus.noRelease);
    expect((await updater.check(device)).status, UpdateStatus.noRelease);
    updater.close();
  });
  test('metadata rejects package, ABI, fractional version and missing source/hash', () {
    for (final invalid in [
      {...manifest(), 'applicationId': 'com.other'},
      {
        ...manifest(),
        'abis': ['x86_64']
      },
      {...manifest(), 'versionCode': 2006.1},
      {...manifest(), 'sourceCommit': ''},
      {...manifest(), 'source': null},
      {
        ...manifest(),
        'apk': {'name': 'JMS.apk', 'size': 100, 'sha256': ''}
      },
    ]) {
      expect(() => UpdateManifest.parse(invalid), throwsA(isA<UpdateFailure>()));
    }
  });
  test('wrong minSDK or device ABI is incompatible', () async {
    final updater = checker(metadata: {...manifest(), 'minSdk': 36});
    expect((await updater.check(device)).status, UpdateStatus.incompatible);
    updater.close();
    final arm = checker();
    expect((await arm.check(const UpdateDevice('com.jim608.jms', 2005, 35, ['x86_64']))).status,
        UpdateStatus.incompatible);
    arm.close();
  });
  test('same-release assets, complete source and exact size required', () async {
    for (final assets in [
      [asset('update.json', 1000), asset('JMS.apk', 100)],
      [asset('update.json', 1000), asset('JMS.apk', 101), asset('JMS-source.zip', 200)],
      [
        asset('update.json', 1000),
        {...asset('JMS.apk', 100), 'browser_download_url': 'https://evil.test/JMS.apk'},
        asset('JMS-source.zip', 200)
      ],
    ]) {
      final updater = checker(releases: [
        {...release(), 'assets': assets}
      ]);
      expect((await updater.check(device)).status, UpdateStatus.incomplete);
      updater.close();
    }
  });
  test('manual single flight, preferences and skip persist', () async {
    SharedPreferences.setMockInitialValues({});
    final bridge = FakeBridge();
    final controller = UpdateController(checker: checker(), bridge: bridge);
    await controller.initialize();
    await Future.wait([controller.check(), controller.check()]);
    expect(controller.latestRelease, isNotNull);
    expect(bridge.downloads, 0);
    await controller.skip();
    await controller.setAutomatic(false);
    await controller.setPrerelease(true);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('jms.update.auto'), false);
    expect(prefs.getBool('jms.update.prerelease'), true);
    expect(prefs.getInt('jms.update.skipped'), 2006);
    controller.dispose();
  });
  test('playback prevents check download and installer; never auto-downloads', () async {
    SharedPreferences.setMockInitialValues({});
    final bridge = FakeBridge();
    final controller = UpdateController(checker: checker(), bridge: bridge);
    await controller.initialize();
    await controller.check(manual: false);
    expect(bridge.downloads, 0);
    controller.setPlayback(true);
    expect(controller.hasNewUpdate, false);
    await controller.download();
    await controller.install();
    expect(bridge.downloads, 0);
    expect(bridge.installs, 0);
    expect(controller.status, UpdateStatus.playbackBlocked);
    controller.dispose();
  });
  for (final code in ['hash', 'signature', 'incompatible', 'space', 'download']) {
    test('native download rejection $code never installs', () async {
      SharedPreferences.setMockInitialValues({});
      final bridge = FakeBridge()..downloadError = code;
      final controller = UpdateController(checker: checker(), bridge: bridge);
      await controller.initialize();
      await controller.check();
      await controller.download();
      expect(controller.status, UpdateStatus.downloadFailed);
      expect(controller.failure, code);
      expect(bridge.installs, 0);
      controller.dispose();
    });
  }
  test('cancel download and permission denial / installer cancellation', () async {
    SharedPreferences.setMockInitialValues({});
    final bridge = FakeBridge()..downloadPending = Completer<void>();
    final controller = UpdateController(checker: checker(), bridge: bridge);
    await controller.initialize();
    await controller.check();
    final download = controller.download();
    await controller.cancel();
    await download;
    expect(controller.status, UpdateStatus.cancelled);
    bridge.downloadPending = null;
    await controller.download();
    bridge.permissionAllowed = false;
    await controller.install();
    expect(controller.status, UpdateStatus.permissionRequired);
    expect(bridge.installs, 0);
    bridge.permissionAllowed = true;
    await controller.install();
    expect(controller.status, UpdateStatus.installCancelled);
    controller.dispose();
  });
  test('only installed version after restart confirms success', () async {
    SharedPreferences.setMockInitialValues({'jms.update.pending': 2006});
    final pending = UpdateController(checker: checker(), bridge: FakeBridge());
    await pending.initialize();
    expect(pending.status, UpdateStatus.installPending);
    pending.dispose();
    final complete = UpdateController(checker: checker(), bridge: FakeBridge()..installedCode = 2006);
    await complete.initialize();
    expect(complete.status, UpdateStatus.updated);
    complete.dispose();
  });
  test('auto check cooldown persists across restarts and manual check can bypass', () async {
    SharedPreferences.setMockInitialValues({'jms.update.lastCheck': DateTime.now().millisecondsSinceEpoch});
    var requests = 0;
    final updater = UpdateChecker(
        source: source,
        client: MockClient((_) async {
          requests++;
          return http.Response('[]', 200);
        }));
    final controller = UpdateController(checker: updater, bridge: FakeBridge());
    await controller.initialize();
    await controller.check(manual: false);
    expect(requests, 0);
    await controller.check();
    expect(requests, 1);
    await controller.check(manual: false);
    expect(requests, 1);
    controller.dispose();
  });
}
