import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/services/discord/discord_activity.dart';
import 'package:fladder/services/discord/discord_artwork.dart';
import 'package:fladder/services/discord/discord_presence_controller.dart';

import 'fixtures/discord_fake_client.dart';

const _poster = 'https://image.tmdb.org/t/p/w500/AnimePoster123.jpg';
const _playback = DiscordPlaybackSnapshot(
  active: true,
  title: '測試動畫',
  playing: true,
);

Future<void> _settle() async {
  for (var index = 0; index < 5; index++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  final now = DateTime.fromMillisecondsSinceEpoch(1800000000000, isUtc: true);

  group('public Discord artwork URL', () {
    test('TMDB images use the bounded canonical poster size', () {
      for (final size in ['original', 'w92', 'w342', 'w500', 'w780']) {
        expect(
          discordArtworkUrl(
              'https://image.tmdb.org/t/p/$size/AnimePoster123.jpg'),
          _poster,
          reason: size,
        );
      }
      expect(
        discordArtworkUrl('https://image.tmdb.org/t/p/original/Poster123.webp'),
        'https://image.tmdb.org/t/p/w500/Poster123.webp',
      );
    });

    test('TVDB public artwork preserves its validated path', () {
      for (final path in [
        'banners/v4/series/12345/posters/abcdef.jpg',
        'banners/series/12345/posters/anime_poster-1.png',
        'banners/movies/12345/posters/abcdef.webp',
      ]) {
        final url = 'https://artworks.thetvdb.com/$path';
        expect(discordArtworkUrl(url), url);
      }
    });

    final rejected = <String, String?>{
      'missing URL': null,
      'empty URL': '',
      'private Jellyfin artwork':
          'https://media.example.invalid/Items/123/Images/Primary',
      'documentation IPv4 host': 'https://192.0.2.1/t/p/w500/Poster.jpg',
      'loopback host': 'https://localhost/t/p/w500/Poster.jpg',
      'arbitrary public host': 'https://covers.example.invalid/Poster.jpg',
      'HTTP': 'http://image.tmdb.org/t/p/w500/Poster.jpg',
      'protocol relative URL': '//image.tmdb.org/t/p/w500/Poster.jpg',
      'file protocol': 'file:///t/p/w500/Poster.jpg',
      'data protocol': 'data:image/png;base64,c3ludGhldGlj',
      'embedded credentials':
          'https://fixture-only@image.tmdb.org/t/p/w500/Poster.jpg',
      'signed query':
          'https://image.tmdb.org/t/p/w500/Poster.jpg?api_key=fixture',
      'empty query': 'https://image.tmdb.org/t/p/w500/Poster.jpg?',
      'explicit HTTPS port': 'https://image.tmdb.org:443/t/p/w500/Poster.jpg',
      'alternate port': 'https://artworks.thetvdb.com:8443/banners/Poster.jpg',
      'fragment': 'https://image.tmdb.org/t/p/w500/Poster.jpg#fixture',
      'empty fragment': 'https://image.tmdb.org/t/p/w500/Poster.jpg#',
      'escaped filename': 'https://image.tmdb.org/t/p/w500/Post%65r.jpg',
      'escaped path separator': 'https://image.tmdb.org/t/p/w500%2FPoster.jpg',
      'escaped credentials':
          'https://image.tmdb.org%40fixture.invalid/t/p/w500/Poster.jpg',
      'backslash': r'https://image.tmdb.org\t\p\w500\Poster.jpg',
      'newline': 'https://image.tmdb.org/t/p/w500/Poster.jpg\n',
      'NUL control': 'https://image.tmdb.org/t/p/w500/Poster\u0000.jpg',
      'DEL control': 'https://image.tmdb.org/t/p/w500/Poster\u007f.jpg',
      'leading whitespace': ' https://image.tmdb.org/t/p/w500/Poster.jpg',
      'embedded whitespace': 'https://image.tmdb.org/t/p/w500/Poster Name.jpg',
      'TMDB host suffix spoof':
          'https://image.tmdb.org.fixture.invalid/t/p/w500/Poster.jpg',
      'TMDB host prefix spoof':
          'https://fixtureimage.tmdb.org/t/p/w500/Poster.jpg',
      'TVDB host suffix spoof':
          'https://artworks.thetvdb.com.fixture.invalid/banners/Poster.jpg',
      'userinfo host spoof':
          'https://image.tmdb.org@fixture.invalid/t/p/w500/Poster.jpg',
      'non-artwork path': 'https://image.tmdb.org/Items/123/Images/Primary',
      'executable extension': 'https://image.tmdb.org/t/p/w500/Poster.svg',
      'oversized URL':
          'https://image.tmdb.org/t/p/w500/${List.filled(240, 'a').join()}.jpg',
    };

    for (final entry in rejected.entries) {
      test('rejects ${entry.key}', () {
        expect(discordArtworkUrl(entry.value), isNull);
      });
    }
  });

  group('Discord artwork serialization', () {
    test('exports only public artwork and its selected display title', () {
      final activity = discordActivity(
        _playback,
        shareTitle: true,
        shareArtwork: true,
        artworkUrl: _poster,
        now: now,
      )!;
      expect(activity.keys.toSet(), {'type', 'details', 'state', 'assets'});
      expect(activity['assets'], {
        'large_image': _poster,
        'large_text': _playback.title,
      });
      expect(activity['details'], _playback.title);
      expect(activity['type'], 3);
    });

    test('artwork requires both title and artwork consent', () {
      for (final consent in [(false, false), (false, true), (true, false)]) {
        final activity = discordActivity(
          _playback,
          shareTitle: consent.$1,
          shareArtwork: consent.$2,
          artworkUrl: _poster,
          now: now,
        )!;
        expect(activity, isNot(contains('assets')));
        expect(jsonEncode(activity), isNot(contains(_poster)));
        if (!consent.$1) {
          expect(jsonEncode(activity), isNot(contains(_playback.title)));
        }
      }
      expect(
        discordActivity(_playback,
            shareTitle: true, artworkUrl: _poster, now: now),
        isNot(contains('assets')),
      );
    });

    test('audio playback does not export a video poster', () {
      final activity = discordActivity(
        const DiscordPlaybackSnapshot(
            active: true, title: '測試動畫原聲帶', playing: true, audio: true),
        shareTitle: true,
        shareArtwork: true,
        artworkUrl: _poster,
        now: now,
      )!;
      expect(activity['type'], 2);
      expect(activity, isNot(contains('assets')));
      expect(jsonEncode(activity), isNot(contains(_poster)));
    });

    test('invalid display titles cannot reveal the associated cover', () {
      for (final title in [
        '',
        ' \n\u0000 ',
        'https://media.example.invalid/title',
        r'C:\Synthetic\anime.mkv',
        'password=synthetic fixture',
      ]) {
        final activity = discordActivity(
          DiscordPlaybackSnapshot(active: true, title: title, playing: true),
          shareTitle: true,
          shareArtwork: true,
          artworkUrl: _poster,
          now: now,
        )!;
        expect(activity['details'], 'JMS 媒體播放');
        expect(activity, isNot(contains('assets')));
        expect(jsonEncode(activity), isNot(contains(_poster)));
      }
    });

    test('cover hover text uses the sanitized title', () {
      final activity = discordActivity(
        const DiscordPlaybackSnapshot(
            active: true, title: '測試\n動畫\u0000', playing: true),
        shareTitle: true,
        shareArtwork: true,
        artworkUrl: _poster,
        now: now,
      )!;
      expect(activity['assets'], {
        'large_image': _poster,
        'large_text': '測試 動畫',
      });
    });

    test('private or signed URLs never enter a serialized activity', () {
      for (final url in [
        'https://media.example.invalid/Items/fixture/Images/Primary',
        'https://image.tmdb.org/t/p/w500/Poster.jpg?api_key=fixture',
      ]) {
        final activity = discordActivity(
          _playback,
          shareTitle: true,
          shareArtwork: true,
          artworkUrl: url,
          now: now,
        )!;
        expect(activity['details'], _playback.title);
        expect(activity, isNot(contains('assets')));
        expect(jsonEncode(activity), isNot(contains(url)));
      }
    });
  });

  group('artwork consent withdrawal', () {
    late FakeDiscordPresenceClient client;
    late DiscordPresenceController controller;

    setUp(() {
      client = FakeDiscordPresenceClient();
      controller = DiscordPresenceController(
        client: client,
        now: () => now,
        minimumInterval: Duration.zero,
        positionInterval: Duration.zero,
      );
    });

    tearDown(() async {
      controller.dispose();
      for (final gate in [client.connectGate, client.activityGate]) {
        if (gate != null && !gate.isCompleted) gate.complete();
      }
      await _settle();
      await client.events.close();
    });

    void update({bool shareArtwork = true, bool shareTitle = true}) {
      controller.update(
        scope: 'synthetic-account',
        enabled: true,
        shareTitle: shareTitle,
        shareArtwork: shareArtwork,
        artworkUrl: _poster,
        privateMode: false,
        playback: _playback,
      );
    }

    test('revoke during handshake never publishes the withdrawn cover',
        () async {
      client.connectGate = Completer<void>();
      update();
      await _settle();
      expect(client.connections, 1);
      expect(client.activities, isEmpty);

      update(shareArtwork: false);
      await _settle();
      expect(client.activities, isEmpty);
      client.connectGate!.complete();
      await _settle();

      final published = client.activities.whereType<Map<String, Object?>>();
      expect(published, hasLength(1));
      expect(published.single['details'], _playback.title);
      expect(published.single, isNot(contains('assets')));
      expect(jsonEncode(client.activities), isNot(contains(_poster)));
    });

    test('revoke during ACK clears immediately and stale ACK cannot restore it',
        () async {
      client.activityGate = Completer<void>();
      update();
      await _settle();
      expect(client.activities.single?['assets'],
          containsPair('large_image', _poster));

      update(shareArtwork: false);
      await _settle();
      expect(client.activities, hasLength(2));
      expect(client.activities[1], isNull);

      client.activityGate!.complete();
      await _settle();
      expect(client.activities, hasLength(3));
      expect(client.activities.last?['details'], _playback.title);
      expect(client.activities.last, isNot(contains('assets')));
      expect(
        client.activities.skip(1).whereType<Map<String, Object?>>(),
        everyElement(isNot(contains('assets'))),
      );
      final count = client.activities.length;
      update(shareArtwork: false);
      await _settle();
      expect(client.activities, hasLength(count));
    });

    test('revoking title during ACK removes cover and title together',
        () async {
      client.activityGate = Completer<void>();
      update();
      await _settle();
      expect(client.activities.single?['assets'], isNotNull);

      update(shareTitle: false);
      await _settle();
      expect(client.activities.last, isNull);
      client.activityGate!.complete();
      await _settle();

      expect(client.activities[1], isNull);
      expect(client.activities.last?['details'], 'JMS 媒體播放');
      for (final activity
          in client.activities.skip(1).whereType<Map<String, Object?>>()) {
        expect(activity, isNot(contains('assets')));
        expect(jsonEncode(activity), isNot(contains(_playback.title)));
        expect(jsonEncode(activity), isNot(contains(_poster)));
      }
    });
  });
}
