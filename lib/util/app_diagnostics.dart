import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:fladder/util/diagnostics_http_client.dart';

enum DiagnosticCategory { flutterFramework, unhandledAsync, slowFrames }

extension on DiagnosticCategory {
  String get wireName => switch (this) {
        DiagnosticCategory.flutterFramework => 'flutter_framework',
        DiagnosticCategory.unhandledAsync => 'unhandled_async',
        DiagnosticCategory.slowFrames => 'slow_frames',
      };
}

/// Only the explicit diagnostic API is accepted. Service/account URLs are never
/// inferred, and credentials, queries and fragments cannot be added to it.
Uri? diagnosticEndpoint(String? value,
    {Uri? webOrigin, bool allowInsecureForTesting = false}) {
  if (value == null || value.length > 2048) return null;
  var uri = Uri.tryParse(value.trim());
  if (uri == null) return null;
  if (!uri.hasScheme && value.trim() == '/api/jms/diagnostics/v1') {
    if (webOrigin == null) return null;
    uri = webOrigin.resolveUri(uri);
  }
  final secure = uri.scheme == 'https';
  final testLocal = allowInsecureForTesting &&
      uri.scheme == 'http' &&
      {'localhost', '127.0.0.1', '::1'}.contains(uri.host);
  if ((!secure && !testLocal) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      uri.path != '/api/jms/diagnostics/v1') {
    return null;
  }
  return uri;
}

/// The transport cannot accept exception text, stacks, identities or log files.
/// Every field comes from an enum, validated build metadata or bounded counts.
class AppDiagnostics {
  AppDiagnostics({
    required this.endpoint,
    required this.platform,
    required this.version,
    required this.buildId,
    String? sourceCommit,
    http.Client Function()? clientFactory,
    DateTime Function()? now,
    this.timeout = const Duration(seconds: 3),
    this.minimumInterval = const Duration(minutes: 5),
    this.maximumReports = 20,
  })  : sourceCommit = sourceCommit != null &&
                RegExp(r'^[0-9a-f]{40}$').hasMatch(sourceCommit)
            ? sourceCommit
            : null,
        _clientFactory = clientFactory ?? createDiagnosticClient,
        _now = now ?? DateTime.now;

  final Uri? endpoint;
  final String platform;
  final String version;
  final String buildId;
  final String? sourceCommit;
  final Duration timeout;
  final Duration minimumInterval;
  final int maximumReports;
  final http.Client Function() _clientFactory;
  final DateTime Function() _now;
  final Map<DiagnosticCategory, DateTime> _lastAttempt = {};
  bool _enabled = false;
  bool _disposed = false;
  int _generation = 0;
  int _reportCount = 0;
  http.Client? _activeClient;

  bool get configured =>
      diagnosticEndpoint(endpoint?.toString()) != null &&
      {'android', 'windows', 'linux', 'web', 'ios', 'macos'}
          .contains(platform) &&
      RegExp(r'^\d+\.\d+\.\d+-jms\.\d+$').hasMatch(version) &&
      RegExp('^JMS-${RegExp.escape(version)}'
              r'(?:-(?:android|windows|linux|web))?-[a-f0-9]{12,64}$')
          .hasMatch(buildId);

  set enabled(bool value) {
    _enabled = value;
    if (!value) {
      _generation++;
      _activeClient?.close();
      _activeClient = null;
    }
  }

  Future<bool> runtimeError(DiagnosticCategory category) async {
    if (category == DiagnosticCategory.slowFrames) return false;
    return _send(category);
  }

  Future<bool> performance({
    required int frameCount,
    required int slowFrameCount,
    required int worstFrameMs,
    required int totalDurationMs,
  }) async {
    if (frameCount < 1 ||
        frameCount > 600 ||
        slowFrameCount < 1 ||
        slowFrameCount > frameCount ||
        worstFrameMs < 0 ||
        worstFrameMs > 60000 ||
        totalDurationMs < 0 ||
        totalDurationMs > 180000) {
      return false;
    }
    return _send(DiagnosticCategory.slowFrames, {
      'frameCount': frameCount,
      'slowFrameCount': slowFrameCount,
      'worstFrameMs': worstFrameMs,
      'totalDurationMs': totalDurationMs,
    });
  }

  Future<bool> _send(DiagnosticCategory category,
      [Map<String, int>? metrics]) async {
    if (_disposed ||
        !_enabled ||
        !configured ||
        _activeClient != null ||
        _reportCount >= maximumReports) {
      return false;
    }
    final now = _now();
    final previous = _lastAttempt[category];
    if (previous != null && now.difference(previous) < minimumInterval) {
      return false;
    }
    _lastAttempt[category] = now;
    _reportCount++;
    final generation = _generation;
    http.Client? client;
    try {
      client = _clientFactory();
      _activeClient = client;
      final request = http.Request('POST', endpoint!)
        ..followRedirects = false
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode({
          'schemaVersion': 1,
          'event': metrics == null ? 'runtime_error' : 'performance',
          'platform': platform,
          'version': version,
          'buildId': buildId,
          if (sourceCommit != null) 'sourceCommit': sourceCommit,
          'category': category.wireName,
          if (metrics != null) 'metrics': metrics,
        });
      final response = await client.send(request).timeout(timeout);
      return _enabled &&
          !_disposed &&
          generation == _generation &&
          response.statusCode >= 200 &&
          response.statusCode < 300;
    } catch (_) {
      // A diagnostic outage must never throw into the application error hooks.
      return false;
    } finally {
      client?.close();
      if (identical(client, _activeClient)) _activeClient = null;
    }
  }

  void dispose() {
    _disposed = true;
    enabled = false;
  }
}
