@TestOn('vm')
library;

import 'dart:io';

import 'package:fladder/util/seerr_http_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  for (final transport in <String, http.Client Function()>{
    'Jellyfin': createJellyfinHttpClient,
    'Seerr': createSeerrHttpClient,
  }.entries) {
    test(
        '${transport.key} does not forward account credentials to redirects '
        'and cannot send after close', () async {
      final redirectedRequests = <String?>[];
      final destination =
          await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => destination.close(force: true));
      destination.listen((request) {
        redirectedRequests.add(request.headers.value('authorization'));
        request.response.write('Unexpected redirected request');
        request.response.close();
      });

      final sourceRequests = <String?>[];
      final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => source.close(force: true));
      source.listen((request) {
        sourceRequests.add(request.headers.value('authorization'));
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(HttpHeaders.locationHeader,
            'http://127.0.0.1:${destination.port}/private-destination');
        request.response.close();
      });

      final client = transport.value();
      addTearDown(client.close);
      final target = Uri.parse('http://127.0.0.1:${source.port}/redirect');
      const authorization = 'MediaBrowser Token="synthetic-account-token"';
      final response =
          await client.get(target, headers: {'authorization': authorization});

      expect(response.statusCode, HttpStatus.found);
      expect(sourceRequests, [authorization]);
      expect(redirectedRequests, isEmpty);

      client.close();
      await expectLater(
          client.get(target, headers: {'authorization': authorization}),
          throwsA(isA<http.ClientException>()));
      expect(sourceRequests, [authorization]);
      expect(redirectedRequests, isEmpty);
    });
  }
}
