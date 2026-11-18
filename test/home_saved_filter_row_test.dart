import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:fladder/l10n/generated/app_localizations.dart';
import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/library_filters_model.dart';
import 'package:fladder/providers/connectivity_provider.dart';
import 'package:fladder/providers/home_saved_filters_provider.dart';
import 'package:fladder/routes/auto_router.gr.dart';
import 'package:fladder/screens/dashboard/dashboard_screen.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('retrying a failed home preset leaves the other row usable', (tester) async {
    final failure = Completer<List<ItemBaseModel>>();
    final recovery = Completer<List<ItemBaseModel>>();
    var failedRowRequests = 0;
    var otherRowRequests = 0;

    HomeSavedFilterRow row(String id) => HomeSavedFilterRow(
          key: ValueKey(id),
          filter: LibraryFiltersModel(id: id, name: id, isFavourite: false, showOnHome: true),
          contentPadding: EdgeInsets.zero,
          tvMode: false,
        );
    Finder inRow(String id, Finder matching) => find.descendant(of: find.byKey(ValueKey(id)), matching: matching);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          offlineStateProvider.overrideWithValue(false),
          homeSavedFilterPreviewProvider('first').overrideWith((_) {
            failedRowRequests++;
            return failedRowRequests == 1 ? failure.future : recovery.future;
          }),
          homeSavedFilterPreviewProvider('other').overrideWith((_) async {
            otherRowRequests++;
            return const <ItemBaseModel>[];
          }),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: Column(children: [row('first'), row('other')])),
        ),
      ),
    );

    failure.completeError(StateError('synthetic preview failure'));
    await tester.pumpAndSettle();
    final noPreview = AppLocalizations.of(tester.element(find.byType(Scaffold))).jmsSavedFilterNoPreview;
    final retry = inRow('first', find.text('Retry'));
    final otherTitle = inRow('other', find.byWidgetPredicate((widget) => widget is TextButton));
    expect(retry, findsOneWidget);
    expect(tester.widget<TextButton>(otherTitle).onPressed, isNotNull);
    expect(inRow('other', find.text(noPreview)), findsOneWidget);

    await tester.tap(retry);
    await tester.pump();
    expect(failedRowRequests, 2);
    expect(otherRowRequests, 1);
    expect(retry, findsNothing);
    expect(tester.widget<TextButton>(otherTitle).onPressed, isNotNull);

    recovery.complete(const <ItemBaseModel>[]);
    await tester.pumpAndSettle();
    expect(retry, findsNothing);
    expect(find.text(noPreview), findsNWidgets(2));
  });

  testWidgets('the home preset title opens the saved search with its real library scope', (tester) async {
    final filter = LibraryFiltersModel(
      id: 'saved-unwatched',
      name: 'Unwatched animation',
      ids: ['animation-library'],
      isFavourite: false,
      showOnHome: true,
    );
    LibrarySearchRouteArgs? opened;
    final router = RootStackRouter.build(routes: [
      NamedRouteDef(
        name: 'SavedFiltersHomeTest',
        path: '/',
        builder: (_, _) => Scaffold(
          body: HomeSavedFilterRow(filter: filter, contentPadding: EdgeInsets.zero, tvMode: false),
        ),
      ),
      NamedRouteDef(
        name: LibrarySearchRoute.name,
        path: '/saved-search',
        builder: (_, data) {
          opened = data.argsAs<LibrarySearchRouteArgs>();
          return const Scaffold();
        },
      ),
    ]);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          offlineStateProvider.overrideWithValue(false),
          homeSavedFilterPreviewProvider(filter.id).overrideWith((_) async => const <ItemBaseModel>[]),
        ],
        child: MaterialApp.router(
          routerConfig: router.config(),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(filter.name));
    await tester.pumpAndSettle();

    expect(opened?.savedFilterId, filter.id);
    expect(opened?.parentId, ['animation-library']);
  });
}
