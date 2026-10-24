import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/credentials_model.dart';
import 'package:fladder/models/items/movie_model.dart';
import 'package:fladder/models/media_playback_model.dart';
import 'package:fladder/models/playback/playback_model.dart';
import 'package:fladder/providers/discord_browsing_provider.dart';
import 'package:fladder/providers/discord_presence_provider.dart';
import 'package:fladder/providers/incognito_mode_provider.dart';
import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/screens/login/lock_screen.dart';
import 'package:fladder/services/discord/discord_activity.dart';
import 'package:fladder/services/discord/discord_artwork.dart';
import 'package:fladder/services/discord/discord_presence_controller.dart';

import 'fixtures/discord_fake_client.dart';

const _poster = 'https://image.tmdb.org/t/p/w500/SyntheticBrowsing.jpg';
const _details = DiscordBrowsingSnapshot.details(
  title: 'Synthetic browsing movie',
  artworkItemId: 'TEST_ONLY local item',
  artworkUrl: _poster,
);

AccountModel _account(String id) => AccountModel(
      name: 'Synthetic account',
      id: id,
      avatar: '',
      lastUsed: DateTime(2026),
      credentials: CredentialsModel.internal(
        serverId: 'synthetic-server',
        url: 'https://media.example.invalid',
      ),
    );

class _TestUser extends User {
  _TestUser(this.initial);
  final AccountModel? initial;

  @override
  AccountModel? build() => initial;

  void change(AccountModel? value) => state = value;
}

class _Harness {
  _Harness(this.container, this.client, this.settings);
  final ProviderContainer container;
  final FakeDiscordPresenceClient client;
  final DiscordPresenceSettings settings;
  bool _closed = false;

  Future<void> close(WidgetTester tester) async {
    if (_closed) {
      return;
    }
    _closed = true;
    container.dispose();
    for (var index = 0; index < 3; index++) {
      await tester.pump();
    }
    await client.events.close();
  }

  List<Map<String, Object?>> get disclosed =>
      client.activities.whereType<Map<String, Object?>>().toList();

  void changeAccount(AccountModel? account) =>
      (container.read(userProvider.notifier) as _TestUser).change(account);
}

Future<void> _pump(WidgetTester tester) async {
  for (var index = 0; index < 3; index++) {
    await tester.pump();
  }
  await tester.pump(const Duration(seconds: 2));
  for (var index = 0; index < 3; index++) {
    await tester.pump();
  }
}

