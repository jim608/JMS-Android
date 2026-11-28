import 'dart:async';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/models/syncing/download_stream.dart';
import 'package:fladder/providers/sync/background_download_provider.dart';
import 'package:fladder/providers/sync_provider.dart';

class _Backend extends Fake implements FileDownloader {
  Future<bool> Function(Task) accept = (_) async => true;

  @override
  Future<bool> enqueue(Task task) => accept(task);
}

class _Downloader extends BackgroundDownloader {
  _Downloader(this.backend);
  final _Backend backend;

  @override
  FileDownloader build() => backend;
}

void main() {
  late _Backend backend;
  late ProviderContainer container;
  late BackgroundDownloader downloads;
  final task = DownloadTask(
    taskId: 'episode',
    url: 'https://media.example.invalid/video',
    metaData: 'first-attempt',
  );
  final other = task.copyWith(taskId: 'another-episode');
  List<DownloadTask> active() => container.read(activeDownloadTasksProvider);
  DownloadStream details() =>
      container.read(downloadTasksProvider(task.taskId));

  setUp(() {
    backend = _Backend();
    container = ProviderContainer(overrides: [
      backgroundDownloaderProvider.overrideWith(() => _Downloader(backend)),
    ]);
    addTearDown(container.dispose);
    downloads = container.read(backgroundDownloaderProvider.notifier);
  });

  for (final status in [TaskStatus.failed, TaskStatus.notFound]) {
    test('$status keeps its reason and removes only the finished task',
        () async {
      await downloads.enqueueDownload(other);
      await downloads.enqueueDownload(task);
      downloads.updateTask(TaskStatusUpdate(task, TaskStatus.waitingToRetry));
      expect(active(), [other, task]);
      downloads.updateTask(TaskProgressUpdate(task, 0.4));
      downloads.updateTask(TaskStatusUpdate(task, status));
      expect(active(), [other]);
      expect(details().status, status);
      expect(details().hasDownload, isFalse);
    });
  }

  test('rejected and throwing enqueues both leave the active count at zero',
      () async {
    backend.accept = (_) async => false;
    expect(await downloads.enqueueDownload(task), isFalse);
    expect(active(), isEmpty);
    expect(details().status, TaskStatus.failed);
    backend.accept = (_) async => throw StateError('enqueue rejected');
    await expectLater(downloads.enqueueDownload(task), throwsStateError);
    expect(active(), isEmpty);
    expect(details().status, TaskStatus.failed);
  });

  test(
      'late rejection and callbacks cannot retire a replacement for the same item',
      () async {
    final pending = Completer<bool>();
    final replacement = task.copyWith(metaData: 'second-attempt');
    backend.accept = (request) =>
        identical(request, task) ? pending.future : Future.value(true);
    final first = downloads.enqueueDownload(task);
    await downloads.enqueueDownload(replacement);
    downloads.updateTask(TaskStatusUpdate(task, TaskStatus.canceled));
    pending.complete(false);
    expect(await first, isFalse);
    expect(active().single, same(replacement));
    expect(details().status, TaskStatus.enqueued);
  });

  test('late callbacks after replacement completion keep the item settled',
      () async {
    final pending = Completer<bool>();
    final replacement = task.copyWith(metaData: 'replacement');
    backend.accept = (request) =>
        identical(request, task) ? pending.future : Future.value(true);
    final first = downloads.enqueueDownload(task);
    await downloads.enqueueDownload(replacement);
    downloads.updateTask(TaskStatusUpdate(replacement, TaskStatus.complete));
    downloads.updateTask(TaskStatusUpdate(task, TaskStatus.failed));
    pending.complete(false);
    expect(await first, isFalse);
    expect(active(), isEmpty);
    expect(details().task, isNull);
    expect(details().status, DownloadStream.empty().status);
  });
}
