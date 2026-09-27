import 'dart:convert';
import 'dart:io';

import 'package:fladder/util/update_checker.dart';
import 'package:fladder/util/update_source.dart';

Future<void> main(List<String> arguments) async {
  final config = jsonDecode(await File('config/jms_updates.json').readAsString()) as Map<String, dynamic>;
  final windows = arguments.contains('--windows');
  final source = windows ? const UpdateSource(owner: 'jim608', repo: 'JMS-Desktop')
      : UpdateSource(owner: config['owner'] as String, repo: config['repo'] as String);
  final installedArgument = arguments.where((value) => value.startsWith('--installed-code=')).firstOrNull;
  final installedCode = installedArgument == null ? (windows ? 17 : 2008) : int.parse(installedArgument.split('=').last);
  final checker = UpdateChecker(source: source);
  try {
    final prerelease = arguments.contains('--prerelease');
    final expectedArgument = arguments.where((value) => value.startsWith('--expected-code=')).firstOrNull;
    final expectedCode = expectedArgument == null ? null : int.parse(expectedArgument.split('=').last);
    final result =
        await checker.check(windows
            ? UpdateDevice('com.jim608.jms', installedCode, 17763, ['x86_64'], platform: 'windows-x64')
            : UpdateDevice('com.jim608.jms', installedCode, 35, ['arm64-v8a']), prerelease: prerelease);
    stdout.writeln(jsonEncode({
      'repository': source.identity,
      'checkedAt': DateTime.now().toUtc().toIso8601String(),
      'status': result.status.name,
      'channel': prerelease ? 'prerelease' : 'stable',
      'installedVersionCode': installedCode,
      'availableVersionCode': result.release?.manifest.versionCode,
      'authentication': 'none',
      'deviceUpgradeTest': false,
    }));
    if (![UpdateStatus.noRelease, UpdateStatus.current, UpdateStatus.available].contains(result.status)) {
      exitCode = 1;
    }
    if (expectedCode != null &&
        (result.status != UpdateStatus.available || result.release?.manifest.versionCode != expectedCode)) {
      exitCode = 1;
    }
  } finally {
    checker.close();
  }
}
