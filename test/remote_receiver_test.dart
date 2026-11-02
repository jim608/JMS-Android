import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/services/jellyfin_session_socket.dart';
import 'package:fladder/services/remote_control/remote_control_models.dart';
import 'package:fladder/services/remote_control/remote_control_protocol.dart';
import 'package:fladder/services/remote_control/remote_receiver.dart';

const _binding = RemotePlaybackBinding(
  itemId: 'item',
  mediaSourceId: 'source',
  playbackId: 'jms-remote-play',
);
const _replay = RemotePlaybackBinding(
  itemId: 'item',
  mediaSourceId: 'source',
  playbackId: 'jms-remote-replay',
);
RemotePlaybackSnapshot _snapshot({
  RemotePlaybackBinding binding = _binding,
  int position = 0,
  int? subtitle = 2,
  bool canSeek = true,
  bool paused = true,
}) =>
    RemotePlaybackSnapshot(
      binding: binding,
      positionTicks: position,
      durationTicks: 100000000,
      paused: paused,
      canSeek: canSeek,
      subtitleIndex: subtitle,
      playSessionId: 'play',
      audioStreamIndex: 3,
    );

class _Socket implements JellyfinSessionSocket {
  final input = StreamController<Object?>.broadcast(sync: true);
  final connected = Completer<void>();
  final sent = <String>[];
  Completer<void>? closeGate;
  bool closed = false;
  @override
  Future<void> get ready => connected.future;
  @override
  Stream<Object?> get messages => input.stream;
  @override
  void send(String message) => sent.add(message);
  @override
  Future<void> close() async {
    closed = true;
    await closeGate?.future;
  }
}

class _Api implements RemoteReceiverApi {
  final advertised = <bool>[];
  final reports = <PlaybackProgressInfo>[];
  Completer<void>? reportGate;
  Completer<void>? capabilityGate;
  Future<void> Function(bool enabled)? capabilityRequest;
  Completer<String?>? sessionGate;
  String sessionId = 'session';
  int reportsInFlight = 0;
  int maximumReportsInFlight = 0;
  @override
  Future<String?> ownSessionId() async {
    if (sessionGate == null) return sessionId;
    return sessionGate!.future;
  }

  @override
  Future<void> capabilities(bool enabled) async {
    advertised.add(enabled);
    await capabilityGate?.future;
    await capabilityRequest?.call(enabled);
  }

  @override
  Future<void> report(PlaybackProgressInfo progress) async {
    reports.add(progress);
    reportsInFlight++;
    if (reportsInFlight > maximumReportsInFlight) {
      maximumReportsInFlight = reportsInFlight;
    }
    await reportGate?.future;
    reportsInFlight--;
  }
}

class _Player implements RemotePlaybackPort {
  @override
  RemotePlaybackSnapshot? snapshot = _snapshot();
  @override
  bool blockedBySyncPlay = false;
  final calls = <String>[];
  Completer<void>? gate;
  bool failSubtitle = false;
  Future<void> _apply(
    String call,
    RemotePlaybackBinding binding, {
    int? subtitle,
    int? position,
    bool? paused,
  }) async {
    calls.add(call);
    await gate?.future;
    if (failSubtitle && subtitle != null) throw StateError('selection failed');
    final current = snapshot;
    if (current == null || current.binding != binding) return;
    snapshot = _snapshot(
      binding: binding,
      subtitle: subtitle ?? current.subtitleIndex,
      position: position ?? current.positionTicks,
      canSeek: current.canSeek,
      paused: paused ?? current.paused,
    );
  }

  @override
  Future<void> play(RemotePlaybackBinding binding) =>
      _apply('play', binding, paused: false);
  @override
  Future<void> pause(RemotePlaybackBinding binding) =>
      _apply('pause', binding, paused: true);
  @override
  Future<void> seek(Duration position, RemotePlaybackBinding binding) => _apply(
        'seek:${position.inMicroseconds * 10}',
        binding,
        position: position.inMicroseconds * 10,
      );
  @override
  Future<void> setSubtitle(int index, RemotePlaybackBinding binding) =>
      _apply('sub:$index', binding, subtitle: index);
}

