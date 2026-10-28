/// Finalize Web-only content URLs and Flutter's generated offline manifest.
/// Never touches application, native or user configuration inputs.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

const marker = '__JMS_MAIN_CONTENT_SHA256__';

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void main(List<String> arguments) {
  require(arguments.length == 1, 'Expected the generated Web directory');
  final directory = Directory(arguments.single).absolute;
  require(directory.existsSync(), 'Generated Web directory is missing');
  final mainFile = File('${directory.path}/main.dart.js');
  final workerFile = File('${directory.path}/flutter_service_worker.js');
  final version = sha256.convert(mainFile.readAsBytesSync()).toString();
  final updated = <File, String>{};
  final originalHashes = <String, String>{};
  for (final name in ['index.html', 'flutter_bootstrap.js']) {
    final file = File('${directory.path}/$name');
    final content = file.readAsStringSync();
    require(marker.allMatches(content).length == 1,
        'Unexpected or already finalized bootstrap marker in $name');
    originalHashes[name] = md5.convert(utf8.encode(content)).toString();
    updated[file] = content.replaceFirst(marker, version);
  }
  final originalWorker = workerFile.readAsStringSync();
  final resourcePattern =
      RegExp(r'^const RESOURCES = (\{.*?\});$', multiLine: true, dotAll: true);
  final corePattern =
      RegExp(r'^const CORE = (\[.*?\]);$', multiLine: true, dotAll: true);
  final resourcesMatch = resourcePattern.firstMatch(originalWorker);
  final coreMatch = corePattern.firstMatch(originalWorker);
  require(resourcesMatch != null && coreMatch != null,
      'Unsupported generated Flutter service worker');
  final resources =
      Map<String, dynamic>.from(jsonDecode(resourcesMatch!.group(1)!) as Map);
  final core = List<String>.from(jsonDecode(coreMatch!.group(1)!) as List);
  require(
      resources['main.dart.js'] ==
          md5.convert(mainFile.readAsBytesSync()).toString(),
      'Main resource hash differs');
  require(core.where((value) => value == 'main.dart.js').length == 1,
      'Unexpected generated core entrypoint');
  for (final entry in updated.entries) {
    final name = entry.key.uri.pathSegments.last;
    require(resources[name] == originalHashes[name],
        'Generated resource hash differs for $name');
    if (name == 'index.html' && resources.containsKey('/')) {
      require(
          resources['/'] == originalHashes[name], 'Root resource hash differs');
    }
    resources[name] = md5.convert(utf8.encode(entry.value)).toString();
    if (name == 'index.html' && resources.containsKey('/')) {
      resources['/'] = resources[name];
    }
  }
  final versionedMain = 'main.dart.js?v=$version';
  resources[versionedMain] = resources['main.dart.js'];
  core[core.indexOf('main.dart.js')] = versionedMain;
  // CacheStorage ignores HTTP no-store unless the worker opts out. Mutable
  // runtime settings/version checks must keep the server's network policy.
  for (final name in [
    'assets/config/config.json',
    'version.json',
    'jms-config.json'
  ]) {
    resources.remove(name);
    core.remove(name);
  }
  const oldRequest = "new Request(value, {'cache': 'reload'})";
  require(oldRequest.allMatches(originalWorker).length == 1,
      'Unsupported generated core request policy');
  var worker = originalWorker.replaceFirst(
      resourcesMatch.group(0)!, 'const RESOURCES = ${jsonEncode(resources)};');
  worker = worker.replaceFirst(
      coreMatch.group(0)!, 'const CORE = ${jsonEncode(core)};');
  worker = worker.replaceFirst(
      oldRequest, "new Request(value, {'cache': 'no-cache'})");
  // Validate every transformation before writing any generated output.
  for (final entry in updated.entries) {
    entry.key.writeAsStringSync(entry.value, encoding: utf8);
  }
  workerFile.writeAsStringSync(worker, encoding: utf8);
  stdout.writeln(jsonEncode({
    'mainSha256': version,
    'versionedMain': versionedMain,
    'serviceWorkerForegroundWait': false
  }));
}
