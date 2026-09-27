import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fladder/screens/video_player/components/playback_diagnostics.dart';
import 'package:fladder/widgets/shared/ambient_blur.dart';

void main() {
  testWidgets('diagnostics has no floating launcher or collection before menu activation', (tester) async {
    final ambient = AmbientBlurDiagnostics();
    final composition = ValueNotifier(AmbientComposition.direct);
    await tester.pumpWidget(ProviderScope(child: MaterialApp(home: Stack(children: [
      PlaybackDiagnostics(ambient: ambient, composition: composition),
    ]))));
    await tester.pump(const Duration(seconds: 2));
    expect(find.byType(IconButton), findsNothing);
    expect(ambient.enabled, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    composition.dispose();
  });

  test('diagnostics visibility resets when playback consumers leave', () async {
    final container = ProviderContainer();
    final subscription = container.listen(playbackDiagnosticsVisibleProvider, (_, next) {});
    container.read(playbackDiagnosticsVisibleProvider.notifier).state = true;
    expect(container.read(playbackDiagnosticsVisibleProvider), isTrue);
    subscription.close();
    await container.pump();
    expect(container.read(playbackDiagnosticsVisibleProvider), isFalse);
    container.dispose();
  });
}
