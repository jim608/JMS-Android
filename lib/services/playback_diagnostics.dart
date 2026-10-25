import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:fladder/util/build_info.dart';

enum PlaybackStage {
  attempt,
  itemDetails,
  playbackInfo,
  streamSelection,
  resume,
  playerInit,
  mediaOpen,
  firstFrame,
  buffering,
  syncPlay,
  lifecycle,
}

enum PlaybackEvent { started, succeeded, failed, note }

enum PlaybackBackend {
  unknown,
  mediaKit,
  nativePlayer,
  webVideo,
  externalPlayer,
}

enum PlaybackSourceKind { unknown, localFile, networkStream }

enum PlaybackRendererKind { unknown, gpu, software }

/// An internal monotonic correlation reference, never a media or account ID.
class PlaybackAttemptRef {
  PlaybackAttemptRef._(this._owner, this._number, this.backend);

  final Object _owner;
  final int _number;
  final PlaybackBackend backend;

  String get label => 'attempt-${_number.toString().padLeft(6, '0')}';
}

/// The only free-text boundary. Conservative redaction is intentional.
/// No caller should pass URLs, headers, account data, or raw player output.
abstract final class PlaybackDiagnosticRedactor {
  static final _url = RegExp(
    r'''\b[a-z][a-z0-9+.-]{1,20}://[^\s"'<>`]+''',
    caseSensitive: false,
  );
  static final _otherUrl = RegExp(
    r'''\b(?:data|blob|mailto|magnet|intent):[^\s"'<>`]+''',
    caseSensitive: false,
  );
  static final _relativeUrl = RegExp(
    r'''(?:\bwww\.|(?<!:)//)[^\s"'<>`]+''',
    caseSensitive: false,
  );
  static final _windowsPath = RegExp(
    r'''\b[a-z]:[\\/][^\r\n"'<>]*''',
    caseSensitive: false,
  );
  static final _uncPath = RegExp(r'''\\{2,}[^\r\n"'<>]*''');
  static final _homePath = RegExp(
    r'''(?:~[\\/]|/(?:home|Users|root|storage|data|mnt|media|tmp|var/home|run/user)/)[^\r\n"'<>]*''',
    caseSensitive: false,
  );
  static final _sensitiveField = RegExp(
    r'''["']?(?:authorization|proxy[-_]?authorization|cookie|set[-_]?cookie|x[-_]?api[-_]?key|api[-_]?key|password|passwd|pwd|secret|client[-_]?secret|access[-_]?token|refresh[-_]?token|token|signature|x[-_]amz[-_]credential|session(?:[-_]?(?:id|cookie|token))?|(?:user|account|item|media|playback)[-_]?id)["']?\s*[:=]''',
    caseSensitive: false,
  );
  static final _credentialScheme = RegExp(
    r'\b(?:bearer|basic)\s+\S+',
    caseSensitive: false,
  );
  static final _jwt = RegExp(
    r'\b[A-Za-z0-9_-]{3,}\.[A-Za-z0-9_-]{3,}\.[A-Za-z0-9_-]{8,}\b',
  );
  static final _opaque = RegExp(r'\b[A-Za-z0-9_+/=-]{24,}\b');
  static final _opaqueId = RegExp(r'\b[A-Za-z0-9_-]{24,}\b');
  static final _encoded = RegExp(
    r'%[0-9a-f]{2}|\\(?:u[0-9a-f]{4}|x[0-9a-f]{2})',
    caseSensitive: false,
  );

  static String _locations(String text) => text
      .replaceAll(_otherUrl, '[url]')
      .replaceAll(_url, '[url]')
      .replaceAll(_relativeUrl, '[url]')
      .replaceAll(_windowsPath, '[path]')
      .replaceAll(_uncPath, '[path]')
      .replaceAll(_homePath, '[path]');

  static String _safeDecode(String text) {
    String ascii(int code, String original) =>
        code > 32 && code < 127 && !{34, 39, 60, 62, 96}.contains(code)
        ? String.fromCharCode(code)
        : original;
    return text
        .replaceAll(r'\/', '/')
        .replaceAllMapped(
          RegExp(r'%([0-9a-f]{2})', caseSensitive: false),
          (match) => ascii(int.parse(match[1]!, radix: 16), match[0]!),
        )
        .replaceAllMapped(
          RegExp(r'\\u([0-9a-f]{4})', caseSensitive: false),
          (match) => ascii(int.parse(match[1]!, radix: 16), match[0]!),
        )
        .replaceAllMapped(
          RegExp(r'\\x([0-9a-f]{2})', caseSensitive: false),
          (match) => ascii(int.parse(match[1]!, radix: 16), match[0]!),
        )
        .replaceAll('&amp;', '&')
        .replaceAllMapped(
          RegExp(r'&#(x[0-9a-f]+|[0-9]+);', caseSensitive: false),
          (match) {
            final raw = match[1]!;
            final code = raw.toLowerCase().startsWith('x')
                ? int.tryParse(raw.substring(1), radix: 16)
                : int.tryParse(raw);
            return code == null ? '[encoded]' : ascii(code, match[0]!);
          },
        );
  }

