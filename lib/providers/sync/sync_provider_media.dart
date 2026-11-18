import 'dart:developer';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;

import 'package:fladder/models/items/chapters_model.dart';
import 'package:fladder/models/items/images_models.dart';
import 'package:fladder/models/items/media_streams_model.dart';
import 'package:fladder/models/syncing/sync_item.dart';
import 'package:fladder/providers/sync_provider.dart';
import 'package:fladder/screens/shared/fladder_notification_overlay.dart';
import 'package:fladder/util/string_extensions.dart';

extension SyncMediaHelpers on SyncNotifier {
  Future<List<SubStreamModel>> saveExternalSubtitles(List<SubStreamModel>? subtitles, SyncedItem item) async {
    if (subtitles == null) return [];

    final directory = item.directory;

    await directory.create(recursive: true);

    return Stream.fromIterable(subtitles.mapIndexed((position, element) => (position, element)))
        .asyncMap((track) async {
      final (position, element) = track;
      final canDownload = element.isExternal || (element.supportsExternalStream && element.url != null);
      if (canDownload) {
        try {
          final response = await http.get(Uri.parse(element.url!));
          if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
            final ext = subtitleExtension(element.codec);
            final file = File(path.join(directory.path, 'subtitle-${element.index}-$position.$ext'));
            await file.writeAsBytes(response.bodyBytes);
            return element.copyWith(
              url: () => file.path,
              isExternal: true,
            );
          }
        } catch (e) {
          log('Failed to download subtitle: ${element.displayTitle} - $e');
        }
      }
      return element;
    }).toList();
  }

  // Map codec to subtitle file extension, defaulting to .srt if unknown
  String subtitleExtension(String codec) {
    return switch (codec.toLowerCase()) {
      'ass' => 'ass',
      'ssa' => 'ssa',
      'subrip' || 'srt' => 'srt',
      'webvtt' || 'vtt' => 'vtt',
      'sub' || 'microdvd' => 'sub',
      'pgs' || 'pgssub' => 'sup',
      _ => 'srt',
    };
  }

  Future<ImagesData?> saveImageData(ImagesData? data, Directory saveDirectory) async {
    if (data == null) return data;
    if (!saveDirectory.existsSync()) return data;

    final primary = await urlDataToFileData(data.primary, saveDirectory, "primary.jpg");
    final logo = await urlDataToFileData(data.logo, saveDirectory, "logo.jpg");
    final backdrops = await Stream.fromIterable(data.backDrop ?? <ImageData>[])
        .asyncMap((element) async => await urlDataToFileData(element, saveDirectory, "backdrop-${element.key}.jpg"))
        .toList();

    return data.copyWith(
      primary: () => primary,
      logo: () => logo,
      backDrop: () => backdrops.nonNulls.toList(),
    );
  }

  Future<List<Chapter>?> saveChapterImages(List<Chapter>? data, Directory itemPath) async {
    if (data == null) return data;
    if (!itemPath.existsSync()) return data;
    if (data.isEmpty) return data;
    final saveDirectory = Directory(path.joinAll([itemPath.path, SyncedItem.chaptersPath]));

    await saveDirectory.create(recursive: true);

    final saveChapters = await Stream.fromIterable(data).asyncMap((event) async {
      if (event.imageUrl.isEmpty) return event;

      final safeName = event.name.sanitizedFileName;
      final fileName = '$safeName.jpg';

      try {
        final response = await http.get(Uri.parse(event.imageUrl));
        if (response.statusCode != 200 || response.bodyBytes.isEmpty) return event;

        final file = File(path.joinAll([saveDirectory.path, fileName]));
        await file.parent.create(recursive: true);
        await file.writeAsBytes(response.bodyBytes);

        return event.copyWith(
          imageUrl: path.joinAll([SyncedItem.chaptersPath, fileName]),
        );
      } catch (e, stackTrace) {
        FladderSnack.showException(e, stackTrace: stackTrace);
        return event;
      }
    }).toList();

    return saveChapters.nonNulls.toList();
  }

  Future<ImageData?> urlDataToFileData(ImageData? data, Directory directory, String fileName) async {
    if (data?.path == null) return null;
    final response = await http.get(Uri.parse(data?.path ?? ""));

    final file = File(path.joinAll([directory.path, fileName]));
    file.writeAsBytesSync(response.bodyBytes);

    return data?.copyWith(path: fileName);
  }
}
