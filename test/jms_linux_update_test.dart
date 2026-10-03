import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fladder/models/settings/video_player_settings.dart';
import 'package:fladder/util/linux_update_bridge_io.dart';
import 'package:fladder/util/update_checker.dart';
import 'package:fladder/util/update_controller.dart';
import 'package:fladder/util/update_source.dart';
import 'package:flutter/foundation.dart';

const linuxDevice =
    UpdateDevice('com.jim608.jms', 20, 36, ['x86_64'], platform: 'linux-x64');
const source = UpdateSource(owner: 'jim608', repo: 'JMS-Linux');
Map<String, dynamic> linuxManifest() => {
      'schemaVersion': 1,
      'applicationId': 'com.jim608.jms',
      'platform': 'linux-x64',
      'versionName': '0.11.1-jms.19',
      'versionCode': 21,
      'minGlibcMinor': 36,
      'packageVersion': '0.11.1_jms.19-21',
      'packageFormat': 'arch',
      'signing': 'unsigned',
      'sourceCommit': 'a' * 40,
      'installer': {
        'name': 'JMS-Linux-0.11.1-jms.19-x86_64.pkg.tar.xz',
        'size': 100,
        'sha256': 'b' * 64
      },
      'source': {'name': 'JMS-source.zip', 'size': 200, 'sha256': 'c' * 64},
    };

