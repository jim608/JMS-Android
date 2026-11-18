import 'package:flutter_riverpod/legacy.dart';

import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/util/sleep_timer.dart';

final sleepTimerProvider = ChangeNotifierProvider<SleepTimerController>((ref) {
  return SleepTimerController(pause: () => ref.read(videoPlayerProvider).pause());
});
