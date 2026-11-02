import 'dart:async';

import 'package:fladder/services/remote_control/remote_control_controller.dart';
import 'package:fladder/services/remote_control/remote_control_models.dart';
import 'package:flutter_test/flutter_test.dart';

final clock = DateTime.utc(2026, 11, 2, 12);

RemoteTarget target(
        {String id = 'tesla',
        String source = 'source-one',
        String occurrence = 'one',
        bool paused = false,
        int subtitle = -1,
        int position = 0,
        DateTime? report}) =>
    RemoteTarget(
      id: id,
      deviceId: id,
      name: id,
      userId: 'owner',
      serverId: 'server',
      binding: RemotePlaybackBinding(
          itemId: 'item',
          mediaSourceId: source,
          playbackId: 'jms-remote-$occurrence'),
      positionTicks: position,
      durationTicks: 6000000000,
      paused: paused,
      canSeek: true,
      subtitleIndex: subtitle,
      lastPlaybackCheckIn: report ?? clock.subtract(const Duration(seconds: 1)),
    );

Future<void> flush() => Future<void>.delayed(Duration.zero);

class FakeApi
    implements
        RemoteControlApi,
        RemoteControlCancellation,
        RemoteControlSendObservation {
  List<RemoteTarget> targets = [target()];
  final actions = <RemoteAction>[];
  final sentTargets = <RemoteTarget>[];
  final gates = <Completer<void>>[];
  bool hold = false;
  RemoteControlFailure? sendFailure;
  @override
  RemoteTarget? lastAcceptedBaseline;
  int discoveries = 0;
  int cancellations = 0;
  int closes = 0;
  Completer<List<RemoteTarget>>? pendingDiscovery;
  Completer<List<RemoteSubtitle>>? pendingSubtitles;
  @override
  Future<List<RemoteTarget>> discover() async {
    discoveries++;
    if (pendingDiscovery != null) return await pendingDiscovery!.future;
    return targets;
  }

  @override
  Future<List<RemoteSubtitle>> subtitles(RemoteTarget target) async {
    if (pendingSubtitles != null) return await pendingSubtitles!.future;
    return const [];
  }

  @override
  Future<void> send(RemoteTarget target, RemoteAction action) async {
    sentTargets.add(target);
    actions.add(action);
    if (sendFailure != null) throw sendFailure!;
    if (hold) {
      final gate = Completer<void>();
      gates.add(gate);
      await gate.future;
    }
  }

  @override
  void invalidatePending() => cancellations++;
  @override
  Future<void> close() async {
    closes++;
  }
}

Future<RemoteControlController> selected(FakeApi api,
    {Duration confirmationTimeout = const Duration(seconds: 6),
    bool Function()? current}) async {
  final controller = RemoteControlController(
      api: api,
      now: () => clock,
      confirmationTimeout: confirmationTimeout,
      isCurrent: current);
  await controller.refresh();
  await controller.select(controller.state.targets.first);
  return controller;
}

