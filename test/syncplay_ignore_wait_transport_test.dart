import 'dart:convert';

import 'package:fladder/services/syncplay/syncplay_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'syncplay_transport_test.dart' as fixtures;

void main() {
  test('IgnoreWait wire shape rejects missing, null, numeric and extra fields',
      () {
    for (final body in <Map<String, dynamic>>[
      {},
      {'IgnoreWait': null},
      {'IgnoreWait': 1},
      {'IgnoreWait': 'true'},
      {'IgnoreWait': true, 'GroupId': 'not-allowed'}
    ]) {
      expect(() => SyncPlayRequest(SyncPlayRequestType.setIgnoreWait, body),
          throwsFormatException);
    }
  });
  for (final value in [true, false]) {
    test(
        'IgnoreWait $value uses captured-session generated API with boolean DTO',
        () async {
      final f = fixtures.Fixture();
      addTearDown(f.transport.close);
      await f.transport.connect();
      await f.transport.sendRequest(SyncPlayRequest(
          SyncPlayRequestType.setIgnoreWait, {'IgnoreWait': value}));
      expect(f.requests.single.url.path, endsWith('/SyncPlay/SetIgnoreWait'));
      expect(jsonDecode(f.requests.single.body), {'IgnoreWait': value});
      expect(f.requests.single.url.queryParameters, isNot(contains('GroupId')));
    });
  }
  for (final status in [404, 405, 501]) {
    test('IgnoreWait HTTP $status is explicitly unsupported', () async {
      final f =
          fixtures.Fixture(handler: (_) async => http.Response('', status));
      addTearDown(f.transport.close);
      await f.transport.connect();
      await expectLater(
          f.transport.sendRequest(SyncPlayRequest(
              SyncPlayRequestType.setIgnoreWait, {'IgnoreWait': true})),
          throwsA(fixtures.failure(SyncPlayFailureCode.unsupported)));
      expect(f.requests, hasLength(1));
    });
  }
  test('IgnoreWait 503 is ambiguous and 403 is denied without leaking response',
      () async {
    for (final code in [503, 403]) {
      final f = fixtures.Fixture(
          handler: (_) async => http.Response('synthetic-only', code));
      addTearDown(f.transport.close);
      await f.transport.connect();
      await expectLater(
          f.transport.sendRequest(SyncPlayRequest(
              SyncPlayRequestType.setIgnoreWait, {'IgnoreWait': true})),
          throwsA(fixtures.failure(code == 503
              ? SyncPlayFailureCode.timeoutUnknown
              : SyncPlayFailureCode.denied)));
    }
  });
}
