import 'dart:async';

import 'package:fladder/util/mpv_hdr_tonemap.dart';
import 'package:fladder/util/mpv_render_capabilities.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.alexmercerind/media_kit_video');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Map<String, Object> reply(
          {String api = 'sw', String transfer = 'sdr', String format = 'rgb0', String handle = '42'}) =>
      {'version': 1, 'handle': handle, 'apiType': api, 'pixelFormat': format, 'outputTransfer': transfer};

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('dispose, reinit and replaced-controller replies cannot overwrite the active capability owner', () async {
    final owner = MpvRenderCapabilityOwner();
    final oldReply = Completer<MpvRenderCapabilities>();
    final pending = owner.resolve(() => oldReply.future, isCurrent: () => true);
    owner.reset(); // Dispose invalidates the in-flight query.
    final newReply = Completer<MpvRenderCapabilities>();
    final replacement = owner.resolve(() => newReply.future, isCurrent: () => true);
    expect(owner.value.softwareSdr, isFalse);
    // An already-stale init must not invalidate the new init's pending query.
    expect(await owner.resolve(() async => throw StateError('must not query'), isCurrent: () => false), isFalse);
    newReply.complete(const MpvRenderCapabilities(apiType: 'opengl', reason: 'new GL controller'));
    expect(await replacement, isTrue);
    oldReply.complete(MpvRenderCapabilities.configuredWindows);
    expect(await pending, isFalse);
    expect(owner.value.apiType, 'opengl');
    expect(owner.value.softwareSdr, isFalse);

    final stale = Completer<MpvRenderCapabilities>();
    var currentController = true;
    final changedHandle = owner.resolve(() => stale.future, isCurrent: () => currentController);
    currentController = false;
    stale.complete(MpvRenderCapabilities.configuredWindows);
    expect(await changedHandle, isFalse);
    expect(owner.value.apiType, 'unknown');
    expect(owner.value.softwareSdr, isFalse);
    expect(await owner.resolve(() async => throw StateError('must not query'), isCurrent: () => false), isFalse);
  });

  test('Linux queries the actual native context for the exact player handle', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return reply();
    });
    final capabilities = await queryMpvRenderCapabilities(playerHandle: () async => 42, platform: TargetPlatform.linux);
    expect(capabilities.softwareSdr, isTrue);
    expect(capabilities.reason, contains('Native Linux'));
    expect(calls.single.method, 'VideoOutputManager.GetRenderCapabilities');
    expect(calls.single.arguments, {'handle': '42'});
  });

  test('GL, HDR output, malformed, incompatible and stale replies cannot enable conversion', () async {
    for (final response in <Object?>[
      reply(api: 'opengl'),
      reply(transfer: 'pq'),
      reply(transfer: 'hlg'),
      reply(transfer: 'unknown'),
      reply(format: 'rgba16f'),
      reply(handle: '43'),
      {...reply(), 'version': 2},
      {...reply(), 'version': '1'},
      {...reply(), 'handle': 42},
      'libmpv',
      null,
      <String, Object>{},
    ]) {
      expect(MpvRenderCapabilities.fromNative(response, handle: 42).softwareSdr, isFalse, reason: '$response');
    }
  });

  test('old or failed plugins and stalled native replies fail closed', () async {
    for (final error in [MissingPluginException(), PlatformException(code: 'synthetic-failure')]) {
      final result = await queryMpvRenderCapabilities(
        playerHandle: () async => 42,
        platform: TargetPlatform.linux,
        invoke: (_, __) async => throw error,
      );
      expect(result.softwareSdr, isFalse);
    }
    final stalled = await queryMpvRenderCapabilities(
      playerHandle: () async => 42,
      platform: TargetPlatform.linux,
      invoke: (_, __) => Completer<Object?>().future,
      timeout: const Duration(milliseconds: 1),
    );
    expect(stalled.softwareSdr, isFalse);
  });

  test('Windows compatibility path is retained; other platforms do not invoke Linux query', () async {
    var calls = 0;
    for (final platform in TargetPlatform.values) {
      if (platform == TargetPlatform.linux) continue;
      final result = await queryMpvRenderCapabilities(
        playerHandle: () async {
          calls++;
          return 42;
        },
        platform: platform,
        invoke: (_, __) async {
          calls++;
          return reply();
        },
      );
      expect(result.softwareSdr, platform == TargetPlatform.windows, reason: platform.name);
    }
    final web = await queryMpvRenderCapabilities(
        playerHandle: () async {
          calls++;
          return 42;
        },
        platform: TargetPlatform.windows,
        web: true);
    expect(web.softwareSdr, isFalse);
    expect(calls, 0);
  });

  test('only confirmed Linux SW SDR applies one filter and clears it across HDR SDR HDR', () async {
    for (final api in ['sw', 'opengl', 'unknown']) {
      final capabilities = MpvRenderCapabilities.fromNative(reply(api: api), handle: 42);
      final filters = <String>[];
      final commands = <List<String>>[];
      final mapper = MpvHdrToneMapper(
        softwareRenderer: capabilities.softwareSdr,
        read: (name) async {
          if (name == 'vf') return filters.join(',');
          final output = name.startsWith('video-out-params/');
          return <String, String>{
                'gamma': output ? 'bt.1886' : 'pq',
                'primaries': output ? 'bt.709' : 'bt.2020',
                'colormatrix': output ? 'bt.709' : 'bt.2020-ncl',
                'colorlevels': 'limited',
                'max-cll': '4000',
              }[name.split('/').last] ??
              '';
        },
        command: (arguments) async {
          commands.add(arguments);
          if (arguments[1] == 'pre') filters.add(arguments[2]);
          if (arguments[1] == 'remove') filters.clear();
        },
        delay: (_) async {},
      );
      for (final source in [
        const MpvHdrSource(range: 'HDR10'),
        const MpvHdrSource(range: 'SDR'),
        const MpvHdrSource(range: 'HDR10')
      ]) {
        final generation = mapper.begin();
        await mapper.resetForMedia(generation);
        final result = await mapper.prepare(generation, source);
        expect(result.applied, api == 'sw' && source.range == 'HDR10');
        expect(filters.length, result.applied ? 1 : 0);
        if (result.applied) expect(filters.single, contains('peak=40.0'));
      }
      await mapper.clear();
      expect(filters, isEmpty);
      if (api != 'sw') expect(commands, isEmpty);
    }
  });
}
