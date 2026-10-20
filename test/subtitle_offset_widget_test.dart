import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/l10n/generated/app_localizations.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/screens/video_player/components/subtitle_offset_dialog.dart';
import 'package:fladder/util/input_handler.dart';
import 'package:fladder/util/subtitle_offset.dart';
import 'package:fladder/wrappers/media_control_wrapper.dart';

Future<void> _pumpControls(
  WidgetTester tester,
  SubtitleOffsetController controller, {
  bool primaryEnabled = true,
  bool secondaryEnabled = true,
  Locale locale = const Locale('en'),
  Size viewport = const Size(800, 900),
  double textScale = 1,
  bool dialog = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = viewport;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final controls = SubtitleOffsetControls(
    controller: controller,
    primaryEnabled: primaryEnabled,
    secondaryEnabled: secondaryEnabled,
  );
  await tester.pumpWidget(MaterialApp(
    locale: locale,
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: Scaffold(
      body: dialog
          ? AlertDialog(
              title: const Text('Subtitle timing'),
              content: SizedBox(
                  width: 440, child: SingleChildScrollView(child: controls)),
            )
          : SingleChildScrollView(
              child:
                  Padding(padding: const EdgeInsets.all(16), child: controls)),
    ),
  ));
  await tester.pumpAndSettle();
}

Finder _button(String slot, String action) =>
    find.byKey(Key('subtitle-offset-$slot-$action'));

Finder _input(String slot) => _button(slot, 'input');

String _inputText(WidgetTester tester, String slot) => tester
    .widget<EditableText>(
        find.descendant(of: _input(slot), matching: find.byType(EditableText)))
    .controller
    .text;

Future<void> _enterOffset(
    WidgetTester tester, String slot, String value) async {
  await tester.ensureVisible(_input(slot));
  await tester.enterText(_input(slot), value);
  await tester.pumpAndSettle();
}

Future<void> _submitOffset(WidgetTester tester) async {
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String slot, String action) async {
  await tester.ensureVisible(_button(slot, action));
  await tester.tap(_button(slot, action));
  await tester.pumpAndSettle();
}

class _PlayingMedia extends MediaControlsWrapper {
  _PlayingMedia(Ref ref, this.offsets) : super(ref: ref) {
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (playing) ticks++;
    });
  }

  final SubtitleOffsetController? offsets;
  late final Timer _clock;
  bool playing = true;
  int ticks = 0;
  int pauseCalls = 0;
  int playCalls = 0;
  int playOrPauseCalls = 0;

  @override
  SubtitleOffsetController? get subtitleOffsets => offsets;

  @override
  Future<void> pause() async {
    pauseCalls++;
    playing = false;
  }

  @override
  Future<void> play({bool userInitiated = true}) async {
    playCalls++;
    playing = true;
  }

  @override
  Future<void> playOrPause() async {
    playOrPauseCalls++;
    playing = !playing;
  }

  @override
  Future<void> dispose() async => _clock.cancel();
}

class _PlayingNotifier extends VideoPlayerNotifier {
  _PlayingNotifier(super.ref, SubtitleOffsetController? offsets) {
    state = _PlayingMedia(ref, offsets);
  }
}

class _RoutePushes extends NavigatorObserver {
  int pushes = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => pushes++;
}

class _EmbeddedPlayer extends ConsumerStatefulWidget {
  const _EmbeddedPlayer(
      {required this.onBackgroundTap, required this.onEscapedKey});

  final VoidCallback onBackgroundTap;
  final VoidCallback onEscapedKey;

  @override
  ConsumerState<_EmbeddedPlayer> createState() => _EmbeddedPlayerState();
}

class _EmbeddedPlayerState extends ConsumerState<_EmbeddedPlayer> {
  late final Timer _hideControls;
  late final MediaControlsWrapper _player;
  bool _toolbarVisible = true;

