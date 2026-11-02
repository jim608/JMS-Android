import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/services/playback_reporting_scope.dart';

class _Counter {
  int active = 0;
  int maximum = 0;
}

class _Call {
  _Call(this.client, this.kind, this.payload);
  final String client;
  final String kind;
  final Object payload;

  String get session => switch (payload) {
        PlaybackStartInfo info => info.playSessionId!,
        PlaybackProgressInfo info => info.playSessionId!,
        PlaybackStopInfo info => info.playSessionId!,
        _ => throw StateError('Unexpected fixture report'),
      };
  int? get position => switch (payload) {
        PlaybackProgressInfo info => info.positionTicks,
        PlaybackStopInfo info => info.positionTicks,
        _ => null,
      };
}

class _Api implements PlaybackReportApi {
  _Api(this.name, {List<_Call>? ledger, _Counter? counter})
      : calls = ledger ?? <_Call>[],
        counter = counter ?? _Counter();

  final String name;
  final List<_Call> calls;
  final _Counter counter;
  Completer<void>? nextGate;
  bool closed = false;

  Future<void> _write(String kind, Object payload) async {
    if (closed) throw StateError('The captured client is already closed');
    final gate = nextGate;
    nextGate = null;
    calls.add(_Call(name, kind, payload));
    counter.active++;
    if (counter.active > counter.maximum) counter.maximum = counter.active;
    try {
      await gate?.future;
    } finally {
      counter.active--;
    }
  }

  @override
  Future<void> start(PlaybackStartInfo info) => _write('start', info);
  @override
  Future<void> progress(PlaybackProgressInfo info) => _write('progress', info);
  @override
  Future<void> stop(PlaybackStopInfo info) => _write('stop', info);
  @override
  void close() => closed = true;
}

class _Harness {
  final api = _Api('captured-account-A');
  final stoppedLocally = <PlaybackStopInfo>[];
  int generation = 0;
  bool enabled = true;
  PlaybackReportingScope? model;
  late final capture = PlaybackReportingCapture(
    api: api,
    isCurrent: () => generation == 0,
    isPlaybackCurrent: (scope) => identical(model, scope),
    enabled: () => enabled,
    onStopped: stoppedLocally.add,
  );

  PlaybackReportingScope bind(String session) => capture.bind(
      itemId: 'item',
      mediaSourceId: 'source',
      playSessionId: session,
      playlistItemId: 'jms-remote-$session');

  PlaybackReportingScope activate(String session) {
    final scope = model = bind(session);
    expect(scope.activate(), isTrue);
    return scope;
  }
}

PlaybackStartInfo _start(PlaybackReportingScope scope) => PlaybackStartInfo(
      itemId: scope.itemId,
      mediaSourceId: scope.mediaSourceId,
      playSessionId: scope.playSessionId,
      playlistItemId: scope.playlistItemId,
      nowPlayingQueue: [
        QueueItem(id: scope.itemId, playlistItemId: scope.playlistItemId),
        const QueueItem(id: 'next', playlistItemId: 'next-occurrence'),
      ],
      subtitleStreamIndex: 8,
      audioStreamIndex: 2,
    );
PlaybackProgressInfo _progress(PlaybackReportingScope scope, int ticks,
        {int? subtitleIndex = 8}) =>
    PlaybackProgressInfo(
      itemId: scope.itemId,
      mediaSourceId: scope.mediaSourceId,
      playSessionId: scope.playSessionId,
      playlistItemId: scope.playlistItemId,
      positionTicks: ticks,
      subtitleStreamIndex: subtitleIndex,
    );
