import 'package:chopper/chopper.dart';
import 'package:fladder/models/api_result.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  test('successful typed response preserves actual body instead of Chopper Body annotation', () {
    final result = Response<Map<String, int>>(http.Response('', 201), {'id': 10}).apiResult;
    expect(result.isSuccess, isTrue);
    expect(result.data, {'id': 10});
  });

  test('empty successful response remains empty', () {
    final result = Response<String>(http.Response('', 204), null).apiResult;
    expect(result.isSuccess, isTrue);
    expect(result.data, isNull);
  });

  test('failed response is not promoted to success', () {
    final result = Response<String>(http.Response('', 403), null, error: 'denied').apiResult;
    expect(result.isSuccess, isFalse);
    expect(result.error?.statusCode, 403);
    expect(result.data, isNull);
  });

  test('future and synchronous response expose identical data', () async {
    final response = Response<int>(http.Response('', 200), 42);
    expect((await Future.value(response).apiResult).data, response.apiResult.data);
  });
}
