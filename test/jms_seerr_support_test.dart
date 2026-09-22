import 'dart:async';
import 'dart:convert';

import 'package:chopper/chopper.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fladder/providers/seerr_api_provider.dart';
import 'package:fladder/providers/seerr_service_provider.dart';
import 'package:fladder/seerr/seerr_chopper_service.dart';
import 'package:fladder/seerr/seerr_connection.dart';
import 'package:fladder/seerr/seerr_issue_models.dart';
import 'package:fladder/seerr/seerr_json_converter.dart';
import 'package:fladder/seerr/seerr_models.dart';
import 'package:fladder/util/seerr_http_client.dart';

void main() {
  late ProviderContainer container;
  late SeerrService service;
  late ChopperClient client;
  late List<http.Request> calls;
  late int permissions;
  late int remaining;
  int? quotaLimit;
  late bool restricted;
  late int issueOwner;
  late List<Map<String, dynamic>> issues;
  late List<Map<String, dynamic>> requests;
  Future<http.Response> Function(http.Request)? extra;

  http.Response json(Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});
  Map<String, dynamic> issueJson({int owner = 1}) => {
        'id': 91,
        'issueType': 3,
        'status': 1,
        'createdBy': {'id': owner},
        'media': {'id': 7, 'tmdbId': 42, 'mediaType': 'movie'},
        'comments': [
          {
            'id': 2,
            'user': {'id': owner},
            'message': 'ASS animation absent'
          }
        ],
      };

  setUp(() {
    calls = [];
    issues = [];
    requests = [];
    permissions = SeerrPermission.createIssues.bit | SeerrPermission.request.bit;
    remaining = 20;
    quotaLimit = 20;
    restricted = false;
    issueOwner = 1;
    extra = null;
    container = ProviderContainer();
    client = ChopperClient(
        baseUrl: Uri.parse('https://example.invalid'),
        converter: const SeerrJsonConverter(),
        client: MockClient((request) async {
          calls.add(request);
          final path = request.url.path;
          if (path == '/api/v1/auth/me') {
            return json({'id': 1, 'permissions': permissions, 'jellyfinUserId': 'aabbcc'});
          }
          if (path == '/api/v1/movie/42' || path == '/api/v1/tv/42') {
            return json({
              'id': 42,
              'title': 'Fixture film',
              'name': 'Fixture series',
              'mediaInfo': {
                'id': 7,
                'tmdbId': 42,
                'mediaType': path.contains('/tv/') ? 'tv' : 'movie',
                'status': 5,
                'requests': requests
              }
            });
          }
          if (path == '/api/v1/user/1/quota') {
            return json({
              'movie': {'limit': quotaLimit, 'remaining': remaining, 'restricted': restricted},
              'tv': {'limit': quotaLimit, 'remaining': remaining, 'restricted': restricted}
            });
          }
          if (path == '/api/v1/issue' && request.method == 'GET') {
            return json({
              'results': issues,
              'pageInfo': {'pages': 1}
            });
          }
          if (path == '/api/v1/issue/91' && request.method == 'GET') {
            return json(issueJson(owner: issueOwner));
          }
          if (extra != null) return extra!(request);
          if (path == '/api/v1/issue' && request.method == 'POST') {
            return json(issueJson(), 201);
          }
          if (path == '/api/v1/request') {
            return json({
              'id': 10,
              'status': 1,
              'is4k': false,
              'requestedBy': {'id': 1}
            }, 201);
          }
          return json({}, 404);
        }));
    final provider = Provider((ref) => SeerrService(ref, SeerrChopperService.create(client)));
    service = container.read(provider);
  });
  tearDown(() {
    client.dispose();
    container.dispose();
  });

  test('preserves reverse proxy base path and query, rejects arbitrary origin', () {
    expect(seerrRequestUri('https://example.invalid/seerr/', Uri.parse('/api/v1/search?query=a%20b')).toString(),
        'https://example.invalid/seerr/api/v1/search?query=a%20b');
    expect(() => seerrRequestUri('https://example.invalid', Uri.parse('https://else.invalid/api/v1/auth/me')),
        throwsA(isA<SeerrFailure>()));
    for (final value in [
      Uri(scheme: 'https', userInfo: 'user:pass', host: 'example.invalid').toString(),
      'https://example.invalid?q=secret',
      'file:///tmp'
    ]) {
      expect(() => seerrBaseUri(value), throwsA(isA<SeerrFailure>()));
    }
  });

  test('redirects disabled; transport failures do not expose URLs or credentials', () async {
    final transport = SeerrHttpClient(MockClient((request) async {
      expect(request.followRedirects, isFalse);
      throw StateError('https://private.invalid/video?secret=hidden /storage/media');
    }));
    try {
      await seerrBounded(transport.get(Uri.parse('https://example.invalid')));
      fail('must fail');
    } on SeerrFailure catch (error) {
      expect(error.toString(), 'Seerr: network_error');
    }
    transport.close();
  });

  test('redacts by rejecting secrets and paths before report submission', () {
    for (final message in [
      'https://private.invalid/a',
      'Token=hidden',
      'Cookie: hidden',
      r'C:\private\movie.mkv',
      '/storage/emulated/0/test.ass'
    ]) {
      expect(seerrSafeMessage(message), isFalse);
    }
    expect(seerrSafeMessage('Episode 3 at 00:12:34, ASS animation absent'), isTrue);
    expect(seerrTrackAttribute('/private/media'), 'unavailable');
  });

  test('issue enums and unknown statuses are not fabricated', () {
    expect(SeerrIssueType.values.map((entry) => entry.value), [1, 2, 3, 4]);
    expect(SeerrIssue.fromJson({...issueJson(), 'status': 99}).status, 99);
  });

  test('Issue uses verified internal ID, not TMDB or Jellyfin ID', () async {
    final target = await service.issueTarget(42, false);
    await service.reportIssue(target, SeerrIssueType.subtitles, 'ASS animation absent');
    final sent = calls.singleWhere((request) => request.method == 'POST');
    expect(jsonDecode(sent.body)['mediaId'], 7);
    expect(jsonDecode(sent.body)['issueType'], 3);
    expect(jsonDecode(sent.body).containsKey('userId'), isFalse);
  });

  test('wrong or missing internal media mapping never sends POST', () async {
    expect(
        () => SeerrIssueTarget.verified(tmdbId: 42, isTv: false, title: '', media: SeerrMediaInfo(id: 7, tmdbId: 99)),
        throwsA(isA<SeerrFailure>()));
    final wrong = SeerrIssueTarget.verified(
        tmdbId: 42, isTv: false, title: '', media: SeerrMediaInfo(id: 99, tmdbId: 42, mediaType: 'movie'));
    await expectLater(service.reportIssue(wrong, SeerrIssueType.video, 'Video problem'), throwsA(isA<SeerrFailure>()));
    expect(calls.where((request) => request.method == 'POST'), isEmpty);
  });

  test('API doc mismatch: Issue uses createdBy, never Request requestedBy', () async {
    await service.issues(skip: 20);
    final request = calls.last;
    expect(request.url.queryParameters, containsPair('createdBy', '1'));
    expect(request.url.queryParameters, containsPair('skip', '20'));
    expect(request.url.queryParameters.containsKey('requestedBy'), isFalse);
    issues = [issueJson(owner: 2)];
    await expectLater(
        service.issues(), throwsA(predicate((error) => error is SeerrFailure && error.code == 'incompatible_filter')));
  });

  test('ordinary user cannot manage status or another user reports', () async {
    await expectLater(service.changeIssueStatus(91, true), throwsA(isA<SeerrFailure>()));
    await expectLater(service.issues(management: true), throwsA(isA<SeerrFailure>()));
    permissions = SeerrPermission.requestAdvanced.bit;
    expect(SeerrUserModel(permissions: permissions).canManageRequests, isFalse);
    final target = await service.issueTarget(42, false);
    await expectLater(service.reportIssue(target, SeerrIssueType.video, 'Problem'), throwsA(isA<SeerrFailure>()));
    expect(calls.where((request) => request.method == 'POST'), isEmpty);
  });

  test('comment and manager status use real routes and read server status', () async {
    extra = (request) async => json({...issueJson(), 'status': request.url.path.endsWith('/resolved') ? 2 : 1});
    await service.addIssueComment(91, 'Additional observation');
    expect(calls.last.url.path, '/api/v1/issue/91/comment');
    permissions = SeerrPermission.manageIssues.bit;
    expect((await service.changeIssueStatus(91, true)).status, 2);
    expect(calls.last.url.path, '/api/v1/issue/91/resolved');
  });

  test('ordinary movie and selected TV seasons use server defaults', () async {
    await service.requestMovie(tmdbId: 42);
    expect(jsonDecode(calls.last.body)['mediaId'], 42);
    expect(jsonDecode(calls.last.body)['serverId'], isNull);
    await service.requestSeries(tmdbId: 42, seasons: [0, 2]);
    expect(jsonDecode(calls.last.body)['seasons'], [0, 2]);
    await expectLater(service.requestSeries(tmdbId: 42, seasons: []), throwsA(isA<SeerrFailure>()));
  });

  test('quota, admin parameters and 4K permission reject before POST', () async {
    remaining = 0;
    await expectLater(service.requestMovie(tmdbId: 42), throwsA(isA<SeerrFailure>()));
    remaining = 20;
    restricted = true;
    await expectLater(service.requestMovie(tmdbId: 42), throwsA(isA<SeerrFailure>()));
    restricted = false;
    await expectLater(service.requestMovie(tmdbId: 42, serverId: 1), throwsA(isA<SeerrFailure>()));
    await expectLater(service.requestMovie(tmdbId: 42, is4k: true), throwsA(isA<SeerrFailure>()));
    expect(calls.where((request) => request.method == 'POST'), isEmpty);
  });

  test('existing request reconciled before a side-effecting POST', () async {
    requests = [
      {
        'id': 10,
        'status': 2,
        'is4k': false,
        'requestedBy': {'id': 1}
      }
    ];
    expect((await service.requestMovie(tmdbId: 42)).body?.id, 10);
    expect(calls.where((request) => request.method == 'POST'), isEmpty);
  });

  test('completed double click does not send a second POST', () async {
    await service.requestMovie(tmdbId: 42);
    await service.requestMovie(tmdbId: 42);
    expect(calls.where((request) => request.method == 'POST').length, 1);
  });

  test('unlimited quota is not treated as exhausted', () async {
    quotaLimit = null;
    remaining = 0;
    restricted = false;
    await service.requestMovie(tmdbId: 42);
    expect(calls.where((request) => request.method == 'POST').length, 1);
  });

  test('ordinary account cannot comment on another account issue', () async {
    issueOwner = 2;
    await expectLater(service.addIssueComment(91, 'Observation'), throwsA(isA<SeerrFailure>()));
    expect(calls.where((request) => request.method == 'POST'), isEmpty);
  });

  test('in-flight duplicate POST is rejected without a second write', () async {
    final started = Completer<void>();
    final response = Completer<http.Response>();
    extra = (request) async {
      started.complete();
      return response.future;
    };
    final pending = service.requestMovie(tmdbId: 42);
    await started.future;
    await expectLater(service.requestMovie(tmdbId: 42),
        throwsA(predicate((error) => error is SeerrFailure && error.code == 'already_sending')));
    response.complete(json({'id': 10}));
    await pending;
    expect(calls.where((request) => request.method == 'POST').length, 1);
  });

  test('uncertain submission checks history but never blindly retries POST', () async {
    extra = (request) async => throw const SeerrFailure('timeout_check_history');
    await expectLater(service.requestMovie(tmdbId: 42), throwsA(isA<SeerrFailure>()));
    await expectLater(service.requestMovie(tmdbId: 42), throwsA(isA<SeerrFailure>()));
    expect(calls.where((request) => request.method == 'POST').length, 1);
    requests = [
      {
        'id': 10,
        'status': 1,
        'requestedBy': {'id': 1}
      }
    ];
    expect((await service.requestMovie(tmdbId: 42)).body?.id, 10);
    expect(calls.where((request) => request.method == 'POST').length, 1);
  });

  test('session expiry callback clears only the bound Seerr session', () async {
    var expirations = 0;
    var active = true;
    final bound = ChopperClient(
        client: MockClient((request) async => json({}, 401)),
        converter: const SeerrJsonConverter(),
        interceptors: [
          SeerrRequest('https://example.invalid', {}, {}, () => active, onUnauthorized: () => expirations++)
        ]);
    final api = SeerrChopperService.create(bound);
    await expectLater(
        api.getMe(), throwsA(predicate((error) => error is SeerrFailure && error.code == 'session_expired')));
    expect(expirations, 1);
    active = false;
    await expectLater(api.getMe(), throwsA(isA<SeerrFailure>()));
    expect(expirations, 1);
    bound.dispose();
  });

  test('401/403/404 and rate errors remain distinct', () {
    final codes = <int, String>{
      401: 'session_expired',
      403: 'request_rejected_unknown',
      404: 'unsupported_or_missing',
      429: 'quota_or_rate_limit'
    };
    for (final entry in codes.entries) {
      expect(() => seerrCheckStatus(entry.key),
          throwsA(predicate((error) => error is SeerrFailure && error.code == entry.value)));
    }
  });

  test('link capability requires initialized Jellyfin JSON and explicit policy', () async {
    extra = (request) async => json(request.url.path.endsWith('/status')
        ? {'version': '3.4.1'}
        : {'initialized': true, 'mediaServerType': 2, 'mediaServerLogin': true});
    expect((await service.linkCapabilities())['quickConnect'], isTrue);
    extra = (request) async => json({'initialized': true, 'mediaServerType': 1, 'mediaServerLogin': true});
    await expectLater(service.linkCapabilities(), throwsA(isA<SeerrFailure>()));
    extra = (request) async => http.Response('<html>Login</html>', 200);
    await expectLater(service.linkCapabilities(), throwsA(isA<SeerrFailure>()));
    expect(calls.where((request) => request.method == 'POST'), isEmpty);
  });

  test('legacy version is not assumed to support Quick Connect', () async {
    extra = (request) async => json(request.url.path.endsWith('/status')
        ? {'version': '2.7.3'}
        : {'initialized': true, 'mediaServerType': 2, 'mediaServerLogin': true});
    expect((await service.linkCapabilities())['quickConnect'], isFalse);
  });

  test('password linkage sends only credentials, verifies stable user ID and me', () async {
    extra = (request) async {
      expect(request.url.path, '/api/v1/auth/jellyfin');
      expect(jsonDecode(request.body), {'username': 'fixture', 'password': 'TEST_ONLY'});
      return http.Response(jsonEncode({'id': 1, 'jellyfinUserId': 'aabbcc'}), 200, headers: {
        'content-type': 'application/json',
        'set-cookie': 'csrf=ignored; Path=/, connect.sid=TEST_ONLY; HttpOnly; Secure'
      });
    };
    expect(await service.linkPassword('fixture', 'TEST_ONLY', 'aa-bb-cc'), 'connect.sid=TEST_ONLY');
    expect(calls.last.url.path, '/api/v1/auth/me');
    expect(calls.last.headers['Cookie'] ?? calls.last.headers['cookie'], 'connect.sid=TEST_ONLY');
    await expectLater(service.checkLinkedCookie('connect.sid=TEST_ONLY', 'another-user'),
        throwsA(predicate((error) => error is SeerrFailure && error.code == 'identity_mismatch')));
  });

  test('Quick Connect validates only challenge returned by this service flow', () async {
    extra = (request) async {
      if (request.url.path.endsWith('/initiate')) {
        return json({'code': '123456', 'secret': 'TEST_ONLY_0000000000000000'});
      }
      return json({'code': 'https://untrusted.invalid', 'secret': 'bad'});
    };
    await expectLater(service.startQuickLink(), throwsA(isA<SeerrFailure>()));
    extra = (request) async => json({'code': '123456', 'secret': 'aabbccddeeff00112233'});
    expect((await service.startQuickLink())['code'], '123456');
    extra = (request) async => json({'authenticated': true});
    expect(await service.checkQuickLink('aabbccddeeff00112233'), isTrue);
  });

  test('bound client ignores stale responses and never sends credentials to login', () async {
    bool active = true;
    final completion = Completer<http.Response>();
    final transport = MockClient((request) async {
      expect(request.url.path, '/prefix/api/v1/auth/local');
      expect(request.headers.containsKey('cookie'), isFalse);
      expect(request.headers.containsKey('Cookie'), isFalse);
      return completion.future;
    });
    final bound = ChopperClient(client: transport, converter: const SeerrJsonConverter(), interceptors: [
      SeerrRequest('https://example.invalid/prefix', {'Cookie': 'TEST_ONLY'}, {}, () => active)
    ]);
    final api = SeerrChopperService.create(bound);
    final pending = api.authenticateLocal(SeerrAuthLocalBody(email: 'test@example.invalid', password: 'TEST_ONLY'));
    await Future<void>.delayed(Duration.zero);
    active = false;
    completion.complete(json({'id': 1}));
    await expectLater(pending, throwsA(predicate((error) => error is SeerrFailure && error.code == 'account_changed')));
    bound.dispose();
  });
}
