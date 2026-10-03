import 'dart:async';

import 'package:fladder/l10n/generated/app_localizations.dart';
import 'package:fladder/screens/shared/default_title_bar.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:window_manager/window_manager.dart';

void main() {
  const channel = MethodChannel('window_manager');
  final variant = TargetPlatformVariant.only(TargetPlatform.windows);

  Future<void> pumpTitleBar(WidgetTester tester) async {
    await tester.pumpWidget(ProviderScope(
      child: AdaptiveLayoutBuilder(
        child: (_) => const MaterialApp(
          locale: Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: DefaultTitleBar(label: 'Synthetic window')),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  void windowStateEvent(bool maximized) {
    for (final listener in windowManager.listeners) {
      if (maximized) {
        listener.onWindowMaximize();
      } else {
        listener.onWindowUnmaximize();
      }
    }
  }

  testWidgets('maximize and restore use distinct square icons and actual state',
      (tester) async {
    var maximized = false;
    final commands = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      switch (call.method) {
        case 'isMaximized':
          return maximized;
        case 'isMinimized':
        case 'isFullScreen':
          return false;
        case 'maximize':
          commands.add(call.method);
          maximized = true;
          windowStateEvent(true);
          return null;
        case 'unmaximize':
          commands.add(call.method);
          maximized = false;
          windowStateEvent(false);
          return null;
        default:
          throw StateError('Unexpected window method ${call.method}');
      }
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await pumpTitleBar(tester);
    expect(find.byIcon(Icons.crop_square_rounded), findsOneWidget);
    expect(find.byIcon(Icons.maximize_rounded), findsNothing);
    await tester.tap(find.byKey(const Key('jms-window-maximize')));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.filter_none_rounded), findsOneWidget);
    expect(find.byIcon(Icons.crop_square_rounded), findsNothing);
    await tester.tap(find.byKey(const Key('jms-window-maximize')));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.crop_square_rounded), findsOneWidget);
    expect(commands, ['maximize', 'unmaximize']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: variant);

  testWidgets('OS maximize events update the icon without a button click',
      (tester) async {
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => false);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await pumpTitleBar(tester);
    windowStateEvent(true);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.filter_none_rounded), findsOneWidget);
    windowStateEvent(false);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.crop_square_rounded), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: variant);

  testWidgets('a late initial query cannot overwrite a newer window event',
      (tester) async {
    final initialState = Completer<bool>();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async =>
            call.method == 'isMaximized' ? initialState.future : false);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await pumpTitleBar(tester);
    windowStateEvent(true);
    initialState.complete(false);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.filter_none_rounded), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: variant);
}
