part of 'play_item_helpers.dart';

const _playlistAudioInitialQueueLimit = 5;
const _playlistAudioRefillLimit = 100;

extension PlaylistModelPlayback on PlaylistModel? {
  Future<void> play(
    BuildContext context,
    WidgetRef ref, {
    Duration? startPosition,
    bool showPlaybackOption = false,
  }) async {
    final playlist = this;
    if (playlist == null) return;

    final diagnostics = PlaybackDiagnostics.instance;
    final attempt = diagnostics.startAttempt();
    try {
      await ref.read(videoPlayerProvider.notifier).init();
    } catch (error) {
      diagnostics.record(attempt, PlaybackStage.playerInit,
          event: PlaybackEvent.failed,
          errorClass: error.runtimeType.toString(),
          detail: 'playlist_renderer');
      _showPlaybackError(context);
      return;
    }

    final op = CancelableOperation.fromFuture(Future(() async {
      final previewItems =
          await _fetchPlaylistItems(playlist.id, ref, maxItems: 50);
      final previewClassification = _classifyPlaylistItems(previewItems);

      if (!previewClassification.hasAny) return null;

      final actionCount = [
        previewClassification.hasPlayable,
        previewClassification.hasMusic,
        previewClassification.hasGallery,
      ].where((value) => value).length;

      if (actionCount > 1) {
        return (
          classification: previewClassification,
          model: null,
          queue: <ItemBaseModel>[],
          isAudio: false,
          photos: <PhotoModel>[]
        );
      }

      if (previewClassification.hasMusic) {
        final queueSource = PlaylistAudioQueueSource(
          playlistId: playlist.id,
          limit: _playlistAudioRefillLimit,
          shuffle: false,
        );
        final initialQueue = await queueSource.fetchQueue(
          ref.read,
          limit: _playlistAudioInitialQueueLimit,
          startIndex: 0,
        );
        if (initialQueue.isEmpty) return null;
        final model = await ref.read(playbackModelHelper).createPlaybackModel(
              context,
              initialQueue.firstOrNull,
              libraryQueue: initialQueue,
              diagnosticAttempt: attempt,
              queueSource: queueSource,
            );
        return (
          classification: null,
          model: model,
          queue: initialQueue,
          isAudio: true,
          photos: <PhotoModel>[]
        );
      }

      final fullItems = await _fetchPlaylistItems(playlist.id, ref);
      final full = _classifyPlaylistItems(fullItems);

      if (previewClassification.hasPlayable) {
        if (full.playable.isEmpty) return null;
        final model = await ref.read(playbackModelHelper).createPlaybackModel(
              context,
              full.playable.firstOrNull,
              libraryQueue: full.playable,
              diagnosticAttempt: attempt,
            );
        return (
          classification: null,
          model: model,
          queue: full.playable,
          isAudio: false,
          photos: <PhotoModel>[]
        );
      }

      return (
        classification: null,
        model: null,
        queue: <ItemBaseModel>[],
        isAudio: false,
        photos: full.gallery
      );
    }));

    showPlaybackLoadingIndicator(context, playlist, op);

    final result = await op.valueOrCancellation(null);

    if (!op.isCanceled) {
      closePlaybackLoadingIndicator(op);
    }

    if (op.isCanceled || result == null) {
      if (op.isCanceled) {
        diagnostics.record(attempt, PlaybackStage.lifecycle,
            cancelled: true, detail: 'loading_cancelled');
      }
      if (!op.isCanceled && context.mounted) {
        _showPlaybackError(context, unableToPlay: true);
      }
      return;
    }

    if (!context.mounted) return;

    if (result.classification != null) {
      final classification = result.classification!;
      await showLibraryPlayOptions(
        context,
        context.localized.libraryPlayItems,
        playVideos: classification.hasPlayable
            ? () => _playPlaylistVideos(context, ref, playlist.id)
            : null,
        playMusic: classification.hasMusic
            ? () => _playPlaylistMusic(context, ref, playlist.id)
            : null,
        viewGallery: classification.hasGallery
            ? () => _playPlaylistGallery(context, ref, playlist.id)
            : null,
      );
      return;
    }

    if (result.photos.isNotEmpty) {
      await context.pushRoute(PhotoViewerRoute(items: result.photos));
      if (context.mounted) await context.refreshData();
      return;
    }

    if (result.model == null || result.queue.isEmpty) {
      _showPlaybackError(context, unableToPlay: true);
      return;
    }

    final model = result.model!;
    final queue = result.queue;

    if (result.isAudio) {
      final currentIndex = queue
          .indexWhere((e) => e.id == model.item.id)
          .clamp(0, queue.length - 1);
      final actualStartPosition =
          startPosition ?? await model.startDuration() ?? Duration.zero;
      await ref.read(videoPlayerProvider.notifier).loadAudioPlaybackItem(
          model, queue, currentIndex, actualStartPosition);
    } else {
      if (!await _openPlaylistVideo(context, ref, model, attempt,
          startPosition: startPosition)) {
        return;
      }
      if (AdaptiveLayout.of(context).isDesktop &&
          defaultTargetPlatform != TargetPlatform.macOS) {
        fullScreenHelper.closeFullScreen(ref);
      }
      if (context.mounted) await context.refreshData();
    }
  }
}

