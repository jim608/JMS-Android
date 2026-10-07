// @dart=3.3
@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:fladder/util/seerr_http_client.dart'
    if (dart.library.html) 'package:fladder/util/seerr_http_client_web.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

@JS('globalThis.fetch')
external JSFunction get browserFetch;

@JS('globalThis.fetch')
external set browserFetch(JSFunction value);

@JS('Response')
extension type _FetchResponse._(JSObject _) implements JSObject {
  external _FetchResponse(JSString body, JSObject options);
}

void main() {
  late JSFunction originalFetch;
  late List<Map<String, Object?>> requests;
  late List<http.Client> clients;

  setUp(() {
    originalFetch = browserFetch;
    requests = [];
    clients = [];
    browserFetch = ((JSString input, JSObject options) {
      final headers = options.getProperty<JSObject>('headers'.toJS);
      requests.add({
        'url': input.toDart,
        'method': options.getProperty<JSString>('method'.toJS).toDart,
        'credentials': options.getProperty<JSString>('credentials'.toJS).toDart,
        'headers': Map<String, Object?>.from(headers.dartify()! as Map),
      });
      return Future<JSObject>.value(_FetchResponse(
        '{}'.toJS,
        {
          'status': 200,
          'headers': {'content-type': 'application/json'},
        }.jsify()! as JSObject,
      )).toJS;
    }).toJS;
  });

  tearDown(() {
    for (final client in clients) {
      client.close();
    }
    browserFetch = originalFetch;
  });

  test(
      'Jellyfin keeps explicit account headers without cross-origin cookies '
      'while Seerr retains cookie credentials', () async {
    final jellyfin = createJellyfinHttpClient();
    final seerr = createSeerrHttpClient();
    clients.addAll([jellyfin, seerr]);
    const authorization =
        'MediaBrowser Token="synthetic-account-token", Client="Fixture"';

    final jellyfinResponse = await jellyfin.get(
      Uri.parse('https://media.example.invalid/System/Info/Public'),
      headers: {'authorization': authorization},
    );
    final seerrResponse = await seerr.post(
      Uri.parse('https://requests.example.invalid/api/v1/auth/jellyfin'),
      headers: {'content-type': 'application/json'},
      body: '{}',
    );

    expect(jellyfinResponse.statusCode, 200);
    expect(jellyfinResponse.body, '{}');
    expect(seerrResponse.statusCode, 200);
    expect(seerrResponse.body, '{}');
    expect(requests, hasLength(2));
    expect(requests[0]['credentials'], 'same-origin');
    expect(requests[0]['method'], 'GET');
    expect((requests[0]['headers'] as Map)['authorization'], authorization);
    expect(requests[1]['credentials'], 'include');
    expect(requests[1]['method'], 'POST');
    expect(
        (requests[1]['headers'] as Map).containsKey('authorization'), isFalse);
  });

  test('closing either transport prevents requests only from that client',
      () async {
    final jellyfin = createJellyfinHttpClient();
    final seerr = createSeerrHttpClient();
    clients.addAll([jellyfin, seerr]);
    final target = Uri.parse('https://fixture.example.invalid/status');

    jellyfin.close();
    await expectLater(
        jellyfin.get(target), throwsA(isA<http.ClientException>()));
    expect(requests, isEmpty);

    expect((await seerr.get(target)).statusCode, 200);
    expect(requests, hasLength(1));
    expect(requests.single['credentials'], 'include');

    seerr.close();
    await expectLater(seerr.get(target), throwsA(isA<http.ClientException>()));
    expect(requests, hasLength(1));
  });
}
