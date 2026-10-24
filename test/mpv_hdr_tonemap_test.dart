import 'dart:async';

import 'package:fladder/util/mpv_hdr_tonemap.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeNative {
  final filters = <String>['@user_crop:crop=320:180', '@user_flip:hflip'];
  final commands = <List<String>>[];
  final events = <String>[];
  final input = <String, String>{
    'gamma': 'pq',
    'primaries': 'bt.2020',
    'colormatrix': 'bt.2020-ncl',
    'colorlevels': 'limited',
    'max-cll': '1000',
    'max-luma': '4000',
    'sig-peak': '4.926108',
  };
  int reads = 0;
  bool failAdd = false;
  bool outputReady = true;
  bool failRemove = false;
  Future<String>? firstGamma;
  Completer<void>? addGate;
  final addStarted = Completer<void>();

  Future<String> read(String name) async {
    reads++;
    if (name == 'vf') return filters.join(',');
    if (name.startsWith('video-dec-params/')) {
      final key = name.split('/').last;
      if (key == 'gamma' && firstGamma != null) {
        final value = firstGamma!;
        firstGamma = null;
        return value;
      }
      return input[key] ?? '';
    }
    if (name.startsWith('video-out-params/')) {
      if (!outputReady || !filters.any((filter) => filter.startsWith('@${MpvHdrToneMapper.label}:'))) return '';
      return {
            'gamma': 'bt.1886',
            'primaries': 'bt.709',
            'colormatrix': 'bt.709',
            'colorlevels': 'limited'
          }[name.split('/').last] ??
          '';
    }
    return '';
  }

  Future<void> command(List<String> arguments) async {
    commands.add(List.of(arguments));
    if (arguments[0] != 'vf') return;
    if (arguments[1] == 'pre') {
      events.add('filter');
      if (!addStarted.isCompleted) addStarted.complete();
      await addGate?.future;
      filters.insert(0, arguments[2]);
      if (failAdd) throw StateError('synthetic partial filter failure');
    } else if (arguments[1] == 'remove') {
      events.add('remove');
      if (failRemove) throw StateError('synthetic remove failure');
      filters.removeWhere((filter) => filter.startsWith('${arguments[2]}:'));
    }
  }

  MpvHdrToneMapper mapper({bool softwareRenderer = true}) => MpvHdrToneMapper(
        softwareRenderer: softwareRenderer,
        read: read,
        command: command,
        attempts: 3,
        delay: (_) async {},
      );
}

const hdr = MpvHdrSource(range: 'HDR10');
const sdr = MpvHdrSource(range: 'SDR');

