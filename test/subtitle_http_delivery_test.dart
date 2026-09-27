import 'dart:io';

import 'package:fladder/util/subtitle_delivery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('HTTP delivery preserves complete ASS/SSA bytes instead of querying WebVTT', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final client = HttpClient();
    addTearDown(() async {
      client.close(force: true);
      await server.close(force: true);
    });
    final sources = {
      'ass': await File('test/fixtures/subtitles/representative.ass').readAsBytes(),
      'ssa': await File('test/fixtures/subtitles/traditional.ssa').readAsBytes(),
    };
    server.listen((request) async {
      final format = request.uri.queryParameters['format'] ?? request.uri.path.split('.').last;
      request.response.add(sources[format] ?? 'WEBVTT\n\n00:00.000 --> 00:01.000\nplain text\n'.codeUnits);
      await request.response.close();
    });
    for (final codec in sources.keys) {
      final original = 'http://127.0.0.1:${server.port}/Videos/id/source/Subtitles/3/Stream.vtt?format=vtt';
      final requested = subtitleDeliveryUrl(original, codec)!;
      final request = await client.getUrl(Uri.parse(requested));
      final response = await request.close();
      final bytes = await response.fold<List<int>>([], (buffer, chunk) => buffer..addAll(chunk));
      expect(bytes, sources[codec],
          reason: 'Styles, font references, events and effect tags must arrive byte-for-byte');
      final oldRequest = await client.getUrl(Uri.parse(original.replaceFirst('/Stream.vtt', '/Stream.$codec')));
      final oldResponse = await oldRequest.close();
      final oldBytes = await oldResponse.fold<List<int>>([], (buffer, chunk) => buffer..addAll(chunk));
      expect(oldBytes, isNot(sources[codec]), reason: '.4 changed the path but the format query still took precedence');
    }
  });
}
