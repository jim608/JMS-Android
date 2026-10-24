import 'dart:io';
import 'dart:isolate';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

Future<Map<String, String>> _probeWorkerNamespace(
    Map<String, String> message, String fakeValue) async {
  DesktopDirectoryPaths.fromMessage(message).installForCurrentIsolate();
  final download = DownloadTask(
    taskId: 'SYNTHETIC_TASK',
    url: 'https://download.example.invalid/unused',
    filename: 'fixture.fake',
    directory: 'probe',
  );
  final upload = UploadTask(
    url: 'https://upload.example.invalid/unused',
    filename: 'fixture.fake',
    directory: 'probe',
    baseDirectory: BaseDirectory.applicationSupport,
  );
  final changedTask = download.copyWith(
    filename: 'changed.fake',
    baseDirectory: BaseDirectory.applicationLibrary,
  );
  final temporary = await getTemporaryDirectory();
  final support = await getApplicationSupportDirectory();
  final fakeFile = File(p.join(temporary.path, 'fixture.fake'));
  await fakeFile.writeAsString(fakeValue, flush: true);

  // Exercise the same worker-side local store used by callbacks. Its metadata
  // and the fake resume record must both remain in the supplied support path.
  final store = LocalStorePersistentStorage();
  await store.initialize();
  await store.storeResumeData(ResumeData(download, fakeFile.path, 1, 'FAKE_ETAG'));
  final record = await store.retrieveResumeData(download.taskId);
  await store.retrieveAllResumeData();
  return {
    'download': await download.filePath(),
    'upload': await upload.filePath(),
    'changedTask': await changedTask.filePath(),
    'temporary': temporary.path,
    'support': support.path,
    'cache': (await getApplicationCacheDirectory()).path,
    'downloads': (await getDownloadsDirectory())!.path,
    'resumeFile': record!.tempFilepath,
    'fakeValue': await fakeFile.readAsString(),
  };
}

Future<Map<String, String>> _runWorkerProbe(
        Map<String, String> message, String fakeValue) async =>
    (await _runFixtureWorker(message, fakeValue, false)) as Map<String, String>;

Future<String> _foreignResumeWorker(
    Map<String, String> message, String foreignFakePath) async {
  DesktopDirectoryPaths.fromMessage(message).installForCurrentIsolate();
  final task = DownloadTask(
    taskId: 'FOREIGN_SYNTHETIC_TASK',
    url: 'https://download.example.invalid/unused',
    filename: 'fixture.fake',
  );
  final store = LocalStorePersistentStorage();
  await store.initialize();
  await store.storeResumeData(ResumeData(task, foreignFakePath, 1, 'FAKE_ETAG'));
  // Await a concrete disk read/close before exercising the rejecting getter.
  await store.retrieveAllResumeData();
  return (await store.retrieveResumeData(task.taskId))!.tempFilepath;
}

Future<String> _runForeignResumeProbe(
        Map<String, String> message, String foreignFakePath) async =>
    (await _runFixtureWorker(message, foreignFakePath, true)) as String;

Future<void> _fixtureWorkerEntry(
    (Map<String, String>, String, bool, SendPort) request) async {
  final (message, payload, foreignResume, reply) = request;
  try {
    final result = foreignResume
        ? await _foreignResumeWorker(message, payload)
        : await _probeWorkerNamespace(message, payload);
    reply.send((true, result, null));
  } catch (error, stack) {
    reply.send((false, error, stack.toString()));
  }
  // Return normally so Localstore's unawaited stream-close microtasks can drain.
  // Isolate.run would force Isolate.exit as soon as its computation completes.
}

Future<Object?> _runFixtureWorker(
    Map<String, String> message, String payload, bool foreignResume) async {
  final replies = ReceivePort();
  final exits = ReceivePort();
  final response = replies.first;
  final exited = exits.first;
  try {
    await Isolate.spawn(_fixtureWorkerEntry,
        (message, payload, foreignResume, replies.sendPort),
        onError: replies.sendPort, onExit: exits.sendPort);
    final result = await response;
    // Await real worker shutdown before deleting any owned fixture directory.
    await exited;
    if (result case (bool success, Object? value, String? stack)) {
      if (success) return value;
      Error.throwWithStackTrace(value!, StackTrace.fromString(stack!));
    }
    throw StateError('Unexpected fixture worker failure: $result');
  } finally {
    replies.close();
    exits.close();
  }
}

class _NoHostPaths extends PathProviderPlatform {
  var calls = 0;

  Future<String?> _reject() async {
    calls++;
    throw StateError('No host directory may be resolved in this fixture');
  }

  @override
  Future<String?> getTemporaryPath() => _reject();

