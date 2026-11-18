import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/util/settings_backup.dart';

final settingsBackupFilesProvider = Provider((ref) => SettingsBackupFiles());

class SettingsBackupFiles {
  Future<Uint8List?> pick() async {
    final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['json']);
    if (file == null) return null;
    final size = file.lengthSync();
    if (size != null && size > SettingsBackup.maxBytes) {
      throw const SettingsBackupFailure('size');
    }
    return readLimited(file.readAsByteStream());
  }

  static Future<Uint8List> readLimited(Stream<List<int>> stream) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in stream.timeout(const Duration(seconds: 15))) {
      if (bytes.length + chunk.length > SettingsBackup.maxBytes) {
        throw const SettingsBackupFailure('size');
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  Future<String> save(Uint8List bytes) async {
    final path = await FilePicker.saveFile(fileName: 'JMS-settings-v1.json', mimeType: 'application/json', bytes: bytes);
    return kIsWeb
        ? 'saveRequested'
        : path == null
            ? 'cancelled'
            : 'saved';
  }
}
