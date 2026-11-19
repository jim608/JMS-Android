import 'package:fladder/localization_delegates.dart';
import 'package:fladder/models/items/media_streams_model.dart';
import 'package:fladder/providers/settings/home_settings_provider.dart';
import 'package:fladder/screens/details_screens/components/media_stream_information.dart';
import 'package:fladder/screens/details_screens/components/overview_header.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout.dart';
import 'package:fladder/util/adaptive_layout/adaptive_layout_model.dart';
import 'package:fladder/util/localization_helper.dart';
import 'package:fladder/util/poster_defaults.dart';
import 'package:fladder/widgets/shared/enum_selection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  for (final classic in [false, true]) {
    testWidgets('detail stream choices stay usable on a narrow screen, classic=$classic', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 850);
      addTearDown(tester.view.reset);
      var streams = MediaStreamsModel(
        defaultAudioStreamIndex: 2,
        versionStreams: [
          VersionStreamModel(
            name: '院線版',
            index: 0,
            defaultAudioStreamIndex: 2,
            defaultSubStreamIndex: -1,
            videoStreams: [],
            audioStreams: [AudioStreamModel.no(index: 2, displayTitle: '華語環繞聲')],
            subStreams: [SubStreamModel.no(index: 7, displayTitle: '繁體中文')],
          ),
          VersionStreamModel(
            name: '默片修復版',
            index: 1,
            defaultAudioStreamIndex: null,
            defaultSubStreamIndex: null,
            videoStreams: [],
            audioStreams: [],
            subStreams: [],
          ),
        ],
      );
      const locale = Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [classicInterfaceProvider.overrideWithValue(classic)],
          child: MaterialApp(
            locale: locale,
            supportedLocales: const [locale],
            localizationsDelegates: FladderLocalizations.localizationsDelegates,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)),
              child: AdaptiveLayout(
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
                child: child!,
              ),
            ),
            home: Scaffold(
              body: ListView(
                children: [
                  StatefulBuilder(
                    builder: (context, setState) => OverviewHeader(
                      name: '曙光',
                      minHeight: 0,
                      mediaStreamHelper: MediaStreamHelper(
                        mediaStream: streams,
                        onItemChanged: (value) => setState(() => streams = value),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final options = find.byWidgetPredicate((widget) => widget is EnumBox);
      final labels = tester.element(find.byType(OverviewHeader)).localized;
      expect(options, findsNWidgets(3));
      expect(find.text(labels.subtitles), classic ? findsNothing : findsOneWidget);
      if (!classic) {
        final rects = [for (final option in options.evaluate()) tester.getRect(find.byWidget(option.widget))];
        expect(rects.last.top, greaterThan(rects.first.top));
        for (final rect in rects) {
          expect(rect.height, greaterThanOrEqualTo(48));
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(320));
        }
        expect(find.text(labels.off), findsOneWidget);
      }
      await tester.tap(options.last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('繁體中文').last);
      await tester.pumpAndSettle();
      expect(streams.defaultSubStreamIndex, 7);
      expect(streams.defaultAudioStreamIndex, 2);
      expect(find.text('繁體中文'), findsOneWidget);
      await tester.tap(options.first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('默片修復版').last);
      await tester.pumpAndSettle();
      expect(streams.versionStreamIndex, 1);
      expect(options, findsNWidgets(classic ? 3 : 1));
      if (!classic) expect(find.text('默片修復版'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
