import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:fladder/util/brand.dart';
import 'package:fladder/util/update_source.dart';

extension DownloadLabelFormatter on String {
  String capitalize() => isEmpty ? this : '${this[0].toUpperCase()}${substring(1)}';
}

enum UpdateStatus {
  unconfigured,
  idle,
  checking,
  noRelease,
  current,
  available,
  network,
  sourceUnavailable,
  rateLimited,
  incomplete,
  incompatible,
  downloading,
  downloaded,
  cancelled,
  downloadFailed,
  permissionRequired,
  installPending,
  installCancelled,
  installBlocked,
  updated,
  playbackBlocked,
  unsupported,
}

class UpdateFailure implements Exception {
  final UpdateStatus status;
  const UpdateFailure(this.status);
}

class UpdateDevice {
  final String applicationId;
  final int versionCode;
  final int sdk;
  final List<String> abis;
  const UpdateDevice(this.applicationId, this.versionCode, this.sdk, this.abis);
  factory UpdateDevice.fromJson(Map<Object?, Object?> json) => UpdateDevice(
        json['applicationId'] as String,
        json['versionCode'] as int,
        json['sdk'] as int,
        List<String>.from(json['abis'] as List),
      );
}

class UpdateManifest {
  static const maxApkBytes = 300 * 1024 * 1024;
  final Map<String, dynamic> json;
  UpdateManifest._(this.json);
  String get applicationId => json['applicationId'] as String;
  String get versionName => json['versionName'] as String;
  int get versionCode => json['versionCode'] as int;
  int get minSdk => json['minSdk'] as int;
  List<String> get abis => List<String>.from(json['abis'] as List);
  Map<String, dynamic> get apk => Map<String, dynamic>.from(json['apk'] as Map);
  String get assetName => apk['name'] as String;
  int get size => apk['size'] as int;
  String get sha256 => apk['sha256'] as String;

  factory UpdateManifest.parse(dynamic value) {
    try {
      final json = Map<String, dynamic>.from(value as Map);
      final manifest = UpdateManifest._(json);
      final source = Map<String, dynamic>.from(json['source'] as Map);
      final hash = RegExp(r'^[a-f0-9]{64}$');
      if (json['schemaVersion'] != 1 ||
          manifest.applicationId != Brand.applicationId ||
          manifest.versionCode <= 0 ||
          manifest.versionName.isEmpty ||
          manifest.minSdk < 24 ||
          manifest.minSdk > 100 ||
          manifest.abis.length != 1 ||
          manifest.abis.single != 'arm64-v8a' ||
          manifest.size <= 0 ||
          manifest.size > maxApkBytes ||
          !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._+-]*\.apk$').hasMatch(manifest.assetName) ||
          !hash.hasMatch(manifest.sha256) ||
          !RegExp(r'^[a-f0-9]{40}$').hasMatch(json['sourceCommit'] as String) ||
          !hash.hasMatch(source['sha256'] as String) ||
          !(source['name'] as String).endsWith('-source.zip') ||
          source['size'] is! int ||
          (source['size'] as int) <= 0) {
        throw const UpdateFailure(UpdateStatus.incomplete);
      }
      return manifest;
    } catch (_) {
      throw const UpdateFailure(UpdateStatus.incomplete);
    }
  }

  bool supports(UpdateDevice device) =>
      applicationId == device.applicationId && minSdk <= device.sdk && device.abis.contains('arm64-v8a');
}

class ReleaseInfo {
  final UpdateManifest manifest;
  final String changelog;
  final DateTime published;
  final Uri apkUrl;
  final String repository;
  String get version => manifest.versionName;
  const ReleaseInfo(this.manifest, this.changelog, this.published, this.apkUrl, this.repository);
}

class UpdateCheckResult {
  final UpdateStatus status;
  final ReleaseInfo? release;
  const UpdateCheckResult(this.status, [this.release]);
}

