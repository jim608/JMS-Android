// @dart=3.3
@TestOn('browser')
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:fladder/util/app_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

@JS('globalThis.fetch')
external JSFunction get browserFetch;

@JS('globalThis.fetch')
external set browserFetch(JSFunction value);

void main() {
  test(
      'Web diagnostic Fetch explicitly omits credentials and rejects redirects',
      () async {
    final original = browserFetch;
    final requests = <Map<String, Object?>>[];
    browserFetch = ((JSString input, JSObject options) {
      requests.add({
        'url': input.toDart,
        'credentials': options.getProperty<JSString>('credentials'.toJS).toDart,
        'redirect': options.getProperty<JSString>('redirect'.toJS).toDart,
        'body': jsonDecode(options.getProperty<JSString>('body'.toJS).toDart),
      });
      return Future<JSObject>.value({'status': 202}.jsify()! as JSObject).toJS;
    }).toJS;
    final reporter = AppDiagnostics(
      endpoint:
          Uri.parse('https://diagnostics.example.org/api/jms/diagnostics/v1'),
      platform: 'web',
      version: '0.11.1-jms.25',
      buildId: 'JMS-0.11.1-jms.25-web-123456abcdef',
    );
    try {
      expect(await reporter.runtimeError(DiagnosticCategory.flutterFramework),
          false);
      expect(requests, isEmpty);
      reporter.enabled = true;
      expect(await reporter.runtimeError(DiagnosticCategory.flutterFramework),
          true);
      expect(requests.single['credentials'], 'omit');
      expect(requests.single['redirect'], 'error');
      expect((requests.single['body'] as Map)['category'], 'flutter_framework');
    } finally {
      reporter.dispose();
      browserFetch = original;
    }
  });
}
