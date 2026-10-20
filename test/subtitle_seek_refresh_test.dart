import 'dart:async';
import 'package:fladder/util/dual_subtitle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
      'same cue seek reads both texts even if the distinct stream sends no update',
      () async {
    final refresh = SubtitleSeekRefresh();
    SubtitleTextPair? visible;
    refresh.begin();
    await refresh.onSeekingChanged(
        'no',
        () async => const SubtitleTextPair(primary: 'same', secondary: 'cue'),
        (text) => visible = text);
    expect(visible?.primary, 'same');
    expect(visible?.secondary, 'cue');
  });

  test('seeking and duplicate completion events do not cause repeated reads',
      () async {
    final refresh = SubtitleSeekRefresh();
    var reads = 0;
    Future<SubtitleTextPair> read() async {
      reads++;
      return const SubtitleTextPair();
    }

    refresh.begin();
    await refresh.onSeekingChanged('yes', read, (_) {});
    expect(reads, 0);
    await refresh.onSeekingChanged('no', read, (_) {});
    await refresh.onSeekingChanged('no', read, (_) {});
    expect(reads, 1);
  });

  test(
      'a newer seek prevents an older asynchronous read from filling stale cues',
      () async {
    final refresh = SubtitleSeekRefresh();
    final oldRead = Completer<SubtitleTextPair>();
    final visible = <SubtitleTextPair>[];
    refresh.begin();
    final old =
        refresh.onSeekingChanged('no', () => oldRead.future, visible.add);
    refresh.begin();
    await refresh.onSeekingChanged(
        'no',
        () async => const SubtitleTextPair(primary: 'new', secondary: 'next'),
        visible.add);
    oldRead
        .complete(const SubtitleTextPair(primary: 'old', secondary: 'stale'));
    await old;
    expect(visible.map((text) => text.primary), ['new']);
    expect(visible.single.secondary, 'next');
  });

  test('changing video cancels pending and already running seek refreshes',
      () async {
    final refresh = SubtitleSeekRefresh();
    final pending = Completer<SubtitleTextPair>();
    final visible = <SubtitleTextPair>[];
    refresh.begin();
    final read =
        refresh.onSeekingChanged('no', () => pending.future, visible.add);
    refresh.cancel();
    pending.complete(const SubtitleTextPair(primary: 'previous video'));
    await read;
    await refresh.onSeekingChanged('no',
        () async => const SubtitleTextPair(primary: 'unexpected'), visible.add);
    expect(visible, isEmpty);
  });

  test('a seek into a subtitle gap clears both previously visible cue slots',
      () async {
    final refresh = SubtitleSeekRefresh();
    var visible = const SubtitleTextPair(
        primary: 'old primary', secondary: 'old secondary');
    refresh.begin();
    await refresh.onSeekingChanged(
        'no', () async => const SubtitleTextPair(), (text) => visible = text);
    expect(visible.primary, isEmpty);
    expect(visible.secondary, isEmpty);
  });
}
