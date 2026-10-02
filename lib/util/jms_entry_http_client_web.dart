// @dart=3.3
import 'dart:async';
import 'dart:js_interop';

import 'package:http/http.dart' as http;

@JS('fetch')
external JSPromise<_Response> _fetch(JSString url, _Options options);

@JS('AbortController')
extension type _Controller._(JSObject _) implements JSObject {
  external _Controller();
  external JSObject get signal;
  external void abort();
}

extension type _Options._(JSObject _) implements JSObject {
  external factory _Options({
    required String method,
    required String credentials,
    required String redirect,
    required JSObject signal,
    required JSObject headers,
  });
}

extension type _Response._(JSObject _) implements JSObject {
  external int get status;
  external _Headers get headers;
  external _ReadableStream? get body;
}

extension type _Headers._(JSObject _) implements JSObject {
  external JSString? get(JSString name);
}

extension type _ReadableStream._(JSObject _) implements JSObject {
  external _Reader getReader();
}

extension type _Reader._(JSObject _) implements JSObject {
  external JSPromise<_ReadResult> read();
  external JSPromise<JSAny?> cancel();
}

extension type _ReadResult._(JSObject _) implements JSObject {
  external bool get done;
  external JSUint8Array? get value;
}

http.Client createEntryClient({int maxResponseBytes = 65536}) =>
    _EntryBrowserClient(maxResponseBytes);

final class _EntryBrowserClient extends http.BaseClient {
  _EntryBrowserClient(this._maxResponseBytes);

  final int _maxResponseBytes;
  final Set<_Controller> _controllers = {};
  bool _closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed || request.method != 'GET') {
      throw http.ClientException('entry_request_unavailable');
    }
    request.finalize();
    final controller = _Controller();
    _controllers.add(controller);
    var active = true;
    if (request case http.Abortable(:final abortTrigger?)) {
      unawaited(abortTrigger.then((_) {
        if (active) {
          active = false;
          controller.abort();
          _controllers.remove(controller);
        }
      }));
    }
    try {
      final response = await _fetch(
          request.url.toString().toJS,
          _Options(
            method: 'GET',
            credentials: 'omit',
            redirect: 'error',
            signal: controller.signal,
            headers: {'accept': 'application/json'}.jsify()! as JSObject,
          )).toDart;
      final headers = <String, String>{};
      for (final name in ['content-type', 'content-length']) {
        final value = response.headers.get(name.toJS)?.toDart;
        if (value != null) headers[name] = value;
      }
      Stream<List<int>> readBody() async* {
        final reader = response.body?.getReader();
        var size = 0;
        try {
          if (reader == null) return;
          while (true) {
            final part = await reader.read().toDart;
            if (part.done) break;
            final bytes = part.value?.toDart;
            if (bytes == null) continue;
            size += bytes.length;
            if (size > _maxResponseBytes) {
              throw http.ClientException('entry_response_too_large');
            }
            yield bytes;
          }
        } finally {
          active = false;
          controller.abort();
          _controllers.remove(controller);
          try {
            await reader?.cancel().toDart;
          } catch (_) {}
        }
      }

      return http.StreamedResponse(readBody(), response.status,
          headers: headers, request: request);
    } catch (_) {
      active = false;
      controller.abort();
      _controllers.remove(controller);
      // Browsers intentionally do not distinguish network, TLS or redirect fetch
      // failures. Never expose a raw exception containing a private address.
      throw http.ClientException('entry_network_failure');
    }
  }

  @override
  void close() {
    _closed = true;
    for (final controller in _controllers.toList()) {
      controller.abort();
    }
    _controllers.clear();
  }
}
