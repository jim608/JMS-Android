import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fladder/util/update_checker.dart';

class AndroidUpdateBridge {
  static const channel = MethodChannel('com.jim608.jms/updates');
  void Function(double progress)? onProgress;
  AndroidUpdateBridge() {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'progress') onProgress?.call((call.arguments as num).toDouble());
    });
  }
  Future<UpdateDevice> device() async => UpdateDevice.fromJson((await channel.invokeMapMethod('device'))!);
  Future<void> setAllowed(bool allowed) => channel.invokeMethod('allowed', allowed);
  Future<void> cancel() => channel.invokeMethod('cancel');
  Future<void> download(ReleaseInfo release) => channel.invokeMethod('download', {
        ...release.manifest.json,
        'url': release.apkUrl.toString(),
        'repository': release.repository,
      });
  Future<bool> canInstall() async => await channel.invokeMethod<bool>('canInstall') ?? false;
  Future<void> permission() => channel.invokeMethod('permission');
  Future<String> install() async => await channel.invokeMethod<String>('install') ?? 'installPending';
}

class UpdateController extends ChangeNotifier with WidgetsBindingObserver {
  final UpdateChecker checker;
  final AndroidUpdateBridge bridge;
  final Future<SharedPreferences> Function() preferences;
  final bool supported;
  SharedPreferences? _prefs;
  UpdateDevice? _device;
  Timer? _timer;
  bool _disposed = false;
  bool _checking = false;
  bool _installing = false;
  bool _foreground = true;
  bool playback = false;
  bool automatic = true;
  bool prerelease = false;
  int? skipped;
  bool deferred = false;
  bool ready = false;
  double progress = 0;
  String? failure;
  UpdateStatus status = UpdateStatus.idle;
  ReleaseInfo? latestRelease;
  bool get busy => _checking || status == UpdateStatus.downloading || _installing;
  bool get blocked => playback || !_foreground;
  bool get hasNewUpdate =>
      !blocked && !deferred && latestRelease != null && skipped != latestRelease!.manifest.versionCode;

  UpdateController(
      {required this.checker,
      required this.bridge,
      this.preferences = SharedPreferences.getInstance,
      this.supported = true}) {
    status = !supported
        ? UpdateStatus.unsupported
        : checker.source.configured
            ? UpdateStatus.idle
            : UpdateStatus.unconfigured;
    bridge.onProgress = (value) {
      progress = value;
      _notify();
    };
  }

  Future<void> initialize() async {
    if (!supported) return;
    WidgetsBinding.instance.addObserver(this);
    try {
      _prefs = await preferences();
      if (_disposed) return;
      automatic = _prefs!.getBool('jms.update.auto') ?? automatic;
      prerelease = _prefs!.getBool('jms.update.prerelease') ?? false;
      skipped = _prefs!.getInt('jms.update.skipped');
      try {
        final cached = jsonDecode(_prefs!.getString('jms.update.cache') ?? '{}');
        if (cached is Map<String, dynamic>) checker.cache.addAll(cached);
      } catch (_) {
        checker.cache.clear();
      }
      final retry = _prefs!.getInt('jms.update.retryAfter');
      if (retry != null) checker.retryAfter = DateTime.fromMillisecondsSinceEpoch(retry);
      _device = await bridge.device();
      if (_disposed) return;
      await bridge.setAllowed(!blocked);
      final pending = _prefs!.getInt('jms.update.pending');
      if (pending != null && _device!.versionCode >= pending) {
        status = UpdateStatus.updated;
        await _prefs!.remove('jms.update.pending');
      } else if (pending != null) {
        status = UpdateStatus.installPending;
      }
      ready = true;
      _notify();
      _timer = Timer(const Duration(seconds: 3), () => check(manual: false));
    } catch (_) {
      status = UpdateStatus.installBlocked;
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
    if (busy) return;
    prerelease = value;
    latestRelease = null;
    status = checker.source.configured ? UpdateStatus.idle : UpdateStatus.unconfigured;
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
      unawaited(bridge.setAllowed(!blocked).catchError((Object _) {}));
      if (blocked && status == UpdateStatus.downloading) unawaited(cancel());
    }
    _notify();
    if (!blocked && ready) unawaited(check(manual: false));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (supported) {
      unawaited(bridge.setAllowed(!blocked).catchError((Object _) {}));
      if (blocked && status == UpdateStatus.downloading) unawaited(cancel());
    }
    if (_foreground) unawaited(check(manual: false));
  }

