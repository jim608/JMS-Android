import 'dart:io';

import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:fladder/util/brand.dart';
import 'package:fladder/util/update_checker.dart';
import 'package:fladder/util/update_controller.dart';
import 'package:fladder/util/update_source.dart';
import 'package:fladder/util/windows_update_bridge_io.dart';

UpdateBridge createLinuxUpdateBridge() => LinuxUpdateBridge();

bool validLinuxPackageMetadata(String value, UpdateManifest manifest) {
  final fields = <String, String>{};
  for (final line in value.split('\n')) {
    final separator = line.indexOf(' = ');
    if (separator < 0) continue;
    final name = line.substring(0, separator);
    if (!{'pkgname', 'arch', 'pkgver'}.contains(name)) continue;
    if (fields.containsKey(name)) return false;
    fields[name] = line.substring(separator + 3);
  }
  return fields['pkgname'] == 'jms' &&
      fields['arch'] == 'x86_64' &&
      fields['pkgver'] == manifest.json['packageVersion'];
}

class LinuxUpdateBridge extends WindowsUpdateBridge {
  LinuxUpdateBridge({
    super.clientFactory,
    super.directory,
    Future<ProcessResult> Function(String, List<String>)? processRunner,
    Duration packageQueryTimeout = const Duration(seconds: 5),
  })  : _runProcess = processRunner ?? Process.run,
        _packageQueryTimeout = packageQueryTimeout;

  final Future<ProcessResult> Function(String, List<String>) _runProcess;
  final Duration _packageQueryTimeout;

  @override
  UpdateSource get source =>
      const UpdateSource(owner: 'jim608', repo: 'JMS-Linux');
  @override
  String get targetPlatform => 'linux-x64';
  @override
  String get installerFileName => 'installer.pkg.tar.xz';

  @override
  Future<UpdatePackageChannel> currentPackageChannel() async {
    for (final package in [
      (name: 'jms-bin', channel: UpdatePackageChannel.community),
      (name: 'jms', channel: UpdatePackageChannel.official),
    ]) {
      try {
        final result =
            await _runProcess('/usr/bin/pacman', ['-Q', package.name])
                .timeout(_packageQueryTimeout);
        final output = result.stdout;
        if (result.exitCode == 1 && output is String && output.trim().isEmpty) {
          continue;
        }
        if (result.exitCode != 0 || output is! String) {
          return UpdatePackageChannel.unknown;
        }
        final match =
            RegExp(r'^([a-z][a-z0-9-]*) ([A-Za-z0-9][A-Za-z0-9.+_:~-]*)$')
                .firstMatch(output.trim());
        if (match?.group(1) != package.name) {
          return UpdatePackageChannel.unknown;
        }
        return package.channel;
      } catch (_) {
        return UpdatePackageChannel.unknown;
      }
    }
    return UpdatePackageChannel.unknown;
  }

  @override
  Future<UpdateDevice> device() async {
    final architecture = await Process.run('/usr/bin/uname', ['-m']);
    final libc = await Process.run('/usr/bin/getconf', ['GNU_LIBC_VERSION']);
    final os = await File('/etc/os-release').readAsString();
    final supported =
        RegExp(r'^ID=(?:"?)(arch|endeavouros)(?:"?)$', multiLine: true)
            .hasMatch(os);
    final minor =
        RegExp(r'^glibc 2\.(\d+)').firstMatch('${libc.stdout}')?.group(1);
    if (!supported ||
        architecture.exitCode != 0 ||
        '${architecture.stdout}'.trim() != 'x86_64' ||
        libc.exitCode != 0 ||
        minor == null) {
      throw PlatformException(code: 'incompatible');
    }
    final info = await PackageInfo.fromPlatform();
    return UpdateDevice(Brand.applicationId, int.parse(info.buildNumber),
        int.parse(minor), ['x86_64'],
        platform: targetPlatform);
  }

  @override
  Future<void> validateInstaller(File installer, ReleaseInfo release) async {
    final result = await Process.run('/usr/bin/bsdtar', [
      '-xOf',
      installer.path,
      '.PKGINFO',
    ]).timeout(const Duration(seconds: 30));
    if (result.exitCode != 0 ||
        !validLinuxPackageMetadata('${result.stdout}', release.manifest)) {
      throw PlatformException(code: 'metadata');
    }
  }

  @override
  Future<String> launchInstaller(File installer, ReleaseInfo release) async {
    final result = await Process.run('/usr/bin/pkexec', [
      '/usr/bin/pacman',
      '-U',
      '--needed',
      '--noconfirm',
      '--',
      installer.path,
    ]);
    if (result.exitCode == 126) return 'installCancelled';
    return result.exitCode == 0 ? 'installPending' : 'installBlocked';
  }
}
