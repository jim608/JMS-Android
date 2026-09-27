import 'dart:convert';
import 'dart:io';

import 'package:fladder/util/update_checker.dart';
import 'package:fladder/util/update_source.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Future<void> main(List<String> arguments) async {
  const source = UpdateSource(owner: 'jim608', repo: 'JMS-Android');
  final fixture = arguments
      .where((argument) => argument.startsWith('--fixture='))
      .firstOrNull;
  final expected = arguments
      .where((argument) => argument.startsWith('--expected-code='))
      .firstOrNull;
  Map<String, dynamic>? manifest;
  if (fixture != null) {
    manifest = jsonDecode(
            await File(fixture.substring('--fixture='.length)).readAsString())
        as Map<String, dynamic>;
  }
  final checker = UpdateChecker(
    source: source,
    client: manifest == null
        ? null
        : MockClient((request) async {
            if (request.url == source.releases) {
              final assets = <Map<String, dynamic>>[];
              for (final entry in [
                manifest!['apk'],
                manifest['source'],
                {
                  'name': 'update.json',
                  'size': utf8.encode(jsonEncode(manifest)).length
                }
              ]) {
                assets.add({
                  'name': entry['name'],
                  'size': entry['size'],
                  'state': 'uploaded',
                  'browser_download_url':
                      'https://github.com/jim608/JMS-Android/releases/download/vfixture/${entry['name']}',
                });
              }
              return http.Response(
                  jsonEncode([
                    {
                      'tag_name': 'vfixture',
                      'name': 'JMS fixture',
                      'body': '',
                      'draft': false,
                      'prerelease': true,
                      'published_at': '2026-09-01T00:00:00Z',
                      'html_url':
                          'https://github.com/jim608/JMS-Android/releases/tag/vfixture',
                      'assets': assets,
                    }
                  ]),
                  200);
            }
            return http.Response(jsonEncode(manifest), 200);
          }),
  );
  try {
    final installed =
        manifest == null ? 2008 : (manifest['versionCode'] as int) - 1;
    final result = await checker.check(
        UpdateDevice('com.jim608.jms', installed, 35, ['arm64-v8a']),
        prerelease: true);
    final code = result.release?.manifest.versionCode;
    stdout.writeln(jsonEncode({
      'verifier': 'installed-android-2008',
      'authentication': 'none',
      'mode': manifest == null ? 'anonymous' : 'fixture',
      'status': result.status.name,
      'versionCode': code
    }));
    if (result.status != UpdateStatus.available ||
        (expected != null && code != int.parse(expected.split('=').last))) {
      exitCode = 1;
    }
  } finally {
    checker.close();
  }
}