  @override
  void initState() {
    super.initState();
    _player = ref.read(videoPlayerProvider);
    _hideControls = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _toolbarVisible = false);
    });
  }

  @override
  void dispose() {
    _hideControls.cancel();
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(videoPlayerProvider);
    return InputHandler(
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          widget.onEscapedKey();
        }
        return KeyEventResult.ignored;
      },
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onBackgroundTap,
              onHorizontalDragDown: (_) => player.playOrPause(),
              child: const ColoredBox(color: Colors.black),
            ),
          ),
          if (_toolbarVisible)
            Align(
              alignment: Alignment.topLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SubtitleOffsetButton(),
                  IconButton(
                    key: const Key('fixture-subtitle-menu'),
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) =>
                          const SimpleDialog(children: [SubtitleOffsetTile()]),
                    ),
                    tooltip: 'Subtitle menu',
                    icon: const Icon(Icons.more_vert),
                  ),
                ],
              ),
            ),
          const SubtitleOffsetOverlay(),
        ],
      ),
    );
  }
}

class _EmbeddedFixture {
  _EmbeddedFixture({required this.controller}) {
    container = ProviderContainer(overrides: [
      videoPlayerProvider
          .overrideWith((ref) => _PlayingNotifier(ref, controller)),
    ]);
    player = container.read(videoPlayerProvider) as _PlayingMedia;
  }

  final SubtitleOffsetController? controller;
  late final ProviderContainer container;
  late final _PlayingMedia player;
  final routes = _RoutePushes();
  int backgroundTaps = 0;
  int escapedKeys = 0;

