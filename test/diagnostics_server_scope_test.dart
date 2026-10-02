import 'package:fladder/providers/diagnostics_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const receiverA = 'https://a.example.org/api/jms/diagnostics/v1';
  const receiverB = 'https://b.example.org/api/jms/diagnostics/v1';
  const manual = 'https://manual.example.org/api/jms/diagnostics/v1';
  late SharedPreferences preferences;
  late List<Uri> sent;
  late List<DiagnosticsSettings> instances;
  FlutterExceptionHandler? originalFlutter;
  bool Function(Object, StackTrace)? originalPlatform;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    sent = [];
    instances = [];
    originalFlutter = FlutterError.onError;
    originalPlatform = PlatformDispatcher.instance.onError;
    FlutterError.onError = (_) {};
    PlatformDispatcher.instance.onError = (_, __) => true;
  });

  tearDown(() {
    for (final settings in instances.reversed) {
      settings.dispose();
    }
    FlutterError.onError = originalFlutter;
    PlatformDispatcher.instance.onError = originalPlatform;
  });

  DiagnosticsSettings create(
      {String platform = 'android', String? configured}) {
    final settings = DiagnosticsSettings(
      preferences: preferences,
      version: '0.11.1-jms.28',
      buildId: 'JMS-0.11.1-jms.28-123456abcdef',
      platform: platform,
      configuredEndpoint: configured,
      clientFactory: () => MockClient((request) async {
        sent.add(request.url);
        expect(request.headers.containsKey('Authorization'), false);
        expect(request.headers.containsKey('Cookie'), false);
        return http.Response('', 202);
      }),
    );
    instances.add(settings);
    return settings;
  }

  Future<void> error() async {
    FlutterError
        .onError!(FlutterErrorDetails(exception: StateError('synthetic')));
    await Future<void>.delayed(Duration.zero);
  }

  test('native startup cannot send using legacy consent before scope loads',
      () async {
    await preferences.setString(DiagnosticsSettings.endpointKey, manual);
    await preferences.setBool(DiagnosticsSettings.consentKey, true);
    final settings = create();
    expect(settings.enabled, false);
    expect(settings.configured, false);
    expect(await settings.setEnabled(true), false);
    await error();
    expect(sent, isEmpty);
    expect(
        await settings.activateServer('server-a/account-one', receiverA), true);
    expect(settings.endpointValue, manual);
    expect(settings.serverProvided, false);
    expect(settings.enabled, false);
    expect(preferences.getString(DiagnosticsSettings.endpointKey), manual);
    await error();
    expect(sent, isEmpty);
  });

  test('discovery requires consent and switching scope stops hooks immediately',
      () async {
    final settings = create();
    await settings.activateServer('server-a/account-one', receiverA);
    expect(settings.serverProvided, true);
    expect(settings.endpointValue, receiverA);
    expect(settings.enabled, false);
    await error();
    expect(sent, isEmpty);
    expect(await settings.setEnabled(true), true);
    await error();
    expect(sent, [Uri.parse(receiverA)]);

    final switchServer =
        settings.activateServer('server-b/account-one', receiverB);
    expect(settings.enabled, false);
    await error();
    expect(sent, hasLength(1));
    expect(await switchServer, true);
    expect(settings.endpointValue, receiverB);
    expect(await settings.setEnabled(true), true);
    await error();
    expect(sent, [Uri.parse(receiverA), Uri.parse(receiverB)]);

    await settings.activateServer('server-a/account-one', receiverA);
    expect(settings.enabled, false);
    await error();
    expect(sent, hasLength(2));
  });

  test('same server with different account cannot inherit consent', () async {
    final settings = create();
    await settings.activateServer('server-a/account-one', receiverA);
    await settings.setEnabled(true);
    await settings.activateServer('server-a/account-two', receiverA);
    expect(settings.enabled, false);
    await error();
    expect(sent, isEmpty);
  });

  test('manual endpoint has priority only within its own scope', () async {
    final settings = create();
    await settings.activateServer('server-a', receiverA);
    await settings.setEnabled(true);
    expect(await settings.setEndpoint(manual), true);
    expect(settings.enabled, false);
    expect(settings.serverProvided, false);
    expect(settings.endpointValue, manual);
    await error();
    expect(sent, isEmpty);
    await settings.setEnabled(true);
    await settings.activateServer('server-a', receiverB);
    expect(settings.endpointValue, manual);
    expect(settings.enabled, true);

    await settings.activateServer('server-b', receiverB);
    expect(settings.endpointValue, receiverB);
    expect(settings.serverProvided, true);
    expect(settings.enabled, false);
    await settings.activateServer('server-a', receiverA);
    expect(settings.endpointValue, manual);
    expect(settings.enabled, false);
    await settings.setEndpoint('');
    expect(settings.endpointValue, receiverA);
    expect(settings.serverProvided, true);
    expect(settings.enabled, false);
  });

  test('missing receiver disables server integration without build fallback',
      () async {
    final settings = create(configured: manual);
    await settings.activateServer('server-a', receiverA);
    await settings.setEnabled(true);
    await settings.activateServer('server-a', null);
    expect(settings.endpointValue, isEmpty);
    expect(settings.configured, false);
    expect(settings.enabled, false);
    expect(await settings.setEnabled(true), false);
    await error();
    expect(sent, isEmpty);
  });

  test('endpoint persistence cannot race a new enable request', () async {
    final settings = create();
    await settings.activateServer('server-a', receiverA);
    await settings.setEnabled(true);
    final editing = settings.setEndpoint(manual);
    expect(settings.enabled, false);
    expect(settings.configured, false);
    expect(await settings.setEnabled(true), false);
    await error();
    expect(sent, isEmpty);
    expect(await editing, true);
    expect(settings.endpointValue, manual);
    expect(settings.enabled, false);
  });

  test('invalid receiver cannot enable reports or bypass endpoint validation',
      () async {
    final settings = create();
    for (final value in [
      'http://a.example.org/api/jms/diagnostics/v1',
      'https://a.example.org/api/jms/diagnostics/v1?key=synthetic',
      'https://a.example.org/not-diagnostics',
    ]) {
      await settings.activateServer('server-a', value);
      expect(settings.configured, false);
      expect(await settings.setEnabled(true), false);
    }
    await settings.activateServer('server-a', receiverA);
    await settings.setEnabled(true);
    expect(await settings.setEndpoint('http://a.example.org/invalid'), false);
    expect(settings.endpointValue, receiverA);
    expect(settings.enabled, true);
  });

  test(
      'restart restores only an accepted matching persisted scope and receiver',
      () async {
    final first = create();
    await first.activateServer('server-a', receiverA);
    await first.setEnabled(true);
    first.dispose();
    instances.remove(first);
    final restarted = create();
    expect(restarted.enabled, false);
    await error();
    expect(sent, isEmpty);
    await restarted.activateServer('server-a', receiverA);
    expect(restarted.enabled, true);
    await error();
    expect(sent, [Uri.parse(receiverA)]);
    restarted.dispose();
    instances.remove(restarted);

    final changed = create();
    await changed.activateServer('server-a', receiverB);
    expect(changed.enabled, false);
    await error();
    expect(sent, hasLength(1));
  });

  test('legacy manual endpoint migrates once without granting consent',
      () async {
    await preferences.setString(DiagnosticsSettings.endpointKey, manual);
    final settings = create();
    await settings.activateServer('server-a', receiverA);
    expect(settings.endpointValue, manual);
    expect(settings.enabled, false);
    await settings.activateServer('server-b', receiverB);
    expect(settings.endpointValue, receiverB);
    expect(settings.enabled, false);
    expect(preferences.getString(DiagnosticsSettings.endpointKey), manual);
    await settings.activateServer(null, null);
    expect(settings.endpointValue, manual);
    expect(settings.enabled, false);
  });

  test('first activation after restart revokes the previously persisted scope',
      () async {
    final first = create();
    await first.activateServer('server-a', receiverA);
    await first.setEnabled(true);
    final oldConsentKey = preferences.getKeys().singleWhere((key) =>
        key.startsWith('jms.diagnostics.server.v1.') &&
        key.endsWith('.consent'));
    expect(preferences.getBool(oldConsentKey), true);
    first.dispose();
    instances.remove(first);
    final restarted = create();
    await restarted.activateServer('server-b', receiverB);
    expect(preferences.getBool(oldConsentKey), false);
    expect(restarted.enabled, false);
    await error();
    expect(sent, isEmpty);
  });

  test('Web no-scope configured endpoint remains available without discovery',
      () async {
    final settings = create(platform: 'web', configured: receiverA);
    expect(settings.configured, true);
    expect(settings.endpointValue, receiverA);
    expect(settings.enabled, false);
    await settings.setEnabled(true);
    await error();
    expect(sent, [Uri.parse(receiverA)]);
    await settings.setEndpoint(receiverB);
    expect(settings.enabled, false);
    await error();
    expect(sent, hasLength(1));
  });
}
