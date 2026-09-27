import 'dart:io';
import 'dart:ui' as ui;

import 'package:fladder/screens/shared/fladder_logo.dart';
import 'package:fladder/util/application_info.dart';
import 'package:fladder/util/brand.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the product logo renders JMS on light and dark backgrounds', (tester) async {
    final fontLoader = FontLoader('Rubik')..addFont(rootBundle.load('assets/fonts/rubik/Rubik-VariableFont_wght.ttf'));
    await fontLoader.load();
    final boundaryKey = GlobalKey();
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          applicationInfoProvider.overrideWith((ref) => ApplicationInfo(
                name: Brand.name,
                version: '0.11.1-jms.1',
                buildNumber: '1',
                platform: TargetPlatform.android,
              )),
        ],
        child: MaterialApp(
          theme: ThemeData(brightness: brightness, colorSchemeSeed: Colors.teal, fontFamily: 'Rubik'),
          home: RepaintBoundary(key: boundaryKey, child: const Scaffold(body: Center(child: FladderLogo()))),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('JMS'), findsOneWidget);
      expect(find.textContaining('Fladder'), findsNothing);
      await tester.runAsync(() async {
        final boundary = boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final screenshot = await boundary.toImage();
        try {
          final bytes = await screenshot.toByteData(format: ui.ImageByteFormat.png);
          final output = File('artifacts/checks/logo-${brightness.name}.png');
          await output.parent.create(recursive: true);
          await output.writeAsBytes(bytes!.buffer.asUint8List());
        } finally {
          screenshot.dispose();
        }
      });
    }
  });
}