class _Harness {
  final socket = _Socket();
  final api = _Api();
  final player = _Player();
  bool current = true;
  int socketRequests = 0;
  DateTime time = DateTime.utc(2026, 11, 2);
  late final controller = RemoteReceiverController(
    api: api,
    socketFactory: (_) {
      socketRequests++;
      return socket;
    },
    socketUri: Uri.parse('wss://example.invalid/socket'),
    currentUserId: 'user',
    player: player,
    isCurrent: () => current,
    now: () => time,
  );
  Future<void> start(WidgetTester tester) async {
    socket.connected.complete();
    await _settle(tester, controller.enable());
  }

  Future<void> close(WidgetTester tester) =>
      _settle(tester, controller.close());
  Future<void> disable(WidgetTester tester) =>
      _settle(tester, controller.disable());

  Map<String, dynamic> packet(
    RemoteAction action,
    int sequence, {
    String user = 'user',
    String session = 'session',
    RemotePlaybackBinding binding = _binding,
    DateTime? issuedAt,
  }) =>
      {
        'MessageType': 'GeneralCommand',
        'Data': RemoteControlProtocol.encode(
          userId: user,
          sessionId: session,
          binding: binding,
          action: action,
          controllerId: 'controller',
          requestId: 'request-$sequence',
          sequence: sequence,
          now: issuedAt ?? time,
        ).toJson(),
      };
  void send(RemoteAction action, int sequence) =>
      socket.input.add(jsonEncode(packet(action, sequence)));
}

Future<void> _settle(WidgetTester tester, Future<void> pending) async {
  var completed = false;
  pending.then<void>((_) {
    completed = true;
  }, onError: (Object _, StackTrace __) {
    completed = true;
  });
  for (var count = 0; count < 10 && !completed; count++) {
    await tester.pump();
    if (!completed) {
      // Stream cancellation may return Dart's shared root-zone null future.
      // Let that real microtask settle, then flush the receiver's fake zone.
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }
  }
  expect(completed, isTrue,
      reason: 'Receiver operation did not settle after flushing microtasks');
  await pending;
  await _flush(tester);
}

Future<void> _flush(WidgetTester tester) async {
  for (var turn = 0; turn < 3; turn++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }
}

