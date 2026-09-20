import 'dart:convert';
import 'dart:io';

import 'package:fladder/util/update_checker.dart';
import 'package:fladder/util/update_source.dart';

Future<void> main(List<String> arguments) async {
  final config = jsonDecode(await File('config/jms_updates.json').readAsString()) as Map<String, dynamic>;
  final source = UpdateSource(owner: config['owner'] as String, repo: config['repo'] as String);
  final checker = UpdateChecker(source: source);
  try {
    final prerelease = arguments.contains('--prerelease');
    final expectedArgument = arguments.where((value) => value.startsWith('--expected-code=')).firstOrNull;
    final expectedCode = expectedArgument == null ? null : int.parse(expectedArgument.split('=').last);
    final result =
        await checker.check(const UpdateDevice('com.jim608.jms', 2008, 35, ['arm64-v8a']), prerelease: prerelease);
    stdout.writeln(jsonEncode({
      'repository': source.identity,
      'checkedAt': DateTime.now().toUtc().toIso8601String(),
      'status': result.status.name,
      'channel': prerelease ? 'prerelease' : 'stable',
      'installedVersionCode': 2008,
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
