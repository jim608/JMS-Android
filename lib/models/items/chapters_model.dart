import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart' as dto;
import 'package:fladder/providers/image_provider.dart';
import 'package:fladder/util/custom_cache_manager.dart';

class Chapter {
  final String name;
  final String imageUrl;
  final Uint8List? imageData;
  final Duration startPosition;
  Chapter({
    required this.name,
    required this.imageUrl,
    this.imageData,
    required this.startPosition,
  });

  ImageProvider get imageProvider {
    if (imageData != null) {
      return Image.memory(imageData!).image;
    }
    if (imageUrl.startsWith("http")) {
      return CachedNetworkImageProvider(
        cacheKey: name + imageUrl,
        cacheManager: CustomCacheManager.instance,
        imageUrl,
      );
    } else {
      return Image.file(
        key: Key(name + imageUrl),
        File(imageUrl),
      ).image;
    }
  }

  static List<Chapter> chaptersFromInfo(
      String itemId, List<dto.ChapterInfo> chapters, Ref ref) {
    return chapters
        // Missing timestamps are not chapter starts. Keep the original server
        // index for thumbnails even when malformed entries are discarded.
        .mapIndexed((index, element) {
          final ticks = element.startPositionTicks;
          if (ticks == null || ticks < 0) return null;
          return Chapter(
            name: element.name ?? "",
            imageUrl:
                ref.read(imageUtilityProvider).getChapterUrl(itemId, index),
            startPosition: Duration(microseconds: ticks ~/ 10),
          );
        })
        .whereType<Chapter>()
        .toList();
  }

  Chapter copyWith({
    String? name,
    String? imageUrl,
    Duration? startPosition,
  }) {
    return Chapter(
      name: name ?? this.name,
      imageUrl: imageUrl ?? this.imageUrl,
      startPosition: startPosition ?? this.startPosition,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'imageUrl': imageUrl,
      'startPosition': startPosition.inMilliseconds,
    };
  }

  factory Chapter.fromMap(Map<String, dynamic> map) {
    return Chapter(
      name: map['name'] ?? '',
      imageUrl: map['imageUrl'] ?? '',
      startPosition: Duration(milliseconds: map['startPosition'] as int),
    );
  }

  String toJson() => json.encode(toMap());

  factory Chapter.fromJson(String source) =>
      Chapter.fromMap(json.decode(source));
}

extension ChapterExtension on List<Chapter> {
  ChapterNavigation navigationAt(Duration position, {Duration? duration}) =>
      ChapterNavigation(chapters: this, position: position, duration: duration);

  Chapter? getChapterFromDuration(Duration duration) {
    return lastWhereOrNull((element) => element.startPosition < duration);
  }
}

/// Navigation uses actual, unique chapter starts and never wraps at an edge.
/// A zero/unknown media duration does not manufacture an upper bound.
class ChapterNavigation {
  ChapterNavigation({
    required Iterable<Chapter> chapters,
    required this.position,
    Duration? duration,
  }) : chapters = _normalize(chapters, duration);

  final List<Chapter> chapters;
  final Duration position;

  Chapter? get previous =>
      chapters.lastWhereOrNull((chapter) => chapter.startPosition < position);
  Chapter? get next =>
      chapters.firstWhereOrNull((chapter) => chapter.startPosition > position);

  static List<Chapter> _normalize(
      Iterable<Chapter> source, Duration? duration) {
    final unique = <Duration, Chapter>{};
    for (final chapter in source) {
      final start = chapter.startPosition;
      if (start < Duration.zero ||
          (duration != null && duration > Duration.zero && start >= duration)) {
        continue;
      }
      unique.putIfAbsent(start, () => chapter);
    }
    final starts = unique.keys.toList()..sort();
    return List.unmodifiable(starts.map((start) => unique[start]!));
  }
}