  void _schedule() {
    _timer?.cancel();
    if (!automatic || !checker.source.configured || _disposed) return;
    final last = _prefs?.getInt('jms.update.lastCheck') ?? 0;
    final next = DateTime.fromMillisecondsSinceEpoch(last).add(const Duration(hours: 24));
    final delay = next.difference(DateTime.now());
    _timer = Timer(delay.isNegative ? const Duration(seconds: 3) : delay, () => check(manual: false));
  }

  Future<void> check({bool manual = true}) async {
    if (!supported || !ready || busy) return;
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
        (!automatic || DateTime.now().millisecondsSinceEpoch - last < const Duration(hours: 24).inMilliseconds)) {
      _schedule();
      return;
    }
    _checking = true;
    status = UpdateStatus.checking;
    failure = null;
    if (manual) deferred = false;
    _notify();
    try {
      await _prefs!.setInt('jms.update.lastCheck', DateTime.now().millisecondsSinceEpoch);
      final result = await checker.check(_device!, prerelease: prerelease);
      if (_disposed) return;
      status = result.status;
      latestRelease = result.release;
      if (manual && latestRelease != null) skipped = null;
      await _prefs!.setString('jms.update.cache', jsonEncode(checker.cache));
      if (checker.retryAfter != null) {
        await _prefs!.setInt('jms.update.retryAfter', checker.retryAfter!.millisecondsSinceEpoch);
      }
    } catch (_) {
      status = UpdateStatus.network;
    } finally {
      _checking = false;
      _schedule();
      _notify();
    }
  }

  Future<void> download() async {
    if (busy || latestRelease == null) return;
    if (blocked) {
      status = UpdateStatus.playbackBlocked;
      _notify();
      return;
    }
    status = UpdateStatus.downloading;
    failure = null;
    progress = 0;
    _notify();
    try {
      await bridge.download(latestRelease!);
      status = UpdateStatus.downloaded;
    } on PlatformException catch (error) {
      failure = error.code;
      status = error.code == 'cancelled' ? UpdateStatus.cancelled : UpdateStatus.downloadFailed;
    } catch (_) {
      status = UpdateStatus.downloadFailed;
    }
    _notify();
  }

  Future<void> cancel() async {
    await bridge.cancel();
  }

  Future<void> install({bool openPermission = false}) async {
    if (busy || latestRelease == null) return;
    if (blocked) {
      status = UpdateStatus.playbackBlocked;
      _notify();
      return;
    }
    _installing = true;
    failure = null;
    _notify();
    try {
      if (!await bridge.canInstall()) {
        status = UpdateStatus.permissionRequired;
        if (openPermission) await bridge.permission();
        return;
      }
      await _prefs!.setInt('jms.update.pending', latestRelease!.manifest.versionCode);
      final result = await bridge.install();
      status = switch (result) {
        'installCancelled' => UpdateStatus.installCancelled,
        'installBlocked' => UpdateStatus.installBlocked,
        _ => UpdateStatus.installPending,
      };
    } on PlatformException catch (error) {
      failure = error.code;
      status = UpdateStatus.installBlocked;
    } catch (_) {
      status = UpdateStatus.installBlocked;
    } finally {
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
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (supported) unawaited(bridge.cancel().catchError((Object _) {}));
    checker.close();
    super.dispose();
  }
}