PlaybackStopInfo _stop(PlaybackReportingScope scope, {int ticks = 900}) =>
    PlaybackStopInfo(
        itemId: scope.itemId,
        mediaSourceId: scope.mediaSourceId,
        playSessionId: scope.playSessionId,
        playlistItemId: scope.playlistItemId,
        positionTicks: ticks);

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  test(
      'capture and prefetch binding do not activate or retire current playback',
      () async {
    final h = _Harness();
    final current = h.model = h.bind('current');
    expect(current.isOwned, isTrue);
    expect(current.isCurrent, isFalse);
    await current.progress(_progress(current, 1));
    expect(h.api.calls, isEmpty);
    expect(current.activate(), isTrue);
    final prefetched = h.bind('prefetched');
    expect(prefetched.isOwned, isTrue);
    expect(prefetched.isCurrent, isFalse);
    expect(current.isCurrent, isTrue);
    expect(prefetched.activate(), isFalse);
    expect(current.isCurrent, isTrue);
    h.capture.close();
  });

  test(
      'one original HTTP request stays in flight and only latest progress follows it',
      () async {
    final h = _Harness(), scope = h.activate('one');
    final gate = h.api.nextGate = Completer<void>();
    final first = scope.progress(_progress(scope, 100));
    final replaced = scope.progress(_progress(scope, 200));
    final latest = scope.progress(_progress(scope, 300, subtitleIndex: -1));
    await replaced;
    expect(h.api.calls.map((call) => call.position), [100]);
    expect(h.api.counter.active, 1);
    gate.complete();
    await Future.wait([first, latest]);
    expect(h.api.calls.map((call) => call.position), [100, 300]);
    expect(
        (h.api.calls.last.payload as PlaybackProgressInfo).subtitleStreamIndex,
        -1);
    expect(h.api.counter.maximum, 1);
    h.capture.close();
  });

  test('replay start waits for original old HTTP and drops queued old progress',
      () async {
    final h = _Harness(), old = h.activate('old');
    final gate = h.api.nextGate = Completer<void>();
    final oldPhysical = old.progress(_progress(old, 100));
    final oldQueued = old.progress(_progress(old, 200));
    final replay = h.activate('replay');
    final replayStart = replay.start(_start(replay));
    final replayProgress = replay.progress(_progress(replay, 5));
    await oldQueued;
    await old.stop(_stop(old));
    expect(h.api.calls.map((call) => '${call.kind}:${call.session}'),
        ['progress:old']);
    gate.complete();
    await Future.wait([oldPhysical, replayStart, replayProgress]);
    expect(h.api.calls.map((call) => '${call.kind}:${call.session}'),
        ['progress:old', 'start:replay', 'progress:replay']);
    expect(h.api.counter.maximum, 1);
    expect(old.isCurrent, isFalse);
    expect(h.stoppedLocally, isEmpty);
    h.capture.close();
  });

  test(
      'normal stop after model clear is delivered once and permanently rejects progress',
      () async {
    final h = _Harness(), scope = h.activate('one');
    final start = _start(scope);
    await scope.start(start);
    final gate = h.api.nextGate = Completer<void>();
    final physical = scope.progress(_progress(scope, 400));
    final obsolete = scope.progress(_progress(scope, 500));
    h.model = null;
    final stopped = scope.stop(_stop(scope));
    await obsolete;
    await scope.progress(_progress(scope, 1000));
    expect(scope.isOwned, isFalse);
    expect(scope.activate(), isFalse);
    gate.complete();
    await Future.wait([physical, stopped]);
    await scope.stop(_stop(scope));
    expect(h.api.calls.map((call) => call.kind), ['start', 'progress', 'stop']);
    expect((h.api.calls.first.payload as PlaybackStartInfo).nowPlayingQueue,
        start.nowPlayingQueue);
    expect(h.stoppedLocally.single.positionTicks, 900);
    expect(h.api.counter.maximum, 1);
    h.capture.close();
  });

  test(
      'already queued old stop precedes new occurrence start on the same physical writer',
      () async {
    final h = _Harness(), old = h.activate('old');
    await old.start(_start(old));
    final gate = h.api.nextGate = Completer<void>();
    final progress = old.progress(_progress(old, 800));
    final stopped = old.stop(_stop(old));
    final next = h.activate('next');
    final nextStart = next.start(_start(next));
    gate.complete();
    await Future.wait([progress, stopped, nextStart]);
    expect(h.api.calls.map((call) => '${call.kind}:${call.session}'),
        ['start:old', 'progress:old', 'stop:old', 'start:next']);
    expect(h.stoppedLocally.single.playSessionId, 'old');
    h.capture.close();
  });

  test(
      'scope never reported to server needs no stop and cannot report after stopping',
      () async {
    final h = _Harness(), scope = h.activate('unsent');
    await scope.stop(_stop(scope));
    await scope.start(_start(scope));
    await scope.progress(_progress(scope, 1));
    expect(h.api.calls, isEmpty);
    expect(scope.isOwned, isFalse);
    expect(h.stoppedLocally, isEmpty);
    h.capture.close();
  });

  test('late old stop is rejected after another occurrence becomes active',
      () async {
    final h = _Harness(), old = h.activate('old');
    await old.start(_start(old));
    final next = h.activate('next');
    await next.start(_start(next));
    await old.stop(_stop(old));
    await old.progress(_progress(old, 50));
    expect(h.api.calls.map((call) => '${call.kind}:${call.session}'),
        ['start:old', 'start:next']);
    expect(h.stoppedLocally, isEmpty);
    expect(next.isCurrent, isTrue);
    h.capture.close();
  });

  test('account invalidation prevents queued REST and local stop side effects',
      () async {
    final h = _Harness(), scope = h.activate('one');
    final gate = h.api.nextGate = Completer<void>();
    final first = scope.progress(_progress(scope, 100));
    final queued = scope.progress(_progress(scope, 200));
    final stopped = scope.stop(_stop(scope));
    h.generation++;
    h.capture.close();
    expect(h.api.closed, isFalse); // The original write must actually settle.
    expect(scope.isCurrent, isFalse);
    await queued;
    gate.complete();
    await Future.wait([first, stopped]);
    await _flush();
    expect(h.api.calls.map((call) => call.kind), ['progress']);
    expect(h.stoppedLocally, isEmpty);
    expect(h.api.closed, isTrue);
  });

  test(
      'A to B to A reuses A physical lane without reviving old capture or credentials',
      () async {
    final laneA = PlaybackReportLane(), laneB = PlaybackReportLane();
    final ledger = <_Call>[], aCounter = _Counter();
    final apiA =
        _Api('A-old-private-client', ledger: ledger, counter: aCounter);
    final apiB = _Api('B-private-client', ledger: ledger);
    final apiA2 =
        _Api('A-new-private-client', ledger: ledger, counter: aCounter);
    var generation = 0;
    PlaybackReportingScope? model;
    PlaybackReportingCapture capture(
            _Api api, int ownerGeneration, PlaybackReportLane lane) =>
        PlaybackReportingCapture(
            api: api,
            lane: lane,
            isCurrent: () => generation == ownerGeneration,
            isPlaybackCurrent: (scope) => identical(model, scope));
    PlaybackReportingScope bind(
            PlaybackReportingCapture owner, String session) =>
        owner.bind(
            itemId: 'item',
            mediaSourceId: 'source',
            playSessionId: session,
            playlistItemId: 'jms-remote-$session');

    final oldOwner = capture(apiA, 0, laneA),
        old = model = bind(oldOwner, 'A-old');
    expect(old.activate(), isTrue);
    final gate = apiA.nextGate = Completer<void>();
    final oldPhysical = old.progress(_progress(old, 10));
    final oldQueued = old.progress(_progress(old, 20));
    generation = 1;
    oldOwner.close();
    final bOwner = capture(apiB, 1, laneB), b = model = bind(bOwner, 'B');
    await b.start(_start(b));
    expect(apiA.closed, isFalse);
    expect(ledger.map((call) => call.client),
        ['A-old-private-client', 'B-private-client']);

    generation = 2;
    bOwner.close();
    final newOwner = capture(apiA2, 2, laneA),
        fresh = model = bind(newOwner, 'A-new');
    final freshStart = fresh.start(_start(fresh));
    await old.progress(_progress(old, 30));
    await oldQueued;
    expect(old.activate(), isFalse);
    expect(ledger.map((call) => call.client),
        ['A-old-private-client', 'B-private-client']);
    gate.complete();
    await Future.wait([oldPhysical, freshStart]);
    await _flush();
    expect(ledger.map((call) => '${call.client}:${call.session}'), [
      'A-old-private-client:A-old',
      'B-private-client:B',
      'A-new-private-client:A-new'
    ]);
    expect(aCounter.maximum, 1);
    expect(apiA.closed, isTrue);
    expect(apiB.closed, isTrue);
    newOwner.close();
  });

  test('incognito suppresses HTTP but stop still retires the playback scope',
      () async {
    final h = _Harness()..enabled = false;
    final scope = h.activate('private');
    await scope.start(_start(scope));
    await scope.progress(_progress(scope, 1));
    await scope.stop(_stop(scope));
    h.enabled = true;
    await scope.progress(_progress(scope, 2));
    await scope.start(_start(scope));
    expect(h.api.calls, isEmpty);
    expect(h.stoppedLocally, isEmpty);
    expect(scope.isOwned, isFalse);
    h.capture.close();
  });

  test('privacy change discards queued progress before its physical send',
      () async {
    final h = _Harness(), scope = h.activate('one');
    final gate = h.api.nextGate = Completer<void>();
    final first = scope.progress(_progress(scope, 1));
    final queued = scope.progress(_progress(scope, 2));
    h.enabled = false;
    gate.complete();
    await Future.wait([first, queued]);
    expect(h.api.calls.map((call) => call.position), [1]);
    h.capture.close();
  });

  test(
      'payload item source session and occurrence must match the captured scope',
      () async {
    final h = _Harness(), scope = h.activate('one');
    final validStart = _start(scope),
        validProgress = _progress(scope, 1),
        validStop = _stop(scope);
    for (final wrong in [
      validStart.copyWith(itemId: 'other'),
      validStart.copyWith(mediaSourceId: 'other'),
      validStart.copyWith(playSessionId: 'other'),
      validStart.copyWith(playlistItemId: 'other'),
    ]) {
      await scope.start(wrong);
    }
    for (final wrong in [
      validProgress.copyWith(itemId: 'other'),
      validProgress.copyWith(mediaSourceId: 'other'),
      validProgress.copyWith(playSessionId: 'other'),
      validProgress.copyWith(playlistItemId: 'other'),
    ]) {
      await scope.progress(wrong);
    }
    for (final wrong in [
      validStop.copyWith(itemId: 'other'),
      validStop.copyWith(mediaSourceId: 'other'),
      validStop.copyWith(playSessionId: 'other'),
      validStop.copyWith(playlistItemId: 'other'),
    ]) {
      await scope.stop(wrong);
    }
    expect(h.api.calls, isEmpty);
    await scope.progress(validProgress);
    expect(h.api.calls.single.position, 1);
    expect(scope.isCurrent, isTrue);
    h.capture.close();
  });

  test(
      'completed API failure releases physical slot without replaying the mutation',
      () async {
    final h = _Harness(), scope = h.activate('one');
    final gate = h.api.nextGate = Completer<void>();
    final first = scope.progress(_progress(scope, 1));
    final latest = scope.progress(_progress(scope, 2));
    gate.completeError(StateError('synthetic network failure'));
    await Future.wait([first, latest]);
    expect(h.api.calls.map((call) => call.position), [1, 2]);
    expect(h.api.counter.maximum, 1);
    h.capture.close();
  });

  test('new start discards older queued progress for that occurrence',
      () async {
    final h = _Harness(), old = h.activate('old');
    final gate = h.api.nextGate = Completer<void>();
    final physical = old.progress(_progress(old, 100));
    final fresh = h.activate('new');
    final progress = fresh.progress(_progress(fresh, 23));
    final start = fresh.start(_start(fresh));
    gate.complete();
    await Future.wait([physical, progress, start]);
    expect(h.api.calls.map((call) => '${call.kind}:${call.session}'),
        ['progress:old', 'start:new']);
    h.capture.close();
  });

  test(
      'pause then play drops stale paused progress but keeps progress after new start',
      () async {
    final h = _Harness(), scope = h.activate('one');
    final gate = h.api.nextGate = Completer<void>();
    final raw = scope.progress(_progress(scope, 10).copyWith(isPaused: false));
    final paused =
        scope.progress(_progress(scope, 20).copyWith(isPaused: true));
    final played = scope.start(_start(scope).copyWith(isPaused: false));
    final latest =
        scope.progress(_progress(scope, 30).copyWith(isPaused: false));
    await paused;
    gate.complete();
    await Future.wait([raw, played, latest]);
    expect(h.api.calls.map((call) => call.kind),
        ['progress', 'start', 'progress']);
    expect((h.api.calls[1].payload as PlaybackStartInfo).isPaused, isFalse);
    expect(
        (h.api.calls.last.payload as PlaybackProgressInfo).isPaused, isFalse);
    expect(h.api.calls.last.position, 30);
    h.capture.close();
  });

  test(
      'late remote disable discards guarded report and preserves queued ordinary progress',
      () async {
    final h = _Harness(), scope = h.activate('one');
    final gate = h.api.nextGate = Completer<void>();
    final raw = scope.progress(_progress(scope, 10));
    final normal = scope.progress(_progress(scope, 20));
    var enabled = true;
    final remote =
        scope.progress(_progress(scope, 30), isCurrent: () => enabled);
    enabled = false;
    gate.complete();
    await Future.wait([raw, normal, remote]);
    expect(h.api.calls.map((call) => call.position), [10, 20]);
    h.capture.close();
  });

  test(
      'invalid guard cannot replace normal latest and independent slots retain enqueue order',
      () async {
    final h = _Harness(), scope = h.activate('one');
    final gate = h.api.nextGate = Completer<void>();
    final raw = scope.progress(_progress(scope, 10));
    final replaced = scope.progress(_progress(scope, 20));
    await scope.progress(_progress(scope, 30), isCurrent: () => false);
    await scope.progress(_progress(scope, 31),
        isCurrent: () => throw StateError('stale owner'));
    final remote = scope.progress(_progress(scope, 40), isCurrent: () => true);
    final latest = scope.progress(_progress(scope, 50));
    await replaced;
    gate.complete();
    await Future.wait([raw, remote, latest]);
    expect(h.api.calls.map((call) => call.position), [10, 40, 50]);
    h.capture.close();
  });

  test(
      'copy preserves same scope while source or occurrence change creates an inactive scope',
      () {
    final h = _Harness(), scope = h.activate('one');
    final copied = scope.rebind(
        itemId: scope.itemId,
        mediaSourceId: scope.mediaSourceId,
        playSessionId: scope.playSessionId,
        playlistItemId: scope.playlistItemId);
    expect(identical(copied, scope), isTrue);
    final replay = scope.rebind(
        itemId: scope.itemId,
        mediaSourceId: scope.mediaSourceId,
        playSessionId: 'two',
        playlistItemId: 'jms-remote-two');
    final otherSource = scope.rebind(
        itemId: scope.itemId,
        mediaSourceId: 'other-source',
        playSessionId: scope.playSessionId,
        playlistItemId: scope.playlistItemId);
    expect(replay.isCurrent, isFalse);
    expect(otherSource.isCurrent, isFalse);
    expect(scope.isCurrent, isTrue);
    h.capture.close();
  });
}
