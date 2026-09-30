import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fladder/util/update_checker.dart';
import 'package:fladder/util/windows_update_bridge_io.dart';

final desktopSource = WindowsUpdateBridge().source;
const desktopDevice = UpdateDevice('com.jim608.jms', 15, 22631, ['x86_64'],
    platform: 'windows-x64');
final installerBytes = utf8.encode('synthetic-installer-not-executable');

Map<String, dynamic> desktopManifest({int code = 16}) => {
      'schemaVersion': 1,
      'applicationId': 'com.jim608.jms',
      'platform': 'windows-x64',
      'minWindowsBuild': 17763,
      'versionName': '0.11.1-jms.16',
      'versionCode': code,
      'sourceCommit': 'a' * 40,
      'signing': 'unsigned',
      'installer': {
        'name': 'JMS-Windows-0.11.1-jms.16-x64-setup.exe',
        'size': installerBytes.length,
        'sha256': sha256.convert(installerBytes).toString()
      },
      'source': {'name': 'JMS-source.zip', 'size': 200, 'sha256': 'b' * 64},
    };

ReleaseInfo desktopRelease([Map<String, dynamic>? metadata]) {
  final manifest = UpdateManifest.parse(metadata ?? desktopManifest(),
      platform: 'windows-x64');
  return ReleaseInfo(
      manifest,
      '修正測試',
      DateTime.utc(2026),
      Uri.parse(
          'https://github.com/${desktopSource.identity}/releases/download/v16/${manifest.assetName}'),
      desktopSource.identity);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late WindowsUpdateBridge bridge;
  var installedCode = 15;
  var validates = 0;
  var installs = 0;
  var metadataAccepted = true;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('jms-updater-test-');
    installedCode = 15;
    validates = installs = 0;
    metadataAccepted = true;
    messenger.setMockMethodCallHandler(WindowsUpdateBridge.channel,
        (call) async {
      switch (call.method) {
        case 'device':
          return {'versionCode': installedCode, 'windowsBuild': 22631};
        case 'validate':
          validates++;
          return metadataAccepted;
        case 'install':
          installs++;
          return 'installPending';
      }
      return null;
    });
    bridge = WindowsUpdateBridge(
        directory: () async => temp,
        clientFactory: () => MockClient(
            (request) async => http.Response.bytes(installerBytes, 200)));
  });
  tearDown(() async {
    await bridge.cancel();
    messenger.setMockMethodCallHandler(WindowsUpdateBridge.channel, null);
    await temp.delete(recursive: true);
  });

  test('Windows manifest is platform-specific and rejects APK metadata', () {
    final value = desktopManifest();
    final manifest = UpdateManifest.parse(value, platform: 'windows-x64');
    expect(manifest.supports(desktopDevice), isTrue);
    expect(
        manifest.supports(
            const UpdateDevice('com.jim608.jms', 1, 35, ['arm64-v8a'])),
        isFalse);
    expect(() => UpdateManifest.parse(value), throwsA(isA<UpdateFailure>()));
    for (final change in [
      {'platform': 'windows-arm64'},
      {'applicationId': 'other'},
      {'signing': 'claimed-trusted'},
      {'versionCode': 0},
      {
        'installer': {...value['installer'] as Map, 'name': 'other.exe'}
      },
      {
        'installer': {...value['installer'] as Map, 'sha256': 'bad'}
      },
    ]) {
      expect(
          () => UpdateManifest.parse({...value, ...change},
              platform: 'windows-x64'),
          throwsA(isA<UpdateFailure>()));
    }
  });

  test(
      'shared checker discovers desktop updates, filters prerelease and refuses downgrade',
      () async {
    var prerelease = true;
    var code = 16;
    Map<String, dynamic> asset(String name, int size) => {
          'name': name,
          'state': 'uploaded',
          'size': size,
          'browser_download_url':
              'https://github.com/${desktopSource.identity}/releases/download/v16/$name',
        };
    final checker = UpdateChecker(
        source: desktopSource,
        client: MockClient((request) async {
          final metadata = desktopManifest(code: code);
          return http.Response(
              jsonEncode(request.url.host == 'api.github.com'
                  ? [
                      {
                        'draft': false,
                        'prerelease': prerelease,
                        'tag_name': 'v16',
                        'published_at': '2026-09-27T00:00:00Z',
                        'body': '修正測試',
                        'assets': [
                          asset('update.json', 1000),
                          asset(metadata['installer']['name'],
                              installerBytes.length),
                          asset('JMS-source.zip', 200)
                        ],
                      }
                    ]
                  : metadata),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }));
    addTearDown(checker.close);
    expect((await checker.check(desktopDevice)).status, UpdateStatus.noRelease);
    expect((await checker.check(desktopDevice, prerelease: true)).status,
        UpdateStatus.available);
    prerelease = false;
    for (final older in [15, 14]) {
      code = older;
      expect((await checker.check(desktopDevice)).status, older == 15 ? UpdateStatus.current : UpdateStatus.ahead);
    }
  });

  test(
      'download validates size hash metadata; launch is pending, never success',
      () async {
    await bridge.download(desktopRelease());
    expect(validates, 1);
    expect(installs, 0);
    expect(await bridge.install(), 'installPending');
    expect(installs, 1);
  });

  test('hash mismatch deletes temporary files and never validates or installs',
      () async {
    final metadata = desktopManifest();
    metadata['installer']['sha256'] = '0' * 64;
    await expectLater(bridge.download(desktopRelease(metadata)),
        throwsA(isA<PlatformException>()));
    expect(validates, 0);
    expect(
        await temp.list(recursive: true).where((entry) => entry is File).length,
        0);
    expect(installs, 0);
  });

  test('native metadata rejection blocks installation', () async {
    metadataAccepted = false;
    await expectLater(
        bridge.download(desktopRelease()), throwsA(isA<PlatformException>()));
    await expectLater(bridge.install(), throwsA(isA<PlatformException>()));
    expect(installs, 0);
  });

  test('tampering after download fails rehash', () async {
    await bridge.download(desktopRelease());
    final file = await temp
        .list(recursive: true)
        .where((entry) => entry is File)
        .first as File;
    await file.writeAsBytes(List.filled(installerBytes.length, 0));
    await expectLater(bridge.install(), throwsA(isA<PlatformException>()));
    expect(installs, 0);
  });

  test('playback blocks download and install without changing settings',
      () async {
    await bridge.download(desktopRelease());
    await bridge.setAllowed(false);
    await expectLater(bridge.install(), throwsA(isA<PlatformException>()));
    await expectLater(
        bridge.download(desktopRelease()), throwsA(isA<PlatformException>()));
    expect(installs, 0);
  });

  test('same or older version never downloads', () async {
    installedCode = 16;
    await expectLater(
        bridge.download(desktopRelease()), throwsA(isA<PlatformException>()));
    expect(validates, 0);
  });

  test('cancelled download and duplicate calls do not leave installers',
      () async {
    final pending = Completer<http.Response>();
    bridge = WindowsUpdateBridge(
        directory: () async => temp,
        clientFactory: () => MockClient((request) => pending.future));
    final task = bridge.download(desktopRelease());
    await expectLater(
        bridge.download(desktopRelease()), throwsA(isA<PlatformException>()));
    await bridge.cancel();
    pending.complete(http.Response.bytes(installerBytes, 200));
    await expectLater(task, throwsA(isA<PlatformException>()));
    expect(
        await temp.list(recursive: true).where((entry) => entry is File).length,
        0);
  });

  test('non-GitHub redirect is rejected', () async {
    bridge = WindowsUpdateBridge(
        directory: () async => temp,
        clientFactory: () => MockClient((request) async => http.Response(
            '', 302,
            headers: {'location': 'https://untrusted.example/installer.exe'})));
    await expectLater(
        bridge.download(desktopRelease()), throwsA(isA<PlatformException>()));
    expect(validates, 0);
  });
}
