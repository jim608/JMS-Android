import 'dart:async';

import 'package:fladder/util/subtitle_replacement.dart';
import 'package:fladder/util/subtitle_selection_failure.dart';
import 'package:fladder/util/subtitle_timeline.dart';
import 'package:flutter_test/flutter_test.dart';

class _Track {
  _Track(this.name);
  final String name;
  int disposals = 0;
}

void main() {
  late SubtitleReplacement<_Track> replacement;
  late List<String> activations;

  Future<void> apply(_Track track) => replacement.replace(
        prepare: (_) async => track,
        load: (_, __) async {},
        isCurrent: () => true,
      );

  setUp(() {
    activations = [];
    replacement = SubtitleReplacement<_Track>(
      activate: (track) => activations.add(track.name),
      dispose: (track) => track.disposals++,
    );
  });

  for (final failure in ['fetch', 'parse']) {
    test('$failure failure preserves the applied subtitle', () async {
      final previous = _Track('Traditional');
      await apply(previous);
      await expectLater(
        replacement.replace(
          prepare: (_) async {
            if (failure == 'parse') {
              browserSubtitleVtt('<html>Invalid subtitle response</html>');
            }
            throw StateError('Request failed');
          },
          load: (_, __) async {},
          isCurrent: () => true,
        ),
        throwsA(failure == 'parse' ? isFormatException : isStateError),
      );
      expect(replacement.current, same(previous));
      expect(previous.disposals, 0);
      expect(activations, ['Traditional']);
    });
  }

  for (final reason in ['missing track', 'track error', 'load timeout']) {
    test('$reason disposes candidate without disabling old subtitles',
        () async {
      final previous = _Track('Traditional');
      final candidate = _Track('Other');
      await apply(previous);
      await expectLater(
        replacement.replace(
          prepare: (_) async => candidate,
          load: (_, __) async => throw const SubtitleSelectionFailure(
              SubtitleSelectionFailureReason.unavailable),
          isCurrent: () => true,
        ),
        throwsA(isA<SubtitleSelectionFailure>()),
      );
      expect(replacement.current, same(previous));
      expect(previous.disposals, 0);
      expect(candidate.disposals, 1);
      expect(activations, ['Traditional']);
    });
  }

  test('replacement applies only after candidate load then releases old track',
      () async {
    final previous = _Track('Traditional');
    final candidate = _Track('Other');
    final loaded = Completer<void>();
    await apply(previous);
    final pending = replacement.replace(
      prepare: (_) async => candidate,
      load: (_, __) => loaded.future,
      isCurrent: () => true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(replacement.current, same(previous));
    expect(previous.disposals, 0);
    loaded.complete();
    await pending;
    expect(replacement.current, same(candidate));
    expect(previous.disposals, 1);
    expect(candidate.disposals, 0);
    expect(activations, ['Traditional', 'Other']);
  });

  test('cancelled selection retains old track and a later retry can succeed',
      () async {
    final previous = _Track('Traditional');
    final cancelled = _Track('Cancelled');
    final retry = _Track('Retry');
    final loaded = Completer<void>();
    await apply(previous);
    final pending = replacement.replace(
      prepare: (_) async => cancelled,
      load: (_, __) => loaded.future,
      isCurrent: () => true,
    );
    final rejected =
        expectLater(pending, throwsA(isA<SubtitleSelectionFailure>()));
    await Future<void>.delayed(Duration.zero);
    replacement.cancelPending();
    loaded.complete();
    await rejected;
    expect(replacement.current, same(previous));
    expect(cancelled.disposals, 1);
    expect(previous.disposals, 0);
    await apply(retry);
    expect(replacement.current, same(retry));
    expect(previous.disposals, 1);
  });

  test('explicit Off clears applied track and cancels a pending candidate',
      () async {
    final previous = _Track('Traditional');
    final candidate = _Track('Late');
    final loaded = Completer<void>();
    await apply(previous);
    final pending = replacement.replace(
      prepare: (_) async => candidate,
      load: (_, __) => loaded.future,
      isCurrent: () => true,
    );
    final rejected =
        expectLater(pending, throwsA(isA<SubtitleSelectionFailure>()));
    await Future<void>.delayed(Duration.zero);
    replacement.clear();
    loaded.complete();
    await rejected;
    expect(replacement.current, isNull);
    expect(previous.disposals, 1);
    expect(candidate.disposals, 1);
    expect(activations, ['Traditional']);
  });

  test('late old-session fetch cannot overwrite a loaded new-session track',
      () async {
    final oldCandidate = _Track('Old media');
    final newCandidate = _Track('New media');
    final fetched = Completer<_Track>();
    final pending = replacement.replace(
      prepare: (_) => fetched.future,
      load: (_, __) async {},
      isCurrent: () => true,
    );
    final rejected =
        expectLater(pending, throwsA(isA<SubtitleSelectionFailure>()));
    replacement.clear();
    await apply(newCandidate);
    fetched.complete(oldCandidate);
    await rejected;
    expect(replacement.current, same(newCandidate));
    expect(oldCandidate.disposals, 1);
    expect(newCandidate.disposals, 0);
    expect(activations, ['New media']);
  });

  test('external session identity must still match after track load', () async {
    final previous = _Track('Traditional');
    final candidate = _Track('Stale');
    var current = true;
    final loaded = Completer<void>();
    await apply(previous);
    final pending = replacement.replace(
      prepare: (_) async => candidate,
      load: (_, __) => loaded.future,
      isCurrent: () => current,
    );
    final rejected =
        expectLater(pending, throwsA(isA<SubtitleSelectionFailure>()));
    await Future<void>.delayed(Duration.zero);
    current = false;
    loaded.complete();
    await rejected;
    expect(replacement.current, same(previous));
    expect(candidate.disposals, 1);
    expect(activations, ['Traditional']);
  });

  test('new-session clear during activation cannot resurrect a stale track',
      () async {
    final previous = _Track('Traditional');
    final candidate = _Track('New source');
    replacement = SubtitleReplacement<_Track>(
      activate: (track) {
        activations.add(track.name);
        if (identical(track, candidate)) replacement.clear();
      },
      dispose: (track) => track.disposals++,
    );
    await apply(previous);
    await expectLater(
        apply(candidate), throwsA(isA<SubtitleSelectionFailure>()));
    expect(replacement.current, isNull);
    expect(previous.disposals, 1);
    expect(candidate.disposals, 1);
  });
}
