import 'dart:async';
import 'dart:convert';

import 'package:fladder/services/jms_entry_cache.dart';
import 'package:fladder/util/jms_entry_http_client.dart';
import 'package:fladder/util/jms_service_config.dart';
import 'package:http/http.dart' as http;

enum JmsEntryResolutionKind { configured, direct, cached, error }

enum JmsEntryError {
  invalidEntry,
  network,
  timeout,
  tls,
  httpError,
  redirect,
  responseTooLarge,
  invalidJson,
  invalidConfig,
  notJellyfin,
  closed;

  String get code => name;
}

final class JmsEntryResolution {
  const JmsEntryResolution({
    required this.kind,
    this.entry,
    this.config,
    this.error,
    this.serverId,
  });

  final JmsEntryResolutionKind kind;
  final Uri? entry;
  final JmsServiceConfig? config;
  final JmsEntryError? error;
  final String? serverId;
  bool get isSuccess => config != null && kind != JmsEntryResolutionKind.error;
  bool get fromCache => kind == JmsEntryResolutionKind.cached;
}

/// Isolated anonymous discovery, not an authenticated Jellyfin API client.
final class JmsEntryDiscovery {
  JmsEntryDiscovery({
    http.Client? client,
    this.cache,
    Duration timeout = const Duration(seconds: 8),
    int maxResponseBytes = 65536,
  })  : timeout = _validateTimeout(timeout),
        maxResponseBytes = _validateLimit(maxResponseBytes),
        _client = client ??
            createEntryClient(
                maxResponseBytes: _validateLimit(maxResponseBytes)),
        _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;
  final JmsEntryCache? cache;
  final Duration timeout;
  final int maxResponseBytes;
  final Set<Completer<void>> _requests = {};
  bool _closed = false;

  static Uri normalizeEntry(String value) => normalizeJmsEntry(value);

  static Duration _validateTimeout(Duration value) {
    if (value <= Duration.zero || value > const Duration(minutes: 2)) {
      throw ArgumentError('Invalid entry request timeout');
    }
    return value;
  }

  static int _validateLimit(int value) {
    if (value < 1 || value > 1048576) {
      throw ArgumentError('Invalid entry response limit');
    }
    return value;
  }

  Future<JmsEntryResolution> discover(String value,
      {bool forceDirect = false}) async {
    if (_closed) return _error(null, JmsEntryError.closed);
    final Uri entry;
    try {
      entry = normalizeEntry(value);
    } on FormatException {
      return _error(null, JmsEntryError.invalidEntry);
    }
    final clock = Stopwatch()..start();
    final directOnly = forceDirect || entry.scheme == 'http';
    try {
      if (directOnly) return await _probe(entry, clock);
      final response = await _get(entry.resolve('jms-config.json'), clock);
      if (response.status == 404 ||
          (response.status == 200 && response.isHtml)) {
        return await _probe(entry, clock);
      }
      if (response.status != 200) {
        throw _Failure(JmsEntryError.httpError,
            allowCache: response.status >= 500 && response.status <= 599);
      }
      final dynamic decoded;
      try {
        decoded = jsonDecode(utf8.decode(response.body));
      } on FormatException {
        throw const _Failure(JmsEntryError.invalidJson);
      }
      if (decoded is! Map<String, dynamic>) {
        throw const _Failure(JmsEntryError.invalidConfig);
      }
      final JmsServiceConfig config;
      try {
        config = JmsServiceConfig.fromJson(decoded);
      } on FormatException {
        throw const _Failure(JmsEntryError.invalidConfig);
      }
      return JmsEntryResolution(
          kind: JmsEntryResolutionKind.configured,
          entry: entry,
          config: config);
    } catch (error) {
      final failure = _classify(error);
      if (!directOnly && !_closed && failure.allowCache) {
        final previous = await cache?.read(entry);
        if (previous != null) {
          return JmsEntryResolution(
              kind: JmsEntryResolutionKind.cached,
              entry: entry,
              config: previous,
              error: failure.error);
        }
      }
      return _error(entry, _closed ? JmsEntryError.closed : failure.error);
    }
  }

