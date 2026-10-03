import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fladder/util/update_checker.dart';
import 'package:fladder/util/update_controller.dart';

import 'jms_update_test.dart' show manifest, source;

ReleaseInfo flowRelease(
    {Map<String, dynamic>? metadata,
    String? repository,
    String? url,
    String platform = 'android',
    String notes = 'TEST_ONLY notes'}) {
  final parsed =
      UpdateManifest.parse(metadata ?? manifest(), platform: platform);
  return ReleaseInfo(
      parsed,
      notes,
      DateTime.utc(2026),
      Uri.parse(url ??
          'https://github.com/${source.identity}/releases/download/v6/${parsed.assetName}'),
      repository ?? source.identity);
}

class FlowChecker extends UpdateChecker {
  UpdateCheckResult result;
  FlowChecker(this.result) : super(source: source);
  @override
  Future<UpdateCheckResult> check(UpdateDevice device,
          {bool prerelease = false}) async =>
      result;
}

class FlowBridge extends UpdateBridge {
  UpdateDevice installed =
      const UpdateDevice('com.jim608.jms', 2005, 35, ['arm64-v8a']);
  UpdateTransfer? restored;
  Completer<void>? transfer;
  Completer<bool>? permissionCheck;
  String? downloadFailure;
  String? installFailure;
  UpdatePackageChannel packageChannel = UpdatePackageChannel.unknown;
  int downloads = 0, installs = 0, cancellations = 0;
  @override
  bool get supportsBackgroundDownload => true;
  @override
  Future<UpdateDevice> device() async => installed;
  @override
  Future<UpdateTransfer?> restoreTransfer() async => restored;
  @override
  Future<UpdatePackageChannel> currentPackageChannel() async => packageChannel;
  @override
  Future<void> setAllowed(bool allowed) async {}
  @override
  Future<void> download(ReleaseInfo release) async {
    downloads++;
    if (downloadFailure != null) {
      throw PlatformException(code: downloadFailure!);
    }
    await transfer?.future;
  }

  @override
  Future<void> cancel() async {
    cancellations++;
    if (transfer != null && !transfer!.isCompleted) {
      transfer!.completeError(PlatformException(code: 'cancelled'));
    }
  }

  @override
  Future<bool> canInstall() async =>
      permissionCheck == null ? true : await permissionCheck!.future;
  @override
  Future<void> permission() async {}
  @override
  Future<String> install() async {
    installs++;
    if (installFailure != null) throw PlatformException(code: installFailure!);
    return 'installPending';
  }
}

