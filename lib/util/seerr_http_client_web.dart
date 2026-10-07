import 'package:http/browser_client.dart';
import 'package:http/http.dart' as http;

http.Client createSeerrHttpClient() {
  return BrowserClient()..withCredentials = true;
}

http.Client createJellyfinHttpClient() {
  // Jellyfin authenticates with explicit account headers, not cross-site
  // browser cookies. Including cookies also rejects wildcard CORS responses.
  return BrowserClient()..withCredentials = false;
}
