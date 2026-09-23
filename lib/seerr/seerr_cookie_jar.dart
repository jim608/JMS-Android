import 'package:intl/intl.dart';

List<String> seerrSetCookieHeaders(Map<String, String> headers) => [
      for (final entry in headers.entries)
        if (entry.key.toLowerCase() == 'set-cookie') entry.value,
    ];

class SeerrCookieJar {
  SeerrCookieJar(this.origin);

  final Uri origin;
  final List<_Cookie> _cookies = [];

  factory SeerrCookieJar.fromJson(Uri origin, Map<String, dynamic> record) {
    if (record['version'] != 2 ||
        record['origin'] != origin.origin ||
        record['cookies'] is! List) {
      throw const FormatException('Invalid Seerr session scope');
    }
    final jar = SeerrCookieJar(origin);
    final entries = record['cookies'] as List;
    if (entries.length > 32) {
      throw const FormatException('Too many Seerr cookies');
    }
    for (final entry in entries) {
      if (entry is! Map<String, dynamic>) {
        throw const FormatException('Invalid Seerr cookie');
      }
      final cookie = _Cookie.fromJson(entry);
      if (cookie != null && cookie.domainMatches(origin.host)) {
        jar._cookies.add(cookie);
      }
    }
    return jar;
  }

  Map<String, dynamic> toJson() => {
        'version': 2,
        'origin': origin.origin,
        'cookies': [for (final cookie in _cookies) cookie.toJson()],
      };

  bool get isEmpty => _cookies.isEmpty;

  bool ingest(Uri responseUri, Iterable<String> headers, {DateTime? now}) {
    if (responseUri.origin != origin.origin) return false;
    final current = now ?? DateTime.now().toUtc();
    var received = false;
    for (final header in headers) {
      for (final setCookie in _splitSetCookie(header)) {
        final cookie = _Cookie.parse(setCookie, responseUri, current);
        if (cookie == null) continue;
        _cookies.removeWhere((existing) => existing.sameIdentity(cookie));
        if (cookie.expiresAt == null || cookie.expiresAt!.isAfter(current)) {
          _cookies.add(cookie);
          received = true;
        }
      }
    }
    _cookies
        .removeWhere((cookie) => cookie.expiresAt?.isAfter(current) == false);
    if (_cookies.length > 32) {
      throw const FormatException('Too many Seerr cookies');
    }
    return received;
  }

  String? headerFor(Uri requestUri, {DateTime? now}) {
    if (requestUri.origin != origin.origin) return null;
    final current = now ?? DateTime.now().toUtc();
    final matching = _cookies
        .where((cookie) =>
            cookie.matches(requestUri) &&
            (cookie.expiresAt?.isAfter(current) ?? true))
        .toList()
      ..sort(
          (first, second) => second.path.length.compareTo(first.path.length));
    return matching.isEmpty
        ? null
        : matching.map((cookie) => '${cookie.name}=${cookie.value}').join('; ');
  }

  static Iterable<String> _splitSetCookie(String header) sync* {
    var start = 0;
    var quoted = false;
    for (var index = 0; index < header.length; index++) {
      if (header[index] == '"' && (index == 0 || header[index - 1] != r'\')) {
        quoted = !quoted;
      }
      if (quoted || header[index] != ',') continue;
      if (RegExp(r"^\s*[!#\$%&'*+.^_`|~0-9A-Za-z-]+=")
          .hasMatch(header.substring(index + 1))) {
        yield header.substring(start, index).trim();
        start = index + 1;
      }
    }
    yield header.substring(start).trim();
  }
}

class _Cookie {
  _Cookie(this.name, this.value, this.domain, this.hostOnly, this.path,
      this.secure, this.httpOnly, this.sameSite, this.expiresAt);

  final String name;
  final String value;
  final String domain;
  final bool hostOnly;
  final String path;
  final bool secure;
  final bool httpOnly;
  final String? sameSite;
  final DateTime? expiresAt;

  bool sameIdentity(_Cookie other) =>
      name == other.name && domain == other.domain && path == other.path;

  bool domainMatches(String host) => hostOnly
      ? host.toLowerCase() == domain
      : host.toLowerCase() == domain || host.toLowerCase().endsWith('.$domain');

