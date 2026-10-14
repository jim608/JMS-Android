@TestOn('browser')
library;

import 'package:fladder/util/ambient_frame_capture.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' as mpv;
import 'package:web/web.dart' as web;

mpv.WebPlayer _player() {
  final player = mpv.WebPlayer(configuration: const mpv.PlayerConfiguration());
  addTearDown(player.dispose);
  return player;
}

web.HTMLVideoElement _element(mpv.WebPlayer player) =>
    (player as dynamic).element as web.HTMLVideoElement;

void main() {
  test('anonymous capture is configured only for the specified player', () {
    final first = _player();
    final second = _player();
    configureAmbientVideoCapture(first);
    expect(_element(first).getAttribute('crossorigin'), 'anonymous');
    expect(_element(second).getAttribute('crossorigin'), isNull);
    expect(_element(first).currentSrc, isEmpty);
    expect(_element(second).currentSrc, isEmpty);
  });

  for (final configured in ['', 'anonymous', 'use-credentials']) {
    test('existing crossorigin "$configured" is preserved', () {
      final player = _player();
      _element(player).setAttribute('crossorigin', configured);
      configureAmbientVideoCapture(player);
      expect(_element(player).getAttribute('crossorigin'), configured);
    });
  }

  test('capture without a ready frame never configures or changes media',
      () async {
    final player = _player();
    final element = _element(player);
    expect(await captureAmbientVideoFrame(player, 192), isNull);
    expect(element.getAttribute('crossorigin'), isNull);
    expect(element.currentSrc, isEmpty);
    expect(element.srcObject, isNull);
  });

  test('unsupported platforms do not inspect any browser media', () async {
    configureAmbientVideoCapture(null);
    configureAmbientVideoCapture(Object());
    expect(await captureAmbientVideoFrame(null, 192), isNull);
    expect(await captureAmbientVideoFrame(Object(), 192), isNull);
  });

  test('disposed players cannot be configured or captured', () async {
    final player =
        mpv.WebPlayer(configuration: const mpv.PlayerConfiguration());
    final element = _element(player);
    await player.dispose();
    configureAmbientVideoCapture(player);
    expect(await captureAmbientVideoFrame(player, 192), isNull);
    expect(element.getAttribute('crossorigin'), isNull);
  });

  test('invalid capture bounds remain visible as programmer errors', () async {
    final player = _player();
    for (final bound in [0.0, -1.0, double.nan, double.infinity]) {
      await expectLater(
          captureAmbientVideoFrame(player, bound), throwsArgumentError);
    }
  });
}
