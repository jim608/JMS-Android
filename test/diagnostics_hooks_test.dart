import 'dart:convert';
import 'dart:ui';

import 'package:fladder/providers/diagnostics_provider.dart';
import 'package:fladder/util/app_diagnostics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _PrivateError {
  @override
  String toString() => throw StateError('Error text must not be inspected');
}

FrameTiming frame(int milliseconds) => FrameTiming(
      vsyncStart: 0,
      buildStart: 0,
      buildFinish: 0,
      rasterStart: 0,
      rasterFinish: milliseconds * 1000,
      rasterFinishWallTime: milliseconds * 1000,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final endpoint =
      Uri.parse('https://diagnostics.example.org/api/jms/diagnostics/v1');
  var now = DateTime(2026);
  List<Map<String, dynamic>> sent = [];
  AppDiagnostics reporter() => AppDiagnostics(
      endpoint: endpoint,
      platform: 'android',
      version: '0.11.1-jms.25',
      buildId: 'JMS-0.11.1-jms.25-123456abcdef',
      now: () => now,
      clientFactory: () => MockClient((request) async {
            sent.add(jsonDecode(request.body) as Map<String, dynamic>);
            return http.Response('', 202);
          }))
    ..enabled = true;
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  setUp(() {
    now = DateTime(2026);
    sent = [];
  });

  test(
      'hooks preserve both original handlers and never inspect error or stack text',
      () async {
    final originalFlutter = FlutterError.onError;
    final originalPlatform = PlatformDispatcher.instance.onError;
    final error = _PrivateError();
    var flutterCalls = 0;
    var platformCalls = 0;
    FlutterError.onError = (details) {
      expect(details.exception, same(error));
      flutterCalls++;
    };
    PlatformDispatcher.instance.onError = (exception, stack) {
      expect(exception, same(error));
      platformCalls++;
      return true;
    };
    final diagnostics = reporter();
    final hooks = DiagnosticsHooks(diagnostics)..start();
    try {
      FlutterError.onError!(FlutterErrorDetails(exception: error));
      await settle();
      expect(
          PlatformDispatcher.instance.onError!(error, StackTrace.empty), true);
      await settle();
      expect(flutterCalls, 1);
      expect(platformCalls, 1);
      expect(sent.map((item) => item['category']),
          ['flutter_framework', 'unhandled_async']);
      expect(
          sent.every((item) =>
              !item.containsKey('message') && !item.containsKey('stack')),
          true);
    } finally {
      hooks.stop();
      diagnostics.dispose();
      FlutterError.onError = originalFlutter;
      PlatformDispatcher.instance.onError = originalPlatform;
    }
  });

  test('stop restores original handlers and does not replace later owners', () {
    final originalFlutter = FlutterError.onError;
    final originalPlatform = PlatformDispatcher.instance.onError;
    final diagnostics = reporter();
    final hooks = DiagnosticsHooks(diagnostics);
    try {
      hooks.start();
      hooks.start();
      hooks.stop();
      expect(FlutterError.onError, same(originalFlutter));
      expect(PlatformDispatcher.instance.onError, same(originalPlatform));
      hooks.start();
      void later(FlutterErrorDetails details) {}
      FlutterError.onError = later;
      hooks.stop();
      expect(FlutterError.onError, same(later));
    } finally {
      hooks.stop();
      diagnostics.dispose();
      FlutterError.onError = originalFlutter;
      PlatformDispatcher.instance.onError = originalPlatform;
    }
  });

  test('slow frames aggregate, pause resets samples, and stop removes sampling',
      () async {
    final diagnostics = reporter();
    final hooks = DiagnosticsHooks(diagnostics, now: () => now)..start();
    try {
      hooks.didChangeAppLifecycleState(AppLifecycleState.resumed);
      hooks.recordTimings([frame(80)]);
      expect(sent, isEmpty);
      hooks.didChangeAppLifecycleState(AppLifecycleState.paused);
      now = now.add(const Duration(seconds: 31));
      hooks.recordTimings(List.filled(600, frame(100)));
      expect(sent, isEmpty);
      hooks.didChangeAppLifecycleState(AppLifecycleState.resumed);
      hooks.recordTimings([frame(16)]);
      now = now.add(const Duration(seconds: 31));
      hooks.recordTimings([frame(80)]);
      await settle();
      expect(sent.single['metrics'], {
        'frameCount': 2,
        'slowFrameCount': 1,
        'worstFrameMs': 80,
        'totalDurationMs': 96
      });
      hooks.stop();
      now = now.add(const Duration(minutes: 5));
      hooks.recordTimings(List.filled(600, frame(100)));
      await settle();
      expect(sent, hasLength(1));
    } finally {
      hooks.stop();
      diagnostics.dispose();
    }
  });

  test('healthy frames do not trigger performance reports', () async {
    final diagnostics = reporter();
    final hooks = DiagnosticsHooks(diagnostics)..start();
    try {
      hooks.didChangeAppLifecycleState(AppLifecycleState.resumed);
      hooks.recordTimings(List.filled(600, frame(16)));
      await settle();
      expect(sent, isEmpty);
    } finally {
      hooks.stop();
      diagnostics.dispose();
    }
  });

  test('consent and endpoint survive restart independently of account settings',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    DiagnosticsSettings create() => DiagnosticsSettings(
        preferences: prefs,
        version: '0.11.1-jms.25',
        buildId: 'JMS-0.11.1-jms.25-123456abcdef',
        platform: 'android');
    final first = create();
    await first.activateServer(null, null);
    expect(first.enabled, false);
    expect(first.configured, false);
    expect(await first.setEnabled(true), false);
    expect(await first.setEndpoint(endpoint.toString()), true);
    expect(await first.setEnabled(true), true);
    first.dispose();
    final second = create();
    expect(second.enabled, false);
    await second.activateServer(null, null);
    expect(second.enabled, true);
    expect(second.endpoint, endpoint);
    expect(await second.setEnabled(false), true);
    expect(await second.setEndpoint('http://example.org/other'), false);
    expect(second.endpoint, endpoint);
    second.dispose();
    final third = create();
    await third.activateServer(null, null);
    expect(third.enabled, false);
    third.dispose();
  });
}
