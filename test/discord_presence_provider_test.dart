import 'dart:async';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/credentials_model.dart';
import 'package:fladder/models/items/movie_model.dart';
import 'package:fladder/models/items/episode_model.dart';
import 'package:fladder/models/media_playback_model.dart';
import 'package:fladder/models/playback/playback_model.dart';
import 'package:fladder/providers/discord_presence_provider.dart';
import 'package:fladder/providers/incognito_mode_provider.dart';
import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/services/discord/discord_artwork.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures/discord_fake_client.dart';

AccountModel _account({
  String id = 'synthetic-account-a',
  String server = 'synthetic-server-a',
  bool? incognito,
}) =>
    AccountModel(
      name: 'Synthetic account',
      id: id,
      avatar: '',
      lastUsed: DateTime(2026),
      credentials: CredentialsModel.internal(
          serverId: server, url: 'https://media.example.invalid'),
      incognitoMode: incognito,
    );

PlaybackModel _movie(String title, {String id = 'synthetic-movie'}) =>
    PlaybackModel(
      item: MovieModel.fromBaseDto(BaseItemDto(id: id, name: title), null),
      playbackInfo: null,
      media: null,
    );

class _TestUser extends User {
  _TestUser(this.initial);

  final AccountModel? initial;

  @override
  AccountModel? build() => initial;

  void changeAccount(AccountModel? account) => state = account;
}

class _PresenceHarness {
  _PresenceHarness(this.container, this.client, this.settings);

  final ProviderContainer container;
  final FakeDiscordPresenceClient client;
  final DiscordPresenceSettings settings;

  void changeAccount(AccountModel? account) =>
      (container.read(userProvider.notifier) as _TestUser)
          .changeAccount(account);

  List<Map<String, Object?>> get disclosed =>
      client.activities.whereType<Map<String, Object?>>().toList();
}

Future<void> _pumpPresence(WidgetTester tester) async {
  for (var index = 0; index < 3; index++) {
    await tester.pump();
  }
  await tester.pump(const Duration(seconds: 2));
  for (var index = 0; index < 3; index++) {
    await tester.pump();
  }
}

Future<_PresenceHarness> _harness(
  WidgetTester tester, {
  required AccountModel? account,
  bool globalIncognito = false,
  List<AccountModel> previouslyConsented = const [],
  List<AccountModel> previouslyArtworkConsented = const [],
  DiscordArtworkLoader? artworkLoader,
}) async {
  final saved = <String, Object>{};
  for (final consented in previouslyConsented) {
    final scope = discordAccountScope(consented)!;
    saved['jms.discord.presence.v1.$scope.enabled'] = true;
    saved['jms.discord.presence.v1.$scope.shareTitle'] = true;
  }
  for (final consented in previouslyArtworkConsented) {
    final scope = discordAccountScope(consented)!;
    saved['jms.discord.presence.v1.$scope.shareArtwork'] = true;
  }
  SharedPreferences.setMockInitialValues(saved);
  final preferences = await SharedPreferences.getInstance();
  final client = FakeDiscordPresenceClient();
  // Keep the real settings provider, effective incognito provider, playback
  // state providers and controller. Only storage, user state and IPC are fake.
  final container = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(preferences),
    discordPresenceClientProvider.overrideWithValue(client),
    if (artworkLoader != null)
      discordArtworkLoaderProvider.overrideWithValue(artworkLoader),
    userProvider.overrideWith(() => _TestUser(account)),
  ]);
  container.read(incognitoModeProvider.notifier).state = globalIncognito;
  container.read(playBackModel.notifier).state = _movie('Synthetic old movie');
  container.read(mediaPlaybackProvider.notifier).state = MediaPlaybackModel(
    state: VideoPlayerState.fullScreen,
    playing: true,
    position: const Duration(minutes: 5),
    duration: const Duration(minutes: 25),
  );
  final settings = container.read(discordPresenceSettingsProvider);
  addTearDown(() async {
    container.dispose();
    await tester.pump();
    await client.events.close();
  });
  return _PresenceHarness(container, client, settings);
}