void main() {
  test('only a confirmed software SDR output opts into the policy', () async {
    final native = FakeNative();
    final mapper = native.mapper(softwareRenderer: false);
    final result = await mapper.prepare(mapper.begin(), hdr);
    expect(result.applied, isFalse);
    expect(native.reads, 0);
    expect(native.commands, isEmpty);
  });

  test('SDR, HLG, Dolby Vision, unknown and transcode classifications bypass without probing or changing vf', () async {
    for (final source in [
      sdr,
      const MpvHdrSource(),
      const MpvHdrSource(range: 'HLG'),
      const MpvHdrSource(range: 'DOVI'),
      const MpvHdrSource(range: 'DOVIWithHDR10'),
      const MpvHdrSource(range: 'HDR10Plus'),
      const MpvHdrSource(range: 'HDR10', dolbyVision: true),
      const MpvHdrSource(range: 'HDR10', transcoded: true)
    ]) {
      final native = FakeNative();
      final mapper = native.mapper();
      final result = await mapper.prepare(mapper.begin(), source);
      expect(result.applied, isFalse, reason: source.range);
      expect(native.reads, 0);
      expect(native.commands, isEmpty);
      expect(native.filters, ['@user_crop:crop=320:180', '@user_flip:hflip']);
    }
  });

  test('confirmed 1000nit HDR10 inserts one named filter before unchanged user filters', () async {
    final native = FakeNative();
    final mapper = native.mapper();
    final result = await mapper.prepare(mapper.begin(), hdr);
    expect(result.applied, isTrue);
    expect(native.filters.first, MpvHdrToneMapper.filterForPeak(1000));
    expect(native.filters.first, contains('npl=100'));
    expect(native.filters.first, contains('tonemap=tonemap=hable:desat=0:peak=10.0'));
    expect(native.filters.skip(1), ['@user_crop:crop=320:180', '@user_flip:hflip']);
    expect(native.commands.single.take(2), ['vf', 'pre']);
    expect(mapper.diagnostics['HDR output'], contains('BT.1886'));
  });

  test('4000nit input explicitly uses peak40 even when sig-peak has a different normalization', () async {
    final native = FakeNative()
      ..input['max-cll'] = '4000'
      ..input['sig-peak'] = '19.7044';
    final mapper = native.mapper();
    expect((await mapper.prepare(mapper.begin(), hdr)).applied, isTrue);
    expect(native.filters.first, contains('peak=40.0'));
    expect(native.filters.first, isNot(contains('peak=19.7044')));
  });

  test('MaxCLL takes priority over mastering max-luma; missing or zero CLL uses reliable mastering metadata', () async {
    for (final entry in [('', 4000.0), ('0', 4000.0), ('600', 600.0)]) {
      final native = FakeNative()..input['max-cll'] = entry.$1;
      final mapper = native.mapper();
      expect((await mapper.prepare(mapper.begin(), hdr)).applied, isTrue);
      expect(native.filters.first, MpvHdrToneMapper.filterForPeak(entry.$2));
    }
  });

  test('unknown, nonfinite, negative or impossible physical peak never falls back to hardcoded1000nit', () async {
    for (final peak in ['', '0', '-1', 'NaN', 'Infinity', '10001', 'invalid']) {
      final native = FakeNative()
        ..input['max-cll'] = peak
        ..input['max-luma'] = peak;
      final mapper = native.mapper();
      expect((await mapper.prepare(mapper.begin(), hdr)).applied, isFalse, reason: peak);
      expect(native.commands, isEmpty);
      expect(mapper.diagnostics['HDR SDR policy'], contains('peak'));
    }
  });

  test('decoded PQ, primaries, matrix and range must agree; native Dolby Vision is excluded', () async {
    for (final entry in [
      ('gamma', 'hlg'),
      ('primaries', 'bt.709'),
      ('colormatrix', 'bt.709'),
      ('colorlevels', 'full'),
      ('dolby-vision-profile', '8')
    ]) {
      final native = FakeNative()..input[entry.$1] = entry.$2;
      final mapper = native.mapper();
      expect((await mapper.prepare(mapper.begin(), hdr)).applied, isFalse, reason: entry.$1);
      expect(native.commands, isEmpty);
    }
  });

  test('HDR to SDR to HDR clears only its own label and updates the physical peak', () async {
    final native = FakeNative();
    final mapper = native.mapper();
    expect((await mapper.prepare(mapper.begin(), hdr)).applied, isTrue);
    expect((await mapper.prepare(mapper.begin(), sdr)).applied, isFalse);
    expect(native.filters, ['@user_crop:crop=320:180', '@user_flip:hflip']);
    native.input['max-cll'] = '4000';
    expect((await mapper.prepare(mapper.begin(), hdr)).applied, isTrue);
    expect(native.filters.first, contains('peak=40.0'));
    await mapper.clear();
    expect(native.filters, ['@user_crop:crop=320:180', '@user_flip:hflip']);
    expect(native.commands.every((command) => command[0] == 'vf' && ['pre', 'remove'].contains(command[1])), isTrue);
  });

  test('seek retains the existing filter; reload leaves exactly one new label', () async {
    final native = FakeNative();
    final mapper = native.mapper();
    await mapper.prepare(mapper.begin(), hdr);
    await native.command(['seek', '12', 'absolute']);
    expect(mapper.applied, isTrue);
    expect(native.filters.where((filter) => filter.contains(MpvHdrToneMapper.label)), hasLength(1));
    await mapper.prepare(mapper.begin(), hdr);
    expect(native.filters.where((filter) => filter.contains(MpvHdrToneMapper.label)), hasLength(1));
  });

  test('superseded asynchronous metadata cannot add a filter to the next SDR item', () async {
    final native = FakeNative();
    final gate = Completer<String>();
    native.firstGamma = gate.future;
    final mapper = native.mapper();
    final old = mapper.prepare(mapper.begin(), hdr);
    await Future<void>.delayed(Duration.zero);
    final next = await mapper.prepare(mapper.begin(), sdr);
    expect(next.applied, isFalse);
    gate.complete('pq');
    expect((await old).cancelled, isTrue);
    expect(native.commands, isEmpty);
  });

  test('stop during pending filter mutation removes the stale label before completing cleanup', () async {
    final native = FakeNative()..addGate = Completer<void>();
    final mapper = native.mapper();
    final old = mapper.prepare(mapper.begin(), hdr);
    await native.addStarted.future;
    final stopped = mapper.clear();
    native.addGate!.complete();
    expect((await old).cancelled, isTrue);
    await stopped;
    expect(native.filters, ['@user_crop:crop=320:180', '@user_flip:hflip']);
  });

  test('partial filter failure and unconfirmed output both clean up the named filter', () async {
    for (final failAdd in [true, false]) {
      final native = FakeNative()
        ..failAdd = failAdd
        ..outputReady = false;
      final mapper = native.mapper();
      expect((await mapper.prepare(mapper.begin(), hdr)).failed, isTrue);
      expect(native.filters, ['@user_crop:crop=320:180', '@user_flip:hflip']);
      await mapper.clear(reason: 'disposed');
    }
  });

  test('metadata waiting is bounded and leaves unsupported input unmodified', () async {
    final native = FakeNative()..input['gamma'] = '';
    var waits = 0;
    final mapper = MpvHdrToneMapper(
        softwareRenderer: true,
        read: native.read,
        command: native.command,
        attempts: 3,
        delay: (_) async {
          waits++;
        });
    expect((await mapper.prepare(mapper.begin(), hdr)).applied, isFalse);
    expect(waits, 3);
    expect(native.commands, isEmpty);
  });

  test('known HDR is covered before paused open, configured before resume, then uncovered', () async {
    final native = FakeNative();
    final mapper = native.mapper();
    await openMpvWithHdr(
        mapper: mapper,
        source: hdr,
        play: true,
        isCurrent: () => true,
        surfaceReady: (ready) => native.events.add('visible:$ready'),
        pause: () async => native.events.add('pause'),
        open: (play) async => native.events.add('open:$play'),
        resume: () async => native.events.add('resume'),
        stop: () async => native.events.add('stop'),
        frameBarrier: () async => native.events.add('frame-ready'));
    expect(native.events,
        ['visible:false', 'frame-ready', 'pause', 'open:false', 'filter', 'frame-ready', 'resume', 'visible:true']);
  });

  test('SDR load bypass has no pause, metadata wait, surface cover or resume override', () async {
    final native = FakeNative();
    final mapper = native.mapper();
    await openMpvWithHdr(
        mapper: mapper,
        source: sdr,
        play: true,
        isCurrent: () => true,
        surfaceReady: (ready) => native.events.add('visible:$ready'),
        pause: () async => native.events.add('pause'),
        open: (play) async => native.events.add('open:$play'),
        resume: () async => native.events.add('resume'),
        stop: () async => native.events.add('stop'),
        frameBarrier: () async => native.events.add('frame-ready'));
    expect(native.events, ['open:true', 'visible:true']);
    expect(native.reads, 0);
  });

  test('failed HDR load stops before uncovering and never resumes', () async {
    final native = FakeNative()..failAdd = true;
    final mapper = native.mapper();
    final load = openMpvWithHdr(
        mapper: mapper,
        source: hdr,
        play: true,
        isCurrent: () => true,
        surfaceReady: (ready) => native.events.add('visible:$ready'),
        pause: () async => native.events.add('pause'),
        open: (play) async => native.events.add('open:$play'),
        resume: () async => native.events.add('resume'),
        stop: () async => native.events.add('stop'),
        frameBarrier: () async => native.events.add('frame-ready'));
    await expectLater(load, throwsStateError);
    expect(native.events,
        ['visible:false', 'frame-ready', 'pause', 'open:false', 'filter', 'remove', 'stop', 'visible:true']);
    expect(native.filters, ['@user_crop:crop=320:180', '@user_flip:hflip']);
  });

  test('cancelled load cannot unpause or uncover a newer load', () async {
    final native = FakeNative();
    final mapper = native.mapper();
    final opened = Completer<void>();
    var current = true;
    final load = openMpvWithHdr(
        mapper: mapper,
        source: hdr,
        play: true,
        isCurrent: () => current,
        surfaceReady: (ready) => native.events.add('visible:$ready'),
        pause: () async => native.events.add('pause'),
        open: (play) => opened.future,
        resume: () async => native.events.add('resume'),
        stop: () async => native.events.add('stop'),
        frameBarrier: () async => native.events.add('frame-ready'));
    await Future<void>.delayed(Duration.zero);
    current = false;
    await mapper.clear();
    opened.complete();
    await load;
    expect(native.events, ['visible:false', 'frame-ready', 'pause']);
  });

  test('stale load rejects before advancing the mapper epoch or touching the surface', () async {
    final native = FakeNative();
    final mapper = native.mapper();
    final validEpoch = mapper.begin();
    await openMpvWithHdr(
        mapper: mapper,
        source: hdr,
        play: true,
        isCurrent: () => false,
        surfaceReady: (_) => fail('stale load touched surface'),
        pause: () async => fail('stale pause'),
        open: (_) async => fail('stale open'),
        resume: () async => fail('stale resume'),
        stop: () async => fail('stale stop'),
        frameBarrier: () async => fail('stale frame barrier'));
    expect(mapper.current(validEpoch), isTrue);
    expect(native.commands, isEmpty);
  });

  test('user colour filters, unknown vf and a reserved-label collision are preserved without automatic conversion',
      () async {
    for (final filter in [
      '@user:lavfi=[tonemap=hable]',
      'zscale=t=linear',
      'format=yuv420p',
      'eq=brightness=0.1',
      'unknown_filter=x',
      '@${MpvHdrToneMapper.label}:hflip'
    ]) {
      final native = FakeNative()..filters.insert(0, filter);
      final before = List.of(native.filters);
      final mapper = native.mapper();
      expect((await mapper.prepare(mapper.begin(), hdr)).applied, isFalse, reason: filter);
      expect(native.filters, before);
      expect(native.commands, isEmpty);
      await mapper.clear();
      expect(native.filters, before);
    }
  });

  test('explicit pause during deferred HDR preparation revokes captured load resume intent', () async {
    final native = FakeNative()..addGate = Completer<void>();
    final mapper = native.mapper();
    var wantsPlay = true;
    final load = openMpvWithHdr(
        mapper: mapper,
        source: hdr,
        play: true,
        shouldResume: () => wantsPlay,
        isCurrent: () => true,
        surfaceReady: (ready) => native.events.add('visible:$ready'),
        pause: () async => native.events.add('pause'),
        open: (_) async {},
        resume: () async => native.events.add('resume'),
        stop: () async => native.events.add('stop'),
        frameBarrier: () async => native.events.add('frame-ready'));
    await native.addStarted.future;
    wantsPlay = false; // Sleep/SyncPlay/user pause all update the same intent.
    native.addGate!.complete();
    await load;
    expect(native.events, isNot(contains('resume')));
    expect(native.events.last, 'visible:true');
  });

  test('a cover frame timeout stops before removing HDR and does not open new media', () async {
    final native = FakeNative();
    final mapper = native.mapper();
    await mapper.prepare(mapper.begin(), hdr);
    native.events.clear();
    final load = openMpvWithHdr(
        mapper: mapper,
        source: hdr,
        play: true,
        isCurrent: () => true,
        surfaceReady: (ready) => native.events.add('visible:$ready'),
        pause: () async => fail('pause before cover'),
        open: (_) async => fail('open before cover'),
        resume: () async => fail('resume before cover'),
        stop: () async => native.events.add('stop'),
        frameBarrier: () async => throw TimeoutException('synthetic compositor timeout'));
    await expectLater(load, throwsA(isA<TimeoutException>()));
    expect(native.events, ['visible:false', 'stop', 'remove', 'visible:true']);
  });

  test('stop and dispose cleanup stop native output before filter removal; dispose stays covered', () async {
    for (final uncover in [true, false]) {
      final native = FakeNative();
      final mapper = native.mapper();
      await mapper.prepare(mapper.begin(), hdr);
      native.events.clear();
      await stopMpvWithHdr(
          mapper: mapper,
          isCurrent: () => true,
          uncover: uncover,
          stop: () async => native.events.add('stop'),
          surfaceReady: (ready) => native.events.add('visible:$ready'));
      expect(native.events, ['visible:false', 'stop', 'remove', if (uncover) 'visible:true']);
    }
  });

  test('native stop failure never removes the valid HDR filter or uncovers the surface', () async {
    final native = FakeNative();
    final mapper = native.mapper();
    await mapper.prepare(mapper.begin(), hdr);
    native.events.clear();
    await expectLater(
        stopMpvWithHdr(
            mapper: mapper,
            isCurrent: () => true,
            stop: () async => throw StateError('synthetic stop failure'),
            surfaceReady: (ready) => native.events.add('visible:$ready')),
        throwsStateError);
    expect(native.events, ['visible:false']);
    expect(mapper.applied, isTrue);
    await mapper.clear(reason: 'disposed native context');
  });

  test('stop failure in a failed-load path keeps the cover until retry or disposal', () async {
    final native = FakeNative();
    final mapper = native.mapper();
    final load = openMpvWithHdr(
        mapper: mapper,
        source: hdr,
        play: true,
        isCurrent: () => true,
        surfaceReady: (ready) => native.events.add('visible:$ready'),
        pause: () async {},
        open: (_) async {},
        resume: () async {},
        stop: () async => throw StateError('synthetic stop failure'),
        frameBarrier: () async => throw TimeoutException('synthetic compositor timeout'));
    await expectLater(load, throwsStateError);
    expect(native.events, ['visible:false']);
  });

  test('pre-emitted load readiness completes once without waiting for another event or triggering retry', () async {
    final duration = StreamController<Object?>.broadcast();
    final buffering = StreamController<Object?>.broadcast();
    addTearDown(duration.close);
    addTearDown(buffering.close);
    var ready = false;
    var completions = 0;
    // Events were emitted during paused open/tonemap preparation.
    ready = true;
    duration.add(const Duration(seconds: 120));
    buffering.add(false);
    final latch = MpvLoadReadiness(isCurrent: () => true, isReady: () => ready, onReady: () => completions++);
    latch.observe([duration.stream, buffering.stream]);
    expect(completions, 1);
    duration.add(const Duration(seconds: 120));
    await Future<void>.delayed(Duration.zero);
    expect(completions, 1);
  });

  test('cancelled readiness subscriptions cannot mark a replacement item ready', () async {
    final events = StreamController<Object?>.broadcast();
    addTearDown(events.close);
    var ready = false;
    var completions = 0;
    final latch = MpvLoadReadiness(isCurrent: () => true, isReady: () => ready, onReady: () => completions++);
    latch.observe([events.stream]);
    latch.cancel();
    ready = true;
    events.add(null);
    await Future<void>.delayed(Duration.zero);
    expect(completions, 0);
  });
}
