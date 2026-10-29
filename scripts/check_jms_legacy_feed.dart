import 'dart:convert';
import 'dart:io';

import 'package:fladder/util/update_checker.dart';
import 'package:fladder/util/update_source.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// GitHub API/manifest fixtures are UTF-8; the String response constructor
// defaults to Latin-1 and rejects real non-Latin release notes before replay.
http.Response _jsonResponse(String body, int statusCode) => http.Response.bytes(
  utf8.encode(body),
  statusCode,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

Future<void> main(List<String> arguments) async {
  const source = UpdateSource(owner: 'jim608', repo: 'JMS-Android');
  if (arguments.contains('--stable') && arguments.contains('--prerelease')) {
    throw ArgumentError('Select only one channel');
  }
  // Preserve the established legacy opt-in gate unless explicitly selecting a
  // channel for the prospective matrix. The frozen .8 library is untouched.
  final prerelease = !arguments.contains('--stable');
  final historyArgument = arguments
      .where((argument) => argument.startsWith('--history-fixture='))
      .firstOrNull;
  final reportOnly = arguments.contains('--report-only');
  final fixture = arguments
      .where((argument) => argument.startsWith('--fixture='))
      .firstOrNull;
  final expected = arguments
      .where((argument) => argument.startsWith('--expected-code='))
      .firstOrNull;
  Map<String, dynamic>? manifest;
  Map<String, dynamic>? history;
  if (historyArgument != null) {
    if (fixture != null) throw ArgumentError('Select only one fixture mode');
    history = Map<String, dynamic>.from(
      jsonDecode(
            await File(
              historyArgument.substring('--history-fixture='.length),
            ).readAsString(),
          )
          as Map,
    );
    if (history['schemaVersion'] != 1 ||
        history['repository'] != source.identity ||
        history['sourceUrl'] != source.releases.toString() ||
        history['installedVersionCode'] != 2008 ||
        history['releases'] is! List ||
        history['responses'] is! Map) {
      throw const FormatException('Invalid prospective feed fixture');
    }
  } else if (reportOnly) {
    throw ArgumentError('Report-only requires an offline history fixture');
  }
  if (fixture != null) {
    manifest =
        jsonDecode(
              await File(fixture.substring('--fixture='.length)).readAsString(),
            )
            as Map<String, dynamic>;
  }
  final checker = UpdateChecker(
    source: source,
    client: history != null
        ? MockClient((request) async {
            if (request.method != 'GET') {
              throw StateError('Offline checker attempted a non-read request');
            }
            if (request.url == source.releases) {
              return _jsonResponse(jsonEncode(history!['releases']), 200);
            }
            if (!source.ownsAsset(request.url) ||
                request.url.pathSegments.last != 'update.json') {
              throw StateError('Offline checker attempted a non-manifest URL');
            }
            final responses = Map<String, dynamic>.from(
              history!['responses'] as Map,
            );
            final response = responses[request.url.toString()];
            if (response == null) return _jsonResponse('{}', 404);
            final value = Map<String, dynamic>.from(response as Map);
            if (value['statusCode'] is! int || value['body'] is! String) {
              throw const FormatException('Invalid fixture response');
            }
            return _jsonResponse(
              value['body'] as String,
              value['statusCode'] as int,
            );
          })
        : manifest == null
        ? null
        : MockClient((request) async {
            if (request.url == source.releases) {
              final assets = <Map<String, dynamic>>[];
              for (final entry in [
                manifest!['apk'],
                manifest['source'],
                {
                  'name': 'update.json',
                  'size': utf8.encode(jsonEncode(manifest)).length,
                },
              ]) {
                assets.add({
                  'name': entry['name'],
                  'size': entry['size'],
                  'state': 'uploaded',
                  'browser_download_url':
                      'https://github.com/jim608/JMS-Android/releases/download/vfixture/${entry['name']}',
                });
              }
              return _jsonResponse(
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
                  },
                ]),
                200,
              );
            }
            return _jsonResponse(jsonEncode(manifest), 200);
          }),
  );
  try {
    final installed = history != null || manifest == null
        ? 2008
        : (manifest['versionCode'] as int) - 1;
    final result = await checker.check(
      UpdateDevice('com.jim608.jms', installed, 35, ['arm64-v8a']),
      prerelease: prerelease,
    );
    final code = result.release?.manifest.versionCode;
    stdout.writeln(
      jsonEncode({
        'verifier': 'installed-android-2008',
        'authentication': 'none',
        'mode': history != null
            ? 'prospective-fixture'
            : manifest == null
            ? 'anonymous'
            : 'fixture',
        'channel': prerelease ? 'prerelease' : 'stable',
        'installedVersionCode': installed,
        'networkRequestsIssued': history != null || manifest != null ? 0 : null,
        'status': result.status.name,
        'versionCode': code,
      }),
    );
    if (!reportOnly &&
        (result.status != UpdateStatus.available ||
            (expected != null &&
                code != int.parse(expected.split('=').last)))) {
      exitCode = 1;
    }
  } finally {
    checker.close();
  }
}
