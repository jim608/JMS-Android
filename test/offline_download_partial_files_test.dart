import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:fladder/models/account_model.dart';
import 'package:fladder/providers/connectivity_provider.dart';
import 'package:fladder/providers/sync/background_download_provider.dart';
import 'package:fladder/providers/sync_provider.dart';
import 'package:fladder/providers/user_provider.dart';

class _DownloadPaths extends PathProviderPlatform {
  _DownloadPaths(this.directory);
  final Directory directory;
  int tempRequests = 0;

  @override
  Future<String?> getTemporaryPath() async {
    tempRequests++;
    return directory.path;
  }

  @override
  Future<String?> getApplicationSupportPath() async => directory.path;
}

class _SignedOut extends User {
  @override
  AccountModel? build() => null;
}

class _Offline extends ConnectivityStatus {
  @override
  ConnectionState build() => ConnectionState.offline;
}

class _Sync extends SyncNotifier {
  _Sync(super.ref, super.mobileDirectory);

  @override
  Future<void> updateSyncStates() async {}
}

class _FileDownloader extends Fake implements FileDownloader {}

class _Downloader extends BackgroundDownloader {
  @override
  FileDownloader build() => _FileDownloader();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'startup and other tasks finishing preserve paused and unowned downloads',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('jms-partial-files-');
    addTearDown(() => directory.delete(recursive: true));
    final originalPaths = PathProviderPlatform.instance;
    final paths = _DownloadPaths(directory);
    PathProviderPlatform.instance = paths;
    addTearDown(() => PathProviderPlatform.instance = originalPaths);
    final partial =
        File('${directory.path}/com.bbflight.background_downloader147');
    final unowned =
        File('${directory.path}/com.bbflight.background_downloader148');
    await partial.writeAsBytes([1, 2, 3]);
    await unowned.writeAsBytes([4, 5]);

    final container = ProviderContainer(overrides: [
      syncProvider.overrideWith((ref) => _Sync(ref, directory)),
      userProvider.overrideWith(_SignedOut.new),
      connectivityStatusProvider.overrideWith(_Offline.new),
      backgroundDownloaderProvider.overrideWith(_Downloader.new),
    ]);
    addTearDown(container.dispose);
    container.read(syncProvider);
    final downloader = container.read(backgroundDownloaderProvider.notifier);
    for (final status in [TaskStatus.complete, TaskStatus.canceled]) {
      final task = DownloadTask(
          url: 'https://download.example.invalid/${status.name}',
          taskId: status.name);
      downloader.updateTask(TaskStatusUpdate(task, status));
    }

    expect(paths.tempRequests, 0);
    expect(await partial.readAsBytes(), [1, 2, 3]);
    expect(await unowned.readAsBytes(), [4, 5]);
  });
}