Future<void> _playPlaylistMusic(
    BuildContext context, WidgetRef ref, String playlistId) async {
  await ref.read(videoPlayerProvider.notifier).init();

  final op = CancelableOperation.fromFuture(Future(() async {
    final queueSource = PlaylistAudioQueueSource(
      playlistId: playlistId,
      limit: _playlistAudioRefillLimit,
      shuffle: false,
    );
    final initialQueue = await queueSource.fetchQueue(
      ref.read,
      limit: _playlistAudioInitialQueueLimit,
      startIndex: 0,
    );
    if (initialQueue.isEmpty) return null;
    final model = await ref.read(playbackModelHelper).createPlaybackModel(
          context,
          initialQueue.firstOrNull,
          libraryQueue: initialQueue,
          queueSource: queueSource,
        );
    if (model == null) return null;
    return (model, initialQueue);
  }));

  showPlaybackLoadingIndicator(context, null, op);

  final result = await op.valueOrCancellation(null);

  if (!op.isCanceled) {
    closePlaybackLoadingIndicator(op);
  }

  if (op.isCanceled || result == null) {
    if (!op.isCanceled && context.mounted) {
      FladderSnack.show(context.localized.unableToPlayMedia, context: context);
    }
    return;
  }

  final (model, queue) = result;
  final currentIndex =
      queue.indexWhere((e) => e.id == model.item.id).clamp(0, queue.length - 1);
  final actualStartPosition = await model.startDuration() ?? Duration.zero;
  await ref
      .read(videoPlayerProvider.notifier)
      .loadAudioPlaybackItem(model, queue, currentIndex, actualStartPosition);
}

Future<void> _playPlaylistVideos(
    BuildContext context, WidgetRef ref, String playlistId) async {
  final diagnostics = PlaybackDiagnostics.instance;
  final attempt = diagnostics.startAttempt();
  try {
    await ref.read(videoPlayerProvider.notifier).init();
  } catch (error) {
    diagnostics.record(attempt, PlaybackStage.playerInit,
        event: PlaybackEvent.failed,
        errorClass: error.runtimeType.toString(),
        detail: 'playlist_renderer');
    _showPlaybackError(context);
    return;
  }

  final op = CancelableOperation.fromFuture(Future(() async {
    final items = await _fetchPlaylistItems(playlistId, ref);
    final classified = _classifyPlaylistItems(items);
    if (classified.playable.isEmpty) return null;
    final model = await ref.read(playbackModelHelper).createPlaybackModel(
          context,
          classified.playable.firstOrNull,
          libraryQueue: classified.playable,
          diagnosticAttempt: attempt,
        );
    if (model == null) return null;
    return (model, classified.playable);
  }));

  showPlaybackLoadingIndicator(context, null, op);

  final result = await op.valueOrCancellation(null);

  if (!op.isCanceled) {
    closePlaybackLoadingIndicator(op);
  }

  if (op.isCanceled || result == null) {
    if (op.isCanceled) {
      diagnostics.record(attempt, PlaybackStage.lifecycle,
          cancelled: true, detail: 'loading_cancelled');
    }
    if (!op.isCanceled && context.mounted) {
      _showPlaybackError(context, unableToPlay: true);
    }
    return;
  }

  final (model, queue) = result;
  if (!await _openPlaylistVideo(context, ref, model, attempt)) return;
  if (AdaptiveLayout.of(context).isDesktop &&
      defaultTargetPlatform != TargetPlatform.macOS) {
    fullScreenHelper.closeFullScreen(ref);
  }
  if (context.mounted) await context.refreshData();
}

