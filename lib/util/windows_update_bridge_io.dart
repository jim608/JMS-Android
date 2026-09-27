import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'package:fladder/util/brand.dart';
import 'package:fladder/util/update_checker.dart';
import 'package:fladder/util/update_controller.dart';
import 'package:fladder/util/update_source.dart';

UpdateBridge createWindowsUpdateBridge() => WindowsUpdateBridge();

Future<String> installerDigest(String path) async =>
    (await sha256.bind(File(path).openRead()).first).toString();

class WindowsUpdateBridge extends UpdateBridge {
  String get targetPlatform => 'windows-x64';
  String get installerFileName => 'installer.exe';
  @override
  bool get isDesktop => true;
  static const channel = MethodChannel('com.jim608.jms/desktop_updates');
  static const source = UpdateSource(owner: 'jim608', repo: 'JMS-Desktop');
  final http.Client Function() clientFactory;
  final Future<Directory> Function() directory;
  bool _allowed = true;
  bool _downloading = false;
  Completer<void>? _abort;
  File? _installer;
  ReleaseInfo? _release;

  WindowsUpdateBridge(
      {http.Client Function()? clientFactory,
      Future<Directory> Function()? directory})
      : clientFactory = clientFactory ?? http.Client.new,
        directory = directory ?? getApplicationSupportDirectory;

  @override
  Future<UpdateDevice> device() async {
    final data = (await channel.invokeMapMethod<String, dynamic>('device'))!;
    return UpdateDevice(Brand.applicationId, data['versionCode'] as int,
        data['windowsBuild'] as int, ['x86_64'],
        platform: 'windows-x64');
  }

  @override
  Future<void> setAllowed(bool allowed) async {
    _allowed = allowed;
    if (!allowed && _downloading) await cancel();
  }

  @override
  Future<void> cancel() async {
    if (_abort?.isCompleted == false) _abort!.complete();
  }

  void _checkAllowed() {
    if (!_allowed || _abort?.isCompleted == true) {
      throw PlatformException(code: 'cancelled');
    }
  }

  @override
  Future<void> download(ReleaseInfo release) async {
    if (_downloading) throw PlatformException(code: 'busy');
    _checkAllowed();
    if (release.manifest.platform != targetPlatform ||
        release.repository != source.identity ||
        !source.ownsAsset(release.apkUrl) ||
        release.apkUrl.pathSegments.last != release.manifest.assetName) {
      throw PlatformException(code: 'metadata');
    }
    _downloading = true;
    _abort = Completer<void>();
    final client = clientFactory();
    final deadline = Timer(const Duration(minutes: 15), cancel);
    File? temporary;
    IOSink? sink;
    try {
      final current = await device();
      if (!release.manifest.supports(current) ||
          release.manifest.versionCode <= current.versionCode) {
        throw PlatformException(code: 'incompatible');
      }
      await _discard();
      final root = await directory();
      await root.create(recursive: true);
      final folder =
          await Directory('${root.path}/updates').create(recursive: true);
      await for (final entry in folder.list(followLinks: false)) {
        if (entry is Directory &&
            entry.uri.pathSegments
                .where((part) => part.isNotEmpty)
                .last
                .startsWith('jms-')) {
          if (DateTime.now().difference((await entry.stat()).modified) <
              const Duration(days: 1)) {
            continue;
          }
          final oldInstaller = File('${entry.path}/$installerFileName');
          try {
            await _delete(oldInstaller);
          } on FileSystemException {
            throw PlatformException(code: 'storage');
          }
        }
      }
      final staging = await folder.createTemp('jms-');
      temporary = File('${staging.path}/$installerFileName');
      var target = release.apkUrl;
      http.StreamedResponse? payload;
      for (var redirects = 0; redirects < 6; redirects++) {
        _checkAllowed();
        final request =
            http.AbortableRequest('GET', target, abortTrigger: _abort!.future)
              ..followRedirects = false
              ..headers['User-Agent'] = 'JMS-Desktop-Updater';
        final response =
            await client.send(request).timeout(const Duration(seconds: 30));
        if (response.statusCode == 200) {
          payload = response;
          break;
        }
        await response.stream.listen(null).cancel();
        final location = response.headers['location'];
        final next = location == null ? null : target.resolve(location);
        if (response.statusCode < 300 ||
            response.statusCode >= 400 ||
            next == null ||
            !UpdateSource.allowedRedirect(next)) {
          throw PlatformException(code: 'download');
        }
        target = next;
      }
      if (payload == null ||
          (payload.contentLength != null &&
              payload.contentLength != release.manifest.size)) {
        throw PlatformException(code: 'size');
      }
      sink = temporary.openWrite();
      var count = 0;
      final progressClock = Stopwatch()..start();
      await for (final chunk
          in payload.stream.timeout(const Duration(seconds: 30))) {
        _checkAllowed();
        count += chunk.length;
        if (count > release.manifest.size) {
          throw PlatformException(code: 'size');
        }
        sink.add(chunk);
        await sink.flush();
        if (progressClock.elapsedMilliseconds >= 150) {
          onProgress?.call(count / release.manifest.size);
          progressClock.reset();
        }
      }
      await sink.close();
      sink = null;
      _checkAllowed();
      if (count != release.manifest.size) throw PlatformException(code: 'size');
      final path = temporary.path;
      final digest = await Isolate.run(() => installerDigest(path));
      if (digest != release.manifest.sha256) {
        throw PlatformException(code: 'hash');
      }
      _checkAllowed();
      await validateInstaller(temporary, release);
      _installer = temporary;
      _release = release;
      onProgress?.call(1);
    } catch (_) {
      if (sink != null) await sink.close();
      if (temporary != null) await _delete(temporary);
      if (_abort?.isCompleted == true || !_allowed) {
        throw PlatformException(code: 'cancelled');
      }
      rethrow;
    } finally {
      deadline.cancel();
      client.close();
      _downloading = false;
      _abort = null;
    }
  }

  Future<void> validateInstaller(File installer, ReleaseInfo release) async {
    final accepted = await channel.invokeMethod<bool>('validate', {
      'path': installer.path,
      'versionName': release.manifest.versionName,
      'versionCode': release.manifest.versionCode,
    });
    if (accepted != true) throw PlatformException(code: 'metadata');
  }

  Future<void> _delete(File file) async {
    if (await file.exists()) await file.delete();
    if (await file.parent.exists()) await file.parent.delete();
  }

  Future<void> _discard() async {
    final previous = _installer;
    _installer = null;
    _release = null;
    if (previous != null) await _delete(previous);
  }

  @override
  Future<bool> canInstall() async => true;
  @override
  Future<void> permission() async {}

  @override
  Future<String> install() async {
    _checkAllowed();
    final installer = _installer;
    final release = _release;
    if (installer == null || release == null) {
      throw PlatformException(code: 'download');
    }
    final current = await device();
    if (!release.manifest.supports(current) ||
        release.manifest.versionCode <= current.versionCode) {
      throw PlatformException(code: 'incompatible');
    }
    final path = installer.path;
    if (await installer.length() != release.manifest.size ||
        await Isolate.run(() => installerDigest(path)) !=
            release.manifest.sha256) {
      throw PlatformException(code: 'hash');
    }
    _checkAllowed();
    await validateInstaller(installer, release);
    return launchInstaller(installer, release);
  }

  Future<String> launchInstaller(File installer, ReleaseInfo release) async {
    return await channel.invokeMethod<String>('install', {
          'path': installer.path,
          'versionName': release.manifest.versionName,
          'versionCode': release.manifest.versionCode,
        }) ??
        'installBlocked';
  }
}
