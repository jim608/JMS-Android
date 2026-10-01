import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/util/app_diagnostics.dart';
import 'package:fladder/util/application_info.dart';
import 'package:fladder/util/build_info.dart';
import 'package:fladder/util/fladder_config.dart';

final diagnosticsProvider = ChangeNotifierProvider<DiagnosticsSettings>((ref) {
  final info = ref.read(applicationInfoProvider);
  return DiagnosticsSettings(
    preferences: ref.read(sharedPreferencesProvider),
    version: info.version,
    buildId: JmsBuildInfo.id,
    platform: kIsWeb
        ? 'web'
        : switch (defaultTargetPlatform) {
            TargetPlatform.android => 'android',
            TargetPlatform.windows => 'windows',
            TargetPlatform.linux => 'linux',
            TargetPlatform.iOS => 'ios',
            TargetPlatform.macOS => 'macos',
            TargetPlatform.fuchsia => 'unsupported',
          },
    configuredEndpoint: kIsWeb ? FladderConfig.diagnosticsEndpoint : null,
    webOrigin: kIsWeb ? Uri.base : null,
  );
});

class DiagnosticsSettings extends ChangeNotifier {
  DiagnosticsSettings({
    required this.preferences,
    required this.version,
    required this.buildId,
    required this.platform,
    this.configuredEndpoint,
    this.webOrigin,
  }) {
    _enabled = preferences.getBool(consentKey) ?? false;
    _start();
  }

  static const consentKey = 'jms.diagnostics.consent.v1';
  static const endpointKey = 'jms.diagnostics.endpoint.v1';
  static const _buildEndpoint =
      String.fromEnvironment('JMS_DIAGNOSTICS_ENDPOINT');
  static const _sourceCommit = String.fromEnvironment('JMS_SOURCE_COMMIT');
  final SharedPreferences preferences;
  final String version;
  final String buildId;
  final String platform;
  final String? configuredEndpoint;
  final Uri? webOrigin;
  late bool _enabled;
  AppDiagnostics? _reporter;
  DiagnosticsHooks? _hooks;

  bool get enabled => _enabled;
  String get endpointValue =>
      preferences.getString(endpointKey) ??
      configuredEndpoint ??
      _buildEndpoint;
  Uri? get endpoint => diagnosticEndpoint(endpointValue, webOrigin: webOrigin);
  bool get configured => _reporter?.configured ?? false;

  Future<bool> setEnabled(bool value) async {
    if (value && !configured) return false;
    try {
      if (!await preferences.setBool(consentKey, value)) return false;
    } catch (_) {
      return false;
    }
    _enabled = value;
    _reporter?.enabled = value;
    if (value) {
      _hooks?.start();
    } else {
      _hooks?.stop();
    }
    notifyListeners();
    return true;
  }

  Future<bool> setEndpoint(String value) async {
    final normalized = value.trim();
    if (normalized.isNotEmpty &&
        diagnosticEndpoint(normalized, webOrigin: webOrigin) == null) {
      return false;
    }
    try {
      if (!await preferences.setString(endpointKey, normalized)) return false;
    } catch (_) {
      return false;
    }
    _start();
    notifyListeners();
    return true;
  }

  void _start() {
    _hooks?.stop();
    _reporter?.dispose();
    _reporter = AppDiagnostics(
      endpoint: endpoint,
      platform: platform,
      version: version,
      buildId: buildId,
      sourceCommit: _sourceCommit,
    )..enabled = enabled;
    _hooks = DiagnosticsHooks(_reporter!);
    if (enabled && configured) _hooks!.start();
  }

  @override
  void dispose() {
    _hooks?.stop();
    _reporter?.dispose();
    super.dispose();
  }
}

/// Hooks augment the local crash recorder. They never consume its error details
/// or change whether an unhandled platform error was handled.
class DiagnosticsHooks with WidgetsBindingObserver {
  DiagnosticsHooks(this.reporter, {DateTime Function()? now})
      : _now = now ?? DateTime.now {
    _flutterHandler = (details) {
      unawaited(reporter.runtimeError(DiagnosticCategory.flutterFramework));
      _previousFlutter?.call(details);
    };
    _platformHandler = (error, stack) {
      unawaited(reporter.runtimeError(DiagnosticCategory.unhandledAsync));
      return _previousPlatform?.call(error, stack) ?? false;
    };
  }

  final AppDiagnostics reporter;
  final DateTime Function() _now;
  late final FlutterExceptionHandler _flutterHandler;
  late final ErrorCallback _platformHandler;
  FlutterExceptionHandler? _previousFlutter;
  ErrorCallback? _previousPlatform;
  bool _started = false;
  bool _foreground = true;
  DateTime? _windowStart;
  int _frameCount = 0;
  int _slowFrameCount = 0;
  int _worstFrameMs = 0;
  int _totalDurationMs = 0;

  void start() {
    if (_started) return;
    _started = true;
    _foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _resetFrames();
    _previousFlutter = FlutterError.onError;
    _previousPlatform = PlatformDispatcher.instance.onError;
    FlutterError.onError = _flutterHandler;
    PlatformDispatcher.instance.onError = _platformHandler;
    SchedulerBinding.instance.addTimingsCallback(recordTimings);
    WidgetsBinding.instance.addObserver(this);
  }

  void stop() {
    if (!_started) return;
    _started = false;
    if (identical(FlutterError.onError, _flutterHandler)) {
      FlutterError.onError = _previousFlutter;
    }
    if (identical(PlatformDispatcher.instance.onError, _platformHandler)) {
      PlatformDispatcher.instance.onError = _previousPlatform;
    }
    SchedulerBinding.instance.removeTimingsCallback(recordTimings);
    WidgetsBinding.instance.removeObserver(this);
    _resetFrames();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _resetFrames();
  }

  void recordTimings(List<FrameTiming> timings) {
    if (!_started || !_foreground) return;
    for (final timing in timings) {
      final duration = timing.totalSpan.inMilliseconds;
      if (duration < 0 || duration > 60000) continue;
      _windowStart ??= _now();
      _frameCount++;
      if (duration > 50) _slowFrameCount++;
      if (duration > _worstFrameMs) _worstFrameMs = duration;
      _totalDurationMs += duration;
      if (_frameCount >= 600 ||
          _totalDurationMs >= 120000 ||
          _now().difference(_windowStart!) >= const Duration(seconds: 30)) {
        if (_slowFrameCount > 0 &&
            (_slowFrameCount / _frameCount >= 0.1 || _worstFrameMs >= 250)) {
          unawaited(reporter.performance(
            frameCount: _frameCount,
            slowFrameCount: _slowFrameCount,
            worstFrameMs: _worstFrameMs,
            totalDurationMs: _totalDurationMs,
          ));
        }
        _resetFrames();
      }
    }
  }

  void _resetFrames() {
    _windowStart = null;
    _frameCount = 0;
    _slowFrameCount = 0;
    _worstFrameMs = 0;
    _totalDurationMs = 0;
  }
}
