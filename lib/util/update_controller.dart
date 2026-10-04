import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fladder/util/update_checker.dart';

enum UpdatePackageChannel { official, community, unknown }

abstract class UpdateBridge {
  bool get isDesktop => false;
  bool get flatpakManaged => false;
  bool get supportsBackgroundDownload => false;
  void Function(double progress)? onProgress;
  Future<UpdateDevice> device();
  Future<void> setAllowed(bool allowed);
  Future<void> cancel();
  Future<void> download(ReleaseInfo release);
  Future<bool> canInstall();
  Future<void> permission();
  Future<String> install();
  Future<UpdateTransfer?> restoreTransfer() async => null;
  Future<UpdatePackageChannel> currentPackageChannel() async =>
      UpdatePackageChannel.unknown;
}

class UpdateTransfer {
  final ReleaseInfo release;
  final UpdateStatus status;
  final double progress;
  final String? failure;
  const UpdateTransfer(this.release, this.status,
      {this.progress = 0, this.failure});
}

class AndroidUpdateBridge extends UpdateBridge {
  static const channel = MethodChannel('com.jim608.jms/updates');
  AndroidUpdateBridge() {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'progress') {
        onProgress?.call((call.arguments as num).toDouble());
      }
    });
  }
  @override
  bool get supportsBackgroundDownload => true;
  @override
  Future<UpdateDevice> device() async =>
      UpdateDevice.fromJson((await channel.invokeMapMethod('device'))!);
  @override
  Future<void> setAllowed(bool allowed) =>
      channel.invokeMethod('allowed', allowed);
  @override
  Future<void> cancel() => channel.invokeMethod('cancel');
  @override
  Future<void> download(ReleaseInfo release) =>
      channel.invokeMethod('download', {
        ...release.manifest.json,
        'url': release.apkUrl.toString(),
        'repository': release.repository,
      });
  @override
  Future<bool> canInstall() async =>
      await channel.invokeMethod<bool>('canInstall') ?? false;
  @override
  Future<void> permission() => channel.invokeMethod('permission');
  @override
  Future<String> install() async =>
      await channel.invokeMethod<String>('install') ?? 'installPending';
  @override
  Future<UpdateTransfer?> restoreTransfer() async {
    final value = await channel.invokeMapMethod<String, dynamic>('restore');
    if (value == null || value['metadata'] is! Map) return null;
    final metadata = Map<String, dynamic>.from(value['metadata'] as Map);
    final manifest = UpdateManifest.parse(metadata);
    final status = switch (value['status']) {
      'downloading' => UpdateStatus.downloading,
      'downloaded' => UpdateStatus.downloaded,
      'failed' => UpdateStatus.downloadFailed,
      'cancelled' => UpdateStatus.cancelled,
      _ => null,
    };
    if (status == null) return null;
    return UpdateTransfer(
      ReleaseInfo(
          manifest,
          '',
          DateTime.fromMillisecondsSinceEpoch(0),
          Uri.parse(metadata['url'] as String),
          metadata['repository'] as String),
      status,
      progress: ((value['progress'] as num?)?.toDouble() ?? 0).clamp(0, 1),
      failure: value['failure'] as String?,
    );
  }
}

class UpdateController extends ChangeNotifier with WidgetsBindingObserver {
  final UpdateChecker checker;
  final UpdateBridge bridge;
  final Future<SharedPreferences> Function() preferences;
  final bool supported;
  SharedPreferences? _prefs;
  UpdateDevice? _device;
  Timer? _timer;
  bool _disposed = false;
  bool _initializing = false;
  bool _observingLifecycle = false;
  bool _checking = false;
  bool _installing = false;
  bool _downloading = false;
  int _generation = 0;
  String? _verifiedAsset;
  bool? _verifiedChannel;
  bool _foreground = true;
  bool playback = false;
  bool automatic = true;
  bool prerelease = false;
  int? skipped;
  bool deferred = false;
  bool ready = false;
  double progress = 0;
  String? failure;
  UpdateStatus? checkWarning;
  UpdateStatus status = UpdateStatus.idle;
  ReleaseInfo? latestRelease;
  String? get platform => _device?.platform;
  bool get busy => _initializing || _checking || _downloading || _installing;
  bool get settingsReady => _prefs != null;
  bool get blocked => playback || !_foreground;
  bool get _transferAllowed =>
      !playback && (_foreground || bridge.supportsBackgroundDownload);
  bool get hasVerifiedDownload =>
      latestRelease != null &&
      _validRelease(latestRelease!) &&
      _verifiedAsset == _assetIdentity(latestRelease!) &&
      _verifiedChannel == prerelease;

  bool _validRelease(ReleaseInfo release) =>
      _device != null &&
      release.repository == checker.source.identity &&
      checker.source.ownsAsset(release.apkUrl) &&
      release.manifest.supports(_device!) &&
      release.apkUrl.pathSegments.last == release.manifest.assetName &&
      release.manifest.versionCode > _device!.versionCode;

