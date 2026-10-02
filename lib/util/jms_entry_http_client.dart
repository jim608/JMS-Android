import 'package:http/http.dart' as http;

import 'jms_entry_http_client_io.dart'
    if (dart.library.js_interop) 'jms_entry_http_client_web.dart' as platform;

http.Client createEntryClient({int maxResponseBytes = 65536}) =>
    platform.createEntryClient(maxResponseBytes: maxResponseBytes);
