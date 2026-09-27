import 'dart:convert';
import 'dart:io';

import 'package:fladder/util/subtitle_delivery.dart';

Future<void> main(List<String> arguments) async {
  final path = arguments.single;
  final source = await File(path).readAsBytes();
  final text = utf8.decode(source);
  final dialogues = const LineSplitter().convert(text).where((line) => line.startsWith('Dialogue:')).toList();
  final tags = <String, int>{};
  for (final line in dialogues) {
    for (final match in RegExp(r'\\(pos|move|fad|t|i?clip|p|k[fo]?)(?=[(\d])').allMatches(line)) {
      final tag = match.group(1)!;
      tags[tag] = (tags[tag] ?? 0) + 1;
    }
  }
  if (dialogues.isEmpty || !RegExp(r'[\u4e00-\u9fff]').hasMatch(dialogues.join()) || tags.length < 4) {
    throw StateError('Expected a Chinese ASS sample with several real dialogue effect tags');
  }
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final client = HttpClient();
  try {
    server.listen((request) async {
      final format = request.uri.queryParameters['format'] ?? request.uri.path.split('.').last;
      request.response.add(format == 'ass' ? source : utf8.encode('WEBVTT\n\n00:00.000 --> 00:01.000\nplain\n'));
      await request.response.close();
    });
    final url = 'http://127.0.0.1:${server.port}/Videos/test/source/Subtitles/3/Stream.vtt?format=vtt';
    final response = await (await client.getUrl(Uri.parse(subtitleDeliveryUrl(url, 'ass')!))).close();
    final received = await response.fold<List<int>>([], (buffer, chunk) => buffer..addAll(chunk));
    if (received.length != source.length ||
        Iterable<int>.generate(source.length).any((index) => received[index] != source[index])) {
      throw StateError('ASS source changed during delivery');
    }
    final report = {
      'status': 'PASS',
      'source_bytes': source.length,
      'dialogue_events': dialogues.length,
      'dialogue_effect_tags': tags,
      'delivery_bytes_identical': true,
      'source':
          'https://github.com/KyokuSai/ASSFun/blob/036a3e5ef3ff60d412647a6bf960a672f4f1a342/%5BKyokuSai%5D%20sample%20%5BCHS_JPN%5D.kawaii.ass',
      'license': 'No explicit license; local evaluation only; sample/renderings are not redistributed',
      'test_boundary':
          'Loopback fixture reproduces format-query precedence; not a running Jellyfin server or Android renderer',
    };
    await File('artifacts/checks/public-ass-m8.json').writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    stdout.writeln(jsonEncode(report));
  } finally {
    client.close(force: true);
    await server.close(force: true);
  }
}