void main() {
  testWidgets('opt-in waits for socket and own session before advertising', (
    tester,
  ) async {
    final h = _Harness();
    h.api.sessionGate = Completer<String?>();
    expect(h.api.advertised, isEmpty);
    final enabled = h.controller.enable();
    expect(h.socket.input.hasListener, isTrue);
    expect(h.controller.state, RemoteReceiverState.connecting);
    h.socket.connected.complete();
    await tester.pump();
    expect(h.api.advertised, isEmpty);
    h.api.sessionGate!.complete('session');
    await _settle(tester, enabled);
    expect(h.api.advertised, [true]);
    await h.close(tester);
    expect(h.api.advertised, [true, false]);
  });

  testWidgets(
    'play pause seek and subtitle use bound player and report current state',
    (tester) async {
      final h = _Harness();
      await h.start(tester);
      h.send(const RemoteAction.play(), 1);
      await tester.pump();
      h.send(const RemoteAction.pause(), 2);
      await tester.pump();
      h.send(const RemoteAction.seek(Duration(seconds: 4)), 3);
      await tester.pump();
      h.send(const RemoteAction.subtitle(-1), 4);
      await tester.pump();
      expect(h.player.calls, ['play', 'pause', 'seek:40000000', 'sub:-1']);
      expect(h.api.reports.last.positionTicks, 40000000);
      expect(h.api.reports.last.subtitleStreamIndex, -1);
      expect(h.api.reports.last.mediaSourceId, 'source');
      expect(h.api.reports.last.playlistItemId, 'jms-remote-play');
      await h.close(tester);
    },
  );

  testWidgets(
    'wrong user session item source occurrence and bare legacy commands fail closed',
    (tester) async {
      final h = _Harness();
      await h.start(tester);
      const pause = RemoteAction.pause();
      final packets = [
        h.packet(pause, 1, user: 'other'),
        h.packet(pause, 2, session: 'other'),
        h.packet(
          pause,
          3,
          binding: const RemotePlaybackBinding(
            itemId: 'other',
            mediaSourceId: 'source',
            playbackId: 'jms-remote-play',
          ),
        ),
        h.packet(
          pause,
          4,
          binding: const RemotePlaybackBinding(
            itemId: 'item',
            mediaSourceId: 'other',
            playbackId: 'jms-remote-play',
          ),
        ),
        h.packet(pause, 5, binding: _replay),
        {
          'MessageType': 'Playstate',
          'Data': {'Command': 'Pause'},
        },
        {
          'Name': 'PlayState',
          'ControllingUserId': 'user',
          'Arguments': {'Command': 'Pause'},
        },
      ];
      for (final packet in packets) {
        h.socket.input.add(packet);
      }
      await tester.pump();
      expect(h.player.calls, isEmpty);
      await h.close(tester);
    },
  );

  testWidgets(
    'duplicate out-of-order expired and far-future commands are rejected',
    (tester) async {
      final h = _Harness();
      await h.start(tester);
      h.send(const RemoteAction.pause(), 2);
      await tester.pump();
      h.send(const RemoteAction.pause(), 2);
      h.send(const RemoteAction.play(), 1);
      h.socket.input.add(
        h.packet(
          const RemoteAction.play(),
          3,
          issuedAt: h.time.subtract(const Duration(seconds: 20)),
        ),
      );
      h.socket.input.add(
        h.packet(
          const RemoteAction.play(),
          4,
          issuedAt: h.time.add(const Duration(seconds: 10)),
        ),
      );
      await tester.pump();
      expect(h.player.calls, ['pause']);
      await h.close(tester);
    },
  );

  testWidgets(
    'rapid subtitle A off B keeps latest while all player actions serialize',
    (tester) async {
      final h = _Harness();
      await h.start(tester);
      final gate = h.player.gate = Completer<void>();
      h.send(const RemoteAction.subtitle(1), 1);
      h.send(const RemoteAction.subtitle(-1), 2);
      h.send(const RemoteAction.subtitle(4), 3);
      h.send(const RemoteAction.seek(Duration(seconds: 2)), 4);
      h.send(const RemoteAction.play(), 5);
      h.send(const RemoteAction.pause(), 6);
      expect(h.player.calls, ['sub:1']);
      h.player.gate = null;
      gate.complete();
      await tester.pump();
      expect(h.player.calls, ['sub:1', 'sub:4', 'seek:20000000', 'pause']);
      expect(h.api.reports.last.subtitleStreamIndex, 4);
      await h.close(tester);
    },
  );

  testWidgets('seek respects duration and nonseekable media', (tester) async {
    final h = _Harness();
    await h.start(tester);
    h.send(const RemoteAction.seek(Duration(seconds: 11)), 1);
    await tester.pump();
    h.player.snapshot = _snapshot(canSeek: false);
    h.send(const RemoteAction.seek(Duration(seconds: 1)), 2);
    await tester.pump();
    expect(h.player.calls, isEmpty);
    h.player.snapshot = _snapshot();
    h.send(const RemoteAction.seek(Duration(seconds: 10)), 3);
    await tester.pump();
    expect(h.player.calls, ['seek:100000000']);
    await h.close(tester);
  });

  testWidgets(
    'replay during callback discards queued old occurrence and its report',
    (tester) async {
      final h = _Harness();
      await h.start(tester);
      final count = h.api.reports.length;
      h.player.gate = Completer<void>();
      h.send(const RemoteAction.subtitle(1), 1);
      h.send(const RemoteAction.pause(), 2);
      h.player.snapshot = _snapshot(binding: _replay);
      h.player.gate!.complete();
      await tester.pump();
      expect(h.player.calls, ['sub:1']);
      expect(h.api.reports.length, count);
      await h.close(tester);
    },
  );

  testWidgets(
    'queued command expires while previous player callback is pending',
    (tester) async {
      final h = _Harness();
      await h.start(tester);
      h.player.gate = Completer<void>();
      h.send(const RemoteAction.play(), 1);
      h.send(const RemoteAction.subtitle(4), 2);
      h.time = h.time.add(const Duration(seconds: 11));
      h.player.gate!.complete();
      await tester.pump();
      expect(h.player.calls, ['play']);
      await h.close(tester);
    },
  );

  testWidgets(
    'SyncPlay withdraws capabilities rejects actions and restores same opt-in',
    (tester) async {
      final h = _Harness();
      await h.start(tester);
      h.player.blockedBySyncPlay = true;
      h.send(const RemoteAction.pause(), 1);
      await tester.pump();
      expect(h.player.calls, isEmpty);
      expect(h.controller.state, RemoteReceiverState.blocked);
      expect(h.api.advertised, [true, false]);
      h.player.blockedBySyncPlay = false;
      await tester.pump(const Duration(seconds: 2));
      expect(h.controller.state, RemoteReceiverState.enabled);
      expect(h.api.advertised, [true, false, true]);
      await h.close(tester);
    },
  );

  testWidgets(
    'progress has one inflight request and only latest queued snapshot',
    (tester) async {
      final h = _Harness();
      h.api.reportGate = Completer<void>();
      await h.start(tester);
      h.player.snapshot = _snapshot(position: 100);
      await tester.pump(const Duration(seconds: 2));
      h.player.snapshot = _snapshot(position: 300);
      await tester.pump(const Duration(seconds: 2));
      expect(h.api.reports.length, 1);
      h.api.reportGate!.complete();
      await tester.pump();
      expect(h.api.maximumReportsInFlight, 1);
      expect(h.api.reports.map((report) => report.positionTicks), [0, 300]);
      await h.close(tester);
    },
  );

  testWidgets('stale queued report is discarded when occurrence changes', (
    tester,
  ) async {
    final h = _Harness();
    h.api.reportGate = Completer<void>();
    await h.start(tester);
    h.player.snapshot = _snapshot(position: 100);
    await tester.pump(const Duration(seconds: 2));
    h.player.snapshot = _snapshot(binding: _replay);
    h.api.reportGate!.complete();
    await tester.pump();
    expect(h.api.reports.length, 1);
    await h.close(tester);
  });

  testWidgets(
    'unconfirmed subtitle and callback failure never report fake Off',
    (tester) async {
      final h = _Harness();
      h.player.snapshot = _snapshot(subtitle: null);
      await h.start(tester);
      expect(h.api.reports.single.subtitleStreamIndex, isNull);
      expect(
        h.api.reports.single.toJson().containsKey('SubtitleStreamIndex'),
        isFalse,
      );
      h.player.failSubtitle = true;
      h.send(const RemoteAction.subtitle(-1), 1);
      await tester.pump();
      expect(h.api.reports.length, 1);
      await tester.pump(const Duration(seconds: 2));
      expect(h.api.reports.last.subtitleStreamIndex, isNull);
      await h.close(tester);
    },
  );

  testWidgets(
    'socket disconnect closes lease withdraws capabilities and drops pending actions',
    (tester) async {
      final h = _Harness();
      await h.start(tester);
      h.player.gate = Completer<void>();
      h.send(const RemoteAction.play(), 1);
      h.send(const RemoteAction.subtitle(4), 2);
      await _settle(tester, h.socket.input.close());
      await _flush(tester);
      h.player.gate!.complete();
      await tester.pump();
      expect(h.player.calls, ['play']);
      expect(h.socket.closed, isTrue);
      expect(h.controller.state, RemoteReceiverState.disconnected);
      expect(h.api.advertised.last, isFalse);
      await h.close(tester);
    },
  );

  testWidgets(
    'account switch invalidates pending readiness and every mutation',
    (tester) async {
      final h = _Harness();
      final enable = h.controller.enable();
      h.current = false;
      h.socket.connected.complete();
      await _settle(tester, enable);
      h.send(const RemoteAction.play(), 1);
      await tester.pump();
      expect(h.api.advertised, isEmpty);
      expect(h.player.calls, isEmpty);
      await h.close(tester);
      expect(h.socket.closed, isTrue);
    },
  );

  testWidgets('close rejects a concurrent enable while old socket is closing',
      (tester) async {
    final h = _Harness();
    await h.start(tester);
    h.socket.closeGate = Completer<void>();
    final closing = h.controller.close();
    await tester.pump();
    await _settle(tester, h.controller.enable());
    expect(h.socketRequests, 1);
    expect(h.controller.enabled, isFalse);
    h.socket.closeGate!.complete();
    await _settle(tester, closing);
    await tester.pump(const Duration(minutes: 1));
    expect(h.socket.input.hasListener, isFalse);
    expect(h.api.advertised, [true, false]);
  });

  testWidgets('stalled capabilities coalesce and close has bounded cleanup',
      (tester) async {
    final h = _Harness();
    h.api.capabilityGate = Completer<void>();
    await h.start(tester);
    await tester.pump(const Duration(minutes: 1));
    expect(h.api.advertised, [true]);
    final closing = h.controller.close();
    await _flush(tester);
    await tester.pump(const Duration(seconds: 2));
    await _settle(tester, closing);
    expect(h.socket.closed, isTrue);
    expect(h.socket.input.hasListener, isFalse);
    // Full close cannot cancel the actual old HTTP request and does not start
    // another request after its bounded best-effort cleanup has ended.
    h.api.capabilityGate!.complete();
    await tester.pump();
    expect(h.api.advertised, [true]);
  });

  testWidgets('unknown withdrawal clears cache before same-session re-enable',
      (tester) async {
    final h = _Harness();
    await h.start(tester);
    h.api.capabilityRequest = (enabled) async {
      if (!enabled) throw TimeoutException('outcome unknown');
    };
    await h.disable(tester);
    expect(h.api.advertised, [true, false]);
    await _settle(tester, h.controller.enable());
    await _flush(tester);
    expect(h.api.advertised, [true, false, true]);
    expect(h.controller.enabled, isTrue);
    h.api.capabilityRequest = null;
    await h.close(tester);
  });

  testWidgets(
      'failed pending advertisement preserves latest SyncPlay withdrawal',
      (tester) async {
    final h = _Harness();
    final pending = Completer<void>();
    var first = true;
    h.api.capabilityRequest = (enabled) {
      if (enabled && first) {
        first = false;
        return pending.future;
      }
      return Future<void>.value();
    };
    await h.start(tester);
    h.player.blockedBySyncPlay = true;
    h.send(const RemoteAction.pause(), 1);
    await _flush(tester);
    pending.completeError(TimeoutException('superseded outcome unknown'));
    await _flush(tester);
    expect(h.api.advertised, [true, false]);
    expect(h.controller.enabled, isTrue);
    expect(h.controller.state, RemoteReceiverState.blocked);
    h.player.blockedBySyncPlay = false;
    await tester.pump(const Duration(seconds: 2));
    await _flush(tester);
    expect(h.api.advertised, [true, false, true]);
    await h.close(tester);
  });

  testWidgets('unknown advertisement preserves opt-in and retries on next tick',
      (tester) async {
    final h = _Harness();
    var first = true;
    h.api.capabilityRequest = (enabled) async {
      if (enabled && first) {
        first = false;
        throw TimeoutException('outcome unknown');
      }
    };
    await h.start(tester);
    await _flush(tester);
    expect(h.controller.enabled, isTrue);
    expect(h.api.advertised, [true]);
    await tester.pump(const Duration(seconds: 2));
    await _flush(tester);
    expect(h.api.advertised, [true, true]);
    await h.close(tester);
  });

  testWidgets(
      'account switch while player callback pending drops queue and reports',
      (tester) async {
    final h = _Harness();
    await h.start(tester);
    final reportCount = h.api.reports.length;
    h.player.gate = Completer<void>();
    h.send(const RemoteAction.play(), 1);
    h.send(const RemoteAction.subtitle(4), 2);
    h.current = false;
    h.send(const RemoteAction.pause(), 3);
    await tester.pump();
    h.player.gate!.complete();
    await tester.pump();
    // The adapter additionally guards its own asynchronous player commit.
    expect(h.player.calls, ['play']);
    expect(h.api.reports.length, reportCount);
    expect(h.socket.closed, isTrue);
    await h.close(tester);
  });

  testWidgets(
      'no playback binding keeps capabilities withdrawn until a supported occurrence exists',
      (tester) async {
    final h = _Harness();
    h.player.snapshot = null;
    await h.start(tester);
    expect(h.api.advertised, [false]);
    expect(h.api.reports, isEmpty);
    h.player.snapshot = _snapshot();
    await tester.pump(const Duration(seconds: 2));
    expect(h.api.advertised, [false, true]);
    await h.close(tester);
  });

  testWidgets(
      'late old lease cleanup cannot drop advertisement for a new own session',
      (tester) async {
    final h = _Harness();
    h.api.capabilityGate = Completer<void>();
    await h.start(tester);
    h.socket.closeGate = Completer<void>();
    final disabling = h.controller.disable();
    await tester.pump();
    h.api.sessionId = 'new-session';
    await _settle(tester, h.controller.enable());
    h.socket.closeGate!.complete();
    await tester.pump();
    h.api.capabilityGate!.complete();
    await _settle(tester, disabling);
    expect(h.controller.enabled, isTrue);
    expect(h.api.advertised, [true, true]);
    await h.close(tester);
    expect(h.api.advertised, [true, true, false]);
  });

  testWidgets('same valid envelope stays rejected after disable and re-enable',
      (tester) async {
    final h = _Harness();
    await h.start(tester);
    final envelope = h.packet(const RemoteAction.subtitle(4), 1);
    h.socket.input.add(envelope);
    await tester.pump();
    expect(h.player.calls, ['sub:4']);
    await h.disable(tester);
    await _settle(tester, h.controller.enable());
    h.socket.input.add(envelope);
    await tester.pump();
    expect(h.player.calls, ['sub:4']);
    h.send(const RemoteAction.pause(), 2);
    await tester.pump();
    expect(h.player.calls, ['sub:4', 'pause']);
    await h.close(tester);
  });

  testWidgets('disable and close cancel timers and ignore later commands', (
    tester,
  ) async {
    final h = _Harness();
    await h.start(tester);
    await tester.pump(const Duration(seconds: 30));
    expect(h.socket.sent, isNotEmpty);
    await h.disable(tester);
    final reportCount = h.api.reports.length, keepAlives = h.socket.sent.length;
    h.send(const RemoteAction.play(), 1);
    await tester.pump(const Duration(minutes: 1));
    expect(h.player.calls, isEmpty);
    expect(h.api.reports.length, reportCount);
    expect(h.socket.sent.length, keepAlives);
    expect(h.socket.input.hasListener, isFalse);
    await h.close(tester);
    await h.close(tester);
  });
}