Future<void> _playPlaylistGallery(
    BuildContext context, WidgetRef ref, String playlistId) async {
  final op = CancelableOperation.fromFuture(Future(() async {
    final items = await _fetchPlaylistItems(playlistId, ref);
    return _classifyPlaylistItems(items).gallery;
  }));

  showPlaybackLoadingIndicator(context, null, op);

  final photos = await op.valueOrCancellation(null);

  if (!op.isCanceled) {
    closePlaybackLoadingIndicator(op);
  }

  if (op.isCanceled || photos == null || photos.isEmpty) {
    if (!op.isCanceled && context.mounted) {
      FladderSnack.show(context.localized.unableToPlayMedia, context: context);
    }
    return;
  }

  if (context.mounted) {
    await context.pushRoute(PhotoViewerRoute(items: photos));
    if (context.mounted) await context.refreshData();
  }
}

class _PlaylistClassification {
  final List<ItemBaseModel> playable;
  final List<ItemBaseModel> music;
  final List<PhotoModel> gallery;

  const _PlaylistClassification({
    required this.playable,
    required this.music,
    required this.gallery,
  });

  bool get hasPlayable => playable.isNotEmpty;
  bool get hasMusic => music.isNotEmpty;
  bool get hasGallery => gallery.isNotEmpty;
  bool get hasAny => hasPlayable || hasMusic || hasGallery;
}

_PlaylistClassification _classifyPlaylistItems(List<ItemBaseModel> items) {
  return _PlaylistClassification(
    playable: items
        .where((item) => FladderItemType.playable.contains(item.type))
        .toList(),
    music: items
        .where((item) => FladderItemType.musicPlayable.contains(item.type))
        .toList(),
    gallery: items.whereType<PhotoModel>().toList(),
  );
}

Future<List<ItemBaseModel>> _fetchPlaylistItems(
    String playlistId, WidgetRef ref,
    {int? maxItems}) async {
  const pageSize = 100;
  var startIndex = 0;
  final items = <ItemBaseModel>[];

  while (true) {
    final remaining = maxItems != null ? maxItems - items.length : pageSize;
    if (remaining <= 0) break;

    final requestLimit = min(pageSize, remaining);
    final response =
        await ref.read(jellyApiProvider).playlistsPlaylistIdItemsGet(
      playlistId: playlistId,
      startIndex: startIndex,
      limit: requestLimit,
      enableUserData: true,
      enableImages: true,
      imageTypeLimit: 1,
      fields: [
        ItemFields.primaryimageaspectratio,
        ItemFields.mediasources,
        ItemFields.mediastreams,
        ItemFields.parentid,
        ItemFields.overview,
      ],
    );

    final pageItems = response.body?.items ?? const <ItemBaseModel>[];
    if (pageItems.isEmpty) break;

    items.addAll(pageItems);
    startIndex += pageItems.length;

    final totalCount = response.body?.totalRecordCount;
    if (totalCount != null && startIndex >= totalCount) {
      break;
    }

    if (pageItems.length < requestLimit) {
      break;
    }
  }

  return items;
}

Future<bool> _openPlaylistVideo(BuildContext context, WidgetRef ref,
    PlaybackModel model, PlaybackAttemptRef attempt,
    {Duration? startPosition, bool Function()? isCurrent}) async {
  final diagnostics = PlaybackDiagnostics.instance;
  final player = ref.read(videoPlayerProvider.notifier);
  bool available() => context.mounted && (isCurrent?.call() ?? true);
  bool currentAttempt() =>
      available() && player.isPlaybackAttemptCurrent(attempt);
  var stage = PlaybackStage.resume;
  var step = 'start_position';
  try {
    diagnostics.record(attempt, stage,
        event: PlaybackEvent.started, detail: step);
    final actualStartPosition =
        startPosition ?? await model.startDuration() ?? Duration.zero;
    diagnostics.record(attempt, stage,
        event: PlaybackEvent.succeeded, detail: step);
    stage = PlaybackStage.mediaOpen;
    step = 'load_playback';
    if (!available()) return false;
    final loaded = await player.loadPlaybackItem(model, actualStartPosition,
        diagnosticAttempt: attempt, isCurrent: available);
    if (!loaded) {
      if (currentAttempt()) _showPlaybackError(context);
      return false;
    }
    if (!currentAttempt()) return false;
    stage = PlaybackStage.lifecycle;
    step = 'open_player_route';
    await player.openPlaybackAttempt(context, attempt,
        isCurrent: currentAttempt);
    return currentAttempt();
  } catch (error) {
    diagnostics.record(attempt, stage,
        event: PlaybackEvent.failed,
        errorClass: error.runtimeType.toString(),
        detail: step);
    _showPlaybackError(context);
    return false;
  }
}
