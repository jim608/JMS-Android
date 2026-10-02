import 'package:fladder/util/app_diagnostics.dart' as diagnostics;

/// Only public service addresses; never an authentication or global config store.
final class JmsServiceConfig {
  JmsServiceConfig._(this.baseUrl, this.seerrBaseUrl, this.diagnosticsEndpoint);

  factory JmsServiceConfig({
    required String baseUrl,
    String? seerrBaseUrl,
    String? diagnosticsEndpoint,
  }) =>
      JmsServiceConfig.fromJson({
        'baseUrl': baseUrl,
        'seerrBaseUrl': seerrBaseUrl,
        'diagnosticsEndpoint': diagnosticsEndpoint,
      });

  factory JmsServiceConfig.fromJson(Map<String, dynamic> json) {
    const fields = {'baseUrl', 'seerrBaseUrl', 'diagnosticsEndpoint'};
    if (json.keys.any((key) => !fields.contains(key)) ||
        json['baseUrl'] is! String) {
      throw const FormatException('Invalid service configuration fields');
    }
    final base = _serviceUrl(json['baseUrl'] as String);
    final seerr = _optionalString(json, 'seerrBaseUrl');
    final diagnostic = _optionalString(json, 'diagnosticsEndpoint');
    if (diagnostic != null) _validatedUri(diagnostic, allowHttp: false);
    final endpoint =
        diagnostic == null ? null : diagnostics.diagnosticEndpoint(diagnostic);
    if (diagnostic != null && endpoint == null) {
      throw const FormatException('Invalid diagnostic endpoint');
    }
    return JmsServiceConfig._(
        base, seerr == null ? null : _serviceUrl(seerr), endpoint?.toString());
  }

  /// Used only after a successful anonymous Jellyfin public-info probe.
  factory JmsServiceConfig.direct(Uri entry) {
    final normalized = normalizeJmsEntry(entry.toString());
    return JmsServiceConfig._(_withoutTrailingSlash(normalized), null, null);
  }

  final String baseUrl;
  final String? seerrBaseUrl;
  final String? diagnosticsEndpoint;

  Map<String, dynamic> toJson() => {
        'baseUrl': baseUrl,
        'seerrBaseUrl': seerrBaseUrl,
        'diagnosticsEndpoint': diagnosticsEndpoint,
      };

  @override
  bool operator ==(Object other) =>
      other is JmsServiceConfig &&
      baseUrl == other.baseUrl &&
      seerrBaseUrl == other.seerrBaseUrl &&
      diagnosticsEndpoint == other.diagnosticsEndpoint;

  @override
  int get hashCode => Object.hash(baseUrl, seerrBaseUrl, diagnosticsEndpoint);

  static String? _optionalString(Map<String, dynamic> json, String field) {
    final value = json[field];
    if (value == null) return null;
    if (value is! String || value.trim().isEmpty) {
      throw const FormatException('Invalid optional service address');
    }
    return value;
  }

  static String _serviceUrl(String value) {
    final uri = _validatedUri(value, allowHttp: false);
    return _withoutTrailingSlash(uri);
  }
}

/// A missing scheme means HTTPS. Explicit HTTP is retained for direct LAN use;
/// the discovery service never requests a website config over HTTP.
Uri normalizeJmsEntry(String value) {
  final trimmed = value.trim();
  final withScheme = trimmed.contains('://') ? trimmed : 'https://$trimmed';
  final uri = _validatedUri(withScheme, allowHttp: true).normalizePath();
  final path = uri.path.replaceFirst(RegExp(r'/+$'), '');
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: '$path/',
  );
}

Uri _validatedUri(String value, {required bool allowHttp}) {
  final trimmed = value.trim();
  if (trimmed.isEmpty ||
      trimmed.length > 2048 ||
      RegExp(r'[\\\x00-\x20\x7f]').hasMatch(trimmed)) {
    throw const FormatException('Invalid service address');
  }
  final uri = Uri.tryParse(trimmed);
  if (uri == null ||
      (uri.scheme != 'https' && !(allowHttp && uri.scheme == 'http')) ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      uri.port < 1 ||
      uri.port > 65535) {
    throw const FormatException('Invalid service address');
  }
  return uri;
}

String _withoutTrailingSlash(Uri uri) =>
    uri.replace(path: uri.path.replaceFirst(RegExp(r'/+$'), '')).toString();
