import 'dart:convert';
import 'package:chopper/chopper.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/credentials_model.dart';
import 'package:fladder/models/seerr_credentials_model.dart';
import 'package:fladder/providers/seerr_api_provider.dart';
import 'package:fladder/providers/seerr_service_provider.dart';
import 'package:fladder/providers/seerr_link_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/seerr/seerr_chopper_service.dart';
import 'package:fladder/seerr/seerr_json_converter.dart';
import 'package:fladder/seerr/seerr_session_store.dart';

AccountModel seerrFixtureAccount({String id = 'aabbcc', bool bound = true}) => AccountModel(
      name: '測試使用者',
      id: id,
      avatar: '',
      lastUsed: DateTime(2026),
      credentials: CredentialsModel.internal(serverId: 'fixture-server', url: 'https://example.invalid/jellyfin'),
      seerrCredentials: SeerrCredentialsModel(serverUrl: jmsSeerrSource, linkedServerId: bound ? 'fixture-server' : ''),
    );

class SeerrFixtureUser extends User {
  SeerrFixtureUser(this.account);
  final AccountModel account;
  @override
  AccountModel? build() => account;
  @override
  set userState(AccountModel? value) => state = value;
}

class SeerrFixtureStore extends SeerrSessionStore {
  final values = <String, String>{};
  @override
  Future<String?> read(AccountModel account) async => values[SeerrSessionStore.key(account)];
  @override
  Future<void> write(AccountModel account, String? cookie) async {
    if (cookie?.isNotEmpty == true) {
      values[SeerrSessionStore.key(account)] = cookie!;
    } else {
      values.remove(SeerrSessionStore.key(account));
    }
  }
}

class SeerrFixture {
  final calls = <http.Request>[];
  final clients = <ChopperClient>[];
  final store = SeerrFixtureStore();
  String userId = 'aabbcc';
  String version = '2.7.3';
  int authStatus = 200;
  int statusStatus = 200;
  int issueStatus = 200;
  String advertisedJellyfin = '';
  Future<void> Function()? beforeLogin;
  bool requested = false;
  bool reported = false;
  int issueType = 3;
  String issueMessage = '第 3 集 00:12:34 字幕動畫未顯示（合成測試）';

  Map<String, dynamic> get user =>
      {'id': 1, 'displayName': '測試使用者', 'jellyfinUserId': userId, 'permissions': 4194304 | 32};
  Map<String, dynamic> get media => {'id': 7, 'tmdbId': 42, 'mediaType': 'movie', 'status': 3};
  Map<String, dynamic> get request => {'id': 10, 'media': media, 'status': 2, 'requestedBy': user, 'is4k': false};
  Map<String, dynamic> get issue => {
        'id': 91,
        'issueType': issueType,
        'status': 1,
        'media': media,
        'createdBy': user,
        'createdAt': '2026-09-23T01:00:00Z',
        'updatedAt': '2026-09-23T02:00:00Z',
        'comments': [
          {'id': 1, 'user': user, 'message': issueMessage, 'createdAt': '2026-09-23T01:00:00Z'}
        ]
      };

  http.Response json(Object data, {int status = 200, bool cookie = false}) =>
      http.Response(jsonEncode(data), status, headers: {
        'content-type': 'application/json',
        if (cookie) 'set-cookie': 'connect.sid=TEST_ONLY; HttpOnly; Secure'
      });

