import 'dart:ui' show KeyEventDeviceType;

import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout_model.dart';
import 'package:fladder/util/poster_defaults.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
      'controller selects single-pane Deck layout and touch restores the normal layout',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    AdaptiveLayoutModel? actual;
    var taps = 0;
    await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
            home: AdaptiveLayoutBuilder(
      adaptiveLayout: const AdaptiveLayoutModel(
        viewSize: ViewSize.tablet,
        layoutMode: LayoutMode.dual,
        inputDevice: InputDevice.pointer,
        platform: TargetPlatform.linux,
        isDesktop: true,
        posterDefaults: PosterDefaults(size: 350, ratio: 0.55),
        controller: {},
        sideBarWidth: 0,
        topBarHeight: 0,
        statusBarHeight: 0,
      ),
      child: (context) {
        actual = AdaptiveLayout.of(context);
        return Scaffold(
            body: Center(
                child: TextButton(
                    onPressed: () {
                      taps++;
                    },
                    child: const Text('Touch'))));
      },
    ))));
    await tester.pump();
    expect(actual!.inputDevice, InputDevice.pointer);
    expect(actual!.layoutMode, LayoutMode.dual);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(actual!.controllerMode, isFalse);
    expect(actual!.layoutMode, LayoutMode.dual);
    // The Android bridge identifies its directions as a physical d-pad.
    HardwareKeyboard.instance.handleKeyEvent(const KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.arrowDown,
      logicalKey: LogicalKeyboardKey.arrowDown,
      timeStamp: Duration.zero,
      deviceType: KeyEventDeviceType.directionalPad,
    ));
    HardwareKeyboard.instance.handleKeyEvent(const KeyUpEvent(
      physicalKey: PhysicalKeyboardKey.arrowDown,
      logicalKey: LogicalKeyboardKey.arrowDown,
      timeStamp: Duration.zero,
      deviceType: KeyEventDeviceType.directionalPad,
    ));
    await tester.pump();
    expect(actual!.inputDevice, InputDevice.dPad);
    expect(actual!.controllerMode, isTrue);
    expect(actual!.layoutMode, LayoutMode.single);
    expect(actual!.viewSize, ViewSize.tablet);
    expect(actual!.posterDefaults.size, 280);
    tester.view.physicalSize = const Size(853, 533);
    await tester.pump();
    expect(actual!.posterDefaults.size, 240);
    tester.view.physicalSize = const Size(1280, 800);
    await tester.pump();
    await tester.tap(find.text('Touch'));
    await tester.pump();
    expect(taps, 1);
    expect(actual!.inputDevice, InputDevice.touch);
    expect(actual!.layoutMode, LayoutMode.dual);
    expect(actual!.posterDefaults.size, 350);
  }, variant: const TargetPlatformVariant({TargetPlatform.linux}));
}
