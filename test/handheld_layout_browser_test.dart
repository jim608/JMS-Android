@TestOn('browser')
library;

import 'dart:convert';
import 'dart:ui' show KeyEventDeviceType;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fladder/models/settings/arguments_model.dart' show leanBackMode;
import 'package:fladder/models/settings/client_settings_model.dart';
import 'package:fladder/providers/settings/client_settings_provider.dart';
import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout_model.dart';
import 'package:fladder/util/input_detector.dart';
import 'package:fladder/util/poster_defaults.dart';

void main() {
  testWidgets('Linux browser ignores native handheld preference and retains dynamic controller layout', (tester) async {
    expect(kIsWeb, isTrue, reason: 'This regression must execute in a real browser compilation.');
    final priorPlatform = debugDefaultTargetPlatformOverride;
    final priorLeanBackMode = leanBackMode;
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;

    try {
      final saved = ClientSettingsModel.defaultModel().copyWith(
        handheldModePreference: HandheldModePreference.handheld,
      );
      SharedPreferences.setMockInitialValues({'clientSettings': jsonEncode(saved.toJson())});
      final preferences = await SharedPreferences.getInstance();
      final restored = ClientSettingsModel.fromJson(
        jsonDecode(preferences.getString('clientSettings')!) as Map<String, dynamic>,
      );
      expect(restored.handheldModePreference, HandheldModePreference.handheld);
      AdaptiveLayoutModel? actual;
      var pointerTaps = 0;
      await tester.pumpWidget(ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          sharedUtilityProvider.overrideWith((ref) => SharedUtility(ref: ref, sharedPreferences: preferences)),
          clientSettingsProvider.overrideWith((ref) => ClientSettingsNotifier(ref)..applyRestoredSettings(restored)),
        ],
        child: MaterialApp(
          home: AdaptiveLayoutBuilder(
            adaptiveLayout: const AdaptiveLayoutModel(
              viewSize: ViewSize.tablet,
              layoutMode: LayoutMode.dual,
              inputDevice: InputDevice.pointer,
              platform: TargetPlatform.linux,
              isDesktop: false,
              posterDefaults: PosterDefaults(size: 350, ratio: 0.55),
              controller: {},
              sideBarWidth: 0,
              topBarHeight: 0,
              statusBarHeight: 0,
            ),
            child: (context) {
              actual = AdaptiveLayout.of(context);
              return Scaffold(
                body: Center(child: TextButton(onPressed: () => pointerTaps++, child: const Text('Pointer control'))),
              );
            },
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // A restored native preference must not force either browser layout or
      // controller mode, even when the browser reports Linux as its platform.
      expect(defaultTargetPlatform, TargetPlatform.linux);
      expect(actual!.platform, TargetPlatform.linux);
      expect(actual!.controllerMode, isFalse);
      expect(actual!.inputDevice, InputDevice.pointer);
      expect(actual!.layoutMode, LayoutMode.dual);
      expect(actual!.posterDefaults.size, 350);

      // Browser gamepad input still uses the existing controller + viewport
      // rule. The native preference does not disable or permanently force it.
      HardwareKeyboard.instance.handleKeyEvent(const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.arrowDown,
        logicalKey: LogicalKeyboardKey.arrowDown,
        timeStamp: Duration.zero,
        deviceType: KeyEventDeviceType.gamepad,
      ));
      HardwareKeyboard.instance.handleKeyEvent(const KeyUpEvent(
        physicalKey: PhysicalKeyboardKey.arrowDown,
        logicalKey: LogicalKeyboardKey.arrowDown,
        timeStamp: Duration.zero,
        deviceType: KeyEventDeviceType.gamepad,
      ));
      await tester.pumpAndSettle();
      expect(actual!.controllerMode, isTrue);
      expect(actual!.inputDevice, InputDevice.dPad);
      expect(actual!.layoutMode, LayoutMode.single);
      expect(actual!.posterDefaults.size, 280);

      tester.view.physicalSize = const Size(1920, 1080);
      await tester.pumpAndSettle();
      expect(actual!.layoutMode, LayoutMode.dual);
      expect(actual!.posterDefaults.size, 350);

      tester.view.physicalSize = const Size(1280, 800);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pointer control'));
      await tester.pumpAndSettle();
      expect(pointerTaps, 1);
      expect(actual!.controllerMode, isFalse);
      expect(actual!.layoutMode, LayoutMode.dual);
      expect(actual!.posterDefaults.size, 350);
      expect(tester.takeException(), isNull);
    } finally {
      try {
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        debugDefaultTargetPlatformOverride = priorPlatform;
        leanBackMode = priorLeanBackMode;
      }
    }
    expect(InputDetector.activeControllerMode, isNull);
  });
}
