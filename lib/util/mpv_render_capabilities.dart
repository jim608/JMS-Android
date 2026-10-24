import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The actual native render context is queried after the texture is created.
/// libmpv's current-vo cannot distinguish its GL and software render APIs.
class MpvRenderCapabilities {
  const MpvRenderCapabilities({
    this.apiType = 'unknown',
    this.pixelFormat = 'unknown',
    this.outputTransfer = 'unknown',
    this.reason = 'Renderer capability is unknown',
  });

  final String apiType;
  final String pixelFormat;
  final String outputTransfer;
  final String reason;

  bool get softwareSdr => apiType == 'sw' && pixelFormat == 'rgb0' && outputTransfer == 'sdr';

  Map<String, String> get diagnostics => {
        'Native render API': apiType,
        'Native texture pixel format': pixelFormat,
        'Native texture output transfer': outputTransfer,
        'Native render capability': reason,
      };

  static const configuredWindows = MpvRenderCapabilities(
    apiType: 'sw',
    pixelFormat: 'rgb0',
    outputTransfer: 'sdr',
    reason: 'Configured Windows software texture compatibility path',
  );

  factory MpvRenderCapabilities.fromNative(Object? value, {required int handle}) {
    if (value is! Map || value['version'] != 1 || value['handle'] != handle.toString()) {
      return const MpvRenderCapabilities(reason: 'Native renderer reply is missing, incompatible or stale');
    }
    final api = value['apiType'];
    final format = value['pixelFormat'];
    final transfer = value['outputTransfer'];
    if (api == 'sw' && format == 'rgb0' && transfer == 'sdr') {
      return const MpvRenderCapabilities(
          apiType: 'sw', pixelFormat: 'rgb0', outputTransfer: 'sdr', reason: 'Native Linux software render context');
    }
    return MpvRenderCapabilities(
      apiType: api == 'opengl' ? 'opengl' : 'unknown',
      reason: api == 'opengl' ? 'OpenGL output is managed by libmpv' : 'Unconfirmed SDR software texture contract',
    );
  }
}

/// A query belongs to one controller lifetime. Disposing/reinitializing or
/// starting another query invalidates late replies before they become policy.
class MpvRenderCapabilityOwner {
  var _generation = 0;
  MpvRenderCapabilities _value = const MpvRenderCapabilities();
  MpvRenderCapabilities get value => _value;

  void reset([MpvRenderCapabilities value = const MpvRenderCapabilities()]) {
    _generation++;
    _value = value;
  }

  Future<bool> resolve(Future<MpvRenderCapabilities> Function() query, {required bool Function() isCurrent}) async {
    if (!isCurrent()) return false;
    final generation = ++_generation;
    _value = const MpvRenderCapabilities(reason: 'Waiting for the current native texture capability');
    final capabilities = await query();
    if (_generation != generation || !isCurrent()) return false;
    _value = capabilities;
    return true;
  }
}

/// Unsupported/old plugins and late replies fail closed without changing the
/// requested renderer, decoder, display settings or libmpv color options.
Future<MpvRenderCapabilities> queryMpvRenderCapabilities({
  required Future<int> Function() playerHandle,
  TargetPlatform? platform,
  bool web = kIsWeb,
  Future<Object?> Function(String method, Map<String, String> arguments)? invoke,
  Duration timeout = const Duration(seconds: 2),
}) async {
  if (web) return const MpvRenderCapabilities(reason: 'Browser rendering is managed by the browser');
  final target = platform ?? defaultTargetPlatform;
  if (target == TargetPlatform.windows) return MpvRenderCapabilities.configuredWindows;
  if (target != TargetPlatform.linux) {
    return const MpvRenderCapabilities(reason: 'Platform renderer has no confirmed software SDR contract');
  }
  try {
    final handle = await playerHandle().timeout(timeout);
    final call = invoke ??
        (method, arguments) =>
            const MethodChannel('com.alexmercerind/media_kit_video').invokeMethod<Object?>(method, arguments);
    final value =
        await call('VideoOutputManager.GetRenderCapabilities', {'handle': handle.toString()}).timeout(timeout);
    return MpvRenderCapabilities.fromNative(value, handle: handle);
  } catch (_) {
    return const MpvRenderCapabilities(reason: 'Native renderer query unavailable or timed out');
  }
}
