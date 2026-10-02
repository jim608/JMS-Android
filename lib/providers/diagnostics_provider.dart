import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
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
    this.clientFactory,
  }) {
    // Native server/account state is loaded later. A legacy global consent must
    // not install hooks or send a report before that scope is known.
    _awaitingActivation = platform != 'web';
    _enabled = !_awaitingActivation &&
        (preferences.getBool(consentKey) ?? false) &&
        _receiverMatchesConsent(allowLegacy: true);
    _start();
  }

  static const consentKey = 'jms.diagnostics.consent.v1';
  static const endpointKey = 'jms.diagnostics.endpoint.v1';
  static const _activeScopeKey = 'jms.diagnostics.active-scope.v1';
  static const _migrationKey = 'jms.diagnostics.legacy-manual-migrated.v1';
  static const _legacyScope = 'legacy';
  static const _buildEndpoint =
      String.fromEnvironment('JMS_DIAGNOSTICS_ENDPOINT');
  static const _sourceCommit = String.fromEnvironment('JMS_SOURCE_COMMIT');
  final SharedPreferences preferences;
  final String version;
  final String buildId;
  final String platform;
  final String? configuredEndpoint;
  final Uri? webOrigin;
  @visibleForTesting
  final http.Client Function()? clientFactory;
  bool _enabled = false;
  bool _awaitingActivation = false;
  bool _activated = false;
  bool _disposed = false;
  int _generation = 0;
  String? _serverScope;
  String? _providedEndpoint;
  AppDiagnostics? _reporter;
  DiagnosticsHooks? _hooks;

  static String _scopePrefix(String? scope) => scope == null
      ? _legacyScope
      : 'jms.diagnostics.server.v1.${sha256.convert(utf8.encode(scope))}';
  String get _prefix => _scopePrefix(_serverScope);
  String get _consentKey =>
      _serverScope == null ? consentKey : '$_prefix.consent';
  String get _endpointKey =>
      _serverScope == null ? endpointKey : '$_prefix.endpoint';
  String get _consentReceiverKey => _serverScope == null
      ? 'jms.diagnostics.consent-receiver.v1'
      : '$_prefix.consent-receiver';

  bool get enabled => _enabled;
  String? get activeServerScope => _serverScope;
  bool get serverProvided =>
      _serverScope != null &&
      (preferences.getString(_endpointKey)?.isNotEmpty != true) &&
      _providedEndpoint != null;
  String get endpointValue {
    final manual = preferences.getString(_endpointKey);
    if (manual != null && manual.isNotEmpty) return manual;
    if (_serverScope != null) return _providedEndpoint ?? '';
    return manual ?? configuredEndpoint ?? _buildEndpoint;
  }

  Uri? get endpoint => diagnosticEndpoint(endpointValue, webOrigin: webOrigin);
  bool get configured =>
      !_awaitingActivation && (_reporter?.configured ?? false);

  bool _receiverMatchesConsent({bool allowLegacy = false}) {
    final receiver = endpoint?.toString();
    if (receiver == null) return false;
    final accepted = preferences.getString(_consentReceiverKey);
    return receiver == accepted || (allowLegacy && accepted == null);
  }

  /// Select only this server/account's receiver. Discovery never grants consent.
  /// An unchanged persisted scope may resume its explicitly accepted receiver;
  /// changing scope or receiver revokes both the old and selected consent.
  Future<bool> activateServer(
      String? serverScope, String? providedEndpoint) async {
    final trimmed = serverScope?.trim();
    final scope = trimmed == null || trimmed.isEmpty ? null : trimmed;
    final provided =
        diagnosticEndpoint(providedEndpoint, webOrigin: webOrigin)?.toString();
    final prefix = _scopePrefix(scope);
    final previousPrefix = _activated
        ? _prefix
        : preferences.getString(_activeScopeKey) ?? _legacyScope;
    final previousReceiver = _activated ? endpoint?.toString() : null;
    if (_disposed) return false;
    if (_activated &&
        !_awaitingActivation &&
        scope == _serverScope &&
        provided == _providedEndpoint) {
      return true;
    }
    final oldConsentKey =
        previousPrefix == _legacyScope ? consentKey : '$previousPrefix.consent';
    final initialActivation = !_activated;
    final generation = ++_generation;
    _stopReporting();
    _awaitingActivation = true;
    _serverScope = scope;
    _providedEndpoint = provided;
    _activated = true;
    final targetEndpointKey = _endpointKey;
    final targetConsentKey = _consentKey;
    notifyListeners();
    try {
      // Keep the legacy value intact. Only the first server can adopt it, and
      // consent is deliberately not migrated along with an endpoint.
      var migrated = false;
      if (scope != null && preferences.getBool(_migrationKey) != true) {
        final legacy = preferences.getString(endpointKey);
        if (!preferences.containsKey(targetEndpointKey) &&
            legacy != null &&
            legacy.isNotEmpty &&
            diagnosticEndpoint(legacy, webOrigin: webOrigin) != null) {
          if (!await preferences.setString(targetEndpointKey, legacy)) {
            return false;
          }
          migrated = true;
        }
        if (_disposed || generation != _generation) return false;
        if (!await preferences.setBool(_migrationKey, true)) return false;
      }
      if (_disposed || generation != _generation) return false;
      final sameScope = previousPrefix == prefix;
      final sameReceiver = initialActivation
          ? _receiverMatchesConsent(allowLegacy: scope == null)
          : previousReceiver == endpoint?.toString();
      final resume = sameScope && sameReceiver && !migrated;
      if (!resume) {
        if (!await preferences.setBool(oldConsentKey, false)) return false;
        if (_disposed || generation != _generation) return false;
        if (!await preferences.setBool(targetConsentKey, false)) return false;
      }
      if (_disposed || generation != _generation) return false;
      if (!await preferences.setString(_activeScopeKey, prefix)) return false;
      if (_disposed || generation != _generation) return false;
      _awaitingActivation = false;
      _enabled = resume && (preferences.getBool(_consentKey) ?? false);
      _start();
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> setEnabled(bool value) async {
    if (_disposed || (value && !configured)) return false;
    final generation = ++_generation;
    final consent = _consentKey;
    final receiverKey = _consentReceiverKey;
    final receiver = endpoint?.toString();
    _stopReporting();
    notifyListeners();
    try {
      if (value && !await preferences.setString(receiverKey, receiver!)) {
        return false;
      }
      if (_disposed || generation != _generation) return false;
      if (!await preferences.setBool(consent, value)) return false;
      if (_disposed || generation != _generation) return false;
    } catch (_) {
      return false;
    }
    _enabled = value;
    _reporter?.enabled = value;
    if (value) _hooks?.start();
    notifyListeners();
    return true;
  }

  Future<bool> setEndpoint(String value) async {
    final normalized = value.trim();
    if (_disposed ||
        (normalized.isNotEmpty &&
            diagnosticEndpoint(normalized, webOrigin: webOrigin) == null)) {
      return false;
    }
    final generation = ++_generation;
    final endpointPreference = _endpointKey;
    final consent = _consentKey;
    final wasAwaitingActivation = _awaitingActivation;
    _awaitingActivation = true;
    _stopReporting();
    notifyListeners();
    try {
      if (!await preferences.setBool(consent, false)) return false;
      if (_disposed || generation != _generation) return false;
      if (!await preferences.setString(endpointPreference, normalized)) {
        return false;
      }
      if (_disposed || generation != _generation) return false;
    } catch (_) {
      return false;
    }
    _awaitingActivation = wasAwaitingActivation;
    _start();
    notifyListeners();
    return true;
  }

  void _stopReporting() {
    _enabled = false;
    _hooks?.stop();
    _reporter?.enabled = false;
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
      clientFactory: clientFactory,
    )..enabled = enabled;
    _hooks = DiagnosticsHooks(_reporter!);
    if (enabled && configured) _hooks!.start();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _stopReporting();
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