  bool matches(Uri uri) {
    if (secure && uri.scheme != 'https' ||
        !domainMatches(uri.host) ||
        !uri.path.startsWith(path)) {
      return false;
    }
    return path.endsWith('/') ||
        uri.path.length == path.length ||
        uri.path[path.length] == '/';
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'value': value,
        'domain': domain,
        'hostOnly': hostOnly,
        'path': path,
        'secure': secure,
        'httpOnly': httpOnly,
        'sameSite': sameSite,
        'expiresAt': expiresAt?.millisecondsSinceEpoch,
      };

  static _Cookie? fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    final value = json['value'];
    final domain = json['domain'];
    final path = json['path'];
    final expires = json['expiresAt'];
    if (name is! String ||
        !_validName(name) ||
        value is! String ||
        !_validValue(value) ||
        domain is! String ||
        domain.isEmpty ||
        path is! String ||
        !path.startsWith('/') ||
        json['hostOnly'] is! bool ||
        json['secure'] is! bool ||
        json['httpOnly'] is! bool ||
        (expires != null && expires is! int)) {
      return null;
    }
    return _Cookie(
        name,
        value,
        domain,
        json['hostOnly'] as bool,
        path,
        json['secure'] as bool,
        json['httpOnly'] as bool,
        json['sameSite'] is String ? json['sameSite'] as String : null,
        expires == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(expires, isUtc: true));
  }

  static _Cookie? parse(String header, Uri responseUri, DateTime now) {
    final parts = header.split(';');
    final equals = parts.first.indexOf('=');
    if (equals <= 0) return null;
    final name = parts.first.substring(0, equals).trim();
    final value = parts.first.substring(equals + 1).trim();
    if (!_validName(name) || !_validValue(value)) return null;
    var domain = responseUri.host.toLowerCase();
    var hostOnly = true;
    final requestPath = responseUri.path;
    final lastSlash = requestPath.lastIndexOf('/');
    var path = lastSlash <= 0 ? '/' : requestPath.substring(0, lastSlash);
    var secure = false;
    var httpOnly = false;
    String? sameSite;
    DateTime? expiresAt;
    int? maxAge;
    for (final part in parts.skip(1)) {
      final attribute = part.trim();
      final split = attribute.indexOf('=');
      final key = (split < 0 ? attribute : attribute.substring(0, split))
          .trim()
          .toLowerCase();
      final attributeValue =
          split < 0 ? '' : attribute.substring(split + 1).trim();
      switch (key) {
        case 'domain':
          final candidate =
              attributeValue.replaceFirst(RegExp(r'^\.'), '').toLowerCase();
          if (candidate.isEmpty ||
              (responseUri.host.toLowerCase() != candidate &&
                  !responseUri.host.toLowerCase().endsWith('.$candidate'))) {
            return null;
          }
          domain = candidate;
          hostOnly = false;
        case 'path':
          if (attributeValue.startsWith('/')) path = attributeValue;
        case 'max-age':
          maxAge = int.tryParse(attributeValue);
        case 'expires':
          try {
            expiresAt = DateFormat('EEE, dd MMM yyyy HH:mm:ss', 'en_US')
                .parseUtc(attributeValue.replaceFirst(
                    RegExp(r'\s+GMT$', caseSensitive: false), ''));
          } on FormatException {
            expiresAt = null;
          }
        case 'secure':
          secure = true;
        case 'httponly':
          httpOnly = true;
        case 'samesite':
          sameSite = attributeValue;
      }
    }
    if (secure && responseUri.scheme != 'https') return null;
    if (maxAge != null) {
      expiresAt = maxAge <= 0 ? now : now.add(Duration(seconds: maxAge));
    }
    return _Cookie(name, value, domain, hostOnly, path, secure, httpOnly,
        sameSite, expiresAt);
  }

  static bool _validName(String name) =>
      RegExp(r"^[!#\$%&'*+.^_`|~0-9A-Za-z-]{1,256}$").hasMatch(name);

  static bool _validValue(String value) =>
      value.length <= 4096 && !RegExp(r'[\x00-\x1f\x7f;,]').hasMatch(value);
}