Future<UpdateController> flowController(
    FlowChecker checker, FlowBridge bridge) async {
  final controller = UpdateController(checker: checker, bridge: bridge);
  await controller.initialize();
  await controller.check();
  return controller;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
      () => SharedPreferences.setMockInitialValues({'jms.update.auto': false}));

  test(
      'an available release or manually assigned downloaded state cannot install',
      () async {
    final bridge = FlowBridge();
    final controller = await flowController(
        FlowChecker(UpdateCheckResult(UpdateStatus.available, flowRelease())),
        bridge);
    controller.status = UpdateStatus.downloaded;
    await controller.install();
    expect(bridge.installs, 0);
    expect(controller.hasVerifiedDownload, false);
    expect(controller.failure, 'notVerified');
    expect((await SharedPreferences.getInstance()).getInt('jms.update.pending'),
        isNull);
    controller.dispose();
  });

  test(
      'same asset preserves verified download despite key order and presentation changes',
      () async {
    final checker =
        FlowChecker(UpdateCheckResult(UpdateStatus.available, flowRelease()));
    final bridge = FlowBridge();
    final controller = await flowController(checker, bridge);
    await controller.download();
    final metadata =
        Map<String, dynamic>.fromEntries(manifest().entries.toList().reversed)
          ..['notes'] = 'TEST_ONLY display'
          ..['status'] = 'TEST_ONLY presentation';
    metadata['apk'] = Map<String, dynamic>.fromEntries(
        (metadata['apk'] as Map<String, dynamic>).entries.toList().reversed);
    checker.result = UpdateCheckResult(UpdateStatus.available,
        flowRelease(metadata: metadata, notes: 'TEST_ONLY updated notes'));
    await controller.check();
    expect(controller.hasVerifiedDownload, true);
    expect(controller.status, UpdateStatus.downloaded);
    expect(controller.latestRelease!.changelog, 'TEST_ONLY updated notes');
    await controller.install();
    expect(bridge.downloads, 1);
    expect(bridge.installs, 1);
    expect((await SharedPreferences.getInstance()).getInt('jms.update.pending'),
        2006);
    controller.dispose();
  });

  for (final fault in [
    UpdateStatus.network,
    UpdateStatus.rateLimited,
    UpdateStatus.sourceUnavailable
  ]) {
    test(
        '$fault preserves verified local installer with an explicit check warning',
        () async {
      final release = flowRelease();
      final checker =
          FlowChecker(UpdateCheckResult(UpdateStatus.available, release));
      final bridge = FlowBridge();
      final controller = await flowController(checker, bridge);
      await controller.download();
      checker.result = UpdateCheckResult(fault);
      await controller.check();
      expect(controller.latestRelease, same(release));
      expect(controller.hasVerifiedDownload, true);
      expect(controller.checkWarning, fault);
      await controller.install();
      expect(bridge.installs, 1);
      controller.dispose();
    });
  }

  for (final change in [
    'sha256',
    'size',
    'versionCode',
    'url',
    'repository',
    'architecture',
    'platform',
    'sourceCommit',
    'buildId',
    'applicationId',
    'minSdk',
    'signing',
    'certificateSha256',
    'sourceArchive',
  ]) {
    test(
        'changing $change invalidates the exact verified asset and pending version',
        () async {
      final checker =
          FlowChecker(UpdateCheckResult(UpdateStatus.available, flowRelease()));
      final bridge = FlowBridge();
      final controller = await flowController(checker, bridge);
      await controller.download();
      final metadata = manifest(code: change == 'versionCode' ? 2007 : 2006);
      if (change == 'sha256') (metadata['apk'] as Map)['sha256'] = 'd' * 64;
      if (change == 'size') (metadata['apk'] as Map)['size'] = 101;
      if (change == 'sourceCommit') metadata['sourceCommit'] = 'e' * 40;
      if (change == 'buildId') {
        metadata['buildId'] = 'JMS-0.11.1-jms.6-abcdef123456';
      }
      if (change == 'minSdk') metadata['minSdk'] = 25;
      if (change == 'signing') metadata['signing'] = 'TEST_ONLY_SIGNING';
      if (change == 'certificateSha256') {
        metadata['certificateSha256'] = 'e' * 64;
      }
      if (change == 'sourceArchive') {
        (metadata['source'] as Map)['sha256'] = 'e' * 64;
      }
      final changed = flowRelease(
          metadata: metadata,
          repository: change == 'repository' ? 'fixture-owner/other' : null,
          url: change == 'url'
              ? 'https://github.com/${source.identity}/releases/download/v7/JMS.apk'
              : null);
      // A parsed manifest must also remain bound if its public map is modified later.
      if (change == 'architecture') changed.manifest.json['abis'] = ['x86_64'];
      if (change == 'platform') {
        changed.manifest.json['platform'] = 'windows-x64';
      }
      if (change == 'applicationId') {
        changed.manifest.json['applicationId'] = 'com.example.invalid';
      }
      checker.result = UpdateCheckResult(UpdateStatus.available, changed);
      await controller.check();
      expect(controller.hasVerifiedDownload, false);
      await controller.install();
      expect(bridge.installs, 0);
      expect(controller.failure, 'notVerified');
      expect(
          (await SharedPreferences.getInstance()).getInt('jms.update.pending'),
          isNull);
      controller.dispose();
    });
  }

  test('switching release channels invalidates even an identical installer',
      () async {
    final release = flowRelease();
    final checker =
        FlowChecker(UpdateCheckResult(UpdateStatus.available, release));
    final bridge = FlowBridge();
    final controller = await flowController(checker, bridge);
    await controller.download();
    await controller.setPrerelease(true);
    await controller.check();
    expect(controller.hasVerifiedDownload, false);
    await controller.install();
    expect(bridge.installs, 0);
    controller.dispose();
  });

  test('a definitive missing or invalid release invalidates local readiness',
      () async {
    for (final status in [
      UpdateStatus.noRelease,
      UpdateStatus.incomplete,
      UpdateStatus.incompatible
    ]) {
      final checker =
          FlowChecker(UpdateCheckResult(UpdateStatus.available, flowRelease()));
      final controller = await flowController(checker, FlowBridge());
      await controller.download();
      checker.result = UpdateCheckResult(status);
      await controller.check();
      expect(controller.hasVerifiedDownload, false);
      expect(controller.latestRelease, isNull);
      controller.dispose();
    }
  });

  test(
      'known stable native downloaded restore grants readiness but a failed transfer does not',
      () async {
    SharedPreferences.setMockInitialValues({
      'jms.update.auto': false,
      'jms.update.transferChannel': false,
    });
    for (final status in [
      UpdateStatus.downloaded,
      UpdateStatus.downloadFailed
    ]) {
      final bridge = FlowBridge()
        ..restored = UpdateTransfer(flowRelease(), status);
      final controller = UpdateController(
          checker: FlowChecker(const UpdateCheckResult(UpdateStatus.noRelease)),
          bridge: bridge);
      await controller.initialize();
      expect(controller.hasVerifiedDownload, status == UpdateStatus.downloaded);
      await controller.install();
      expect(bridge.installs, status == UpdateStatus.downloaded ? 1 : 0);
      controller.dispose();
    }
  });

  test(
      'a current feed preserves a verified restore with native transport metadata',
      () async {
    SharedPreferences.setMockInitialValues({
      'jms.update.auto': false,
      'jms.update.transferChannel': false,
    });
    final feedRelease = flowRelease();
    final nativeMetadata = manifest()
      ..['url'] = feedRelease.apkUrl.toString()
      ..['repository'] = feedRelease.repository;
    final bridge = FlowBridge()
      ..restored = UpdateTransfer(
          flowRelease(metadata: nativeMetadata), UpdateStatus.downloaded);
    final controller = UpdateController(
        checker:
            FlowChecker(UpdateCheckResult(UpdateStatus.available, feedRelease)),
        bridge: bridge);
    await controller.initialize();
    expect(controller.hasVerifiedDownload, true);
    await controller.check();
    expect(controller.hasVerifiedDownload, true);
    expect(controller.status, UpdateStatus.downloaded);
    expect(bridge.downloads, 0);
    controller.dispose();
  });

  test('unknown legacy transfer channel never grants stable-channel readiness',
      () async {
    final bridge = FlowBridge()
      ..restored = UpdateTransfer(flowRelease(), UpdateStatus.downloaded);
    final controller = UpdateController(
        checker: FlowChecker(const UpdateCheckResult(UpdateStatus.noRelease)),
        bridge: bridge);
    await controller.initialize();
    expect(controller.prerelease, false);
    expect(controller.latestRelease, isNull);
    expect(controller.hasVerifiedDownload, false);
    expect(bridge.installs, 0);
    controller.dispose();
  });

  test('explicit testing channel can restore the legacy native transfer',
      () async {
    SharedPreferences.setMockInitialValues({
      'jms.update.auto': false,
      'jms.update.prerelease': true,
    });
    final bridge = FlowBridge()
      ..restored = UpdateTransfer(flowRelease(), UpdateStatus.downloaded);
    final controller = UpdateController(
        checker: FlowChecker(const UpdateCheckResult(UpdateStatus.noRelease)),
        bridge: bridge);
    await controller.initialize();
    expect(controller.hasVerifiedDownload, true);
    expect(bridge.installs, 0);
    controller.dispose();
  });

  test('restart never restores a download selected on a different channel',
      () async {
    SharedPreferences.setMockInitialValues({
      'jms.update.auto': false,
      'jms.update.transferChannel': true,
      'jms.update.prerelease': false
    });
    final bridge = FlowBridge()
      ..restored = UpdateTransfer(flowRelease(), UpdateStatus.downloaded);
    final controller = UpdateController(
        checker: FlowChecker(const UpdateCheckResult(UpdateStatus.noRelease)),
        bridge: bridge);
    await controller.initialize();
    expect(controller.latestRelease, isNull);
    expect(controller.hasVerifiedDownload, false);
    controller.dispose();
  });

  test('failed hash or native revalidation never leaves an installable binding',
      () async {
    final bridge = FlowBridge()..downloadFailure = 'hash';
    final controller = await flowController(
        FlowChecker(UpdateCheckResult(UpdateStatus.available, flowRelease())),
        bridge);
    await controller.download();
    await controller.install();
    expect(bridge.installs, 0);
    bridge.downloadFailure = null;
    await controller.download();
    bridge.installFailure = 'hash';
    await controller.install();
    expect(controller.hasVerifiedDownload, false);
    await controller.install();
    expect(bridge.installs, 1);
    controller.dispose();
  });

  test(
      'selection changes during permission checks cannot launch another version',
      () async {
    final bridge = FlowBridge()..permissionCheck = Completer<bool>();
    final controller = await flowController(
        FlowChecker(UpdateCheckResult(UpdateStatus.available, flowRelease())),
        bridge);
    await controller.download();
    final install = controller.install();
    controller.latestRelease = flowRelease(metadata: manifest(code: 2007));
    bridge.permissionCheck!.complete(true);
    await install;
    expect(bridge.installs, 0);
    expect((await SharedPreferences.getInstance()).getInt('jms.update.pending'),
        isNull);
    controller.dispose();
  });

  test('in-place manifest changes cannot rebind a completing transfer',
      () async {
    final bridge = FlowBridge()..transfer = Completer<void>();
    final release = flowRelease();
    final controller = await flowController(
        FlowChecker(UpdateCheckResult(UpdateStatus.available, release)),
        bridge);
    final transfer = controller.download();
    release.manifest.json['versionCode'] = 2007;
    bridge.transfer!.complete();
    await transfer;
    expect(controller.hasVerifiedDownload, false);
    expect(controller.status, UpdateStatus.downloadFailed);
    expect(controller.busy, false);
    await controller.install();
    expect(bridge.installs, 0);
    expect((await SharedPreferences.getInstance()).getInt('jms.update.pending'),
        isNull);
    controller.dispose();
  });

  test('leaving foreground while awaiting permission never opens an installer',
      () async {
    final bridge = FlowBridge()..permissionCheck = Completer<bool>();
    final controller = await flowController(
        FlowChecker(UpdateCheckResult(UpdateStatus.available, flowRelease())),
        bridge);
    await controller.download();
    final install = controller.install();
    controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    bridge.permissionCheck!.complete(true);
    await install;
    expect(bridge.installs, 0);
    expect(controller.hasVerifiedDownload, true);
    expect((await SharedPreferences.getInstance()).getInt('jms.update.pending'),
        isNull);
    controller.dispose();
  });

  test(
      'confirmation for an older asset cannot install a newer verified download',
      () async {
    final old = flowRelease();
    final checker = FlowChecker(UpdateCheckResult(UpdateStatus.available, old));
    final bridge = FlowBridge();
    final controller = await flowController(checker, bridge);
    await controller.download();
    checker.result = UpdateCheckResult(
        UpdateStatus.available, flowRelease(metadata: manifest(code: 2007)));
    await controller.check();
    await controller.download();
    await controller.install(expectedRelease: old);
    expect(bridge.installs, 0);
    controller.dispose();
  });

  for (final channel in [
    UpdatePackageChannel.community,
    UpdatePackageChannel.official
  ]) {
    test('Linux $channel never silently switches a community package',
        () async {
      final metadata = {
        'schemaVersion': 1,
        'applicationId': 'com.jim608.jms',
        'platform': 'linux-x64',
        'versionName': '0.11.1-jms.19',
        'versionCode': 21,
        'minGlibcMinor': 36,
        'packageVersion': '0.11.1_jms.19-21',
        'packageFormat': 'arch',
        'signing': 'unsigned',
        'sourceCommit': 'a' * 40,
        'installer': {
          'name': 'JMS-Linux-0.11.1-jms.19-x86_64.pkg.tar.xz',
          'size': 100,
          'sha256': 'b' * 64
        },
        'source': {'name': 'JMS-source.zip', 'size': 200, 'sha256': 'c' * 64},
      };
      final bridge = FlowBridge()
        ..installed = const UpdateDevice('com.jim608.jms', 20, 36, ['x86_64'],
            platform: 'linux-x64')
        ..packageChannel = channel;
      final controller = await flowController(
          FlowChecker(UpdateCheckResult(UpdateStatus.available,
              flowRelease(metadata: metadata, platform: 'linux-x64'))),
          bridge);
      await controller.download();
      await controller.install();
      expect(bridge.installs, channel == UpdatePackageChannel.official ? 1 : 0);
      if (channel == UpdatePackageChannel.community) {
        expect(controller.failure, 'packageChannel');
        expect(
            (await SharedPreferences.getInstance())
                .getInt('jms.update.pending'),
            isNull);
      }
      controller.dispose();
    });
  }
}
