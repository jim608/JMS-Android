import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/services/syncplay/syncplay_buffering.dart';
import 'package:fladder/services/syncplay/syncplay_clock.dart';

class _Job implements SyncPlayCancellation {
  _Job(this.when, this.callback);
  final int when;
  final void Function() callback;
  bool cancelled = false;
  bool fired = false;
  @override
  void cancel() => cancelled = true;
}

class _ManualScheduler implements SyncPlayScheduler {
  int now = 0;
  final jobs = <_Job>[];

  @override
  SyncPlayCancellation schedule(Duration delay, void Function() callback) {
    final job = _Job(now + delay.inMicroseconds, callback);
    jobs.add(job);
    return job;
  }

  int get pending => jobs.where((job) => !job.cancelled && !job.fired).length;

  void elapse(Duration duration) {
    final target = now + duration.inMicroseconds;
    while (true) {
      final due = jobs.where((job) => !job.cancelled && !job.fired && job.when <= target).toList()
        ..sort((a, b) => a.when.compareTo(b.when));
      if (due.isEmpty) break;
      final job = due.first;
      now = job.when;
      job.fired = true;
      job.callback();
    }
    now = target;
  }
}

class _Room {
  final scheduler = _ManualScheduler();
  bool current = true;
  bool buffering = true;
  Object? key = 'first-queue-instance';
  final reports = <(Object?, bool)>[];
  int rawReads = 0;
  int queueReads = 0;
  late final reporter = SyncPlayBufferingReporter(
    isCurrent: () => current,
    isBuffering: () {
      expect(current, isTrue, reason: 'A stale account must never read its old player');
      rawReads++;
      return buffering;
    },
    queueKey: () {
      expect(current, isTrue, reason: 'A stale account must never read its old queue');
      queueReads++;
      return key;
    },
    report: (value) => reports.add((key, value)),
    scheduler: scheduler,
  );

  void update(bool value) {
    buffering = value;
    reporter.update(value);
  }
}