  @override
  Future<String?> getApplicationSupportPath() => _reject();

  @override
  Future<String?> getApplicationDocumentsPath() => _reject();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory fixtureBase;
  late Directory fixture;
  late PathProviderPlatform originalProvider;

  setUp(() async {
    originalProvider = PathProviderPlatform.instance;
    fixtureBase = Directory(
        p.join(Directory.current.path, 'build', 'windows-downloader-fixtures'));
    await fixtureBase.create(recursive: true);
    fixture = await fixtureBase.createTemp('synthetic-');
  });

  tearDown(() async {
    PathProviderPlatform.instance = originalProvider;
    FileDownloader.setDesktopDirectoryPaths(null);
    final basePath = await fixtureBase.resolveSymbolicLinks();
    final fixturePath = await fixture.resolveSymbolicLinks();
    if (!p.isWithin(basePath, fixturePath)) {
      throw StateError('Fixture cleanup escaped its dedicated workspace folder');
    }
    await fixture.delete(recursive: true);
  });

  Future<DesktopDirectoryPaths> namespace(String name) async {
    final root = Directory(p.join(fixture.path, name));
    final paths = DesktopDirectoryPaths(
      temporary: p.join(root.path, 'temp'),
      applicationSupport: p.join(root.path, 'support'),
      documents: p.join(root.path, 'documents'),
      applicationCache: p.join(root.path, 'cache'),
      library: p.join(root.path, 'support', 'Library'),
      downloads: p.join(root.path, 'downloads'),
    );
    for (final directory in paths.toMessage().values) {
      await Directory(directory).create(recursive: true);
    }
    return paths;
  }

  test('configuring worker directories does not initialize a default store',
      () async {
    final paths = await namespace('only-synthetic');
    final rejectingProvider = _NoHostPaths();
    PathProviderPlatform.instance = rejectingProvider;
    FileDownloader.setDesktopDirectoryPaths(paths);
    expect(rejectingProvider.calls, 0);
    FileDownloader.setDesktopDirectoryPaths(null);
    expect(rejectingProvider.calls, 0);
  });

  test('separate worker isolates keep paths and fake local stores per profile',
      () async {
    final first = await namespace('profile-a');
    final second = await namespace('profile-b');
    final firstResult =
        await _runWorkerProbe(first.toMessage(), 'FAKE_PROFILE_A');
    final secondResult =
        await _runWorkerProbe(second.toMessage(), 'FAKE_PROFILE_B');
    for (final entry in [
      (first, firstResult, 'FAKE_PROFILE_A'),
      (second, secondResult, 'FAKE_PROFILE_B'),
    ]) {
      final (paths, result, fakeValue) = entry;
      expect(result['download'],
          p.join(paths.documents, 'probe', 'fixture.fake'));
      expect(result['upload'],
          p.join(paths.applicationSupport, 'probe', 'fixture.fake'));
      expect(result['changedTask'],
          p.join(paths.applicationSupport, 'Library', 'probe', 'changed.fake'));
      expect(result['temporary'], paths.temporary);
      expect(result['support'], paths.applicationSupport);
      expect(result['cache'], paths.applicationCache);
      expect(result['downloads'], paths.downloads);
      expect(result['resumeFile'], p.join(paths.temporary, 'fixture.fake'));
      expect(result['fakeValue'], fakeValue);
      expect(await File(p.join(paths.temporary, 'fixture.fake')).readAsString(),
          fakeValue);
      expect(await Directory(paths.applicationSupport).list().isEmpty, isFalse);
    }
  });

  test('relative worker namespace is rejected without a platform fallback',
      () async {
    final paths = await namespace('valid');
    final invalid = paths.toMessage()..['temporary'] = 'relative-temp';
    expect(() => DesktopDirectoryPaths.fromMessage(invalid), throwsArgumentError);
  });

  test('foreign task and persisted resume paths are rejected before file access',
      () async {
    final first = await namespace('profile-a');
    final second = await namespace('profile-b');
    first.installForCurrentIsolate();
    final foreignFile = File(p.join(second.temporary, 'foreign.fake'));
    await foreignFile.writeAsString('FAKE_PROFILE_B_UNCHANGED', flush: true);
    final foreignTask = DownloadTask(
      url: 'https://download.example.invalid/unused',
      filename: 'foreign.fake',
      directory: second.temporary,
      baseDirectory: BaseDirectory.root,
    );
    await expectLater(foreignTask.filePath(), throwsArgumentError);
    await expectLater(
        _runForeignResumeProbe(first.toMessage(), foreignFile.path),
        throwsArgumentError);
    expect(await foreignFile.readAsString(), 'FAKE_PROFILE_B_UNCHANGED');
  });
}
