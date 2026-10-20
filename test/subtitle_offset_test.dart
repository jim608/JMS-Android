import 'dart:async';

import 'package:fladder/util/subtitle_offset.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('media reset invalidates both input revisions even for unchanged zero',
      () async {
    final controller = SubtitleOffsetController(write: (_, __) async {});
    addTearDown(controller.dispose);
    controller.setAvailable(primary: true, secondary: true);
    final primary = controller.editRevision();
    final secondary = controller.editRevision(secondary: true);
    expect(controller.primary, Duration.zero);

    controller.clear();
    controller.setAvailable(primary: true, secondary: true);
    expect(controller.primary, Duration.zero);
    expect(controller.primaryAvailable, isTrue);
    expect(controller.secondaryAvailable, isTrue);
    expect(controller.editRevision(), greaterThan(primary));
    expect(controller.editRevision(secondary: true), greaterThan(secondary));

    final afterClear = controller.editRevision();
    final afterSecondaryClear = controller.editRevision(secondary: true);
    expect(await controller.resetForMedia(), isTrue);
    expect(controller.editRevision(), greaterThan(afterClear));
    expect(controller.editRevision(secondary: true),
        greaterThan(afterSecondaryClear));
  });

  test('coalesced availability changes invalidate only their channel drafts',
      () {
    final controller = SubtitleOffsetController(write: (_, __) async {});
    addTearDown(controller.dispose);
    controller.setAvailable(primary: true, secondary: true);
    final primary = controller.editRevision();
    final secondary = controller.editRevision(secondary: true);

    controller.setAvailable(primary: false, secondary: true);
    controller.setAvailable(primary: true, secondary: true);
    expect(controller.primaryAvailable, isTrue);
    expect(controller.editRevision(), primary + 2);
    expect(controller.editRevision(secondary: true), secondary);

    controller.setAvailable(primary: true, secondary: false);
    controller.setAvailable(primary: true, secondary: true);
    expect(controller.secondaryAvailable, isTrue);
    expect(controller.editRevision(), primary + 2);
    expect(controller.editRevision(secondary: true), secondary + 2);

    controller.setAvailable(primary: true, secondary: true);
    expect(controller.editRevision(), primary + 2);
    expect(controller.editRevision(secondary: true), secondary + 2);
  });

  test('secondary capabilities invalidate only the secondary input revision',
      () {
    final controller = SubtitleOffsetController(write: (_, __) async {});
    addTearDown(controller.dispose);
    controller.setAvailable(primary: true, secondary: true);
    final primary = controller.editRevision();
    final secondary = controller.editRevision(secondary: true);

    controller.setSecondarySupported(false);
    expect(controller.editRevision(), primary);
    expect(controller.editRevision(secondary: true), secondary + 1);
    expect(controller.secondaryAvailable, isFalse);
    controller.setSecondarySupported(false);
    expect(controller.editRevision(secondary: true), secondary + 1);
    controller.setSecondarySupported(true);
    expect(controller.editRevision(), primary);
    expect(controller.editRevision(secondary: true), secondary + 2);
  });

  test('offset writes and busy changes preserve both input revisions',
      () async {
    final pending = Completer<void>();
    final controller =
        SubtitleOffsetController(write: (_, __) => pending.future);
    addTearDown(controller.dispose);
    controller.setAvailable(primary: true, secondary: true);
    final primary = controller.editRevision();
    final secondary = controller.editRevision(secondary: true);

    final applied = controller.setOffset(const Duration(milliseconds: 10));
    expect(controller.busy, isTrue);
    expect(controller.editRevision(), primary);
    expect(controller.editRevision(secondary: true), secondary);
    pending.complete();
    expect(await applied, isTrue);
    expect(controller.primary, const Duration(milliseconds: 10));
    expect(controller.busy, isFalse);
    expect(controller.editRevision(), primary);
    expect(controller.editRevision(secondary: true), secondary);
  });

  test('seconds input keeps signed hundredths exact and accepts decimal commas',
      () {
    final samples = <String, int>{
      '0': 0,
      '-0.00': 0,
      '+0.01': 10,
      '-0.05': -50,
      '.07': 70,
      '-,09': -90,
      '1.2': 1200,
      '  +1,23  ': 1230,
      '60.00': 60000,
      '-60': -60000,
    };
    for (final entry in samples.entries) {
      expect(parseSubtitleOffsetSeconds(entry.key),
          Duration(milliseconds: entry.value),
          reason: entry.key);
    }
  });

  test('seconds input rejects incomplete, imprecise and out-of-range values',
      () {
    for (final input in [
      '',
      ' ',
      '-',
      '+',
      '.',
      '1.',
      '1,',
      '0.001',
      '-0,001',
      '60.01',
      '-60.01',
      '61',
      '999999999999999999999999999999999999',
      'NaN',
      'Infinity',
      '-Infinity',
      '1e-2',
      '1.2.3',
      '1,2.3',
      '1 2',
      '1 s',
      '--1',
    ]) {
      expect(parseSubtitleOffsetSeconds(input), isNull, reason: input);
    }
  });

  test('seconds display round-trips every hundredth within the allowed range',
      () {
    for (var hundredths = -6000; hundredths <= 6000; hundredths++) {
      final value = Duration(milliseconds: hundredths * 10);
      expect(parseSubtitleOffsetSeconds(formatSubtitleOffsetSeconds(value)),
          value);
    }
    expect(formatSubtitleOffsetSeconds(Duration.zero), '0.00');
    expect(
        formatSubtitleOffsetSeconds(const Duration(milliseconds: 10)), '+0.01');
    expect(formatSubtitleOffsetSeconds(const Duration(milliseconds: -50)),
        '-0.05');
    expect(
        formatSubtitleOffsetSeconds(const Duration(milliseconds: 10),
            showPositiveSign: false),
        '0.01');
    expect(
        formatSubtitleOffsetSeconds(const Duration(milliseconds: -1)), '0.00');
  });

  test('slider conversion snaps to hundredths and clamps to both limits', () {
    expect(subtitleOffsetFromSliderSeconds(0.009999999),
        const Duration(milliseconds: 10));
    expect(subtitleOffsetFromSliderSeconds(-0.050000001),
        const Duration(milliseconds: -50));
    expect(subtitleOffsetFromSliderSeconds(1.234),
        const Duration(milliseconds: 1230));
    expect(subtitleOffsetFromSliderSeconds(61), SubtitleOffsetController.limit);
    expect(
        subtitleOffsetFromSliderSeconds(-61), -SubtitleOffsetController.limit);
    for (final value in [
      double.nan,
      double.infinity,
      double.negativeInfinity
    ]) {
      expect(() => subtitleOffsetFromSliderSeconds(value), throwsArgumentError);
    }
  });

  test('hundredths reach each engine channel and survive exact readback',
      () async {
    final properties = <String, String>{};
    final controller = SubtitleOffsetController(
      write: (name, value) async => properties[name] = value,
      read: (name) async => properties[name]!,
    );
    addTearDown(controller.dispose);
    expect(SubtitleOffsetController.step, const Duration(milliseconds: 10));
    expect(await controller.setOffset(parseSubtitleOffsetSeconds('0.01')!),
        isTrue);
    expect(
        await controller.setOffset(parseSubtitleOffsetSeconds('-0.05')!,
            secondary: true),
        isTrue);
    expect(properties, {'sub-delay': '0.010', 'secondary-sub-delay': '-0.050'});
    expect(controller.primary, const Duration(milliseconds: 10));
    expect(controller.secondary, const Duration(milliseconds: -50));
  });

  test('non-finite engine readback never confirms a subtitle adjustment',
      () async {
    var readback = '0.010';
    final controller = SubtitleOffsetController(
      write: (_, __) async {},
      read: (_) async => readback,
    );
    addTearDown(controller.dispose);
    expect(
        await controller.setOffset(const Duration(milliseconds: 10)), isTrue);
    for (final invalid in ['NaN', 'Infinity', '-Infinity', '1e309']) {
      readback = invalid;
      expect(await controller.setOffset(const Duration(milliseconds: -50)),
          isFalse,
          reason: invalid);
      expect(controller.primary, const Duration(milliseconds: 10));
      expect(controller.failed, isTrue);
    }
  });

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