class UpdateChecker {
  final UpdateSource source;
  final http.Client client;
  final Map<String, dynamic> cache;
  final Duration timeout;
  bool _busy = false;
  DateTime? retryAfter;
  UpdateChecker(
      {this.source = const UpdateSource(),
      http.Client? client,
      Map<String, dynamic>? cache,
      this.timeout = const Duration(seconds: 15)})
      : client = client ?? http.Client(),
        cache = cache ?? {};

  Future<UpdateCheckResult> check(UpdateDevice device, {bool prerelease = false}) async {
    if (!source.configured) return const UpdateCheckResult(UpdateStatus.unconfigured);
    if (!source.valid) return const UpdateCheckResult(UpdateStatus.incomplete);
    if (_busy) return const UpdateCheckResult(UpdateStatus.checking);
    if (retryAfter != null && DateTime.now().isBefore(retryAfter!)) {
      return const UpdateCheckResult(UpdateStatus.rateLimited);
    }
    _busy = true;
    try {
      final response = await _json(source.releases, api: true);
      if (response is! List) throw const UpdateFailure(UpdateStatus.incomplete);
      if (response.any((entry) => entry is! Map || entry['draft'] is! bool || entry['prerelease'] is! bool)) {
        throw const UpdateFailure(UpdateStatus.incomplete);
      }
      final candidates = response
          .where((entry) => entry is Map && entry['draft'] == false && (prerelease || entry['prerelease'] == false))
          .take(20);
      if (candidates.isEmpty) return const UpdateCheckResult(UpdateStatus.noRelease);
      ReleaseInfo? newest;
      var compatible = false;
      for (final release in candidates) {
        final assets = (release['assets'] as List).map((asset) => Map<String, dynamic>.from(asset as Map)).toList();
        final metadata = _asset(assets, 'update.json');
        if (metadata['size'] is! int || metadata['size'] <= 0 || metadata['size'] > 65536) {
          throw const UpdateFailure(UpdateStatus.incomplete);
        }
        final manifest = UpdateManifest.parse(await _json(_assetUri(metadata), maxBytes: 65536));
        final apk = _asset(assets, manifest.assetName);
        final sourceAsset = _asset(assets, manifest.json['source']['name'] as String);
        final apkUrl = _assetUri(apk);
        if (apk['size'] != manifest.size ||
            sourceAsset['size'] != manifest.json['source']['size'] ||
            apkUrl.pathSegments[4] != release['tag_name'] ||
            _assetUri(metadata).pathSegments[4] != release['tag_name'] ||
            _assetUri(sourceAsset).pathSegments[4] != release['tag_name']) {
          throw const UpdateFailure(UpdateStatus.incomplete);
        }
        if (!manifest.supports(device)) continue;
        compatible = true;
        if (manifest.versionCode <= device.versionCode) continue;
        final published = DateTime.parse(release['published_at'] as String);
        if (newest == null || manifest.versionCode > newest.manifest.versionCode) {
          final notes = release['body'] as String? ?? '';
          newest = ReleaseInfo(
              manifest, notes.substring(0, notes.length.clamp(0, 20000)), published, apkUrl, source.identity);
        }
      }
      return UpdateCheckResult(
          newest != null
              ? UpdateStatus.available
              : compatible
                  ? UpdateStatus.current
                  : UpdateStatus.incompatible,
          newest);
    } on UpdateFailure catch (error) {
      return UpdateCheckResult(error.status);
    } on FormatException {
      return const UpdateCheckResult(UpdateStatus.incomplete);
    } on TypeError {
      return const UpdateCheckResult(UpdateStatus.incomplete);
    } catch (_) {
      return const UpdateCheckResult(UpdateStatus.network);
    } finally {
      _busy = false;
    }
  }