void main() {
  const poster = 'https://image.tmdb.org/t/p/w500/SyntheticPoster.jpg';

  test('episode artwork uses its series rather than the episode or season', () {
    final episode = EpisodeModel.fromBaseDto(
        const BaseItemDto(
            id: 'synthetic-episode',
            parentId: 'synthetic-season',
            seriesId: 'synthetic-series',
            name: 'Synthetic episode'),
        null);
    expect(discordArtworkItemId(episode), 'synthetic-series');
    expect(discordArtworkItemId(_movie('Synthetic').item), 'synthetic-movie');
    expect(discordArtworkItemId(null), isNull);
    expect(
        discordArtworkItemId(EpisodeModel.fromBaseDto(
            const BaseItemDto(id: 'synthetic-episode'), null)),
        isNull);
  });

  testWidgets('artwork is separately consented, cached and removed with title',
      (tester) async {
    final calls = <String>[];
    final account = _account();
    final h = await _harness(tester,
        account: account,
        previouslyConsented: [account], artworkLoader: (id) async {
      calls.add(id);
      return poster;
    });
    await _pumpPresence(tester);
    expect(h.settings.shareArtwork, isFalse);
    expect(calls, isEmpty);
    expect(h.disclosed.last, isNot(contains('assets')));
    expect(await h.settings.setShareArtwork(true), isTrue);
    await _pumpPresence(tester);
    expect(calls, ['synthetic-movie']);
    expect((h.disclosed.last['assets'] as Map)['large_image'], poster);
    for (var tick = 1; tick <= 10; tick++) {
      h.container.read(mediaPlaybackProvider.notifier).state = h.container
          .read(mediaPlaybackProvider)
          .copyWith(position: Duration(minutes: tick));
    }
    await _pumpPresence(tester);
    expect(calls, hasLength(1));
    final boundary = h.client.activities.length;
    expect(await h.settings.setShareTitle(false), isTrue);
    await _pumpPresence(tester);
    expect(h.client.activities.skip(boundary), contains(isNull));
    expect(h.disclosed.last['details'], 'JMS 媒體播放');
    expect(h.disclosed.last, isNot(contains('assets')));
  });

  testWidgets('series poster loads once across its episodes', (tester) async {
    final calls = <String>[];
    final account = _account();
    final h = await _harness(tester,
        account: account,
        previouslyConsented: [account], artworkLoader: (id) async {
      calls.add(id);
      return poster;
    });
    for (var episode = 1; episode <= 2; episode++) {
      h.container.read(playBackModel.notifier).state = PlaybackModel(
          item: EpisodeModel.fromBaseDto(
              BaseItemDto(
                  id: 'synthetic-episode-$episode',
                  seriesId: 'synthetic-series',
                  seriesName: 'Synthetic anime',
                  name: 'Episode $episode'),
              null),
          playbackInfo: null,
          media: null);
      if (episode == 1) await h.settings.setShareArtwork(true);
      await _pumpPresence(tester);
      expect((h.disclosed.last['assets'] as Map)['large_image'], poster);
      expect(h.disclosed.last['details'], 'Synthetic anime • Episode $episode');
    }
    expect(calls, ['synthetic-series']);
  });

  for (final boundary in [
    'artwork',
    'title',
    'disabled',
    'private',
    'account',
    'stopped',
    'suspended'
  ]) {
    testWidgets('late artwork cannot survive $boundary boundary',
        (tester) async {
      final pending = Completer<String?>();
      final account = _account();
      final h = await _harness(tester,
          account: account,
          previouslyConsented: [account],
          artworkLoader: (_) => pending.future);
      await h.settings.setShareArtwork(true);
      await _pumpPresence(tester);
      switch (boundary) {
        case 'artwork':
          await h.settings.setShareArtwork(false);
        case 'title':
          await h.settings.setShareTitle(false);
        case 'disabled':
          await h.settings.setEnabled(false);
        case 'private':
          h.container.read(incognitoModeProvider.notifier).state = true;
        case 'account':
          h.changeAccount(_account(id: 'synthetic-other-account'));
        case 'stopped':
          h.container.read(mediaPlaybackProvider.notifier).state =
              h.container.read(mediaPlaybackProvider).copyWith(completed: true);
        case 'suspended':
          h.settings.suspend();
      }
      pending.complete(poster);
      await _pumpPresence(tester);
      expect(h.disclosed.where((activity) => activity.containsKey('assets')),
          isEmpty);
      h.settings.suspend();
      await tester.pump();
    });
  }

  testWidgets('out-of-order artwork never replaces the new work',
      (tester) async {
    final pending = <String, Completer<String?>>{};
    final account = _account();
    final h = await _harness(tester,
        account: account,
        previouslyConsented: [account],
        artworkLoader: (id) => (pending[id] = Completer<String?>()).future);
    await h.settings.setShareArtwork(true);
    await _pumpPresence(tester);
    h.container.read(playBackModel.notifier).state =
        _movie('Synthetic next movie', id: 'synthetic-next');
    await _pumpPresence(tester);
    const nextPoster = 'https://image.tmdb.org/t/p/w500/SyntheticNext.jpg';
    pending['synthetic-next']!.complete(nextPoster);
    await _pumpPresence(tester);
    pending['synthetic-movie']!.complete(poster);
    await _pumpPresence(tester);
    expect((h.disclosed.last['assets'] as Map)['large_image'], nextPoster);
    expect(h.disclosed.last['details'], 'Synthetic next movie');
  });

  testWidgets('artwork failure stays text-only without a polling loop',
      (tester) async {
    var calls = 0;
    final account = _account();
    final h = await _harness(tester,
        account: account,
        previouslyConsented: [account], artworkLoader: (_) async {
      calls++;
      throw StateError('Synthetic offline server');
    });
    await h.settings.setShareArtwork(true);
    await _pumpPresence(tester);
    h.container.read(mediaPlaybackProvider.notifier).state =
        h.container.read(mediaPlaybackProvider).copyWith(playing: false);
    await _pumpPresence(tester);
    expect(calls, 1);
    expect(h.disclosed.last, isNot(contains('assets')));
    expect(h.disclosed.last['state'], '已暫停');
  });

  testWidgets('timed out artwork stays text-only even if it arrives later',
      (tester) async {
    final pending = Completer<String?>();
    var calls = 0;
    final account = _account();
    final h = await _harness(tester,
        account: account,
        previouslyConsented: [account],
        previouslyArtworkConsented: [account], artworkLoader: (_) {
      calls++;
      return pending.future;
    });
    await _pumpPresence(tester);
    await tester.pump(const Duration(seconds: 9));
    pending.complete(poster);
    await _pumpPresence(tester);
    expect(calls, 1);
    expect(h.disclosed.where((activity) => activity.containsKey('assets')),
        isEmpty);
    expect(h.disclosed.last['details'], 'Synthetic old movie');
    h.settings.suspend();
    await tester.pump();
  });

  testWidgets(
      'null account override follows normal global mode and title consent',
      (tester) async {
    final account = _account();
    final h = await _harness(tester, account: account);
    expect(account.incognitoMode, isNull);
    expect(h.container.read(incognitoProvider), isFalse);
    expect(h.settings.hasAccount, isTrue);
    await _pumpPresence(tester);
    expect(h.client.connections, 0);
    expect(h.disclosed, isEmpty);

    expect(await h.settings.setEnabled(true), isTrue);
    await _pumpPresence(tester);
    expect(h.client.connections, 1);
    expect(h.disclosed.last['details'], 'JMS 媒體播放');
    expect(h.disclosed.last.values, isNot(contains('Synthetic old movie')));

    expect(await h.settings.setShareTitle(true), isTrue);
    await _pumpPresence(tester);
    expect(h.disclosed.last['details'], 'Synthetic old movie');
  });

  testWidgets(
      'global private mode clears title and reacts without account change',
      (tester) async {
    final account = _account();
    final h = await _harness(tester,
        account: account,
        globalIncognito: true,
        previouslyConsented: [account]);
    await _pumpPresence(tester);
    expect(h.client.connections, 0);
    expect(h.disclosed, isEmpty);

    h.container.read(incognitoModeProvider.notifier).state = false;
    await _pumpPresence(tester);
    expect(h.disclosed.last['details'], 'Synthetic old movie');
    final beforePrivate = h.client.activities.length;
    h.container.read(incognitoModeProvider.notifier).state = true;
    await _pumpPresence(tester);
    expect(h.client.activities.skip(beforePrivate), contains(isNull));
    expect(h.client.activities.skip(beforePrivate).whereType<Map>(), isEmpty);

    h.container.read(playBackModel.notifier).state =
        _movie('Synthetic private movie');
    h.container.read(mediaPlaybackProvider.notifier).state = h.container
        .read(mediaPlaybackProvider)
        .copyWith(position: const Duration(minutes: 6));
    await _pumpPresence(tester);
    expect(h.client.activities.skip(beforePrivate).whereType<Map>(), isEmpty);
    expect(h.client.connections, 1);
  });

  for (final accountPrivate in [true, false]) {
    for (final globalPrivate in [true, false]) {
      testWidgets(
          'explicit account private=$accountPrivate overrides global=$globalPrivate',
          (tester) async {
        final account = _account(incognito: accountPrivate);
        final h = await _harness(tester,
            account: account,
            globalIncognito: globalPrivate,
            previouslyConsented: [account]);
        expect(h.container.read(incognitoProvider), accountPrivate);
        await _pumpPresence(tester);
        if (accountPrivate) {
          expect(h.client.connections, 0);
          expect(h.disclosed, isEmpty);
        } else {
          expect(h.client.connections, 1);
          expect(h.disclosed.last['details'], 'Synthetic old movie');
        }
      });
    }
  }

  testWidgets('explicit private account changes clear existing disclosure',
      (tester) async {
    final account = _account(incognito: false);
    final h = await _harness(tester,
        account: account, previouslyConsented: [account]);
    await _pumpPresence(tester);
    expect(h.disclosed.last['details'], 'Synthetic old movie');
    final boundary = h.client.activities.length;
    h.changeAccount(account.copyWith(incognitoMode: true));
    await _pumpPresence(tester);
    expect(h.container.read(incognitoProvider), isTrue);
    expect(h.client.activities.skip(boundary), contains(isNull));
    expect(h.client.activities.skip(boundary).whereType<Map>(), isEmpty);
  });

  testWidgets('logout clears presence and subsequent playback cannot reconnect',
      (tester) async {
    final account = _account();
    final h = await _harness(tester,
        account: account, previouslyConsented: [account]);
    await _pumpPresence(tester);
    expect(h.disclosed, isNotEmpty);
    final boundary = h.client.activities.length;
    h.changeAccount(null);
    await _pumpPresence(tester);
    expect(h.settings.hasAccount, isFalse);
    expect(h.settings.enabled, isFalse);
    expect(h.client.activities.skip(boundary), contains(isNull));
    expect(await h.settings.setEnabled(true), isFalse);
    h.container.read(playBackModel.notifier).state =
        _movie('Synthetic logged-out movie');
    await _pumpPresence(tester);
    expect(h.client.activities.skip(boundary).whereType<Map>(), isEmpty);
    expect(h.client.connections, 1);
  });

  for (final changeServer in [false, true]) {
    testWidgets(
        '${changeServer ? 'server' : 'account'} switch with saved consent cannot reuse old playback',
        (tester) async {
      final oldAccount = _account();
      final nextAccount = changeServer
          ? _account(server: 'synthetic-server-b')
          : _account(id: 'synthetic-account-b');
      final h = await _harness(tester,
          account: oldAccount, previouslyConsented: [oldAccount, nextAccount]);
      await _pumpPresence(tester);
      expect(h.disclosed.last['details'], 'Synthetic old movie');
      final boundary = h.client.activities.length;
      h.changeAccount(nextAccount);
      await _pumpPresence(tester);
      expect(h.settings.activeScope, discordAccountScope(nextAccount));
      expect(h.settings.enabled, isTrue);
      expect(h.settings.shareTitle, isTrue);
      expect(h.client.activities.skip(boundary), contains(isNull));
      expect(h.client.activities.skip(boundary).whereType<Map>(), isEmpty);

      // Late playback state events from the old player do not release its model.
      h.container.read(mediaPlaybackProvider.notifier).state = h.container
          .read(mediaPlaybackProvider)
          .copyWith(playing: false, position: const Duration(minutes: 6));
      await _pumpPresence(tester);
      expect(h.client.activities.skip(boundary).whereType<Map>(), isEmpty);

      h.container.read(playBackModel.notifier).state =
          _movie('Synthetic new movie');
      await _pumpPresence(tester);
      final afterSwitch = h.client.activities.skip(boundary).whereType<Map>();
      expect(afterSwitch, isNotEmpty);
      expect(
          afterSwitch.every((item) => item['details'] == 'Synthetic new movie'),
          isTrue);
    });
  }

  testWidgets('new account never inherits old account consent', (tester) async {
    final oldAccount = _account();
    final h = await _harness(tester,
        account: oldAccount, previouslyConsented: [oldAccount]);
    await _pumpPresence(tester);
    final boundary = h.client.activities.length;
    h.changeAccount(_account(id: 'synthetic-unconsented-account'));
    h.container.read(playBackModel.notifier).state =
        _movie('Synthetic new movie');
    await _pumpPresence(tester);
    expect(h.settings.enabled, isFalse);
    expect(h.settings.shareTitle, isFalse);
    expect(h.client.activities.skip(boundary).whereType<Map>(), isEmpty);
  });

  testWidgets(
      'pending connection cannot disclose old playback after scope change',
      (tester) async {
    final oldAccount = _account();
    final h = await _harness(tester,
        account: oldAccount, previouslyConsented: [oldAccount]);
    final ready = Completer<void>();
    h.client.connectGate = ready;
    await _pumpPresence(tester);
    expect(h.client.connections, 1);
    h.changeAccount(_account(id: 'synthetic-account-b'));
    ready.complete();
    await _pumpPresence(tester);
    expect(h.disclosed, isEmpty);
    expect(h.settings.enabled, isFalse);
  });

  testWidgets('without an actual account global normal mode cannot disclose',
      (tester) async {
    final h = await _harness(tester, account: null);
    expect(h.container.read(incognitoProvider), isFalse);
    await _pumpPresence(tester);
    expect(h.settings.hasAccount, isFalse);
    expect(await h.settings.setEnabled(true), isFalse);
    expect(h.client.connections, 0);
    expect(h.disclosed, isEmpty);
  });
}
