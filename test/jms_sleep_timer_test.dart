import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fladder/util/sleep_timer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DateTime now;
  late SleepTimerController timer;
  late int pauses;
  setUp(() {
    now = DateTime.utc(2026, 9, 20, 12);
    pauses = 0;
    timer = SleepTimerController(
        now: () => now,
        pause: () async {
          pauses++;
        });
    timer.bindMedia('episode-a');
  });
  tearDown(() => timer.dispose());

  test('deadline includes pause/background time; no UI tick accumulation', () {
    timer.countdown(const Duration(minutes: 2));
    final deadline = timer.deadline;
    now = now.add(const Duration(seconds: 90));
    expect(timer.remaining, const Duration(seconds: 30));
    timer.didChangeAppLifecycleState(AppLifecycleState.paused);
    now = now.add(const Duration(minutes: 1));
    timer.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(pauses, 1);
    expect(timer.mode, SleepTimerMode.expired);
    expect(timer.blocksAutoNext, true);
    expect(deadline, DateTime.utc(2026, 9, 20, 12, 2));
    timer.refresh();
    expect(pauses, 1);
  });
  test('reset replaces the deadline and cancel prevents expiry', () {
    timer.countdown(const Duration(minutes: 1));
    now = now.add(const Duration(seconds: 50));
    timer.countdown(const Duration(minutes: 3));
    now = now.add(const Duration(seconds: 20));
    timer.refresh();
    expect(pauses, 0);
    timer.cancel();
    now = now.add(const Duration(hours: 1));
    timer.refresh();
    expect(pauses, 0);
    expect(timer.deadline, isNull);
  });
  test('only real completed event stops the bound episode once', () {
    timer.afterEpisode('episode-a');
    expect(timer.blocksAutoNext, true);
    now = now.add(const Duration(hours: 3));
    timer.refresh();
    expect(pauses, 0);
    timer.completed();
    timer.completed();
    expect(pauses, 1);
    expect(timer.blocksAutoNext, true);
  });
  test('manual episode change cancels end mode; countdown continues', () {
    timer.afterEpisode('episode-a');
    timer.bindMedia('episode-b');
    timer.completed();
    expect(pauses, 0);
    expect(timer.mode, SleepTimerMode.off);
    timer.countdown(const Duration(minutes: 4));
    final deadline = timer.deadline;
    timer.bindMedia('episode-c');
    expect(timer.deadline, deadline);
    expect(timer.mode, SleepTimerMode.countdown);
  });
  test('expiry during an item transition cannot enable automatic playback', () {
    timer.countdown(const Duration(minutes: 1));
    now = now.add(const Duration(minutes: 2));
    timer.refresh();
    timer.bindMedia('episode-b');
    expect(timer.allowsPlayback, false);
    timer.manualPlay();
    expect(timer.allowsPlayback, true);
    expect(timer.blocksAutoNext, false);
  });
  test('ending playback removes pending timer and reopening does not inherit it', () {
    timer.countdown(const Duration(minutes: 1));
    timer.endSession();
    now = now.add(const Duration(hours: 1));
    timer.bindMedia('episode-b');
    expect(pauses, 0);
    expect(timer.mode, SleepTimerMode.off);
    final restarted = SleepTimerController(pause: () async {});
    expect(restarted.mode, SleepTimerMode.off);
    restarted.dispose();
  });
  test('invalid durations do not replace a valid timer', () {
    timer.countdown(const Duration(minutes: 20));
    final deadline = timer.deadline;
    for (final duration in [Duration.zero, const Duration(seconds: -1), const Duration(hours: 13)]) {
      expect(() => timer.countdown(duration), throwsArgumentError);
      expect(timer.deadline, deadline);
    }
  });
  test('pause errors are visible rather than silently claiming success', () async {
    final failing = SleepTimerController(now: () => now, pause: () async => throw StateError('fixture'));
    failing.afterEpisode('episode-a');
    failing.completed();
    await Future<void>.delayed(Duration.zero);
    expect(failing.pauseFailed, true);
    expect(failing.blocksAutoNext, true);
    failing.dispose();
  });
  test('a late pause failure cannot overwrite the result of a replacement timer', () async {
    final pending = Completer<void>();
    var requests = 0;
    final replacement = SleepTimerController(pause: () {
      requests++;
      return requests == 1 ? pending.future : Future<void>.value();
    });
    replacement.afterEpisode('episode-a');
    replacement.completed();
    replacement.afterEpisode('episode-b');
    replacement.completed();
    pending.completeError(StateError('old operation'));
    await Future<void>.delayed(Duration.zero);
    expect(replacement.pauseFailed, false);
    replacement.dispose();
  });
}