  Future<JmsEntryResolution> _probe(Uri entry, Stopwatch clock) async {
    final response = await _get(entry.resolve('System/Info/Public'), clock);
    if (response.status != 200 || response.isHtml) {
      throw const _Failure(JmsEntryError.notJellyfin);
    }
    dynamic info;
    try {
      info = jsonDecode(utf8.decode(response.body));
    } on FormatException {
      throw const _Failure(JmsEntryError.notJellyfin);
    }
    if (info is! Map<String, dynamic> ||
        !{'Jellyfin', 'Jellyfin Server'}.contains(info['ProductName']) ||
        info['Version'] is! String ||
        (info['Version'] as String).trim().isEmpty ||
        info['Id'] is! String ||
        (info['Id'] as String).trim().isEmpty ||
        (info['Id'] as String).length > 256) {
      throw const _Failure(JmsEntryError.notJellyfin);
    }
    return JmsEntryResolution(
        kind: JmsEntryResolutionKind.direct,
        config: JmsServiceConfig.direct(entry),
        serverId: info['Id'] as String);
  }

  Future<_Response> _get(Uri uri, Stopwatch clock) async {
    final remaining = timeout - clock.elapsed;
    if (remaining <= Duration.zero) {
      throw const _Failure(JmsEntryError.timeout, allowCache: true);
    }
    final abort = Completer<void>();
    _requests.add(abort);
    final request =
        http.AbortableRequest('GET', uri, abortTrigger: abort.future)
          ..followRedirects = false
          ..maxRedirects = 0
          ..headers['accept'] = 'application/json';
    StreamIterator<List<int>>? iterator;
    Future<_Response> read() async {
      final response = await _client.send(request);
      if (response.statusCode >= 300 && response.statusCode <= 399) {
        final subscription = response.stream.listen((_) {}, onError: (_) {});
        unawaited(subscription.cancel().catchError((_) {}));
        throw const _Failure(JmsEntryError.redirect);
      }
      if ((response.contentLength ?? 0) > maxResponseBytes) {
        final subscription = response.stream.listen((_) {}, onError: (_) {});
        unawaited(subscription.cancel().catchError((_) {}));
        throw const _Failure(JmsEntryError.responseTooLarge);
      }
      iterator = StreamIterator(response.stream);
      final body = <int>[];
      while (await iterator!.moveNext()) {
        final chunk = iterator!.current;
        if (body.length + chunk.length > maxResponseBytes) {
          throw const _Failure(JmsEntryError.responseTooLarge);
        }
        body.addAll(chunk);
      }
      return _Response(response.statusCode, response.headers, body);
    }

    try {
      return await read().timeout(remaining,
          onTimeout: () =>
              throw const _Failure(JmsEntryError.timeout, allowCache: true));
    } finally {
      if (!abort.isCompleted) abort.complete();
      _requests.remove(abort);
      final pending = iterator;
      if (pending != null) unawaited(pending.cancel().catchError((_) {}));
    }
  }

  static _Failure _classify(Object error) {
    if (error is _Failure) return error;
    if (error is TimeoutException) {
      return const _Failure(JmsEntryError.timeout, allowCache: true);
    }
    if (error is http.ClientException &&
        error.message == 'entry_response_too_large') {
      return const _Failure(JmsEntryError.responseTooLarge);
    }
    if (error is http.ClientException &&
        error.message == 'entry_network_failure') {
      // Browser fetch conceals the cause, including TLS/redirect rejection.
      // Fail closed rather than silently falling back on an unknown cause.
      return const _Failure(JmsEntryError.network);
    }
    final type = error.runtimeType.toString().toLowerCase();
    final description = error.toString().toLowerCase();
    if (type.contains('handshake') ||
        description.contains('certificate_verify_failed') ||
        description.contains('tls handshake') ||
        description.contains('ssl handshake')) {
      return const _Failure(JmsEntryError.tls);
    }
    return const _Failure(JmsEntryError.network, allowCache: true);
  }

  static JmsEntryResolution _error(Uri? entry, JmsEntryError error) =>
      JmsEntryResolution(
          kind: JmsEntryResolutionKind.error, entry: entry, error: error);

  void close() {
    if (_closed) return;
    _closed = true;
    for (final abort in _requests.toList()) {
      if (!abort.isCompleted) abort.complete();
    }
    _requests.clear();
    if (_ownsClient) _client.close();
  }
}

final class _Failure implements Exception {
  const _Failure(this.error, {this.allowCache = false});
  final JmsEntryError error;
  final bool allowCache;
}

final class _Response {
  const _Response(this.status, this.headers, this.body);
  final int status;
  final Map<String, String> headers;
  final List<int> body;
  bool get isHtml {
    final type = headers['content-type']?.split(';').first.toLowerCase();
    if (type == 'text/html' || type == 'application/xhtml+xml') return true;
    final prefix = utf8
        .decode(body.take(512).toList(), allowMalformed: true)
        .trimLeft()
        .toLowerCase();
    return prefix.startsWith('<!doctype html') || prefix.startsWith('<html');
  }
}
