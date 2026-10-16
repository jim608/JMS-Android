typedef DiscordArtworkLoader = Future<String?> Function(String itemId);

/// Only public metadata artwork may leave the app. Never accept a Jellyfin
/// image URL, arbitrary host, signed query or embedded credentials.
String? discordArtworkUrl(String? value) {
  if (value == null || value.length > 256) return null;
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      uri.hasPort ||
      uri.hasQuery ||
      uri.hasFragment ||
      RegExp(r'^https://[^/]*:', caseSensitive: false).hasMatch(value) ||
      value.contains('%') ||
      value.contains('\\') ||
      RegExp(r'[\s\x00-\x1f\x7f]').hasMatch(value)) {
    return null;
  }
  if (uri.host == 'image.tmdb.org' &&
      RegExp(r'^/t/p/(original|w[0-9]+)/[a-zA-Z0-9]+\.(jpg|png|webp)$')
          .hasMatch(uri.path)) {
    // Bound Discord's fetch to a poster-sized image.
    return 'https://image.tmdb.org/t/p/w500/${uri.pathSegments.last}';
  }
  if (uri.host == 'artworks.thetvdb.com' &&
      RegExp(r'^/banners/[a-zA-Z0-9_/-]+\.(jpg|png|webp)$')
          .hasMatch(uri.path)) {
    return uri.toString();
  }
  return null;
}
