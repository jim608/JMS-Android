// Offline counterfactual scope check, never metadata for the historical .46 APK.
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
  if (arguments.length != 1)
    throw ArgumentError('Exact valid manifest path required');
  final original = Map<String, dynamic>.from(
    jsonDecode(await File(arguments.single).readAsString()) as Map,
  );
  if (original['applicationId'] != 'com.jim608.jms' ||
      original['versionCode'] is! int ||
      (original['versionCode'] as int) <= 2008) {
    throw const FormatException('Production upgrade fixture required');
  }
  const source = UpdateSource(owner: 'jim608', repo: 'JMS-Android');
  final requests = <String>[];
  Future<String> check(Map<String, dynamic> manifest) async {
    const tag = 'vpackage-scope-counterfactual';
    String url(String name) =>
        'https://github.com/jim608/JMS-Android/releases/download/$tag/$name';
    final checker = UpdateChecker(
      source: source,
      client: MockClient((request) async {
        if (request.method != 'GET')
          throw StateError('Only fixture GET is allowed');
        requests.add(request.url == source.releases ? 'feed' : 'manifest');
        if (request.url == source.releases) {
          final rows = [
            manifest['apk'],
            manifest['source'],
            {
              'name': 'update.json',
              'size': utf8.encode(jsonEncode(manifest)).length,
            },
          ];
          return _jsonResponse(
            jsonEncode([
              {
                'tag_name': tag,
                'draft': false,
                'prerelease': true,
                'name': 'Offline package identity counterfactual',
                'body': '',
                'published_at': '2026-10-29T00:00:00Z',
                'assets': [
                  for (final item in rows)
                    {
                      'name': (item as Map)['name'],
                      'size': item['size'],
                      'state': 'uploaded',
                      'browser_download_url': url(item['name'] as String),
                    },
                ],
              },
            ]),
            200,
          );
        }
        if (request.url.toString() != url('update.json')) {
          throw StateError('APK/source download forbidden in scope fixture');
        }
        return _jsonResponse(jsonEncode(manifest), 200);
      }),
    );
    try {
      final result = await checker.check(
        const UpdateDevice('com.jim608.jms', 2008, 35, ['arm64-v8a']),
        prerelease: true,
      );
      return result.status.name;
    } finally {
      checker.close();
    }
  }

  final valid = await check(original);
  final development = Map<String, dynamic>.from(original)
    ..['applicationId'] = 'com.jim608.jms.dev';
  final rejected = await check(development);
  if (valid != 'available' || rejected != 'incomplete') {
    throw StateError('Unexpected immutable checker package-identity scope');
  }
  stdout.writeln(
    jsonEncode({
      'status': 'PASS',
      'mode': 'offline-counterfactual-package-scope',
      'productionApplicationId': valid,
      'developmentApplicationId': rejected,
      'onlyChangedField': 'applicationId',
      'actual46MetadataCreated': false,
      'historyOrProductionChanged': false,
      'networkRequestsIssued': 0,
      'apkOrSourceDownloaded': false,
      'fixtureReads': requests.length,
    }),
  );
}