  String _assetIdentity(ReleaseInfo release) {
    final manifest = Map<String, dynamic>.from(release.manifest.json)
      ..removeWhere((key, _) => const {
            'changelog',
            'releaseNotes',
            'notes',
            'status',
            'publishedAt',
            'published_at',
            // Native restore includes these transport fields; they are bound above.
            'url',
            'repository',
          }.contains(key));
    return jsonEncode([
      release.repository,
      release.apkUrl.toString(),
      _canonicalValue(manifest),
    ]);
  }

  Object? _canonicalValue(Object? value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: _canonicalValue(value[key])};
    }
    if (value is List) return value.map(_canonicalValue).toList();
    return value;
  }

  void _invalidateDownload() {
    _verifiedAsset = null;
    _verifiedChannel = null;
    checkWarning = null;
  }

  bool _current(int generation, String identity) =>
      !_disposed &&
      generation == _generation &&
      latestRelease != null &&
      _validRelease(latestRelease!) &&
      _assetIdentity(latestRelease!) == identity;
  bool get hasNewUpdate =>
      !blocked &&
      !deferred &&
      latestRelease != null &&
      skipped != latestRelease!.manifest.versionCode;

  UpdateController(
      {required this.checker,
      required this.bridge,
      this.preferences = SharedPreferences.getInstance,
      bool supported = true})
      : supported = supported && !bridge.flatpakManaged {
    status = !this.supported
        ? UpdateStatus.unsupported
        : checker.source.configured
            ? UpdateStatus.idle
            : UpdateStatus.unconfigured;
    bridge.onProgress = (value) {
      if (_disposed || !_downloading || !value.isFinite) return;
      progress = value.clamp(0, 1);
      _notify();
    };
  }

  Future<void> initialize() async {
    if (!supported || _disposed || ready || _initializing) return;
    _initializing = true;
    failure = null;
    status = UpdateStatus.checking;
    if (!_observingLifecycle) {
      WidgetsBinding.instance.addObserver(this);
      _observingLifecycle = true;
    }
    _notify();
    var initializationFailure = 'initializationPreferences';
    try {
      _prefs ??= await preferences();
      if (_disposed) return;
      automatic = _prefs!.getBool('jms.update.auto') ?? automatic;
      prerelease = _prefs!.getBool('jms.update.prerelease') ?? false;
      skipped = _prefs!.getInt('jms.update.skipped');
      try {
        final cached =
            jsonDecode(_prefs!.getString('jms.update.cache') ?? '{}');
        if (cached is Map<String, dynamic>) checker.cache.addAll(cached);
      } catch (_) {
        checker.cache.clear();
      }
      final retry = _prefs!.getInt('jms.update.retryAfter');
      if (retry != null) {
        checker.retryAfter = DateTime.fromMillisecondsSinceEpoch(retry);
      }
      initializationFailure = 'initializationDevice';
      _device = await bridge.device();
      if (_disposed) return;
      initializationFailure = 'initializationBridge';
      await bridge.setAllowed(_transferAllowed);
      if (_disposed) return;
      initializationFailure = 'initializationPreferences';
      status = checker.source.configured
          ? UpdateStatus.idle
          : UpdateStatus.unconfigured;
      final pending = _prefs!.getInt('jms.update.pending');
      if (pending != null && _device!.versionCode >= pending) {
        status = UpdateStatus.updated;
        await _prefs!.remove('jms.update.pending');
      } else if (pending != null) {
        status = UpdateStatus.installPending;
      }
      try {
        final transfer = await bridge.restoreTransfer();
        if (_disposed) return;
        final transferChannel = _prefs!.getBool('jms.update.transferChannel');
        if (transfer != null &&
            _validRelease(transfer.release) &&
            (transferChannel == null
                ? prerelease
                : transferChannel == prerelease)) {
          latestRelease = transfer.release;
          status = transfer.status;
          progress = transfer.progress;
          failure = transfer.failure;
          if (status == UpdateStatus.downloading) {
            _downloading = true;
            unawaited(_completeDownload(transfer.release, ++_generation));
          } else if (status == UpdateStatus.downloaded) {
            // Installation still revalidates the restored file natively.
            _verifiedAsset = _assetIdentity(transfer.release);
            _verifiedChannel = prerelease;
          }
        }
      } catch (_) {
        // A stale transfer must not disable an otherwise initialized updater.
        _invalidateDownload();
        latestRelease = null;
        failure = 'restore';
        status = UpdateStatus.downloadFailed;
      }
      if (_disposed) return;
      ready = true;
      _schedule();
    } catch (_) {
      ready = false;
      status = UpdateStatus.initializationFailed;
      failure = initializationFailure;
    } finally {
      _initializing = false;
      _notify();
    }
  }

  Future<void> setAutomatic(bool value) async {
    automatic = value;
    await _prefs?.setBool('jms.update.auto', value);
    _timer?.cancel();
    if (value) _schedule();
    _notify();
  }

  Future<void> setPrerelease(bool value) async {
    if (_disposed || busy || value == prerelease) return;
    ++_generation;
    _invalidateDownload();
    prerelease = value;
    latestRelease = null;
    status = checker.source.configured
        ? UpdateStatus.idle
        : UpdateStatus.unconfigured;
    await _prefs?.setBool('jms.update.prerelease', value);
    _notify();
  }

  Future<void> skip() async {
    skipped = latestRelease?.manifest.versionCode;
    if (skipped != null) await _prefs?.setInt('jms.update.skipped', skipped!);
    _notify();
  }

  void later() {
    deferred = true;
    _notify();
  }

  void setPlayback(bool value) {
    playback = value;
    if (supported) {
      unawaited(bridge.setAllowed(_transferAllowed).catchError((Object _) {}));
      if (!_transferAllowed && status == UpdateStatus.downloading) {
        unawaited(cancel());
      }
    }
    _notify();
    if (!blocked && ready) unawaited(check(manual: false));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (supported) {
      unawaited(bridge.setAllowed(_transferAllowed).catchError((Object _) {}));
      if (!_transferAllowed && status == UpdateStatus.downloading) {
        unawaited(cancel());
      }
    }
    if (_foreground) unawaited(check(manual: false));
    _notify();
  }

  void _schedule() {
    _timer?.cancel();
    if (!ready || !automatic || !checker.source.configured || _disposed) return;
    final last = _prefs?.getInt('jms.update.lastCheck') ?? 0;
    final next = DateTime.fromMillisecondsSinceEpoch(last)
        .add(const Duration(hours: 24));
    final delay = next.difference(DateTime.now());
    _timer = Timer(delay.isNegative ? const Duration(seconds: 3) : delay,
        () => check(manual: false));
  }

  Future<void> check({bool manual = true}) async {
    if (_disposed || !supported || busy) return;
    if (!ready) await initialize();
    if (_disposed || !ready || busy) return;
    if (blocked) {
      if (manual) {
        status = UpdateStatus.playbackBlocked;
        _notify();
      }
      return;
    }
    if (!checker.source.configured) {
      status = UpdateStatus.unconfigured;
      _notify();
      return;
    }
    final last = _prefs!.getInt('jms.update.lastCheck') ?? 0;
    if (!manual &&
        (!automatic ||
            DateTime.now().millisecondsSinceEpoch - last <
                const Duration(hours: 24).inMilliseconds)) {
      _schedule();
      return;
    }
    _checking = true;
    final generation = _generation;
    status = UpdateStatus.checking;
    failure = null;
    checkWarning = null;
    if (manual) deferred = false;
    _notify();
    try {
      await _prefs!.setInt(
          'jms.update.lastCheck', DateTime.now().millisecondsSinceEpoch);
      final result = await checker.check(_device!, prerelease: prerelease);
      if (_disposed || generation != _generation) return;
      _acceptCheck(result);
      if (manual && latestRelease != null) skipped = null;
      await _prefs!.setString('jms.update.cache', jsonEncode(checker.cache));
      if (checker.retryAfter != null) {
        await _prefs!.setInt('jms.update.retryAfter',
            checker.retryAfter!.millisecondsSinceEpoch);
      }
    } catch (_) {
      if (!_disposed && generation == _generation) {
        _acceptCheck(const UpdateCheckResult(UpdateStatus.network));
      }
    } finally {
      _checking = false;
      _schedule();
      _notify();
    }
  }

  void _acceptCheck(UpdateCheckResult result) {
    if (hasVerifiedDownload &&
        const {
          UpdateStatus.network,
          UpdateStatus.rateLimited,
          UpdateStatus.sourceUnavailable,
        }.contains(result.status)) {
      checkWarning = result.status;
      status = UpdateStatus.downloaded;
      return;
    }
    final sameVerified = hasVerifiedDownload &&
        result.release != null &&
        _validRelease(result.release!) &&
        _assetIdentity(result.release!) == _verifiedAsset;
    if (!sameVerified) {
      ++_generation;
      _invalidateDownload();
    }
    checkWarning = null;
    latestRelease = result.release;
    status = sameVerified ? UpdateStatus.downloaded : result.status;
  }

  Future<void> download() async {
    if (_disposed || !ready || busy || latestRelease == null) return;
    if (blocked) {
      status = UpdateStatus.playbackBlocked;
      _notify();
      return;
    }
    final release = latestRelease!;
    if (!_validRelease(release)) {
      _invalidateDownload();
      status = UpdateStatus.downloadFailed;
      failure = 'incompatible';
      _notify();
      return;
    }
    _invalidateDownload();
    final generation = ++_generation;
    _downloading = true;
    status = UpdateStatus.downloading;
    failure = null;
    progress = 0;
    _notify();
    final savedChannel =
        _prefs?.setBool('jms.update.transferChannel', prerelease);
    final transfer = _completeDownload(release, generation);
    try {
      await savedChannel;
    } catch (_) {
      // A settings write must not interrupt a confirmed native transfer.
    }
    await transfer;
  }

  Future<void> _completeDownload(ReleaseInfo release, int generation) async {
    final identity = _assetIdentity(release);
    final channel = prerelease;
    try {
      await bridge.download(release);
      if (!_current(generation, identity)) return;
      _verifiedAsset = identity;
      _verifiedChannel = channel;
      progress = 1;
      status = UpdateStatus.downloaded;
    } on PlatformException catch (error) {
      if (!_current(generation, identity)) return;
      failure = error.code;
      status = error.code == 'cancelled'
          ? UpdateStatus.cancelled
          : UpdateStatus.downloadFailed;
    } catch (_) {
      if (!_current(generation, identity)) return;
      status = UpdateStatus.downloadFailed;
    } finally {
      if (!_disposed && generation == _generation) {
        _downloading = false;
        if (!_current(generation, identity) || prerelease != channel) {
          _invalidateDownload();
          failure = 'notVerified';
          status = UpdateStatus.downloadFailed;
        }
      }
      _notify();
    }
  }

  Future<void> cancel() async {
    if (_disposed || !_downloading) return;
    ++_generation;
    _invalidateDownload();
    status = UpdateStatus.cancelled;
    try {
      await bridge.cancel();
    } catch (_) {
      failure = 'download';
    } finally {
      _downloading = false;
      _notify();
    }
  }

  Future<void> install(
      {bool openPermission = false, ReleaseInfo? expectedRelease}) async {
    if (_disposed || !ready || busy || latestRelease == null) return;
    if (blocked) {
      status = UpdateStatus.playbackBlocked;
      _notify();
      return;
    }
    if (!hasVerifiedDownload ||
        (expectedRelease != null &&
            _assetIdentity(expectedRelease) !=
                _assetIdentity(latestRelease!))) {
      _invalidateDownload();
      failure = 'notVerified';
      status = UpdateStatus.installBlocked;
      _notify();
      return;
    }
    final release = latestRelease!;
    final generation = _generation;
    final identity = _assetIdentity(release);
    _installing = true;
    var pending = false;
    failure = null;
    _notify();
    try {
      if (release.manifest.linux &&
          await bridge.currentPackageChannel() ==
              UpdatePackageChannel.community) {
        if (!_current(generation, identity)) return;
        failure = 'packageChannel';
        status = UpdateStatus.installBlocked;
        return;
      }
      if (!_current(generation, identity) || !hasVerifiedDownload || blocked) {
        return;
      }
      if (!await bridge.canInstall()) {
        if (!_current(generation, identity) || blocked) return;
        status = UpdateStatus.permissionRequired;
        if (openPermission) await bridge.permission();
        return;
      }
      if (!_current(generation, identity) || !hasVerifiedDownload || blocked) {
        return;
      }
      await _prefs!.setInt('jms.update.pending', release.manifest.versionCode);
      if (!_current(generation, identity) || !hasVerifiedDownload || blocked) {
        await _prefs?.remove('jms.update.pending');
        return;
      }
      final result = await bridge.install();
      pending = result != 'installCancelled' && result != 'installBlocked';
      if (!_current(generation, identity)) return;
      status = switch (result) {
        'installCancelled' => UpdateStatus.installCancelled,
        'installBlocked' => UpdateStatus.installBlocked,
        _ => UpdateStatus.installPending,
      };
    } on PlatformException catch (error) {
      if (!_current(generation, identity)) return;
      failure = error.code;
      if (const {
        'hash',
        'size',
        'signature',
        'incompatible',
        'source',
        'notVerified',
        'invalidApk',
        'split'
      }.contains(error.code)) {
        _invalidateDownload();
      }
      status = error.code == 'permission'
          ? UpdateStatus.permissionRequired
          : UpdateStatus.installBlocked;
    } catch (_) {
      if (!_current(generation, identity)) return;
      status = UpdateStatus.installBlocked;
    } finally {
      if (!pending) {
        try {
          await _prefs?.remove('jms.update.pending');
        } catch (_) {
          // A settings write failure must not retain the active-operation lock.
        }
      }
      _installing = false;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    bridge.onProgress = null;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (supported && !bridge.supportsBackgroundDownload) {
      unawaited(bridge.cancel().catchError((Object _) {}));
    }
    checker.close();
    super.dispose();
  }
}