void main() {
  test('waiting matures at 3000ms once and duplicate raw true does not restart it', () {
    final room = _Room();
    room.update(true);
    room.scheduler.elapse(const Duration(milliseconds: 2000));
    room.update(true);
    expect(room.scheduler.pending, 1);
    room.scheduler.elapse(const Duration(milliseconds: 999));
    expect(room.reports, isEmpty);
    room.scheduler.elapse(const Duration(milliseconds: 1));
    expect(room.reports, [('first-queue-instance', true)]);
    room.update(true);
    room.scheduler.elapse(const Duration(seconds: 10));
    expect(room.reports, hasLength(1));
    expect(room.scheduler.pending, 0);
  });

  test('transient waiting is cancelled by immediate ready without buffering feedback', () {
    final room = _Room();
    room.update(true);
    final cancelled = room.scheduler.jobs.single;
    room.scheduler.elapse(const Duration(milliseconds: 2999));
    room.update(false);
    expect(room.reports, [('first-queue-instance', false)]);
    room.update(false);
    room.scheduler.elapse(const Duration(seconds: 10));
    cancelled.callback(); // A cancellation race must not resurrect old waiting.
    expect(room.reports, [('first-queue-instance', false)]);
    expect(room.scheduler.pending, 0);
  });

  test('each ready edge is immediate while consecutive duplicate ready events are ignored', () {
    final room = _Room();
    room.update(false);
    room.update(false);
    room.update(true);
    room.scheduler.elapse(const Duration(seconds: 1));
    room.update(false);
    room.update(false);
    expect(room.reports, [('first-queue-instance', false), ('first-queue-instance', false)]);
    expect(room.scheduler.pending, 0);
  });

  test('a new queue gets a fresh waiting period and invalidates the old timer', () {
    final room = _Room();
    room.update(true);
    final oldTimer = room.scheduler.jobs.single;
    room.scheduler.elapse(const Duration(seconds: 2));
    room.key = 'second-queue-instance';
    room.reporter.refreshQueue();
    oldTimer.callback();
    room.scheduler.elapse(const Duration(milliseconds: 2999));
    expect(room.reports, isEmpty);
    room.scheduler.elapse(const Duration(milliseconds: 1));
    expect(room.reports, [('second-queue-instance', true)]);
  });

  test('an unobserved queue change cannot receive the old queue buffering notification', () {
    final room = _Room();
    room.update(true);
    room.scheduler.elapse(const Duration(seconds: 2));
    room.key = 'second-queue-instance';
    room.scheduler.elapse(const Duration(seconds: 1));
    expect(room.reports, isEmpty);
    room.scheduler.elapse(const Duration(seconds: 3));
    expect(room.reports, [('second-queue-instance', true)]);
  });

  test('queue refresh resets ready history and reads raw state without restarting an unchanged edge', () {
    final room = _Room();
    room.update(false);
    room.key = 'second-queue-instance';
    room.reporter.refreshQueue();
    room.reporter.refreshQueue();
    expect(room.reports, [('first-queue-instance', false), ('second-queue-instance', false)]);
    room.update(true);
    room.scheduler.elapse(const Duration(seconds: 2));
    room.reporter.refreshQueue();
    room.scheduler.elapse(const Duration(seconds: 1));
    expect(room.reports.last, ('second-queue-instance', true));
  });

  test('no queue means no report, timer or raw-player read', () {
    final room = _Room()..key = null;
    room.reporter.refreshQueue();
    room.update(true);
    room.update(false);
    expect(room.rawReads, 0);
    expect(room.scheduler.pending, 0);
    expect(room.reports, isEmpty);
    room.key = 'new-queue';
    room.buffering = true;
    room.reporter.refreshQueue();
    room.scheduler.elapse(const Duration(seconds: 3));
    expect(room.reports, [('new-queue', true)]);
    room.key = null;
    room.reporter.refreshQueue();
    expect(room.scheduler.pending, 0);
  });

  test('stale account callbacks do not access captured player or queue state', () {
    final room = _Room();
    room.update(true);
    final reads = (room.rawReads, room.queueReads);
    room.current = false;
    room.scheduler.elapse(const Duration(seconds: 3));
    room.reporter.refreshQueue();
    room.reporter.update(false);
    expect((room.rawReads, room.queueReads), reads);
    expect(room.reports, isEmpty);
    expect(room.scheduler.pending, 0);
  });

  test('an old source timer cannot report into a new room using the same playlist item id', () {
    final scheduler = _ManualScheduler();
    var source = 'old';
    final reports = <(String, bool)>[];
    final old = SyncPlayBufferingReporter(
      isCurrent: () => source == 'old',
      isBuffering: () => throw StateError('Old source player must not be read'),
      queueKey: () {
        expect(source, 'old');
        return ('old-room', 'same-playlist-item');
      },
      report: (value) => reports.add(('old', value)),
      scheduler: scheduler,
    );
    old.update(true);
    final oldTimer = scheduler.jobs.single;
    scheduler.elapse(const Duration(seconds: 2));
    source = 'new';
    final next = SyncPlayBufferingReporter(
      isCurrent: () => source == 'new',
      isBuffering: () => true,
      queueKey: () => ('new-room', 'same-playlist-item'),
      report: (value) => reports.add(('new', value)),
      scheduler: scheduler,
    );
    next.refreshQueue();
    oldTimer.callback();
    scheduler.elapse(const Duration(milliseconds: 2999));
    expect(reports, isEmpty);
    scheduler.elapse(const Duration(milliseconds: 1));
    expect(reports, [('new', true)]);
    old.dispose();
    next.dispose();
    expect(scheduler.pending, 0);
  });

  test('dispose cancels waiting and prevents even stale callbacks from reading dependencies', () {
    final scheduler = _ManualScheduler();
    var disposed = false;
    final reports = <bool>[];
    final reporter = SyncPlayBufferingReporter(
      isCurrent: () {
        expect(disposed, isFalse);
        return true;
      },
      isBuffering: () => throw StateError('Disposed player access'),
      queueKey: () {
        expect(disposed, isFalse);
        return 'queue';
      },
      report: reports.add,
      scheduler: scheduler,
    );
    reporter.update(true);
    final oldTimer = scheduler.jobs.single;
    reporter.dispose();
    disposed = true;
    reporter.dispose();
    reporter.update(false);
    reporter.refreshQueue();
    oldTimer.callback();
    scheduler.elapse(const Duration(seconds: 10));
    expect(reports, isEmpty);
    expect(scheduler.pending, 0);
  });

  test('timer rechecks raw state before reporting a matured waiting edge', () {
    final room = _Room();
    room.update(true);
    room.buffering = false; // Backend changed before its stream event arrived.
    room.scheduler.elapse(const Duration(seconds: 3));
    expect(room.reports, [('first-queue-instance', false)]);
    expect(room.scheduler.pending, 0);
  });
}
