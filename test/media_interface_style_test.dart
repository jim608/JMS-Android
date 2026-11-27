import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_plus/iconsax_plus.dart';
import 'package:material_ui/material_ui.dart';
import 'package:transparent_image/transparent_image.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart' as jelly;
import 'package:fladder/localization_delegates.dart';
import 'package:fladder/models/items/images_models.dart';
import 'package:fladder/models/items/movie_model.dart';
import 'package:fladder/providers/settings/home_settings_provider.dart';
import 'package:fladder/screens/shared/media/components/media_header.dart';
import 'package:fladder/screens/shared/media/components/media_play_button.dart';
import 'package:fladder/screens/shared/media/poster_widget.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout_model.dart';
import 'package:fladder/util/poster_defaults.dart';
import 'package:fladder/util/localization_helper.dart';
import 'package:fladder/widgets/shared/clickable_text.dart';

class _MemoryLogo extends ImageData {
  @override
  final imageProvider = MemoryImage(kTransparentImage);
}

void main() {
  testWidgets('modern media header shows the title until its logo is ready', (tester) async {
    final logo = _MemoryLogo();
    await tester.pumpWidget(ProviderScope(
      overrides: [classicInterfaceProvider.overrideWithValue(false)],
      child: MaterialApp(home: Scaffold(body: MediaHeader(name: '海邊電影院', logo: logo))),
    ));
    expect(find.text('海邊電影院'), findsOneWidget);
    final context = tester.element(find.byType(MediaHeader));
    await tester.runAsync(() => precacheImage(logo.imageProvider, context));
    await tester.pump();
    expect(find.text('海邊電影院'), findsNothing);
    expect(find.bySemanticsLabel('海邊電影院'), findsOneWidget);
  });

  testWidgets('a wrapped classic title remains completely visible with large text', (tester) async {
    const title = '海邊電影院';
    await tester.pumpWidget(ProviderScope(
      overrides: [classicInterfaceProvider.overrideWithValue(true)],
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: const Scaffold(
          body: SingleChildScrollView(child: SizedBox(width: 320, child: MediaHeader(name: title, logo: null))),
        ),
      ),
    ));
    final text = tester.state<EditableTextState>(find.byType(EditableText)).renderEditable;
    final last = text.getLocalRectForCaret(const TextPosition(offset: title.length));
    expect(last.bottom, lessThanOrEqualTo(text.size.height + 1));
  });

  for (final classic in [false, true]) {
    testWidgets('poster captions and detail playback respect classic=$classic', (tester) async {
      final calls = <bool>[];
      final film = MovieModel.fromBaseDto(
        const jelly.BaseItemDto(
          id: 'coast',
          name: 'Coast',
          productionYear: 2026,
          userData: jelly.UserItemDataDto(playedPercentage: 38),
        ),
        null,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [classicInterfaceProvider.overrideWithValue(classic)],
          child: MaterialApp(
            localizationsDelegates: FladderLocalizations.localizationsDelegates,
            home: AdaptiveLayout(
              data: const AdaptiveLayoutModel(
                viewSize: ViewSize.phone,
                layoutMode: LayoutMode.single,
                inputDevice: InputDevice.touch,
                platform: TargetPlatform.android,
                isDesktop: false,
                posterDefaults: PosterDefaults(size: 240, ratio: .55),
                controller: {},
                sideBarWidth: 0,
                topBarHeight: 0,
                statusBarHeight: 0,
              ),
              child: Scaffold(
                body: ListView(
                  children: [
                    Center(
                      child: SizedBox(width: 148, child: PosterWidget(poster: film)),
                    ),
                    const Center(
                      child: SizedBox(width: 320, child: MediaHeader(name: 'Coast', logo: null)),
                    ),
                    MediaPlayButton(item: film, onPressed: calls.add),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final labels = tester.widgetList<ClickableText>(find.byType(ClickableText)).toList();
      expect(labels.map((label) => label.text), classic ? ['Coast', '2026', ''] : ['Coast', '2026']);
      expect(labels.first.maxLines, classic ? 1 : 2);
      final heading = tester.widget<SelectableText>(
        find.descendant(of: find.byType(MediaHeader), matching: find.byType(SelectableText)),
      );
      expect(heading.style!.fontSize, closeTo(classic ? 35.2 : 28.8, 0.01));
      final controls = find.byType(MediaPlayButton);
      final strings = tester.element(controls).localized;
      if (!classic) {
        final resumeLabel = find.descendant(of: controls, matching: find.text(strings.resumeVideo));
        expect(tester.widget<Text>(resumeLabel).semanticsLabel, strings.resume(film.name));
      }
      final play = find.descendant(of: controls, matching: find.byIcon(IconsaxPlusBold.play)).first;
      final restart = find.descendant(of: controls, matching: find.byIcon(IconsaxPlusBold.refresh));
      await tester.tapAt(tester.getCenter(play));
      await tester.tapAt(tester.getCenter(restart));
      expect(calls, [false, true]);
      expect(tester.takeException(), isNull);
    });
  }
}
