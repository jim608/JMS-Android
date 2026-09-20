import 'dart:async';

import 'package:flutter/widgets.dart';

enum SleepTimerMode { off, countdown, episode, expired }

class SleepTimerController extends ChangeNotifier with WidgetsBindingObserver {
  final DateTime Function() now;
  final Future<void> Function() pause;
  Timer? _timer;
  DateTime? deadline;
  String? _mediaId;
  String? _episodeId;
  bool _disposed = false;
  int _generation = 0;
  bool pauseFailed = false;
  SleepTimerMode mode = SleepTimerMode.off;

  SleepTimerController({required this.pause, DateTime Function()? now}) : now = now ?? DateTime.now {
    WidgetsBinding.instance.addObserver(this);
  }

  bool get blocksAutoNext => mode == SleepTimerMode.episode || mode == SleepTimerMode.expired;
  bool get allowsPlayback => mode != SleepTimerMode.expired;
  Duration get remaining {
    final difference = deadline?.difference(now()) ?? Duration.zero;
    return difference.isNegative ? Duration.zero : difference;
  }

  void countdown(Duration duration) {
    if (duration < const Duration(minutes: 1) || duration > const Duration(hours: 12)) {
      throw ArgumentError.value(duration, 'duration');
    }
    _timer?.cancel();
    deadline = now().add(duration);
    _generation++;
    _episodeId = null;
    pauseFailed = false;
    mode = SleepTimerMode.countdown;
    refresh();
    notifyListeners();
  }

  void afterEpisode(String mediaId) {
    if (mediaId.isEmpty) throw ArgumentError.value(mediaId, 'mediaId');
    _timer?.cancel();
    _generation++;
    deadline = null;
    _mediaId = mediaId;
    _episodeId = mediaId;
    pauseFailed = false;
    mode = SleepTimerMode.episode;
    notifyListeners();
  }

  void bindMedia(String mediaId) {
    if (_mediaId != mediaId && mode == SleepTimerMode.episode) cancel();
    _mediaId = mediaId;
    refresh();
  }

  void completed() {
    if (mode == SleepTimerMode.episode && _episodeId == _mediaId) _expire();
  }

  void manualPlay() {
    if (mode == SleepTimerMode.expired) cancel();
    refresh();
  }

  void refresh() {
    if (_disposed || mode != SleepTimerMode.countdown) return;
    _timer?.cancel();
    if (!now().isBefore(deadline!)) {
      _expire();
    } else {
      _timer = Timer(remaining, refresh);
    }
  }

  void _expire() {
    final generation = ++_generation;
    _timer?.cancel();
    deadline = null;
    mode = SleepTimerMode.expired;
    notifyListeners();
    unawaited(Future<void>.sync(pause).catchError((Object error) {
      if (!_disposed && generation == _generation && mode == SleepTimerMode.expired) {
        pauseFailed = true;
        notifyListeners();
      }
    }));
  }

  void cancel() {
    _generation++;
    _timer?.cancel();
    deadline = null;
    _episodeId = null;
    mode = SleepTimerMode.off;
    pauseFailed = false;
    if (!_disposed) notifyListeners();
  }

  void endSession() {
    cancel();
    _mediaId = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refresh();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
