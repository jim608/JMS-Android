import 'dart:io';
import 'dart:isolate';

import 'package:background_downloader/background_downloader.dart';
import 'package:background_downloader/src/desktop/desktop_downloader.dart';
import 'package:background_downloader/src/desktop/download_isolate.dart';
import 'package:background_downloader/src/desktop/isolate.dart' as worker;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logging/logging.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.temporary);
  final String temporary;

  @override
  Future<String?> getTemporaryPath() async => temporary;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const url = 'https://downloads.example.invalid/video?api_key=fixture-query';
  const auth = 'fixture-header';
  final records = <String>[];

  setUp(() {
    final oldLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    records.clear();
    final events =
        Logger.root.onRecord.listen((record) => records.add(record.message));
    addTearDown(() async {
      await events.cancel();
      Logger.root.level = oldLevel;
    });
  });

  test('invalid download URL is rejected without logging the request',
      () async {
    final task = DownloadTask(
        taskId: 'invalid-episode',
        url: '$url%',
        headers: {'authorization': auth});
    final backend = DesktopDownloader();
    expect(await backend.enqueue(task), isFalse);
    expect((await backend.enqueueAndAwait(task)).status, TaskStatus.failed);
    expect(records.join('\n'), contains(task.taskId));
    expect(records.join('\n'), isNot(contains('fixture-query')));
    expect(records.join('\n'), isNot(contains(auth)));
  });

  test(
      'transfer reports the original exception but records only safe diagnostics',
      () async {
    final directory = await Directory.systemTemp.createTemp('jms-worker-log-');
    final paths = PathProviderPlatform.instance;
    final client = DesktopDownloader.httpClient;
    final port = ReceivePort();
    addTearDown(() async {
      port.close();
      PathProviderPlatform.instance = paths;
      DesktopDownloader.httpClient = client;
      await directory.delete(recursive: true);
    });
    PathProviderPlatform.instance = _Paths(directory.path);
    final task = DownloadTask(
      taskId: 'transfer-episode',
      url: url,
      headers: {'authorization': auth},
      baseDirectory: BaseDirectory.root,
      directory: directory.path,
      filename: 'video.bin',
    );
    final error =
        http.ClientException('fixture error for $auth', Uri.parse(url));
    DesktopDownloader.httpClient = MockClient((request) async {
      expect(request.headers['authorization'], auth);
      expect(request.url.toString(), url);
      throw error;
    });
    await doDownloadTask(
        task, null, false, const Duration(seconds: 1), port.sendPort);
    expect(worker.taskException?.description, error.toString());
    final log = records.join('\n');
    expect(log, contains(task.taskId));
    expect(log, contains('ClientException'));
    expect(log, isNot(contains('fixture-query')));
    expect(log, isNot(contains(auth)));
  });

  test(
      'unreadable error body and malformed resume header log only operation details',
      () async {
    final failure =
        http.ClientException('fixture error for $auth', Uri.parse(url));
    final unreadable =
        http.StreamedResponse(Stream<List<int>>.error(failure), 503);
    await expectLater(
        worker.responseContent(unreadable), throwsA(same(failure)));
    final partial = http.StreamedResponse(const Stream.empty(), 206,
        headers: {'content-range': url});
    expect(await prepareResume(partial, ''), isFalse);
    expect(worker.taskException?.description, contains(url));
    final log = records.join('\n');
    expect(log, contains('Content-Range'));
    expect(log, isNot(contains('fixture-query')));
    expect(log, isNot(contains(auth)));
  });
}