  static String sanitize(String input, {int maxBytes = 1024}) {
    // Bound CPU and temporary allocation before processing arbitrary messages.
    var text = input.length > 8192 ? input.substring(0, 8192) : input;
    text = _locations(text.replaceAll(r'\/', '/'));
    for (var pass = 0; pass < 4; pass++) {
      final next = _locations(_safeDecode(text));
      if (next == text) break;
      text = next;
    }
    // A malformed URL may contain unescaped whitespace in a credential.
    // Keep no remainder from a free-text URL-bearing field.
    if (text.contains('[url]')) return '[redacted url detail]';
    // Redact the entire free-text field for sensitive headers/structured data.
    // This also covers nested or malformed JSON and folded multi-line headers.
    final fieldCheck = text.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '');
    if (_sensitiveField.hasMatch(text) ||
        _sensitiveField.hasMatch(fieldCheck) ||
        _credentialScheme.hasMatch(text)) {
      return '[redacted sensitive detail]';
    }
    if (_encoded.hasMatch(text)) return '[redacted encoded detail]';
    text = text
        .replaceAll(_jwt, '[id]')
        .replaceAll(_opaque, '[id]')
        .replaceAll(_opaqueId, '[id]')
        .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return _clipUtf8(text, maxBytes.clamp(16, 1024));
  }

  static String identifier(String? value, {int maxLength = 64}) {
    if (value == null) return 'unknown';
    if (value.length > maxLength ||
        !RegExp(r'^[A-Za-z0-9_.$+-]+$').hasMatch(value) ||
        _opaqueId.hasMatch(value) ||
        _jwt.hasMatch(value)) {
      return 'unknown';
    }
    return value;
  }

  static String errorType(String? value) {
    // Type names are caller supplied as strings. A short syntactically valid
    // identifier could still be a credential, so retain only known categories.
    if (const {
      'TimeoutException',
      'StateError',
      'ArgumentError',
      'RangeError',
      'FormatException',
      'UnsupportedError',
      'PlatformException',
      'MissingPluginException',
      'Exception',
      'Error',
      'SocketException',
      'HttpException',
      'HandshakeException',
      'TlsException',
      'ClientException',
      'ChopperHttpException',
      'NativePlayerException',
      'PlayerException',
      'native_http',
      'native_timeout',
      'native_cancelled',
      'native_network',
      'native_read',
      'native_video_output',
      'native_audio_output',
      'native_decoder',
      'native_demuxer',
      'native_open',
      'native_unknown',
    }.contains(value)) {
      return value!;
    }
    // Preserve a useful canonical category without retaining a long token
    // merely because it was passed through the runtime-type field.
    if (value != null &&
        value.length <= 96 &&
        RegExp(r'^[A-Z][A-Za-z0-9]{1,95}$').hasMatch(value) &&
        (value.endsWith('Exception') ||
            value.endsWith('Error') ||
            value.endsWith('Failure'))) {
      if (value.endsWith('Exception')) return 'OtherException';
      if (value.endsWith('Error')) return 'OtherError';
      return 'OtherFailure';
    }
    return 'unknown';
  }

  static String hardwareDecoder(String? value) =>
      const {
        'no',
        'auto',
        'auto-copy',
        'vaapi',
        'vaapi-copy',
        'vdpau',
        'vdpau-copy',
        'nvdec',
        'nvdec-copy',
        'videotoolbox',
        'videotoolbox-copy',
        'd3d11va',
        'd3d11va-copy',
        'dxva2',
        'dxva2-copy',
        'cuda',
        'cuda-copy',
        'mediacodec',
        'mediacodec-copy',
        'drm',
        'drm-copy',
      }.contains(value)
      ? value!
      : 'unknown';
}

String _clipUtf8(String value, int maxBytes) {
  if (utf8.encode(value).length <= maxBytes) return value;
  final result = StringBuffer();
  var bytes = 0;
  for (final rune in value.runes) {
    final character = String.fromCharCode(rune);
    final count = utf8.encode(character).length;
    if (bytes + count + 3 > maxBytes) break;
    result.write(character);
    bytes += count;
  }
  return '$result...';
}

