import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'package:background_downloader/background_downloader.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:fladder/models/syncing/download_stream.dart';
import 'package:fladder/providers/settings/client_settings_provider.dart';
import 'package:fladder/providers/sync_provider.dart';
import 'package:fladder/util/localization_helper.dart';
import 'package:fladder/util/jms_test_profile_policy.dart';

part 'background_download_provider.g.dart';

final itemDownloadGroup = "ITEM_DOWNLOAD_GROUP";

@Riverpod(keepAlive: true)
class BackgroundDownloader extends _$BackgroundDownloader {
  late StreamSubscription<TaskUpdate> updateListener;

  @override
  FileDownloader build() {
    ref.onDispose(
      () => updateListener.cancel(),
    );

    final maxDownloads = ref.read(
        clientSettingsProvider.select((value) => value.maxConcurrentDownloads));
    final downloader = FileDownloader()
      ..configure(
        globalConfig: globalConfig(maxDownloads),
        androidConfig: (Config.runInForeground, Config.always),
      )
      ..trackTasks();
    updateListener = downloader.updates.listen(updateTask);
    return downloader;
  }

  Future<bool> enqueueDownload(DownloadTask task) async {
    ref.read(activeDownloadTasksProvider.notifier).update((tasks) => [
          ...tasks.where((other) => other.taskId != task.taskId),
          task,
        ]);
    ref.read(downloadTasksProvider(task.taskId).notifier).state =
        DownloadStream(
            id: task.taskId, task: task, status: TaskStatus.enqueued);
    var accepted = false;
    try {
      accepted = await state.enqueue(task);
      return accepted;
    } finally {
      if (!accepted) updateTask(TaskStatusUpdate(task, TaskStatus.failed));
    }
  }

  void updateTask(TaskUpdate update) {
    final details =
        ref.read(downloadTasksProvider(update.task.taskId).notifier);
    final current = details.state;
    if (current.id == update.task.taskId && current.status.isFinalState) return;
    final tracked = current.task;
    // An item can be enqueued again before its old native callbacks arrive.
    if (tracked != null && tracked.metaData != update.task.metaData) return;
    switch (update) {
      case TaskStatusUpdate():
        final status = update.status;
        details.state =
            status == TaskStatus.complete || status == TaskStatus.canceled
                ? DownloadStream.empty(id: update.task.taskId)
                : details.state.copyWith(status: status);
        if (status.isFinalState) {
          ref.read(activeDownloadTasksProvider.notifier).update((state) => state
              .where((element) => element.taskId != update.task.taskId)
              .toList());
        }
      case TaskProgressUpdate():
        final progress = update.progress;
        details.update(
          (state) => state.copyWith(
            progress: progress > 0 && progress < 1 ? progress : null,
            downloadSpeed: update.networkSpeedAsString,
          ),
        );
    }
  }

  void setMaxConcurrent(int value) {
    state.configure(
      globalConfig: globalConfig(value),
      androidConfig: (Config.runInForeground, Config.always),
    );
  }

  void updateTranslations(BuildContext context) async {
    if (kIsWeb || JmsTestProfilePolicy.enabled) return;
    state.configureNotification(
      running: TaskNotification(
          context.localized.notificationDownloadingDownloading,
          '{filename}\n{networkSpeed}'),
      complete: TaskNotification(
          context.localized.notificationDownloadingFinished, '{filename}'),
      paused: TaskNotification(
          context.localized.notificationDownloadingPaused, '{filename}'),
      error: TaskNotification(
          context.localized.notificationDownloadingError, '{filename}'),
      progressBar: true,
    );
  }

  (String, dynamic) globalConfig(int value) => value == 0
      ? (
          Config.holdingQueue,
          (
            null,
            null,
            null,
          )
        )
      : (
          Config.holdingQueue,
          (
            //maxConcurrent
            value,
            //maxConcurrentByHost
            value,
            //maxConcurrentByGroup
            value,
          ),
        );
}