void main() {
  test('204 acceptance needs a newer playback report with the requested state',
      () async {
    final api = FakeApi();
    final controller = await selected(api);
    addTearDown(controller.close);
    await controller.dispatch(const RemoteAction.pause());
    await flush();
    expect(controller.state.status, RemoteCommandStatus.accepted);
    api.targets = [target(paused: true)];
    await controller.refresh();
    expect(controller.state.status, RemoteCommandStatus.accepted);
    api.targets = [
      target(paused: true, report: clock.add(const Duration(seconds: 1)))
    ];
    await controller.refresh();
    expect(controller.state.status, RemoteCommandStatus.confirmed);
  });

  test(
      'confirmation baseline comes from the final transport preflight, not stale UI selection',
      () async {
    final api = FakeApi();
    final controller = await selected(api);
    addTearDown(controller.close);
    api.lastAcceptedBaseline = target(paused: true, report: clock);
    api.targets = [target(paused: true, report: clock)];
    await controller.dispatch(const RemoteAction.pause());
    await flush();
    expect(controller.state.status, RemoteCommandStatus.accepted);
    api.targets = [
      target(paused: true, report: clock.add(const Duration(seconds: 1)))
    ];
    await controller.refresh();
    expect(controller.state.status, RemoteCommandStatus.confirmed);
  });

  test(
      'one in-flight mutation coalesces latest playback, seek and subtitle intents',
      () async {
    final api = FakeApi()..hold = true;
    final controller = await selected(api);
    addTearDown(controller.close);
    final first = controller.dispatch(const RemoteAction.pause());
    await flush();
    final discardedSeek =
        controller.dispatch(const RemoteAction.seek(Duration(seconds: 1)));
    final latestSeek =
        controller.dispatch(const RemoteAction.seek(Duration(seconds: 20)));
    final discardedSubtitle =
        controller.dispatch(const RemoteAction.subtitle(2));
    final latestSubtitle = controller.dispatch(const RemoteAction.subtitle(8));
    final discardedPlay = controller.dispatch(const RemoteAction.play());
    final latestPause = controller.dispatch(const RemoteAction.pause());
    await Future.wait([discardedSeek, discardedSubtitle, discardedPlay]);
    expect(api.actions, [const RemoteAction.pause()]);
    for (var i = 0; i < 4; i++) {
      expect(api.gates, hasLength(i + 1));
      api.gates[i].complete();
      await flush();
    }
    await Future.wait([first, latestSeek, latestSubtitle, latestPause]);
    expect(api.actions, [
      const RemoteAction.pause(),
      const RemoteAction.seek(Duration(seconds: 20)),
      const RemoteAction.subtitle(8),
      const RemoteAction.pause()
    ]);
  });

  test(
      'switching target invalidates preflight and ignores an old mutation completion',
      () async {
    final api = FakeApi()..targets = [target(), target(id: 'other')];
    final controller = await selected(api);
    addTearDown(controller.close);
    api.hold = true;
    final pending = controller.dispatch(const RemoteAction.pause());
    await flush();
    final before = api.cancellations;
    await controller.select(controller.state.targets.last);
    expect(api.cancellations, before + 1);
    api.gates.single.complete();
    await pending;
    expect(controller.state.target?.id, 'other');
    expect(controller.state.status, RemoteCommandStatus.idle);
  });

  test(
      'a changed source or occurrence clears queued commands for the previous playback',
      () async {
    final api = FakeApi()..hold = true;
    final controller = await selected(api);
    addTearDown(controller.close);
    final first = controller.dispatch(const RemoteAction.pause());
    await flush();
    final queued = controller.dispatch(const RemoteAction.subtitle(8));
    api.targets = [target(source: 'source-two', occurrence: 'two')];
    await controller.refresh();
    await queued;
    api.gates.single.complete();
    await first;
    expect(api.actions, hasLength(1));
    expect(controller.state.target?.binding?.mediaSourceId, 'source-two');
    expect(controller.state.status, RemoteCommandStatus.idle);
  });

  test('ambiguous mutation is unknown and refresh never retries it', () async {
    final api = FakeApi()
      ..sendFailure =
          const RemoteControlFailure(RemoteFailureCode.timeoutUnknown);
    final controller = await selected(api);
    addTearDown(controller.close);
    await controller.dispatch(const RemoteAction.pause());
    await controller.refresh();
    expect(controller.state.status, RemoteCommandStatus.unknown);
    expect(api.actions, hasLength(1));
  });

  test('accepted command without a fresh confirmation becomes unknown',
      () async {
    final api = FakeApi();
    final controller = await selected(api,
        confirmationTimeout: const Duration(milliseconds: 5));
    addTearDown(controller.close);
    await controller.dispatch(const RemoteAction.pause());
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(controller.state.status, RemoteCommandStatus.unknown);
    expect(controller.state.failure?.code, RemoteFailureCode.timeoutUnknown);
    expect(api.actions, hasLength(1));
  });

  test('seek and subtitle confirmation use fresh reports on the same playback',
      () async {
    final api = FakeApi();
    final controller = await selected(api);
    addTearDown(controller.close);
    await controller.dispatch(const RemoteAction.seek(Duration(seconds: 30)));
    await flush();
    api.targets = [
      target(position: 300000000, report: clock.add(const Duration(seconds: 1)))
    ];
    await controller.refresh();
    expect(controller.state.status, RemoteCommandStatus.confirmed);
    await controller.dispatch(const RemoteAction.subtitle(8));
    await flush();
    api.targets = [
      target(subtitle: 8, report: clock.add(const Duration(seconds: 2)))
    ];
    await controller.refresh();
    expect(controller.state.status, RemoteCommandStatus.confirmed);
  });

  test('account change invalidates stale discovery and metadata completions',
      () async {
    final api = FakeApi();
    var current = true;
    final controller = await selected(api, current: () => current);
    addTearDown(controller.close);
    final pending = Completer<List<RemoteTarget>>();
    api.pendingDiscovery = pending;
    final refresh = controller.refresh();
    await flush();
    current = false;
    pending.complete([target(id: 'other-account-result')]);
    await refresh;
    await controller.dispatch(const RemoteAction.pause());
    expect(controller.state.target?.id, 'tesla');
    expect(api.actions, isEmpty);
  });

  test('close stops polling and leaves the shared receiver API open', () async {
    final api = FakeApi();
    final controller = RemoteControlController(
        api: api, pollInterval: const Duration(milliseconds: 5));
    await controller.start();
    await controller.close();
    final reads = api.discoveries;
    await Future<void>.delayed(const Duration(milliseconds: 15));
    expect(api.discoveries, reads);
    expect(api.closes, 0);
    await controller.dispatch(const RemoteAction.pause());
    expect(api.actions, isEmpty);
  });
}
