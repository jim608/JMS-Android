import 'dart:async';
import 'dart:convert';

import 'package:fladder/services/jms_entry_cache.dart';
import 'package:fladder/services/jms_entry_discovery.dart';
import 'package:fladder/util/jms_service_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

String configBody([String host = 'media.example.invalid']) =>
    jsonEncode({'baseUrl': 'https://$host'});
String infoBody() => jsonEncode({
      'ProductName': 'Jellyfin Server',
      'Version': '10.11.0',
      'Id': 'fixture-server-id',
    });

final class _StreamClient extends http.BaseClient {
  _StreamClient(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  bool wasClosed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
  @override
  void close() => wasClosed = true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('HTTPS config keeps subpath and requests have no authentication',
      () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return http.Response(configBody(), 200);
    });
    final discovery = JmsEntryDiscovery(client: client);
    final result = await discovery.discover('entry.example.invalid/sub/app');
    expect(result.kind, JmsEntryResolutionKind.configured);
    expect(result.config?.baseUrl, 'https://media.example.invalid');
    expect(result.entry.toString(), 'https://entry.example.invalid/sub/app/');
    expect(requests.single.url.toString(),
        'https://entry.example.invalid/sub/app/jms-config.json');
    expect(requests.single.headers.keys.toSet(), {'accept'});
    expect(requests.single.body, isEmpty);
    expect(requests.single.followRedirects, isFalse);
    expect(requests.single.maxRedirects, 0);
    discovery.close();
  });

  for (final configResponse in [
    http.Response('fixture not found', 404),
    http.Response('<html>fixture app</html>', 200,
        headers: {'content-type': 'text/html'}),
    http.Response('<!DOCTYPE html><html>fixture</html>', 200),
  ]) {
    test('HTML or 404 requires a real public Jellyfin response', () async {
      final paths = <String>[];
      final discovery = JmsEntryDiscovery(client: MockClient((request) async {
        paths.add(request.url.path);
        return paths.length == 1
            ? configResponse
            : http.Response(infoBody(), 200);
      }));
      final result =
          await discovery.discover('https://entry.example.invalid/jf');
      expect(result.kind, JmsEntryResolutionKind.direct);
      expect(result.entry, isNull);
      expect(result.serverId, 'fixture-server-id');
      expect(result.config?.baseUrl, 'https://entry.example.invalid/jf');
      expect(paths, ['/jf/jms-config.json', '/jf/System/Info/Public']);
    });
  }

  test('arbitrary HTML or JSON never becomes a direct Jellyfin server',
      () async {
    for (final body in [
      '<html>fixture</html>',
      '{}',
      jsonEncode({'ProductName': 'fixture-other', 'Version': '1', 'Id': 'x'}),
      jsonEncode({'ProductName': 'Jellyfin Server', 'Version': '1'}),
    ]) {
      final discovery = JmsEntryDiscovery(
          client: MockClient((request) async => http.Response(
              request.url.path.endsWith('jms-config.json') ? '' : body,
              request.url.path.endsWith('jms-config.json') ? 404 : 200)));
      final result = await discovery.discover('entry.example.invalid');
      expect(result.kind, JmsEntryResolutionKind.error);
      expect(result.error, JmsEntryError.notJellyfin);
    }
  });

  test('forceDirect and explicit HTTP only probe public Jellyfin information',
      () async {
    for (final entry in [
      'https://entry.example.invalid/jf',
      'http://lan.example.invalid:8096/jf',
    ]) {
      final paths = <String>[];
      final discovery = JmsEntryDiscovery(client: MockClient((request) async {
        paths.add(request.url.path);
        return http.Response(infoBody(), 200);
      }));
      final result = await discovery.discover(entry, forceDirect: true);
      expect(result.kind, JmsEntryResolutionKind.direct);
      expect(result.entry, isNull);
      expect(result.config?.baseUrl, entry);
      expect(paths, ['/jf/System/Info/Public']);
    }
  });

  test('HTTP is never used for website config discovery', () async {
    final paths = <String>[];
    final discovery = JmsEntryDiscovery(client: MockClient((request) async {
      paths.add(request.url.path);
      return http.Response(infoBody(), 200);
    }));
    expect((await discovery.discover('http://lan.example.invalid/jf')).kind,
        JmsEntryResolutionKind.direct);
    expect(paths, ['/jf/System/Info/Public']);
  });

  test('invalid input fails without sending a request or exposing the input',
      () async {
    var count = 0;
    final discovery = JmsEntryDiscovery(client: MockClient((request) async {
      count++;
      return http.Response(configBody(), 200);
    }));
    for (final entry in [
      '',
      'ftp://entry.example.invalid',
      Uri(
              scheme: 'https',
              host: 'entry.example.invalid',
              userInfo: 'fixture-user:fixture-value')
          .toString(),
      'https://entry.example.invalid?fixture=1',
      'https://entry.example.invalid#fixture',
    ]) {
      final result = await discovery.discover(entry);
      expect(result.error?.code, 'invalidEntry');
      expect(result.entry, isNull);
    }
    expect(count, 0);
  });

  test('redirects including same-origin ones are not followed', () async {
    for (final status in [301, 302, 307, 308]) {
      var count = 0;
      final discovery = JmsEntryDiscovery(client: MockClient((request) async {
        count++;
        return http.Response('', status,
            headers: {'location': 'https://entry.example.invalid/next'});
      }));
      final result = await discovery.discover('entry.example.invalid');
      expect(result.error, JmsEntryError.redirect);
      expect(count, 1);
    }
  });

  test('classifies invalid JSON separately from invalid config', () async {
    final inputs = {
      '{fixture': JmsEntryError.invalidJson,
      '[]': JmsEntryError.invalidConfig,
      '{}': JmsEntryError.invalidConfig,
      '{"baseUrl":42}': JmsEntryError.invalidConfig,
      '{"baseUrl":"http://media.example.invalid"}': JmsEntryError.invalidConfig,
    };
    for (final input in inputs.entries) {
      final discovery = JmsEntryDiscovery(
          client: MockClient((request) async => http.Response(input.key, 200)));
      expect((await discovery.discover('entry.example.invalid')).error,
          input.value);
    }
  });

  test('timeout includes streamed body and cancels the owned request',
      () async {
    var aborted = false;
    var cancelled = false;
    final body = StreamController<List<int>>(onCancel: () => cancelled = true);
    final client = _StreamClient((request) async {
      (request as http.Abortable).abortTrigger!.then((_) => aborted = true);
      return http.StreamedResponse(body.stream, 200);
    });
    final discovery = JmsEntryDiscovery(
        client: client, timeout: const Duration(milliseconds: 20));
    final result = await discovery.discover('entry.example.invalid');
    await Future<void>.delayed(Duration.zero);
    expect(result.error, JmsEntryError.timeout);
    expect(aborted, isTrue);
    expect(cancelled, isTrue);
    discovery.close();
    expect(client.wasClosed, isFalse);
    await body.close();
  });

  test('response limit covers declared size and streaming without length',
      () async {
    for (final declared in [true, false]) {
      var cancelled = false;
      final stream =
          StreamController<List<int>>(onCancel: () => cancelled = true);
      final client = _StreamClient((request) async {
        scheduleMicrotask(() {
          if (!stream.isClosed) stream.add(List.filled(33, 65));
        });
        return http.StreamedResponse(stream.stream, 200,
            contentLength: declared ? 33 : null);
      });
      final discovery = JmsEntryDiscovery(client: client, maxResponseBytes: 32);
      expect((await discovery.discover('entry.example.invalid')).error,
          JmsEntryError.responseTooLarge);
      await Future<void>.delayed(Duration.zero);
      expect(cancelled, isTrue);
      await stream.close();
    }
  });

  test(
      'valid cache fallback keeps fault and never writes a newly received config',
      () async {
    final preferences = await SharedPreferences.getInstance();
    final cache = JmsEntryCache(preferences);
    final entry = JmsEntryDiscovery.normalizeEntry('entry.example.invalid');
    final old = JmsServiceConfig(baseUrl: 'https://old.example.invalid');
    await cache.write(entry, old);
    for (final client in [
      MockClient(
          (request) async => throw http.ClientException('fixture offline')),
      MockClient((request) async => http.Response('', 503)),
      MockClient((request) async => throw TimeoutException('fixture')),
    ]) {
      final result = await JmsEntryDiscovery(client: client, cache: cache)
          .discover(entry.toString());
      expect(result.kind, JmsEntryResolutionKind.cached);
      expect(result.config, old);
      expect(result.error, isNotNull);
    }
    final fresh = await JmsEntryDiscovery(
            client: MockClient((request) async =>
                http.Response(configBody('new.example.invalid'), 200)),
            cache: cache)
        .discover(entry.toString());
    expect(fresh.kind, JmsEntryResolutionKind.configured);
    expect(fresh.config?.baseUrl, 'https://new.example.invalid');
    expect(await cache.read(entry), old);
  });

  test('TLS, unknown browser failures and invalid content cannot use cache',
      () async {
    final preferences = await SharedPreferences.getInstance();
    final cache = JmsEntryCache(preferences);
    final entry = JmsEntryDiscovery.normalizeEntry('entry.example.invalid');
    await cache.write(
        entry, JmsServiceConfig(baseUrl: 'https://old.example.invalid'));
    final clients = {
      MockClient((request) async =>
              throw http.ClientException('CERTIFICATE_VERIFY_FAILED')):
          JmsEntryError.tls,
      MockClient((request) async =>
              throw http.ClientException('entry_network_failure')):
          JmsEntryError.network,
      MockClient((request) async => http.Response('{fixture', 200)):
          JmsEntryError.invalidJson,
      MockClient((request) async => http.Response('{}', 200)):
          JmsEntryError.invalidConfig,
      MockClient((request) async => http.Response('', 302)):
          JmsEntryError.redirect,
      MockClient((request) async => http.Response('', 401)):
          JmsEntryError.httpError,
    };
    for (final client in clients.entries) {
      final result = await JmsEntryDiscovery(client: client.key, cache: cache)
          .discover(entry.toString());
      expect(result.kind, JmsEntryResolutionKind.error);
      expect(result.config, isNull);
      expect(result.error, client.value);
    }
  });

  test('forceDirect failure never returns website configuration from cache',
      () async {
    final preferences = await SharedPreferences.getInstance();
    final cache = JmsEntryCache(preferences);
    final entry = JmsEntryDiscovery.normalizeEntry('entry.example.invalid');
    await cache.write(
        entry, JmsServiceConfig(baseUrl: 'https://old.example.invalid'));
    final result = await JmsEntryDiscovery(
            client: MockClient((request) async =>
                throw http.ClientException('fixture network failure')),
            cache: cache)
        .discover(entry.toString(), forceDirect: true);
    expect(result.kind, JmsEntryResolutionKind.error);
    expect(result.config, isNull);
  });

  test('closed service sends nothing and does not close injected client',
      () async {
    var count = 0;
    final client = _StreamClient((request) async {
      count++;
      return http.StreamedResponse(const Stream.empty(), 200);
    });
    final discovery = JmsEntryDiscovery(client: client)..close();
    expect((await discovery.discover('entry.example.invalid')).error,
        JmsEntryError.closed);
    expect(count, 0);
    expect(client.wasClosed, isFalse);
  });

  test('one timeout budget covers both config lookup and public-info probe',
      () async {
    final client = MockClient((request) async {
      await Future<void>.delayed(const Duration(milliseconds: 45));
      return request.url.path.endsWith('jms-config.json')
          ? http.Response('', 404)
          : http.Response(infoBody(), 200);
    });
    final result = await JmsEntryDiscovery(
            client: client, timeout: const Duration(milliseconds: 60))
        .discover('entry.example.invalid');
    expect(result.error, JmsEntryError.timeout);
  });

  test('close aborts an in-flight request without closing an injected client',
      () async {
    final started = Completer<void>();
    var aborted = false;
    final client = _StreamClient((request) {
      final response = Completer<http.StreamedResponse>();
      (request as http.Abortable).abortTrigger!.then((_) {
        aborted = true;
        response.completeError(http.RequestAbortedException());
      });
      started.complete();
      return response.future;
    });
    final discovery = JmsEntryDiscovery(client: client);
    final result = discovery.discover('entry.example.invalid');
    await started.future;
    discovery.close();
    expect((await result).error, JmsEntryError.closed);
    expect(aborted, isTrue);
    expect(client.wasClosed, isFalse);
  });

  test('request resource limits are enforced outside debug assertions', () {
    expect(
        () => JmsEntryDiscovery(timeout: Duration.zero), throwsArgumentError);
    expect(() => JmsEntryDiscovery(maxResponseBytes: 0), throwsArgumentError);
    expect(() => JmsEntryDiscovery(maxResponseBytes: 1048577),
        throwsArgumentError);
  });
}
