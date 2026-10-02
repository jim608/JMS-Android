import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

http.Client createEntryClient({int maxResponseBytes = 65536}) =>
    IOClient(HttpClient());
