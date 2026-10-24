import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/l10n/generated/app_localizations.dart';
import 'package:fladder/routes/nested_details_screen.dart';
import 'package:fladder/screens/shared/detail_load_state.dart';

Widget host(Widget child) => ProviderScope(
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: child),
      ),
    );

void main() {
  testWidgets('loading keeps a keyboard reachable Back action', (tester) async {
    var backs = 0;
    await tester.pumpWidget(host(DetailLoadState(
      loading: true,
      onBack: () => backs++,
    )));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Back'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(backs, 1);
  });

  testWidgets('error offers retry and Back without transport details',
      (tester) async {
    var retries = 0;
    var backs = 0;
    await tester.pumpWidget(host(DetailLoadState(
      loading: false,
      onBack: () => backs++,
      onRetry: () => retries++,
    )));
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Retry'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(retries, 1);
    await tester.tap(find.text('Back'));
    expect(backs, 1);
  });

  testWidgets(
      'missing item route stays actionable instead of blank or silent redirect',
      (tester) async {
    await tester.pumpWidget(host(const DetailsScreen()));
    await tester.pumpAndSettle();
    expect(find.byType(DetailLoadState), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Back'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
