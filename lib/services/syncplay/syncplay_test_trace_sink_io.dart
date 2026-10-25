import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'package:fladder/util/jms_test_profile_policy.dart';

bool get isNativeWindows => Platform.isWindows;

Future<void> _writes = Future.value();
const _maximumBytes = 64 * 1024;

Future<void> writeSyncPlayTestTraceLine(String line) {
  if (!JmsTestProfilePolicy.enabled || !Platform.isWindows) {
    return Future.value();
  }
  _writes = _writes.then((_) async {
    final bytes = utf8.encode(line);
    if (bytes.length > 2048) return;
    // WindowsTestProfile redirects this path before app services initialize.
    final cache = await getApplicationCacheDirectory();
    final file = File(path.join(cache.path, 'jms-syncplay-test-trace.jsonl'));
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      return;
    }
    final length = type == FileSystemEntityType.file ? await file.length() : 0;
    if (length + bytes.length > _maximumBytes) return;
    await file.writeAsBytes(bytes, mode: FileMode.append);
  }).catchError((Object _) {});
  return _writes;
}
