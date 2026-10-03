import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fladder/providers/discord_presence_provider.dart';
import 'package:fladder/services/discord/discord_activity.dart';
import 'package:fladder/services/discord/discord_presence_controller.dart';

import 'fixtures/discord_fake_client.dart';

const playback = DiscordPlaybackSnapshot(
  active: true,
  title: 'Synthetic movie',
  playing: true,
  position: Duration(minutes: 5),
  duration: Duration(minutes: 25),
);

Future<void> settle() async {
  for (var index = 0; index < 5; index++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  final now = DateTime.fromMillisecondsSinceEpoch(1800000000000, isUtc: true);

  test('only allowed display fields are exported and title requires opt-in',
      () {
    final activity = discordActivity(playback, shareTitle: false, now: now)!;
    expect(activity['details'], 'JMS 媒體播放');
    expect(activity.keys.toSet(), {'type', 'state', 'details', 'timestamps'});
    expect(jsonEncode(activity), isNot(contains(playback.title)));
    expect(discordActivity(playback, shareTitle: true, now: now)!['details'],
        playback.title);
    expect(activity['type'], 3);
  });

  test('paused and buffering playback have no running countdown', () {
    for (final snapshot in [
      const DiscordPlaybackSnapshot(
          active: true, title: 'Synthetic movie', playing: false),
      const DiscordPlaybackSnapshot(
          active: true,
          title: 'Synthetic movie',
          playing: true,
          buffering: true),
    ]) {
      final activity = discordActivity(snapshot, shareTitle: true, now: now)!;
      expect(activity, isNot(contains('timestamps')));
      expect(activity['state'], snapshot.buffering ? '正在緩衝' : '已暫停');
    }
    expect(discordActivity(null, shareTitle: true, now: now), isNull);
    expect(
        discordActivity(
          const DiscordPlaybackSnapshot(
              active: false, title: 'Synthetic movie', playing: true),
          shareTitle: true,
          now: now,
        ),
        isNull);
  });

  test(
      'URL, local path and credential-like titles fall back to generic display',
      () {
    for (final title in [
      'https://media.example.invalid/title',
      'smb://media.example.invalid/title',
      'rtsp://media.example.invalid/title',
      '/srv/fixture-media/movie.mkv',
      r'C:\Synthetic\movie.mkv',
      r'\\example.invalid\movie.mkv',
      'cookie: synthetic fixture',
      'password=synthetic fixture',
    ]) {
      expect(discordDisplayTitle(title), isNull);
      final activity = discordActivity(
        DiscordPlaybackSnapshot(active: true, title: title, playing: true),
        shareTitle: true,
        now: now,
      )!;
      expect(activity['details'], 'JMS 媒體播放');
      expect(jsonEncode(activity), isNot(contains(title)));
    }
  });

  test('Unicode display limits preserve characters and remove controls', () {
    final title = discordDisplayTitle(List.filled(150, '影🎬').join())!;
    expect(utf8.encode(title).length, lessThanOrEqualTo(128));
    expect(title, isNot(contains('\uFFFD')));
    expect(discordDisplayTitle('Synthetic\nmovie\u0000'), 'Synthetic movie');
  });

  test('countdown accounts for playback rate and rejects invalid durations',
      () {
    final activity = discordActivity(
      const DiscordPlaybackSnapshot(
          active: true,
          title: 'Synthetic',
          playing: true,
          position: Duration(seconds: 100),
          duration: Duration(seconds: 300),
          rate: 2),
      shareTitle: false,
      now: now,
    )!;
    expect(activity['timestamps'], {'start': 1799999950, 'end': 1800000100});
    for (final rate in [0.0, double.nan, double.infinity]) {
      expect(
          discordActivity(
            DiscordPlaybackSnapshot(
                active: true,
                title: 'Synthetic',
                playing: true,
                duration: const Duration(seconds: 300),
                rate: rate),
            shareTitle: false,
            now: now,
          ),
          isNot(contains('timestamps')));
    }
  });

  group('controller lifecycle', () {
    late FakeDiscordPresenceClient client;
    late DiscordPresenceController controller;
    setUp(() {
      client = FakeDiscordPresenceClient();
      controller = DiscordPresenceController(
          client: client,
          now: () => now,
          minimumInterval: Duration.zero,
          positionInterval: Duration.zero);
    });
    tearDown(() async {
      controller.dispose();
      await settle();
      await client.events.close();
    });

    void update(
            {bool enabled = true,
            bool shareTitle = true,
            bool privateMode = false,
            String? scope = 'account-a',
            DiscordPlaybackSnapshot? snapshot = playback}) =>
        controller.update(
          scope: scope,
          enabled: enabled,
          shareTitle: shareTitle,
          privateMode: privateMode,
          playback: snapshot,
        );

    test('no connection before consent or while private/logged out/stopped',
        () async {
      update(enabled: false);
      await settle();
      update(privateMode: true);
      await settle();
      update(scope: null);
      await settle();
      update(snapshot: null);
      await settle();
      expect(client.connections, 0);
      expect(client.activities, isEmpty);
    });

    test('playing and paused activity is acknowledged; stopping clears it',
        () async {
      update();
      await settle();
      expect(client.connections, 1);
      expect(client.activities.single?['details'], playback.title);
      expect(controller.status, DiscordConnectionState.connected);
      update(
          snapshot: const DiscordPlaybackSnapshot(
              active: true, title: 'Synthetic movie', playing: false));
      await settle();
      expect(client.activities.last?['state'], '已暫停');
      update(snapshot: null);
      await settle();
      expect(client.activities.last, isNull);
      expect(controller.status, DiscordConnectionState.disconnected);
    });

    test('disable during pending handshake cannot publish late activity',
        () async {
      client.connectGate = Completer<void>();
      update();
      await settle();
      update(enabled: false);
      await settle();
      client.connectGate!.complete();
      await settle();
      expect(client.activities.whereType<Map<String, Object?>>(), isEmpty);
    });

    test('disable during pending ACK clears and does not resurrect title',
        () async {
      client.activityGate = Completer<void>();
      update();
      await settle();
      expect(client.activities.length, 1);
      update(enabled: false);
      await settle();
      expect(client.activities.last, isNull);
      final count = client.activities.length;
      client.activityGate!.complete();
      await settle();
      expect(client.activities.length, count);
    });

    test('revoking title clears first and replaces it with generic presence',
        () async {
      update();
      await settle();
      update(shareTitle: false);
      await settle();
      expect(client.activities[1], isNull);
      expect(client.activities.last?['details'], 'JMS 媒體播放');
      expect(client.connections, 2);
    });

    test('scope change during an ACK cannot replay the previous account',
        () async {
      client.activityGate = Completer<void>();
      update();
      await settle();
      update(scope: 'account-b', snapshot: null);
      await settle();
      client.activityGate!.complete();
      await settle();
      expect(client.activities.last, isNull);
      expect(client.activities.whereType<Map<String, Object?>>().length, 1);
    });
  });

  test('unsupported platforms cannot enable or open a connection', () async {
    SharedPreferences.setMockInitialValues({});
    final client = FakeDiscordPresenceClient(supported: false);
    final settings = DiscordPresenceSettings(
      preferences: await SharedPreferences.getInstance(),
      controller: DiscordPresenceController(client: client),
    );
    settings.activateAccount('synthetic-account');
    expect(await settings.setEnabled(true), false);
    settings.updatePlayback(playback, privateMode: false);
    await settle();
    expect(client.connections, 0);
    settings.dispose();
    await settle();
    await client.events.close();
  });

  test('consent persists only for its account and title has separate consent',
      () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final client = FakeDiscordPresenceClient();
    final settings = DiscordPresenceSettings(
        preferences: preferences,
        controller: DiscordPresenceController(
            client: client,
            minimumInterval: Duration.zero,
            positionInterval: Duration.zero));
    settings.activateAccount('synthetic-a');
    expect(settings.enabled, false);
    expect(settings.shareTitle, false);
    expect(await settings.setShareTitle(true), false);
    expect(await settings.setEnabled(true), true);
    expect(await settings.setShareTitle(true), true);
    settings.updatePlayback(playback, privateMode: false);
    await settle();
    settings.activateAccount('synthetic-b');
    await settle();
    expect(settings.enabled, false);
    expect(settings.shareTitle, false);
    expect(client.activities.last, isNull);
    settings.activateAccount('synthetic-a');
    expect(settings.enabled, true);
    expect(settings.shareTitle, true);
    settings.activateAccount(null);
    expect(settings.enabled, false);
    settings.dispose();
    await settle();
    await client.events.close();
  });

  testWidgets('position updates coalesce while state changes publish promptly',
      (tester) async {
    var current = now;
    final client = FakeDiscordPresenceClient();
    final controller =
        DiscordPresenceController(client: client, now: () => current);
    void update(bool playing, int position) => controller.update(
        scope: 'synthetic-account',
        enabled: true,
        shareTitle: true,
        privateMode: false,
        playback: DiscordPlaybackSnapshot(
            active: true,
            title: 'Synthetic movie',
            playing: playing,
            position: Duration(seconds: position),
            duration: const Duration(minutes: 30)));
    update(true, 0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(client.activities.whereType<Map<String, Object?>>().length, 1);
    for (var tick = 1; tick <= 10; tick++) {
      current = now.add(Duration(seconds: tick));
      update(true, tick * 2);
      await tester.pump(const Duration(seconds: 1));
    }
    expect(client.activities.whereType<Map<String, Object?>>().length, 1);
    update(false, 20);
    await tester.pump(const Duration(milliseconds: 1));
    expect(client.activities.last?['state'], '已暫停');
    controller.dispose();
    await tester.pump();
    await client.events.close();
  });

  testWidgets(
      'unavailable Discord uses backoff despite ongoing playback updates',
      (tester) async {
    var current = now;
    final client = FakeDiscordPresenceClient()..failConnect = true;
    final controller =
        DiscordPresenceController(client: client, now: () => current);
    void update(int tick) => controller.update(
        scope: 'synthetic-account',
        enabled: true,
        shareTitle: true,
        privateMode: false,
        playback: DiscordPlaybackSnapshot(
            active: true,
            title: 'Synthetic movie',
            playing: tick.isEven,
            position: Duration(seconds: tick),
            duration: const Duration(minutes: 30)));
    update(0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(client.connections, 1);
    for (var tick = 1; tick <= 20; tick++) {
      current = now.add(Duration(seconds: tick));
      update(tick);
      await tester.pump(const Duration(seconds: 1));
    }
    expect(client.connections, 1);
    current = now.add(const Duration(seconds: 31));
    await tester.pump(const Duration(seconds: 11));
    expect(client.connections, 2);
    controller.dispose();
    await tester.pump();
    await client.events.close();
  });
}
