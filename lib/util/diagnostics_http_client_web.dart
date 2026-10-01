// @dart=3.3

import 'dart:convert';
import 'dart:js_interop';

import 'package:http/http.dart' as http;

@JS('fetch')
external JSPromise<_FetchResponse> _fetch(JSString input, _RequestInit options);

@JS()
extension type _RequestInit._(JSObject _) implements JSObject {
  external factory _RequestInit({
    String method,
    String body,
    JSObject headers,
    String credentials,
    String redirect,
    _AbortSignal signal,
  });
}

@JS('AbortController')
extension type _AbortController._(JSObject _) implements JSObject {
  external factory _AbortController();
  external _AbortSignal get signal;
  external void abort();
}

@JS()
extension type _AbortSignal._(JSObject _) implements JSObject {}

@JS()
extension type _FetchResponse._(JSObject _) implements JSObject {
  external int get status;
}

http.Client createDiagnosticClient() => _CredentiallessBrowserClient();

/// BrowserClient uses same-origin credentials by default. Anonymous diagnostic
/// traffic explicitly omits browser cookies, including on the same origin.
class _CredentiallessBrowserClient extends http.BaseClient {
  bool _closed = false;
  final Set<_AbortController> _requests = {};

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) throw StateError('Diagnostic client closed');
    final body = await request.finalize().toBytes();
    if (_closed) throw StateError('Diagnostic client closed');
    final controller = _AbortController();
    _requests.add(controller);
    try {
      final response = await _fetch(
          request.url.toString().toJS,
          _RequestInit(
            method: request.method,
            body: utf8.decode(body),
            headers: request.headers.jsify()! as JSObject,
            credentials: 'omit',
            redirect: 'error',
            signal: controller.signal,
          )).toDart;
      return http.StreamedResponse(
          const Stream<List<int>>.empty(), response.status,
          request: request);
    } finally {
      controller.abort();
      _requests.remove(controller);
    }
  }

  @override
  void close() {
    _closed = true;
    for (final request in _requests) {
      request.abort();
    }
    _requests.clear();
  }
}
