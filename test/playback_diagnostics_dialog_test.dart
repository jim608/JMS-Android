import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/l10n/generated/app_localizations.dart';
import 'package:fladder/screens/shared/playback_diagnostics_dialog.dart';

class _Picker extends FilePicker {
  String? result;
  Object? error;
  int calls = 0;
  Uint8List? exportedBytes;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    calls++;
    exportedBytes = bytes;
    expect(initialDirectory, isNull);
    expect(fileName, 'JMS-playback-diagnostics.txt');
    expect(type, FileType.custom);
    expect(allowedExtensions, ['txt']);
    if (error != null) throw error!;
    return result;
  }
}

Widget _app() => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      theme: ThemeData(visualDensity: VisualDensity.compact),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showPlaybackDiagnostics(context),
            child: const Text('Open diagnostics'),
          ),
        ),
      ),
    );

String _preview(WidgetTester tester) => tester
    .widget<SelectableText>(
        find.byKey(const ValueKey('playback-diagnostics-preview')))
    .data!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Picker picker;
  late List<String> copied;

  setUp(() {
    picker = _Picker();
    FilePicker.platform = picker;
    copied = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets(
      'opening exports nothing; Copy is keyboard reachable and targets stay 48px',
      (tester) async {
    await tester.pumpWidget(_app());
    await tester.tap(find.text('Open diagnostics'));
    await tester.pumpAndSettle();
    final report = _preview(tester);
    expect(report, isNotEmpty);
    expect(copied, isEmpty);
    expect(picker.calls, 0);
    for (final label in ['Copy', 'Save', 'Close']) {
      final target = find
          .ancestor(
            of: find.text(label),
            matching: find.byWidgetPredicate((widget) => widget is TextButton),
          )
          .first;
      expect(tester.getSize(target).height, greaterThanOrEqualTo(48));
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(copied, [report]);
    expect(picker.calls, 0);
    expect(find.text('Copied to clipboard'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets(
      'save is explicit, passes only preview bytes, and cancel is silent',
      (tester) async {
    await tester.pumpWidget(_app());
    await tester.tap(find.text('Open diagnostics'));
    await tester.pumpAndSettle();
    final report = _preview(tester);
    expect(picker.calls, 0);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(picker.calls, 1);
    expect(utf8.decode(picker.exportedBytes!), report);
    expect(copied, isEmpty);
    expect(find.text('Saved'), findsNothing);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('save failure shows a generic message and permits retry',
      (tester) async {
    picker.error = StateError('synthetic private exception must stay hidden');
    await tester.pumpWidget(_app());
    await tester.tap(find.text('Open diagnostics'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('synthetic private exception'), findsNothing);
    expect(tester.takeException(), isNull);
    picker.error = null;
    picker.result = '/synthetic/JMS-playback-diagnostics.txt';
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(picker.calls, 2);
    expect(find.text('Saved'), findsOneWidget);
  });
}
