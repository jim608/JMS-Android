import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fladder/providers/update_provider.dart';
import 'package:fladder/screens/settings/widgets/settings_update_information.dart';

void main() {
  testWidgets(
      'Web does not construct the native updater or display update controls',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        updateProvider.overrideWith(
            (ref) => throw StateError('Web must not initialize updater'))
      ],
      child: MaterialApp(home: Consumer(builder: (context, ref, child) {
        expect(ref.watch(hasNewUpdateProvider), isFalse);
        return const SettingsUpdateInformation();
      })),
    ));
    expect(find.byType(SwitchListTile), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
    expect(tester.takeException(), isNull);
  }, skip: !kIsWeb);
}