Future<_Harness> _harness(
  WidgetTester tester, {
  required AccountModel? account,
  List<AccountModel> consented = const [],
  DiscordBrowsingSnapshot browsing = _details,
  DiscordArtworkLoader? loader,
}) async {
  final saved = <String, Object>{};
  for (final account in consented) {
    final scope = discordAccountScope(account)!;
    for (final field in ['enabled', 'shareTitle', 'shareArtwork']) {
      saved['jms.discord.presence.v1.$scope.$field'] = true;
    }
  }
  SharedPreferences.setMockInitialValues(saved);
  final preferences = await SharedPreferences.getInstance();
  final client = FakeDiscordPresenceClient();
  final container = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(preferences),
    discordPresenceClientProvider.overrideWithValue(client),
    // Every potential metadata request is fake, including the default path.
    discordArtworkLoaderProvider.overrideWithValue(loader ?? (_) async => null),
    userProvider.overrideWith(() => _TestUser(account)),
  ]);
  container.read(incognitoModeProvider.notifier).state = false;
  container.read(playBackModel.notifier).state = null;
  container.read(mediaPlaybackProvider.notifier).state = MediaPlaybackModel();
  container.read(discordBrowsingProvider.notifier).activate(
        routeId: Object(),
        scope: discordAccountScope(account),
        snapshot: browsing,
      );
  final settings = container.read(discordPresenceSettingsProvider);
  final harness = _Harness(container, client, settings);
  addTearDown(() => harness.close(tester));
  return harness;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.utc(2026, 10, 17, 12);

  test('selecting activity exports only generic display fields and no time',
      () {
    final activity = discordActivity(null,
        browsing: const DiscordBrowsingSnapshot.selecting(),
        shareTitle: true,
        shareArtwork: true,
        now: now)!;
    expect(activity.keys.toSet(), {'type', 'details', 'state', 'assets'});
    expect(activity['type'], 0);
    expect(activity['details'], 'JMS');
    expect(activity['state'], '正在選片');
    expect((activity['assets'] as Map)['large_image'],
        jmsDiscordApplicationArtworkUrl);
    expect(activity, isNot(contains('timestamps')));
  });

  for (final titleConsent in [false, true]) {
    for (final artworkConsent in [false, true]) {
      test('details title=$titleConsent and artwork=$artworkConsent consent',
          () {
        final activity = discordActivity(null,
            browsing: _details,
            shareTitle: titleConsent,
            shareArtwork: artworkConsent,
            now: now)!;
        expect(activity['details'], titleConsent ? _details.title : 'JMS');
        expect(activity['state'], '正在瀏覽作品');
        expect(activity['type'], 0);
        expect(activity, isNot(contains('timestamps')));
        expect(
            (activity['assets'] as Map)['large_image'],
            titleConsent && artworkConsent
                ? _poster
                : jmsDiscordApplicationArtworkUrl);
        expect(jsonEncode(activity), isNot(contains(_details.artworkItemId!)));
      });
    }
  }

  test('private URLs paths and credentials cannot enter browsing payloads', () {
    for (final title in [
      'https://media.example.invalid/item?api_key=TEST_ONLY_SECRET',
      'token=TEST_ONLY_SECRET',
      r'C:\Synthetic\private.mkv',
      '/srv/synthetic/private.mkv',
    ]) {
      final activity = discordActivity(null,
          browsing: DiscordBrowsingSnapshot.details(
            title: title,
            artworkItemId: 'TEST_ONLY_PRIVATE_ITEM',
            artworkUrl:
                'https://media.example.invalid/image?token=TEST_ONLY_SECRET',
          ),
          shareTitle: true,
          shareArtwork: true,
          now: now)!;
      expect(activity['details'], 'JMS');
      expect((activity['assets'] as Map)['large_image'],
          jmsDiscordApplicationArtworkUrl);
      final encoded = jsonEncode(activity);
      for (final secret in [
        'TEST_ONLY_SECRET',
        'TEST_ONLY_PRIVATE_ITEM',
        title
      ]) {
        expect(encoded, isNot(contains(secret)));
      }
      expect(activity, isNot(contains('timestamps')));
    }
  });

  test('fixed JMS artwork does not widen the media poster whitelist', () {
    for (final rejected in [
      jmsDiscordApplicationArtworkUrl,
      'https://raw.githubusercontent.com/example/repo/main/poster.png',
      'https://poster.example.invalid/poster.jpg',
      'https://127.0.0.1/Images/Primary',
      'https://image.tmdb.org/t/p/w500/Synthetic.jpg?token=TEST_ONLY_SECRET',
    ]) {
      expect(discordArtworkUrl(rejected), isNull);
      final activity = discordActivity(null,
          browsing: DiscordBrowsingSnapshot.details(
              title: 'Synthetic movie', artworkUrl: rejected),
          shareTitle: true,
          shareArtwork: true,
          now: now)!;
      expect((activity['assets'] as Map)['large_image'],
          jmsDiscordApplicationArtworkUrl);
    }
    expect(discordArtworkUrl(_poster), _poster);
  });

  testWidgets(
      'browsing is disabled by default and consent persists per account',
      (tester) async {
    final account = _account('synthetic-a');
    final h = await _harness(tester, account: account);
    await _pump(tester);
    expect(h.settings.enabled, isFalse);
    expect(h.client.connections, 0);
    expect(await h.settings.setShareTitle(true), isFalse);
    expect(await h.settings.setEnabled(true), isTrue);
    await _pump(tester);
    expect(h.disclosed.last['details'], 'JMS');
    expect(await h.settings.setShareArtwork(true), isFalse);
    expect(await h.settings.setShareTitle(true), isTrue);
    await _pump(tester);
    expect(h.disclosed.last['details'], _details.title);
    expect((h.disclosed.last['assets'] as Map)['large_image'],
        jmsDiscordApplicationArtworkUrl);
    expect(await h.settings.setShareArtwork(true), isTrue);
    await _pump(tester);
    expect((h.disclosed.last['assets'] as Map)['large_image'], _poster);

    final boundary = h.client.activities.length;
    h.changeAccount(_account('synthetic-b'));
    await _pump(tester);
    expect(h.settings.enabled, isFalse);
    expect(h.settings.shareTitle, isFalse);
    expect(h.settings.shareArtwork, isFalse);
    expect(h.client.activities.skip(boundary).whereType<Map>(), isEmpty);
    h.changeAccount(account);
    expect(h.settings.enabled, isTrue);
    expect(h.settings.shareTitle, isTrue);
    expect(h.settings.shareArtwork, isTrue);
    await h.close(tester);
  });

  testWidgets('video playback takes priority and stopping returns to browsing',
      (tester) async {
    final account = _account('synthetic-a');
    final h = await _harness(tester, account: account, consented: [account]);
    await _pump(tester);
    expect(h.disclosed.last['state'], '正在瀏覽作品');
    h.container.read(playBackModel.notifier).state = PlaybackModel(
      item: MovieModel.fromBaseDto(
          const BaseItemDto(
              id: 'synthetic-playback', name: 'Synthetic playing movie'),
          null),
      playbackInfo: null,
      media: null,
    );
    h.container.read(mediaPlaybackProvider.notifier).state = MediaPlaybackModel(
      state: VideoPlayerState.fullScreen,
      playing: true,
      position: const Duration(minutes: 1),
      duration: const Duration(minutes: 20),
    );
    await _pump(tester);
    expect(h.disclosed.last['details'], 'Synthetic playing movie');
    expect(h.disclosed.last['state'], '正在觀看');
    expect(h.disclosed.last['type'], 3);
    expect(h.disclosed.last, contains('timestamps'));
    h.container.read(mediaPlaybackProvider.notifier).state =
        MediaPlaybackModel();
    await _pump(tester);
    expect(h.disclosed.last['details'], _details.title);
    expect(h.disclosed.last['type'], 0);
    expect(h.disclosed.last, isNot(contains('timestamps')));
  });

  testWidgets(
      'paused playback keeps its title until exit then clears it on the library route',
      (tester) async {
    final account = _account('synthetic-a');
    final h = await _harness(tester, account: account, consented: [account]);
    h.container.read(playBackModel.notifier).state = PlaybackModel(
      item: MovieModel.fromBaseDto(
          const BaseItemDto(
              id: 'synthetic-playback', name: 'Synthetic paused movie'),
          null),
      playbackInfo: null,
      media: null,
    );
    h.container.read(mediaPlaybackProvider.notifier).state = MediaPlaybackModel(
      state: VideoPlayerState.fullScreen,
      playing: true,
      position: const Duration(minutes: 1),
      duration: const Duration(minutes: 20),
    );
    await _pump(tester);
    expect(h.disclosed.last['state'], '正在觀看');
    h.container.read(mediaPlaybackProvider.notifier).state =
        h.container.read(mediaPlaybackProvider).copyWith(playing: false);
    await _pump(tester);
    expect(h.disclosed.last['state'], '已暫停');
    expect(h.disclosed.last, isNot(contains('timestamps')));
    h.container.read(discordBrowsingProvider.notifier).activate(
          routeId: Object(),
          scope: discordAccountScope(account),
          snapshot: const DiscordBrowsingSnapshot.selecting(),
        );
    await _pump(tester);
    expect(h.disclosed.last['state'], '已暫停');
    expect(h.disclosed.last['details'], 'Synthetic paused movie');
    h.container.read(mediaPlaybackProvider.notifier).state =
        MediaPlaybackModel();
    await _pump(tester);
    expect(h.disclosed.last['state'], '正在選片');
    expect(h.disclosed.last['details'], 'JMS');
    expect(jsonEncode(h.disclosed.last),
        isNot(contains('Synthetic paused movie')));
  });

  for (final gate in ['logout', 'private', 'locked', 'blocked route']) {
    testWidgets('$gate provider gate withdraws browsing and prevents republish',
        (tester) async {
      final account = _account('synthetic-a');
      final h = await _harness(tester, account: account, consented: [account]);
      await _pump(tester);
      expect(h.disclosed.last['details'], _details.title);
      final boundary = h.client.activities.length;
      switch (gate) {
        case 'logout':
          h.changeAccount(null);
        case 'private':
          h.container.read(incognitoModeProvider.notifier).state = true;
        case 'locked':
          h.container.read(lockScreenActiveProvider.notifier).state = true;
        case 'blocked route':
          h.container.read(discordBrowsingProvider.notifier).activate(
              routeId: Object(),
              scope: discordAccountScope(account),
              snapshot: const DiscordBrowsingSnapshot.selecting(),
              blocked: true);
      }
      await _pump(tester);
      expect(h.client.activities.skip(boundary), contains(isNull));
      h.container.read(mediaPlaybackProvider.notifier).state =
          MediaPlaybackModel();
      await _pump(tester);
      expect(h.client.activities.skip(boundary).whereType<Map>(), isEmpty);
      if (gate == 'logout') expect(await h.settings.setEnabled(true), isFalse);
    });
  }

  testWidgets(
      'late detail artwork cannot replace selecting after leaving details',
      (tester) async {
    final pending = Completer<String?>();
    final account = _account('synthetic-a');
    final h = await _harness(tester,
        account: account,
        consented: [account],
        browsing: const DiscordBrowsingSnapshot.details(
            title: 'Synthetic late detail', artworkItemId: 'synthetic-late'),
        loader: (_) => pending.future);
    await _pump(tester);
    h.container.read(discordBrowsingProvider.notifier).activate(
        routeId: Object(),
        scope: discordAccountScope(account),
        snapshot: const DiscordBrowsingSnapshot.selecting());
    final boundary = h.client.activities.length;
    pending.complete(_poster);
    await _pump(tester);
    expect(h.disclosed.last['state'], '正在選片');
    expect(h.disclosed.last['details'], 'JMS');
    expect(
        h.client.activities.skip(boundary).whereType<Map>().any((activity) =>
            (activity['assets'] as Map?)?['large_image'] == _poster),
        isFalse);
  });

  testWidgets(
      'a consented new account cannot disclose the previous route metadata',
      (tester) async {
    final first = _account('synthetic-a');
    final next = _account('synthetic-b');
    final h = await _harness(tester, account: first, consented: [first, next]);
    await _pump(tester);
    final boundary = h.client.activities.length;
    h.changeAccount(next);
    await _pump(tester);
    final activities = h.client.activities.skip(boundary).whereType<Map>();
    expect(activities, isNotEmpty);
    expect(activities.every((activity) => activity['state'] == '正在選片'), isTrue);
    expect(jsonEncode(activities.toList()), isNot(contains(_details.title)));
    expect(jsonEncode(activities.toList()), isNot(contains(_poster)));
  });

  testWidgets(
      'rapid detail selecting detail changes coalesce within two seconds',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'jms.discord.presence.v1.synthetic-a.enabled': true,
      'jms.discord.presence.v1.synthetic-a.shareTitle': true,
      'jms.discord.presence.v1.synthetic-a.shareArtwork': true,
    });
    var current = now;
    final client = FakeDiscordPresenceClient();
    final settings = DiscordPresenceSettings(
      preferences: await SharedPreferences.getInstance(),
      controller: DiscordPresenceController(client: client, now: () => current),
    );
    addTearDown(() async {
      settings.dispose();
      for (var index = 0; index < 3; index++) {
        await tester.pump();
      }
      await client.events.close();
    });
    settings.activateAccount('synthetic-a');
    settings.updateBrowsing(_details, privateMode: false);
    for (var index = 0; index < 3; index++) {
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 1));
    expect(client.activities.whereType<Map>(), hasLength(1));
    final connections = client.connections;
    final boundary = client.activities.length;

    settings.updateBrowsing(const DiscordBrowsingSnapshot.selecting(),
        privateMode: false);
    await tester.pump();
    settings.updateBrowsing(
        const DiscordBrowsingSnapshot.details(
            title: 'Synthetic detail B', artworkUrl: _poster),
        privateMode: false);
    for (var index = 0; index < 3; index++) {
      await tester.pump();
    }
    current = now.add(const Duration(milliseconds: 1999));
    await tester.pump(const Duration(milliseconds: 1999));
    expect(client.connections, connections);
    expect(client.activities.skip(boundary).whereType<Map>(), isEmpty);
    current = now.add(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 1));
    for (var index = 0; index < 3; index++) {
      await tester.pump();
    }
    final published =
        client.activities.skip(boundary).whereType<Map>().toList();
    expect(published, hasLength(1));
    expect(published.single['details'], 'Synthetic detail B');
    expect(client.connections, connections);
  });

  for (final stage in ['handshake', 'ACK', 'queued']) {
    testWidgets('disable during browsing $stage cannot publish pending work',
        (tester) async {
      final client = FakeDiscordPresenceClient();
      if (stage == 'handshake') client.connectGate = Completer<void>();
      if (stage == 'ACK') client.activityGate = Completer<void>();
      final controller =
          DiscordPresenceController(client: client, now: () => now);
      addTearDown(() async {
        controller.dispose();
        await tester.pump();
        await client.events.close();
      });
      void update(bool enabled, DiscordBrowsingSnapshot browsing) =>
          controller.update(
              scope: 'synthetic-a',
              enabled: enabled,
              shareTitle: true,
              privateMode: false,
              playback: null,
              browsing: browsing);
      update(true, const DiscordBrowsingSnapshot.selecting());
      await _pump(tester);
      expect(client.connections, 1);
      if (stage == 'queued') update(true, _details);
      final boundary = client.activities.length;
      update(false, _details);
      await _pump(tester);
      client.connectGate?.complete();
      client.activityGate?.complete();
      await _pump(tester);
      await tester.pump(const Duration(seconds: 31));
      expect(client.activities.skip(boundary).whereType<Map>(), isEmpty);
      expect(client.connections, 1);
      if (stage == 'handshake') {
        expect(client.activities.whereType<Map>(), isEmpty);
      } else {
        expect(client.activities.skip(boundary), contains(isNull));
      }
    });
  }

  testWidgets(
      'browsing changes preserve reconnect backoff when Discord is absent',
      (tester) async {
    var current = now;
    final client = FakeDiscordPresenceClient()..failConnect = true;
    final controller =
        DiscordPresenceController(client: client, now: () => current);
    void update(int index) => controller.update(
        scope: 'synthetic-a',
        enabled: true,
        shareTitle: true,
        privateMode: false,
        playback: null,
        browsing:
            DiscordBrowsingSnapshot.details(title: 'Synthetic movie $index'));
    try {
      update(0);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      expect(client.connections, 1);
      for (var index = 1; index <= 20; index++) {
        current = now.add(Duration(seconds: index));
        update(index);
        await tester.pump(const Duration(seconds: 1));
      }
      expect(client.connections, 1);
      current = now.add(const Duration(seconds: 31));
      await tester.pump(const Duration(seconds: 11));
      expect(client.connections, 2);
      expect(client.activities, isEmpty);
    } finally {
      controller.dispose();
      await tester.pump();
      await client.events.close();
    }
  });
}