class PlaybackDiagnostics {
  PlaybackDiagnostics({
    int maxEvents = 128,
    int maxBytes = 64 * 1024,
    DateTime Function()? clock,
    String buildId = JmsBuildInfo.id,
    String? version,
    String sourceCommit = const String.fromEnvironment('JMS_SOURCE_COMMIT'),
    String? operatingSystem,
  }) : maxEvents = maxEvents.clamp(1, 128),
       maxBytes = maxBytes.clamp(1024, 64 * 1024),
       _clock = clock ?? DateTime.now {
    _buildId =
        RegExp(
              r'^JMS-\d{1,3}\.\d{1,3}\.\d{1,3}-jms\.\d{1,6}-(?:windows-|linux-|android-|flatpak-|web-|steamdeck-)?[a-f0-9]{12}$',
            ).hasMatch(buildId) &&
            !buildId.contains(
              RegExp(r'password|cookie|token|secret', caseSensitive: false),
            )
        ? buildId
        : 'UNSTAMPED';
    final derived = RegExp(
      r'^JMS-(.+?)-(?:windows-|linux-|android-|flatpak-|web-|steamdeck-)?[a-f0-9]{12}$',
    ).firstMatch(_buildId)?[1];
    final candidate = version ?? derived ?? 'unknown';
    _version =
        candidate.length <= 80 &&
            !PlaybackDiagnosticRedactor._opaqueId.hasMatch(candidate) &&
            RegExp(
              r'^\d{1,3}\.\d{1,3}\.\d{1,3}-jms\.\d{1,6}(?:\+\d{1,6})?$',
            ).hasMatch(candidate)
        ? candidate
        : 'unknown';
    _source = RegExp(r'^[a-f0-9]{40}$').hasMatch(sourceCommit)
        ? sourceCommit
        : 'unknown';
    final platform =
        operatingSystem ??
        (kIsWeb ? 'web' : defaultTargetPlatform.name.toLowerCase());
    _operatingSystem =
        const {
          'android',
          'ios',
          'linux',
          'macos',
          'windows',
          'fuchsia',
          'web',
        }.contains(platform)
        ? platform
        : 'unknown';
  }

  static final instance = PlaybackDiagnostics();
  final int maxEvents;
  final int maxBytes;
  final DateTime Function() _clock;
  final Object _owner = Object();
  final ListQueue<String> _events = ListQueue<String>();
  late final String _buildId;
  late final String _version;
  late final String _source;
  late final String _operatingSystem;
  int _nextAttempt = 0;
  int _eventBytes = 0;

  String get _header =>
      'JMS playback diagnostics v1\n'
      'Build: $_buildId\nVersion: $_version\nSource: $_source\nOS: $_operatingSystem\n'
      'Backend/source/renderer: typed per event\n';

  int get eventCount => _events.length;
  int get retainedBytes => utf8.encode(exportText()).length;

  PlaybackAttemptRef startAttempt({
    PlaybackBackend backend = PlaybackBackend.unknown,
  }) {
    final ref = PlaybackAttemptRef._(_owner, ++_nextAttempt, backend);
    record(ref, PlaybackStage.attempt, event: PlaybackEvent.started);
    return ref;
  }

  void record(
    PlaybackAttemptRef attempt,
    PlaybackStage stage, {
    PlaybackEvent event = PlaybackEvent.note,
    PlaybackBackend? backend,
    String? errorClass,
    int? httpStatus,
    bool timedOut = false,
    bool cancelled = false,
    String? detail,
    PlaybackSourceKind sourceKind = PlaybackSourceKind.unknown,
    bool? hardwareRequested,
    String? hwdecActual,
    bool? softwareFallback,
    PlaybackRendererKind rendererKind = PlaybackRendererKind.unknown,
  }) {
    if (!identical(attempt._owner, _owner)) return;
    final values = <String>[
      _clock().toUtc().toIso8601String(),
      attempt.label,
      stage.name,
      event.name,
      'backend=${(backend ?? attempt.backend).name}',
      'source=${sourceKind.name}',
      'renderer=${rendererKind.name}',
      if (errorClass != null)
        'error=${PlaybackDiagnosticRedactor.errorType(errorClass)}',
      if (httpStatus != null && httpStatus >= 100 && httpStatus <= 599)
        'http=$httpStatus',
      'timeout=$timedOut',
      'cancelled=$cancelled',
      if (hardwareRequested != null) 'hardwareRequested=$hardwareRequested',
      if (hwdecActual != null)
        'hwdecActual=${PlaybackDiagnosticRedactor.hardwareDecoder(hwdecActual)}',
      if (softwareFallback != null) 'softwareFallback=$softwareFallback',
      if (detail != null && detail.isNotEmpty)
        'detail=${PlaybackDiagnosticRedactor.sanitize(detail)}',
    ];
    final budget = maxBytes - utf8.encode(_header).length;
    final line = '${_clipUtf8(values.join(' | '), budget - 1)}\n';
    final bytes = utf8.encode(line).length;
    while (_events.isNotEmpty &&
        (_events.length >= maxEvents || _eventBytes + bytes > budget)) {
      _eventBytes -= utf8.encode(_events.removeFirst()).length;
    }
    if (bytes <= budget) {
      _events.addLast(line);
      _eventBytes += bytes;
    }
  }

  /// An explicit caller action; never writes files, stdout, or network traffic.
  String exportText() => _header + _events.join();

  /// Correlation numbers remain monotonic even when a user clears the ring.
  void clear() {
    _events.clear();
    _eventBytes = 0;
  }
}