  Map<String, dynamic> _asset(List<Map<String, dynamic>> assets, String name) {
    final matches = assets.where((asset) => asset['name'] == name && asset['state'] == 'uploaded');
    if (matches.length != 1) throw const UpdateFailure(UpdateStatus.incomplete);
    return matches.single;
  }

  Uri _assetUri(Map<String, dynamic> asset) {
    final uri = Uri.parse(asset['browser_download_url'] as String);
    if (!source.ownsAsset(uri) || uri.pathSegments.last != asset['name']) {
      throw const UpdateFailure(UpdateStatus.incomplete);
    }
    return uri;
  }

  Future<dynamic> _json(Uri uri, {bool api = false, int maxBytes = 2 * 1024 * 1024}) async {
    final key = uri.toString();
    var target = uri;
    for (var attempt = 0; attempt < 6; attempt++) {
      final abort = Completer<void>();
      final deadline = Timer(timeout, () => abort.complete());
      final request = http.AbortableRequest('GET', target, abortTrigger: abort.future)..followRedirects = false;
      try {
        request.headers['User-Agent'] = 'JMS-Android-Updater';
        if (api) {
          request.headers['Accept'] = 'application/vnd.github+json';
          request.headers['X-GitHub-Api-Version'] = '2022-11-28';
        }
        final cached = cache[key];
        if (cached is Map && cached['etag'] is String) request.headers['If-None-Match'] = cached['etag'];
        final response = await client.send(request).timeout(timeout);
        if (response.statusCode == 304 && cached is Map && cached['body'] is String) {
          await response.stream.drain<void>().timeout(timeout);
          return jsonDecode(cached['body'] as String);
        }
        final limited = response.statusCode == 429 ||
            (response.statusCode == 403 &&
                (response.headers['x-ratelimit-remaining'] == '0' || response.headers.containsKey('retry-after')));
        if (limited) {
          await response.stream.listen(null).cancel();
          final seconds = int.tryParse(response.headers['retry-after'] ?? '') ?? 3600;
          final reset = int.tryParse(response.headers['x-ratelimit-reset'] ?? '');
          retryAfter = reset == null
              ? DateTime.now().add(Duration(seconds: seconds.clamp(60, 86400)))
              : DateTime.fromMillisecondsSinceEpoch(reset * 1000);
          throw const UpdateFailure(UpdateStatus.rateLimited);
        }
        if (response.statusCode == 401 || response.statusCode == 403 || response.statusCode == 404) {
          await response.stream.listen(null).cancel();
          throw UpdateFailure(api ? UpdateStatus.sourceUnavailable : UpdateStatus.incomplete);
        }
        if (response.statusCode >= 300 && response.statusCode < 400) {
          final location = response.headers['location'];
          final next = location == null ? null : target.resolve(location);
          if (api || next == null || !UpdateSource.allowedRedirect(next)) {
            throw const UpdateFailure(UpdateStatus.incomplete);
          }
          await response.stream.drain<void>().timeout(timeout);
          target = next;
          continue;
        }
        if (response.statusCode != 200) {
          await response.stream.listen(null).cancel();
          if (attempt == 0 && response.statusCode >= 500) {
            await Future<void>.delayed(const Duration(seconds: 1));
            continue;
          }
          throw const UpdateFailure(UpdateStatus.network);
        }
        final bytes = <int>[];
        await for (final chunk in response.stream.timeout(timeout)) {
          if (bytes.length + chunk.length > maxBytes) throw const UpdateFailure(UpdateStatus.incomplete);
          bytes.addAll(chunk);
        }
        final body = utf8.decode(bytes);
        final decoded = jsonDecode(body);
        if (cache.length >= 24 && !cache.containsKey(key)) cache.remove(cache.keys.first);
        cache[key] = {'etag': response.headers['etag'], 'body': body};
        return decoded;
      } finally {
        deadline.cancel();
        if (!abort.isCompleted) abort.complete();
      }
    }
    throw const UpdateFailure(UpdateStatus.network);
  }

  void close() => client.close();
}