void main() {
  test('Linux identifies community packages before official packages',
      () async {
    final calls = <List<String>>[];
    final bridge =
        LinuxUpdateBridge(processRunner: (executable, arguments) async {
      expect(executable, '/usr/bin/pacman');
      calls.add(arguments);
      return ProcessResult(1, 0, 'jms-bin 0.11.1_jms.29-31\n', '');
    });
    expect(
        await bridge.currentPackageChannel(), UpdatePackageChannel.community);
    expect(calls, [
      ['-Q', 'jms-bin']
    ]);
  });

  test('Linux identifies the exact official package after community is absent',
      () async {
    final calls = <List<String>>[];
    final bridge =
        LinuxUpdateBridge(processRunner: (executable, arguments) async {
      expect(executable, '/usr/bin/pacman');
      calls.add(arguments);
      return arguments.last == 'jms-bin'
          ? ProcessResult(1, 1, '', 'package not found')
          : ProcessResult(1, 0, 'jms 0.11.1_jms.29-31\n', '');
    });
    expect(await bridge.currentPackageChannel(), UpdatePackageChannel.official);
    expect(calls, [
      ['-Q', 'jms-bin'],
      ['-Q', 'jms']
    ]);
  });

  test('Linux does not infer a package channel from untrusted pacman output',
      () async {
    for (final result in [
      ProcessResult(1, 0, 'other 0.11.1-1\n', ''),
      ProcessResult(1, 0, 'jms 0.11.1_jms.29-31\n', ''),
      ProcessResult(1, 0, 'jms-bin 0.11.1-1\nother 1-1\n', ''),
      ProcessResult(1, 0, 'jms-bin\n', ''),
      ProcessResult(1, 0, 'jms-bin ../invalid\n', ''),
      ProcessResult(1, 2, '', 'database error'),
      ProcessResult(1, 1, 'unexpected output', ''),
      ProcessResult(1, 0, <int>[1, 2, 3], ''),
    ]) {
      var calls = 0;
      final bridge = LinuxUpdateBridge(processRunner: (_, __) async {
        calls++;
        return result;
      });
      expect(
          await bridge.currentPackageChannel(), UpdatePackageChannel.unknown);
      expect(calls, 1);
    }
  });

  test('Linux returns unknown when neither supported package is installed',
      () async {
    final bridge = LinuxUpdateBridge(
        processRunner: (_, __) async =>
            ProcessResult(1, 1, '', 'package not found'));
    expect(await bridge.currentPackageChannel(), UpdatePackageChannel.unknown);
  });

  test('Linux package queries fail closed on missing pacman or timeouts',
      () async {
    final missing = LinuxUpdateBridge(processRunner: (_, __) async {
      throw const ProcessException('/usr/bin/pacman', ['-Q', 'jms-bin']);
    });
    final timeout = LinuxUpdateBridge(
        processRunner: (_, __) => Completer<ProcessResult>().future,
        packageQueryTimeout: Duration.zero);
    expect(await missing.currentPackageChannel(), UpdatePackageChannel.unknown);
    expect(await timeout.currentPackageChannel(), UpdatePackageChannel.unknown);
  });

  test('Linux uses MPV without exposing the excluded SDK', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    expect(PlayerOptions.available, {PlayerOptions.libMPV});
    expect(
        VideoPlayerSettingsModel(playerOptions: PlayerOptions.libMDK)
            .wantedPlayer,
        PlayerOptions.libMPV);
  });

  test('Linux manifest and actual Arch package identity must match', () {
    final manifest =
        UpdateManifest.parse(linuxManifest(), platform: 'linux-x64');
    expect(manifest.supports(linuxDevice), isTrue);
    expect(
        manifest.supports(const UpdateDevice(
            'com.jim608.jms', 20, 35, ['x86_64'],
            platform: 'linux-x64')),
        isFalse);
    expect(
        manifest.supports(const UpdateDevice(
            'com.jim608.jms', 20, 36, ['aarch64'],
            platform: 'linux-x64')),
        isFalse);
    expect(
        validLinuxPackageMetadata(
            'pkgname = jms\narch = x86_64\npkgver = 0.11.1_jms.19-21\n',
            manifest),
        isTrue);
    for (final value in [
      'pkgname = other\narch = x86_64\npkgver = 0.11.1_jms.19-21',
      'pkgname = jms\narch = aarch64\npkgver = 0.11.1_jms.19-21',
      'pkgname = jms\narch = x86_64\npkgver = 0.11.1_jms.19-20',
      'pkgname = jms\npkgname = other\narch = x86_64\npkgver = 0.11.1_jms.19-21'
    ]) {
      expect(validLinuxPackageMetadata(value, manifest), isFalse);
    }
    expect(() => UpdateManifest.parse(linuxManifest(), platform: 'windows-x64'),
        throwsA(isA<UpdateFailure>()));
    expect(
        () => UpdateManifest.parse(
            {...linuxManifest(), 'packageVersion': '../bad'},
            platform: 'linux-x64'),
        throwsA(isA<UpdateFailure>()));
  });

  test(
      'shared desktop release selects Linux asset without reading Windows metadata',
      () async {
    final requested = <String>[];
    var versionCode = 21;
    Map<String, dynamic> asset(String name, int size) => {
          'name': name,
          'state': 'uploaded',
          'size': size,
          'browser_download_url':
              'https://github.com/jim608/JMS-Linux/releases/download/v19/$name'
        };
    final checker = UpdateChecker(
        source: source,
        client: MockClient((request) async {
          requested.add(request.url.pathSegments.last);
          final metadata = {
            ...linuxManifest(),
            'versionCode': versionCode,
            'packageVersion': '0.11.1_jms.19-$versionCode'
          };
          final data = request.url.host == 'api.github.com'
              ? [
                  {
                    'draft': false,
                    'prerelease': true,
                    'tag_name': 'v19',
                    'published_at': '2026-09-27T00:00:00Z',
                    'assets': [
                      asset('update.json', 100),
                      asset('update-linux.json', 1000),
                      asset('JMS-Linux-0.11.1-jms.19-x86_64.pkg.tar.xz', 100),
                      asset('JMS-source.zip', 200)
                    ]
                  }
                ]
              : metadata;
          return http.Response(jsonEncode(data), 200,
              headers: {'content-type': 'application/json'});
        }));
    addTearDown(checker.close);
    expect((await checker.check(linuxDevice)).status, UpdateStatus.noRelease);
    expect((await checker.check(linuxDevice, prerelease: true)).status,
        UpdateStatus.available);
    expect(requested, isNot(contains('update.json')));
    expect(requested, contains('update-linux.json'));
    for (final older in [20, 19]) {
      versionCode = older;
      expect((await checker.check(linuxDevice, prerelease: true)).status,
          older == 20 ? UpdateStatus.current : UpdateStatus.ahead);
    }
  });
}