  Future<void> mount(
    WidgetTester tester, {
    Size viewport = const Size(1000, 800),
    double textScale = 1,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = viewport;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await tester.pump();
      controller?.dispose();
    });
    await tester.pumpWidget(UncontrolledProviderScope(
      key: ObjectKey(container),
      container: container,
      child: MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        navigatorObservers: [routes],
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: _EmbeddedPlayer(
            onBackgroundTap: () => backgroundTaps++,
            onEscapedKey: () => escapedKeys++,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  void expectStillPlaying() {
    expect(player.playing, isTrue);
    expect(player.pauseCalls, 0);
    expect(player.playCalls, 0);
    expect(player.playOrPauseCalls, 0);
    expect(backgroundTaps, 0);
  }
}

void main() {
  testWidgets('primary and secondary adjust and reset independently',
      (tester) async {
    final writes = <(String, String)>[];
    final controller = SubtitleOffsetController(
        write: (property, value) async => writes.add((property, value)));
    addTearDown(controller.dispose);
    await _pumpControls(tester, controller);

    await _tap(tester, 'primary', 'later');
    expect(controller.primary, const Duration(milliseconds: 10));
    expect(controller.secondary, Duration.zero);
    expect(find.text('+0.01 s'), findsOneWidget);

    await _tap(tester, 'secondary', 'earlier');
    expect(controller.primary, const Duration(milliseconds: 10));
    expect(controller.secondary, const Duration(milliseconds: -10));
    expect(find.text('-0.01 s'), findsOneWidget);

    await _tap(tester, 'primary', 'reset');
    expect(controller.primary, Duration.zero);
    expect(controller.secondary, const Duration(milliseconds: -10));
    await _tap(tester, 'secondary', 'reset');
    expect(controller.secondary, Duration.zero);
    expect(writes, [
      ('sub-delay', '0.010'),
      ('secondary-sub-delay', '-0.010'),
      ('sub-delay', '0.000'),
      ('secondary-sub-delay', '0.000'),
    ]);
  });

  testWidgets('signed hundredths apply only on submit or the apply button',
      (tester) async {
    final writes = <(String, String)>[];
    final controller = SubtitleOffsetController(
        write: (property, value) async => writes.add((property, value)));
    addTearDown(controller.dispose);
    await _pumpControls(tester, controller);

    await _enterOffset(tester, 'primary', '-');
    expect(writes, isEmpty);
    await _enterOffset(tester, 'primary', '-0.05');
    expect(writes, isEmpty);
    expect(controller.primary, Duration.zero);
    await _submitOffset(tester);
    expect(controller.primary, const Duration(milliseconds: -50));
    expect(_inputText(tester, 'primary'), '-0.05');

    await _enterOffset(tester, 'secondary', '0.01');
    expect(writes, [('sub-delay', '-0.050')]);
    await _tap(tester, 'secondary', 'apply');
    expect(controller.primary, const Duration(milliseconds: -50));
    expect(controller.secondary, const Duration(milliseconds: 10));
    expect(writes, [
      ('sub-delay', '-0.050'),
      ('secondary-sub-delay', '0.010'),
    ]);
  });

  testWidgets('invalid or out of range seconds never reach the engine',
      (tester) async {
    final writes = <(String, String)>[];
    final controller = SubtitleOffsetController(
        write: (property, value) async => writes.add((property, value)));
    addTearDown(controller.dispose);
    await _pumpControls(tester, controller, secondaryEnabled: false);

    for (final input in [
      '',
      '-',
      'abc',
      'NaN',
      'Infinity',
      '60.01',
      '-60.01',
      '0.001',
    ]) {
      await _enterOffset(tester, 'primary', input);
      await _submitOffset(tester);
      expect(writes, isEmpty, reason: 'Invalid input: $input');
      expect(controller.primary, Duration.zero);
    }

    await _enterOffset(tester, 'primary', '60.00');
    await _submitOffset(tester);
    await _enterOffset(tester, 'primary', '-60');
    await _submitOffset(tester);
    expect(writes, [('sub-delay', '60.000'), ('sub-delay', '-60.000')]);
    expect(controller.primary, -SubtitleOffsetController.limit);
  });

  testWidgets('slider previews its value and writes once when dragging ends',
      (tester) async {
    final writes = <(String, String)>[];
    final controller = SubtitleOffsetController(
        write: (property, value) async => writes.add((property, value)));
    addTearDown(controller.dispose);
    await _pumpControls(tester, controller, secondaryEnabled: false);
    final slider = _button('primary', 'slider');
    await tester.ensureVisible(slider);
    final gesture = await tester.startGesture(tester.getCenter(slider));
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    final preview = double.parse(_inputText(tester, 'primary'));
    expect(preview, isNot(0));
    expect(writes, isEmpty);
    expect(controller.primary, Duration.zero);
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();
    expect(writes, isEmpty);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(writes, hasLength(1));
    expect(controller.primary, isNot(Duration.zero));
    expect(controller.primary.inMilliseconds % 10, 0);
    expect(controller.primary.abs(),
        lessThanOrEqualTo(SubtitleOffsetController.limit));
    expect(double.parse(_inputText(tester, 'primary')),
        controller.primary.inMilliseconds / 1000);
  });

  testWidgets('fields follow confirmed changes, reset and media replacement',
      (tester) async {
    final controller = SubtitleOffsetController(write: (_, __) async {});
    addTearDown(controller.dispose);
    await _pumpControls(tester, controller);

    await _enterOffset(tester, 'primary', '0.05');
    await _submitOffset(tester);
    await _enterOffset(tester, 'secondary', '-0.02');
    await _submitOffset(tester);
    await _tap(tester, 'primary', 'reset');
    expect(double.parse(_inputText(tester, 'primary')), 0);
    expect(double.parse(_inputText(tester, 'secondary')), -0.02);

    await controller.setOffset(const Duration(milliseconds: 30));
    await tester.pumpAndSettle();
    expect(double.parse(_inputText(tester, 'primary')), 0.03);
    controller.clear();
    await tester.pumpAndSettle();
    expect(double.parse(_inputText(tester, 'primary')), 0);
    expect(double.parse(_inputText(tester, 'secondary')), 0);
  });

  testWidgets('failed numeric update restores confirmed fields and slider',
      (tester) async {
    var fail = false;
    final controller = SubtitleOffsetController(write: (_, __) async {
      if (fail) throw StateError('private native engine detail');
    });
    addTearDown(controller.dispose);
    await controller.setOffset(const Duration(milliseconds: 50));
    await _pumpControls(tester, controller, secondaryEnabled: false);

    fail = true;
    await _enterOffset(tester, 'primary', '-0.05');
    await _submitOffset(tester);
    expect(controller.primary, const Duration(milliseconds: 50));
    expect(double.parse(_inputText(tester, 'primary')), 0.05);
    expect(tester.widget<Slider>(_button('primary', 'slider')).value, 0.05);
    expect(find.textContaining('private native'), findsNothing);
    expect(find.text('Subtitle timing could not be updated. Try again.'),
        findsOneWidget);
  });

  testWidgets('rejected engine readback keeps the last confirmed seconds',
      (tester) async {
    final controller = SubtitleOffsetController(
      write: (_, __) async {},
      read: (_) async => '0.050',
    );
    addTearDown(controller.dispose);
    await controller.setOffset(const Duration(milliseconds: 50));
    await _pumpControls(tester, controller, secondaryEnabled: false);

    await _enterOffset(tester, 'primary', '-0.05');
    await _submitOffset(tester);
    expect(controller.failed, isTrue);
    expect(controller.primary, const Duration(milliseconds: 50));
    expect(double.parse(_inputText(tester, 'primary')), 0.05);
    expect(tester.widget<Slider>(_button('primary', 'slider')).value, 0.05);
  });

  testWidgets('track availability changes discard unsubmitted numeric drafts',
      (tester) async {
    final writes = <(String, String)>[];
    final controller = SubtitleOffsetController(
        write: (property, value) async => writes.add((property, value)))
      ..setAvailable(primary: true, secondary: true);
    await controller.setOffset(const Duration(milliseconds: 50));
    await controller.setOffset(const Duration(milliseconds: -20),
        secondary: true);
    writes.clear();
    final fixture = _EmbeddedFixture(controller: controller);
    await fixture.mount(tester);
    await tester.tap(find.byKey(const Key('subtitle-offset-open')));
    await tester.pumpAndSettle();
    await _enterOffset(tester, 'primary', '0.25');
    await _enterOffset(tester, 'secondary', '-0.25');
    expect(writes, isEmpty);

    controller.setAvailable(primary: false, secondary: false);
    await tester.pumpAndSettle();
    expect(double.parse(_inputText(tester, 'primary')), 0.05);
    expect(_input('secondary'), findsNothing);
    controller.setAvailable(primary: true, secondary: true);
    await tester.pumpAndSettle();
    expect(double.parse(_inputText(tester, 'primary')), 0.05);
    expect(double.parse(_inputText(tester, 'secondary')), -0.02);
    expect(writes, isEmpty);
    fixture.expectStillPlaying();
  });

  testWidgets('coalesced media reset discards a draft even at zero offset',
      (tester) async {
    final writes = <(String, String)>[];
    final controller = SubtitleOffsetController(
        write: (property, value) async => writes.add((property, value)))
      ..setAvailable(primary: true, secondary: false);
    final fixture = _EmbeddedFixture(controller: controller);
    await fixture.mount(tester);
    await tester.tap(find.byKey(const Key('subtitle-offset-open')));
    await tester.pumpAndSettle();
    await _enterOffset(tester, 'primary', '0.05');
    expect(_inputText(tester, 'primary'), '0.05');
    expect(controller.primary, Duration.zero);

    controller.clear();
    controller.setAvailable(primary: true, secondary: false);
    await tester.pumpAndSettle();
    expect(double.parse(_inputText(tester, 'primary')), 0);
    expect(tester.widget<Text>(_button('primary', 'value')).data, '0.00 s');
    expect(writes, isEmpty);
    fixture.expectStillPlaying();
  });

  testWidgets('coalesced secondary replacement resets only its own draft',
      (tester) async {
    final writes = <(String, String)>[];
    final controller = SubtitleOffsetController(
        write: (property, value) async => writes.add((property, value)))
      ..setAvailable(primary: true, secondary: true);
    final fixture = _EmbeddedFixture(controller: controller);
    await fixture.mount(tester);
    await tester.tap(find.byKey(const Key('subtitle-offset-open')));
    await tester.pumpAndSettle();
    await _enterOffset(tester, 'primary', '0.04');
    await _enterOffset(tester, 'secondary', '0.05');
    expect(controller.primary, Duration.zero);
    expect(controller.secondary, Duration.zero);

    controller.setAvailable(primary: true, secondary: false);
    controller.setAvailable(primary: true, secondary: true);
    await tester.pumpAndSettle();
    expect(_inputText(tester, 'primary'), '0.04');
    expect(double.parse(_inputText(tester, 'secondary')), 0);
    expect(tester.widget<Text>(_button('secondary', 'value')).data, '0.00 s');
    expect(writes, isEmpty);
    fixture.expectStillPlaying();
  });

  testWidgets(
      'inactive primary is disabled and no secondary row appears without a track',
      (tester) async {
    final controller = SubtitleOffsetController(write: (_, __) async {});
    addTearDown(controller.dispose);
    await _pumpControls(tester, controller,
        primaryEnabled: false, secondaryEnabled: false);

    for (final action in ['earlier', 'later', 'reset']) {
      expect(
          tester
              .widget<ButtonStyleButton>(_button('primary', action))
              .onPressed,
          isNull);
    }
    expect(
        tester
            .widget<EditableText>(find.descendant(
                of: _input('primary'), matching: find.byType(EditableText)))
            .readOnly,
        isTrue);
    expect(
        tester.widget<Slider>(_button('primary', 'slider')).onChanged, isNull);
    expect(tester.widget<IconButton>(_button('primary', 'apply')).onPressed,
        isNull);
    expect(_button('secondary', 'earlier'), findsNothing);
    expect(find.textContaining('Burned-in subtitles'), findsOneWidget);
  });

  testWidgets('pending engine change disables both rows until it completes',
      (tester) async {
    final pending = Completer<void>();
    final controller =
        SubtitleOffsetController(write: (_, __) => pending.future);
    addTearDown(controller.dispose);
    await _pumpControls(tester, controller);

    await tester.tap(_button('primary', 'later'));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    for (final slot in ['primary', 'secondary']) {
      for (final action in ['earlier', 'later', 'reset']) {
        expect(
            tester.widget<ButtonStyleButton>(_button(slot, action)).onPressed,
            isNull);
      }
      expect(
          tester
              .widget<EditableText>(find.descendant(
                  of: _input(slot), matching: find.byType(EditableText)))
              .readOnly,
          isTrue);
      expect(tester.widget<Slider>(_button(slot, 'slider')).onChanged, isNull);
      expect(
          tester.widget<IconButton>(_button(slot, 'apply')).onPressed, isNull);
    }

    pending.complete();
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(
        tester.widget<ButtonStyleButton>(_button('primary', 'later')).onPressed,
        isNotNull);
    expect(controller.primary, const Duration(milliseconds: 10));
  });

  testWidgets(
      'failed update keeps confirmed value and displays safe Traditional Chinese feedback',
      (tester) async {
    var fail = false;
    final controller = SubtitleOffsetController(write: (_, __) async {
      if (fail) throw StateError('private native engine detail');
    });
    addTearDown(controller.dispose);
    await controller.setOffset(const Duration(milliseconds: 10));
    await _pumpControls(tester, controller,
        locale:
            const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'));

    fail = true;
    await _tap(tester, 'primary', 'later');
    expect(controller.primary, const Duration(milliseconds: 10));
    expect(find.text('+0.01 秒'), findsOneWidget);
    expect(find.text('無法更新字幕時間，請重試。'), findsOneWidget);
    expect(find.textContaining('private native'), findsNothing);

    fail = false;
    await _tap(tester, 'primary', 'earlier');
    expect(controller.primary, Duration.zero);
    expect(find.text('無法更新字幕時間，請重試。'), findsNothing);
  });

  testWidgets('limit buttons cannot increase beyond plus or minus 60 seconds',
      (tester) async {
    final controller = SubtitleOffsetController(write: (_, __) async {});
    addTearDown(controller.dispose);
    await controller.setOffset(SubtitleOffsetController.limit);
    await controller.setOffset(-SubtitleOffsetController.limit,
        secondary: true);
    await _pumpControls(tester, controller);

    expect(
        tester.widget<ButtonStyleButton>(_button('primary', 'later')).onPressed,
        isNull);
    expect(
        tester
            .widget<ButtonStyleButton>(_button('secondary', 'earlier'))
            .onPressed,
        isNull);
    await _tap(tester, 'primary', 'earlier');
    await _tap(tester, 'secondary', 'later');
    expect(controller.primary, const Duration(milliseconds: 59990));
    expect(controller.secondary, const Duration(milliseconds: -59990));
  });

  testWidgets('narrow dialog wraps and scrolls controls with large text',
      (tester) async {
    final controller = SubtitleOffsetController(write: (_, __) async {});
    addTearDown(controller.dispose);
    await _pumpControls(
      tester,
      controller,
      viewport: const Size(320, 568),
      textScale: 2,
      dialog: true,
    );
    expect(tester.takeException(), isNull);

    await _tap(tester, 'primary', 'later');
    await _tap(tester, 'secondary', 'earlier');
    expect(controller.primary, const Duration(milliseconds: 10));
    expect(controller.secondary, const Duration(milliseconds: -10));
    expect(tester.takeException(), isNull);
    for (final slot in ['primary', 'secondary']) {
      for (final action in ['earlier', 'later', 'reset']) {
        final rect = tester.getRect(_button(slot, action));
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(320));
      }
    }
  });

  testWidgets(
      'direct panel remains interactive after toolbar hides without interrupting playback',
      (tester) async {
    final controller = SubtitleOffsetController(write: (_, __) async {})
      ..setAvailable(primary: true, secondary: true);
    final fixture = _EmbeddedFixture(controller: controller);
    await fixture.mount(tester);
    expect(fixture.routes.pushes, 1);

    await tester.tap(find.byKey(const Key('subtitle-offset-open')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('subtitle-offset-panel')), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(fixture.routes.pushes, 1);
    fixture.expectStillPlaying();

    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(fixture.player.ticks, greaterThanOrEqualTo(6));
    expect(find.byKey(const Key('subtitle-offset-open')), findsNothing);
    expect(find.byKey(const Key('subtitle-offset-panel')), findsOneWidget);
    await _tap(tester, 'primary', 'later');
    await _tap(tester, 'secondary', 'earlier');
    expect(controller.primary, const Duration(milliseconds: 10));
    expect(controller.secondary, const Duration(milliseconds: -10));
    fixture.expectStillPlaying();

    await tester.ensureVisible(find.byKey(const Key('subtitle-offset-close')));
    await tester.tap(find.byKey(const Key('subtitle-offset-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('subtitle-offset-panel')), findsNothing);
    expect(fixture.routes.pushes, 1);
    final ticksBefore = fixture.player.ticks;
    await tester.pump(const Duration(seconds: 2));
    expect(fixture.player.ticks, greaterThan(ticksBefore));
    fixture.expectStillPlaying();
  });

  testWidgets(
      'embedded panel and outside dismissal block pointer events from the player',
      (tester) async {
    final controller = SubtitleOffsetController(write: (_, __) async {})
      ..setAvailable(primary: true, secondary: false);
    final fixture = _EmbeddedFixture(controller: controller);
    await fixture.mount(tester);
    await tester.tap(find.byKey(const Key('subtitle-offset-open')));
    await tester.pumpAndSettle();

    await _tap(tester, 'primary', 'later');
    final panel =
        tester.getRect(find.byKey(const Key('subtitle-offset-panel')));
    await tester.tapAt(Offset(panel.left + 8, panel.top + 8));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('subtitle-offset-panel')), findsOneWidget);
    fixture.expectStillPlaying();

    await tester.tapAt(const Offset(40, 500));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('subtitle-offset-panel')), findsNothing);
    fixture.expectStillPlaying();
  });

  testWidgets(
      'Escape from the focused numeric field closes only the embedded panel',
      (tester) async {
    final controller = SubtitleOffsetController(write: (_, __) async {})
      ..setAvailable(primary: true, secondary: false);
    final fixture = _EmbeddedFixture(controller: controller);
    await fixture.mount(tester);
    await tester.tap(find.byKey(const Key('subtitle-offset-open')));
    await tester.pumpAndSettle();

    await _enterOffset(tester, 'primary', '-0.05');
    expect(tester.testTextInput.hasAnyClients, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('subtitle-offset-panel')), findsNothing);
    expect(fixture.escapedKeys, 0);
    expect(fixture.routes.pushes, 1);
    fixture.expectStillPlaying();
  });

  testWidgets('subtitle menu tile closes its menu and opens the embedded panel',
      (tester) async {
    final controller = SubtitleOffsetController(write: (_, __) async {})
      ..setAvailable(primary: true, secondary: false);
    final fixture = _EmbeddedFixture(controller: controller);
    await fixture.mount(tester);
    await tester.tap(find.byKey(const Key('fixture-subtitle-menu')));
    await tester.pumpAndSettle();
    expect(find.byType(SimpleDialog), findsOneWidget);

    await tester.tap(find.widgetWithText(ListTile, 'Subtitle timing'));
    await tester.pumpAndSettle();
    expect(find.byType(SimpleDialog), findsNothing);
    expect(find.byKey(const Key('subtitle-offset-panel')), findsOneWidget);
    expect(fixture.routes.pushes, 2);
    await _tap(tester, 'primary', 'earlier');
    expect(controller.primary, const Duration(milliseconds: -10));
    fixture.expectStillPlaying();
  });

  testWidgets('actual embedded panel fits a narrow viewport with large text',
      (tester) async {
    final controller = SubtitleOffsetController(write: (_, __) async {})
      ..setAvailable(primary: true, secondary: true);
    final fixture = _EmbeddedFixture(controller: controller);
    await fixture.mount(tester, viewport: const Size(320, 568), textScale: 2);
    await tester.tap(find.byKey(const Key('subtitle-offset-open')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await _tap(tester, 'primary', 'later');
    await _tap(tester, 'secondary', 'earlier');
    expect(controller.primary, const Duration(milliseconds: 10));
    expect(controller.secondary, const Duration(milliseconds: -10));
    expect(tester.takeException(), isNull);
    final panel =
        tester.getRect(find.byKey(const Key('subtitle-offset-panel')));
    expect(panel.left, greaterThanOrEqualTo(0));
    expect(panel.right, lessThanOrEqualTo(320));
    expect(panel.bottom, lessThanOrEqualTo(568));
    fixture.expectStillPlaying();
  });

  testWidgets(
      'direct button is hidden on unsupported players and disabled without an active track',
      (tester) async {
    final unsupported = _EmbeddedFixture(controller: null);
    await unsupported.mount(tester);
    expect(find.byKey(const Key('subtitle-offset-open')), findsNothing);
    expect(find.byKey(const Key('subtitle-offset-panel')), findsNothing);

    final controller = SubtitleOffsetController(write: (_, __) async {});
    final fixture = _EmbeddedFixture(controller: controller);
    await fixture.mount(tester);
    expect(
        tester
            .widget<IconButton>(find.byKey(const Key('subtitle-offset-open')))
            .onPressed,
        isNull);
    controller.setAvailable(primary: true, secondary: false);
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<IconButton>(find.byKey(const Key('subtitle-offset-open')))
            .onPressed,
        isNotNull);
    fixture.expectStillPlaying();
  });

  testWidgets(
      'numeric input and slider remain usable at 320 pixels with keyboard and large text',
      (tester) async {
    final controller = SubtitleOffsetController(write: (_, __) async {})
      ..setAvailable(primary: true, secondary: true);
    final fixture = _EmbeddedFixture(controller: controller);
    await fixture.mount(tester, viewport: const Size(320, 568), textScale: 2);
    await tester.tap(find.byKey(const Key('subtitle-offset-open')));
    await tester.pumpAndSettle();

    await _enterOffset(tester, 'primary', '-0.05');
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    await tester.ensureVisible(_input('primary'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _tap(tester, 'primary', 'apply');
    expect(controller.primary, const Duration(milliseconds: -50));

    await _enterOffset(tester, 'secondary', '0.01');
    await _submitOffset(tester);
    expect(controller.secondary, const Duration(milliseconds: 10));
    expect(tester.takeException(), isNull);
    final panel =
        tester.getRect(find.byKey(const Key('subtitle-offset-panel')));
    expect(panel.left, greaterThanOrEqualTo(0));
    expect(panel.right, lessThanOrEqualTo(320));
    expect(panel.bottom, lessThanOrEqualTo(308));
    for (final slot in ['primary', 'secondary']) {
      for (final action in ['input', 'slider']) {
        final rect = tester.getRect(_button(slot, action));
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(320));
      }
    }
    fixture.expectStillPlaying();
  });
}
