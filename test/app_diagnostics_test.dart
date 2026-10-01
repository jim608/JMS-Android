import 'dart:async';
import 'dart:convert';

import 'package:fladder/util/app_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final endpoint =
      Uri.parse('https://diagnostics.example.org/api/jms/diagnostics/v1');
  DateTime now = DateTime(2026);
  List<http.Request> sent = [];
  AppDiagnostics reporter(
          {String buildId = 'JMS-0.11.1-jms.25-123456abcdef',
          Uri? destination,
          int maximumReports = 20}) =>
      AppDiagnostics(
        endpoint: destination ?? endpoint,
        platform: 'android',
        version: '0.11.1-jms.25',
        buildId: buildId,
        sourceCommit: '1234567890abcdef1234567890abcdef12345678',
        now: () => now,
        maximumReports: maximumReports,
        clientFactory: () => MockClient((request) async {
          sent.add(request);
          return http.Response('', 202);
        }),
      );

  setUp(() {
    now = DateTime(2026);
    sent = [];
  });

  test('consent defaults off and disabled reports do not open HTTP', () async {
    final diagnostics = reporter();
    expect(await diagnostics.runtimeError(DiagnosticCategory.flutterFramework),
        false);
    diagnostics.enabled = true;
    expect(await diagnostics.runtimeError(DiagnosticCategory.flutterFramework),
        true);
    diagnostics.enabled = false;
    expect(await diagnostics.runtimeError(DiagnosticCategory.unhandledAsync),
        false);
    expect(sent, hasLength(1));
    diagnostics.dispose();
  });

  test(
      'payload has only fixed metadata and category; no credentials or redirects',
      () async {
    final diagnostics = reporter()..enabled = true;
    expect(await diagnostics.runtimeError(DiagnosticCategory.unhandledAsync),
        true);
    final request = sent.single;
    expect(request.method, 'POST');
    expect(request.url, endpoint);
    expect(request.followRedirects, false);
    expect(
        request.headers.keys.map((key) => key.toLowerCase()), ['content-type']);
    expect(jsonDecode(request.body), {
      'schemaVersion': 1,
      'event': 'runtime_error',
      'platform': 'android',
      'version': '0.11.1-jms.25',
      'buildId': 'JMS-0.11.1-jms.25-123456abcdef',
      'sourceCommit': '1234567890abcdef1234567890abcdef12345678',
      'category': 'unhandled_async',
    });
    diagnostics.dispose();
  });

  test('missing endpoint or unsafe build metadata is silent', () async {
    final missing = AppDiagnostics(
        endpoint: null,
        platform: 'android',
        version: '0.11.1-jms.25',
        buildId: 'JMS-0.11.1-jms.25-123456abcdef')
      ..enabled = true;
    final invalid = reporter(buildId: 'unsafe/metadata')..enabled = true;
    final insecure = reporter(
        destination: Uri.parse('http://example.org/api/jms/diagnostics/v1'))
      ..enabled = true;
    for (final instance in [missing, invalid, insecure]) {
      expect(await instance.runtimeError(DiagnosticCategory.flutterFramework),
          false);
      instance.dispose();
    }
    expect(sent, isEmpty);
  });

  test('rate limit includes failed attempts and bounds a session', () async {
    final diagnostics = reporter(maximumReports: 2)..enabled = true;
    expect(await diagnostics.runtimeError(DiagnosticCategory.flutterFramework),
        true);
    expect(await diagnostics.runtimeError(DiagnosticCategory.flutterFramework),
        false);
    now = now.add(const Duration(minutes: 5));
    expect(await diagnostics.runtimeError(DiagnosticCategory.flutterFramework),
        true);
    expect(await diagnostics.runtimeError(DiagnosticCategory.unhandledAsync),
        false);
    expect(sent, hasLength(2));
    diagnostics.dispose();
  });

  test('build identity matches the exact version and a hexadecimal revision',
      () async {
    for (final identity in [
      'UNSTAMPED',
      'JMS-0.11.1-jms.24-123456abcdef',
      'JMS-0.11.1-jms.25-unknown',
      'JMS-0.11.1-jms.25-server-123456abcdef',
    ]) {
      final diagnostics = reporter(buildId: identity)..enabled = true;
      expect(diagnostics.configured, false);
      expect(
          await diagnostics.runtimeError(DiagnosticCategory.flutterFramework),
          false);
      diagnostics.dispose();
    }
    expect(sent, isEmpty);
    final valid = reporter(buildId: 'JMS-0.11.1-jms.25-android-123456abcdef')
      ..enabled = true;
    expect(valid.configured, true);
    expect(await valid.runtimeError(DiagnosticCategory.flutterFramework), true);
    valid.dispose();
  });

  test('performance validates bounded counts and only sends allowed metrics',
      () async {
    final diagnostics = reporter()..enabled = true;
    expect(
        await diagnostics.performance(
            frameCount: 601,
            slowFrameCount: 1,
            worstFrameMs: 80,
            totalDurationMs: 100),
        false);
    expect(
        await diagnostics.performance(
            frameCount: 2,
            slowFrameCount: 3,
            worstFrameMs: 80,
            totalDurationMs: 100),
        false);
    expect(
        await diagnostics.performance(
            frameCount: 2,
            slowFrameCount: 1,
            worstFrameMs: 60001,
            totalDurationMs: 100),
        false);
    expect(
        await diagnostics.performance(
            frameCount: 2,
            slowFrameCount: 1,
            worstFrameMs: 80,
            totalDurationMs: 180001),
        false);
    expect(sent, isEmpty);
    expect(
        await diagnostics.performance(
            frameCount: 10,
            slowFrameCount: 2,
            worstFrameMs: 80,
            totalDurationMs: 300),
        true);
    expect(jsonDecode(sent.single.body)['metrics'], {
      'frameCount': 10,
      'slowFrameCount': 2,
      'worstFrameMs': 80,
      'totalDurationMs': 300,
    });
    diagnostics.dispose();
  });

  test('timeout and transport errors are contained without retry', () async {
    var calls = 0;
    var time = DateTime(2026);
    final diagnostics = AppDiagnostics(
      endpoint: endpoint,
      platform: 'linux',
      version: '0.11.1-jms.25',
      buildId: 'JMS-0.11.1-jms.25-123456abcdef',
      now: () => time,
      timeout: const Duration(milliseconds: 5),
      clientFactory: () => MockClient((request) {
        calls++;
        if (calls == 1) return Completer<http.Response>().future;
        throw StateError('Transport unavailable');
      }),
    )..enabled = true;
    expect(await diagnostics.runtimeError(DiagnosticCategory.unhandledAsync),
        false);
    expect(await diagnostics.runtimeError(DiagnosticCategory.unhandledAsync),
        false);
    time = time.add(const Duration(minutes: 5));
    expect(await diagnostics.runtimeError(DiagnosticCategory.unhandledAsync),
        false);
    expect(calls, 2);
    diagnostics.dispose();
  });

  test(
      'disabling invalidates an in-flight response and disposal blocks future work',
      () async {
    final pending = Completer<http.Response>();
    final diagnostics = AppDiagnostics(
        endpoint: endpoint,
        platform: 'windows',
        version: '0.11.1-jms.25',
        buildId: 'JMS-0.11.1-jms.25-123456abcdef',
        clientFactory: () => MockClient((request) => pending.future))
      ..enabled = true;
    final result =
        diagnostics.runtimeError(DiagnosticCategory.flutterFramework);
    diagnostics.enabled = false;
    pending.complete(http.Response('', 202));
    expect(await result, false);
    diagnostics.dispose();
    diagnostics.enabled = true;
    expect(await diagnostics.runtimeError(DiagnosticCategory.unhandledAsync),
        false);
  });

  test('endpoint rejects credential, query, fragment, wrong path and downgrade',
      () {
    expect(diagnosticEndpoint(endpoint.toString()), endpoint);
    for (final value in [
      'http://example.org/api/jms/diagnostics/v1',
      'https://example-user@example.org/api/jms/diagnostics/v1',
      '${endpoint.toString()}?test=1',
      '${endpoint.toString()}#fragment',
      'https://example.org/other',
      '//example.org/api/jms/diagnostics/v1',
      '/api/jms/diagnostics/v1',
    ]) {
      expect(diagnosticEndpoint(value), isNull);
    }
    expect(
        diagnosticEndpoint('/api/jms/diagnostics/v1',
            webOrigin: Uri.parse('https://example.org/')),
        Uri.parse('https://example.org/api/jms/diagnostics/v1'));
    expect(
        diagnosticEndpoint('/api/jms/diagnostics/v1',
            webOrigin: Uri.parse('http://example.org/')),
        isNull);
  });

  test(
      'unknown source revision is omitted and unsupported platform cannot report',
      () async {
    final diagnostics = AppDiagnostics(
        endpoint: endpoint,
        platform: 'web',
        version: '0.11.1-jms.25',
        buildId: 'JMS-0.11.1-jms.25-123456abcdef',
        sourceCommit: 'unknown',
        clientFactory: () => MockClient((request) async {
              sent.add(request);
              return http.Response('', 202);
            }))
      ..enabled = true;
    expect(await diagnostics.runtimeError(DiagnosticCategory.flutterFramework),
        true);
    expect(jsonDecode(sent.single.body).containsKey('sourceCommit'), false);
    diagnostics.dispose();
    final unsupported = AppDiagnostics(
        endpoint: endpoint,
        platform: 'fuchsia',
        version: '0.11.1-jms.25',
        buildId: 'JMS-0.11.1-jms.25-123456abcdef')
      ..enabled = true;
    expect(await unsupported.runtimeError(DiagnosticCategory.flutterFramework),
        false);
    unsupported.dispose();
  });
}