  Future<http.Response> handle(http.Request call) async {
    calls.add(call);
    final path = call.url.path;
    if (path == '/api/v1/auth/me') {
      return json(authStatus == 403
          ? {'status': 403, 'error': 'You do not have permission to access this endpoint'}
          : user, status: authStatus);
    }
    if (path == '/api/v1/status') return json({'version': version}, status: statusStatus);
    if (path == '/api/v1/settings/public') {
      return json({
        'initialized': true,
        'mediaServerType': 2,
        'mediaServerLogin': true,
        'jellyfinExternalHost': advertisedJellyfin
      });
    }
    if (path == '/api/v1/auth/jellyfin') {
      await beforeLogin?.call();
      return json(authStatus == 403 ? {'status': 403, 'message': 'Access denied.'} : user,
          status: authStatus, cookie: authStatus == 200);
    }
    if (path.endsWith('/quickconnect/initiate')) return json({'code': '123456', 'secret': 'aabbccddeeff00112233'});
    if (path.endsWith('/quickconnect/check')) return json({'authenticated': true});
    if (path.endsWith('/quickconnect/authenticate')) return json(user, cookie: true);
    if (path == '/api/v1/issue' && call.method == 'POST') {
      reported = true;
      final body = jsonDecode(call.body) as Map<String, dynamic>;
      issueType = body['issueType'] as int;
      issueMessage = body['message'] as String;
      return json(issue, status: 201);
    }
    if (path == '/api/v1/issue') {
      if (issueStatus == 403) {
        return json({'status': 403, 'error': 'You do not have permission to access this endpoint'}, status: 403);
      }
      return json({
        'results': reported ? [issue] : [],
        'pageInfo': {'pages': 1, 'results': reported ? 1 : 0}
      });
    }
    if (path.startsWith('/api/v1/issue/91')) return json(issue);
    if (path == '/api/v1/request' && call.method == 'POST') {
      requested = true;
      return json(request, status: 201);
    }
    if (path == '/api/v1/user/1/requests' || path == '/api/v1/request') {
      return json({
        'results': requested ? [request] : [],
        'pageInfo': {'pages': 1}
      });
    }
    if (path == '/api/v1/user/1/quota') {
      return json({
        'movie': {'remaining': 5, 'restricted': false, 'limit': 5, 'days': 7},
        'tv': {'remaining': 5, 'restricted': false, 'limit': 5, 'days': 7}
      });
    }
    if (path == '/api/v1/movie/42' || path == '/api/v1/tv/42') {
      return json({
        'id': 42,
        'title': '測試影片',
        'name': '測試影集',
        'overview': '這是隔離測試的合成媒體，沒有送出正式點片。',
        'mediaInfo': {
          ...media,
          'mediaType': path.contains('/tv/') ? 'tv' : 'movie',
          'requests': requested ? [request] : []
        },
        'seasons': [
          {'seasonNumber': 1, 'episodeCount': 12},
          {'seasonNumber': 2, 'episodeCount': 8}
        ]
      });
    }
    if (path == '/api/v1/search') {
      return json({
        'page': 1,
        'totalPages': 1,
        'totalResults': 1,
        'results': [
          {'id': 42, 'mediaType': 'movie', 'title': '測試影片', 'overview': '隔離測試資料', 'mediaInfo': media}
        ]
      });
    }
    if (path.endsWith('/watchproviders/regions') || path.endsWith('/regions')) return json([]);
    if (path.contains('/ratings')) return json({});
    if (path.contains('/recommendations') || path.contains('/similar')) return json({'results': []});
    return json({}, status: 404);
  }

  List<Override> overrides({AccountModel? account}) => [
        userProvider.overrideWith(() => SeerrFixtureUser(account ?? seerrFixtureAccount())),
        seerrSessionStoreProvider.overrideWithValue(store),
        seerrApiProvider.overrideWith(() => _FixtureApi(this)),
      ];

  void dispose() {
    for (final client in clients) {
      client.dispose();
    }
  }
}

class _FixtureApi extends SeerrApi {
  _FixtureApi(this.fixture);
  final SeerrFixture fixture;
  @override
  SeerrService build() {
    final account = ref.watch(userProvider.select((value) => value?.seerrCredentials));
    var active = true;
    ref.onDispose(() => active = false);
    final client =
        ChopperClient(client: MockClient(fixture.handle), converter: const SeerrJsonConverter(), interceptors: [
      SeerrRequest(jmsSeerrSource, {if (account?.sessionCookie.isNotEmpty == true) 'Cookie': account!.sessionCookie},
          {}, () => active, expectedJellyfinUserId: ref.read(userProvider)?.id,
          onDiagnostic: (diagnostic) {
            if (active) ref.read(seerrDiagnosticProvider.notifier).state = diagnostic;
          })
    ]);
    fixture.clients.add(client);
    return SeerrService(ref, SeerrChopperService.create(client));
  }
}
