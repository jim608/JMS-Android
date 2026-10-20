import 'dart:async';

import 'package:fladder/util/subtitle_offset.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a primary-only backend resets only its supported timing property',
      () async {
    final writes = <String>[];
    final controller = SubtitleOffsetController(
      supportsSecondary: false,
      write: (name, value) async => writes.add('$name=$value'),
    );
    addTearDown(controller.dispose);
    expect(
        await controller.setOffset(const Duration(milliseconds: 100)), isTrue);
    expect(
        await controller.setOffset(const Duration(milliseconds: 100),
            secondary: true),
        isFalse);
    expect(await controller.resetForMedia(), isTrue);
    expect(writes, ['sub-delay=0.100', 'sub-delay=0.000']);
    expect(controller.primary, Duration.zero);
  });

  test(
      'native capability discovery can keep primary timing without secondary delay',
      () async {
    final writes = <String>[];
    final controller = SubtitleOffsetController(write: (name, value) async {
      if (name == 'secondary-sub-delay') {
        throw StateError('Property unavailable');
      }
      writes.add('$name=$value');
    });
    addTearDown(controller.dispose);
    controller.setSecondarySupported(false);
    controller.setAvailable(primary: true, secondary: true);
    expect(controller.primaryAvailable, isTrue);
    expect(controller.secondaryAvailable, isFalse);
    expect(await controller.resetForMedia(), isTrue);
    expect(
        await controller.setOffset(const Duration(milliseconds: -100)), isTrue);
    expect(
        await controller.setOffset(const Duration(milliseconds: 100),
            secondary: true),
        isFalse);
    expect(writes, ['sub-delay=0.000', 'sub-delay=-0.100']);
  });

  test('signed milliseconds target independent engine channels', () async {
    final writes = <String>[];
    var refreshes = 0;
    final controller = SubtitleOffsetController(
      write: (name, value) async => writes.add('$name=$value'),
      refresh: () async => refreshes++,
    );
    addTearDown(controller.dispose);
    expect(
        await controller.setOffset(const Duration(milliseconds: -100)), isTrue);
    expect(
        await controller.setOffset(const Duration(milliseconds: 350),
            secondary: true),
        isTrue);
    expect(writes, ['sub-delay=-0.100', 'secondary-sub-delay=0.350']);
    expect(controller.primary, const Duration(milliseconds: -100));
    expect(controller.secondary, const Duration(milliseconds: 350));
    expect(refreshes, 2);
  });

  test('clamps large offsets to the supported range', () async {
    final values = <String>[];
    final controller =
        SubtitleOffsetController(write: (_, value) async => values.add(value));
    addTearDown(controller.dispose);
    await controller.setOffset(const Duration(days: 1));
    await controller.setOffset(const Duration(days: -1), secondary: true);
    expect(values, ['60.000', '-60.000']);
    expect(controller.primary, SubtitleOffsetController.limit);
    expect(controller.secondary, -SubtitleOffsetController.limit);
  });

  test('serializes requests and reports confirmed values only', () async {
    final blocked = Completer<void>();
    final writes = <String>[];
    final controller = SubtitleOffsetController(write: (name, value) async {
      writes.add('$name=$value');
      if (writes.length == 1) await blocked.future;
    });
    addTearDown(controller.dispose);
    final first = controller.setOffset(const Duration(seconds: 1));
    final second =
        controller.setOffset(const Duration(seconds: 2), secondary: true);
    await Future<void>.delayed(Duration.zero);
    expect(writes, ['sub-delay=1.000']);
    expect(controller.busy, isTrue);
    expect(controller.primary, Duration.zero);
    blocked.complete();
    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(writes, ['sub-delay=1.000', 'secondary-sub-delay=2.000']);
    expect(controller.busy, isFalse);
  });

  test('native failures preserve the previous offset and allow retry',
      () async {
    var fail = false;
    final controller = SubtitleOffsetController(write: (_, __) async {
      if (fail) throw StateError('synthetic failure');
    });
    addTearDown(controller.dispose);
    await controller.setOffset(const Duration(seconds: 1));
    fail = true;
    expect(await controller.setOffset(const Duration(seconds: 2)), isFalse);
    expect(controller.primary, const Duration(seconds: 1));
    expect(controller.failed, isTrue);
    expect(controller.busy, isFalse);
    fail = false;
    expect(await controller.setOffset(Duration.zero), isTrue);
    expect(controller.primary, Duration.zero);
    expect(controller.failed, isFalse);
  });

  test(
      'new media invalidates pending work and resets both native properties last',
      () async {
    final blocked = Completer<void>();
    final writes = <String>[];
    final controller = SubtitleOffsetController(write: (name, value) async {
      writes.add('$name=$value');
      if (writes.length == 1) await blocked.future;
    });
    addTearDown(controller.dispose);
    controller.setAvailable(primary: true, secondary: true);
    final old = controller.setOffset(const Duration(seconds: 4));
    final queued =
        controller.setOffset(const Duration(seconds: 5), secondary: true);
    await Future<void>.delayed(Duration.zero);
    final reset = controller.resetForMedia();
    expect(controller.primaryAvailable, isFalse);
    expect(controller.secondaryAvailable, isFalse);
    blocked.complete();
    expect(await old, isFalse);
    expect(await queued, isFalse);
    expect(await reset, isTrue);
    expect(writes,
        ['sub-delay=4.000', 'sub-delay=0.000', 'secondary-sub-delay=0.000']);
    expect(controller.primary, Duration.zero);
    expect(controller.secondary, Duration.zero);
    expect(controller.busy, isFalse);
  });

  test('a failed reset is reported to the loading caller', () async {
    final controller = SubtitleOffsetController(write: (name, _) async {
      if (name == 'secondary-sub-delay') throw StateError('synthetic failure');
    });
    addTearDown(controller.dispose);
    expect(await controller.resetForMedia(), isFalse);
    expect(controller.failed, isTrue);
  });

  test('a silent native write failure is rejected by exact property readback',
      () async {
    final controller = SubtitleOffsetController(
      write: (_, __) async {},
      read: (_) async => '0.000000',
    );
    addTearDown(controller.dispose);
    expect(
        await controller.setOffset(const Duration(milliseconds: 100)), isFalse);
    expect(controller.primary, Duration.zero);
    expect(controller.failed, isTrue);
    expect(await controller.setOffset(Duration.zero), isTrue);
    expect(controller.failed, isFalse);
  });

  test('a missing native property cannot be reported as applied', () async {
    final controller = SubtitleOffsetController(
      write: (_, __) async {},
      read: (_) async => '',
    );
    addTearDown(controller.dispose);
    expect(await controller.resetForMedia(), isFalse);
    expect(controller.failed, isTrue);
  });

  test('clearing a stopped player prevents queued writes and stale completion',
      () async {
    final blocked = Completer<void>();
    var writes = 0;
    final controller = SubtitleOffsetController(write: (_, __) async {
      writes++;
      await blocked.future;
    });
    addTearDown(controller.dispose);
    final first = controller.setOffset(const Duration(seconds: 1));
    final queued = controller.setOffset(const Duration(seconds: 2));
    await Future<void>.delayed(Duration.zero);
    controller.clear();
    blocked.complete();
    expect(await first, isFalse);
    expect(await queued, isFalse);
    await controller.idle;
    expect(writes, 1);
    expect(controller.primary, Duration.zero);
  });

  test('disposal cancels async results without notifying disposed listeners',
      () async {
    final blocked = Completer<void>();
    final controller =
        SubtitleOffsetController(write: (_, __) => blocked.future);
    final pending = controller.setOffset(const Duration(seconds: 1));
    await Future<void>.delayed(Duration.zero);
    controller.dispose();
    blocked.complete();
    expect(await pending, isFalse);
    expect(await controller.setOffset(Duration.zero), isFalse);
  });
}
