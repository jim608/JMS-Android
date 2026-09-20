import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fladder/l10n/generated/app_localizations.dart';
import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/playback/playback_model.dart';
import 'package:fladder/models/settings/video_player_settings.dart';
import 'package:fladder/providers/settings/client_settings_provider.dart';
import 'package:fladder/providers/settings/video_player_settings_provider.dart';
import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/providers/sleep_timer_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/screens/settings/widgets/settings_backup_tile.dart';
import 'package:fladder/screens/video_player/components/sleep_timer_dialog.dart';
import 'package:fladder/util/settings_backup.dart';
import 'package:fladder/util/settings_backup_files.dart';
import 'package:fladder/util/sleep_timer.dart';
import 'package:fladder/wrappers/media_control_wrapper.dart';
import 'package:fladder/wrappers/players/player_states.dart';

class FixtureItem implements ItemBaseModel {
  @override
  String get id => 'fixture-episode';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FixturePlayback implements PlaybackModel {
  @override
  ItemBaseModel get item => FixtureItem();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FixtureMedia extends MediaControlsWrapper {
  FixtureMedia(Ref ref) : super(ref: ref);
  final events = StreamController<PlayerState>.broadcast();
  Completer<void>? initGate;
  int activeInitializations = 0;
  int maximumInitializations = 0;
  @override
  PlayerOptions get backend => PlayerOptions.libMPV;
  @override
  Stream<PlayerState> get stateStream => events.stream;
  @override
  Future<void> init() async {
    activeInitializations++;
    if (activeInitializations > maximumInitializations) {
      maximumInitializations = activeInitializations;
    }
    await initGate?.future;
    activeInitializations--;
  }

  @override
  Future<void> dispose() async {}
  @override
  Future<void> stop({bool preserveSleepTimer = false}) async {}
  @override
  Future<void> pause() async {}
}

class FixtureNotifier extends VideoPlayerNotifier {
  FixtureNotifier(super.ref) {
    state = FixtureMedia(ref);
  }
}

class FixtureFiles extends SettingsBackupFiles {
  Uint8List? picked;
  Uint8List? saved;
  @override
  Future<Uint8List?> pick() async => picked;
  @override
  Future<String> save(Uint8List bytes) async {
    saved = bytes;
    return 'saved';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer container;
  late SharedPreferences preferences;
  late FixtureFiles files;
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'loginCredentialsKey': ['account-sentinel'],
      'jms.update.prerelease': true
    });
    preferences = await SharedPreferences.getInstance();
    files = FixtureFiles();
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      sharedUtilityProvider.overrideWith((ref) => SharedUtility(ref: ref, sharedPreferences: preferences)),
      settingsBackupFilesProvider.overrideWithValue(files),
      videoPlayerProvider.overrideWith((ref) => FixtureNotifier(ref)),
    ]);
  });
  tearDown(() => container.dispose());

  Future<GlobalKey> mount(WidgetTester tester, Widget body) async {
    final font = FontLoader('JmsTestCjk')..addFont(rootBundle.load('assets/subtitle_fonts/NotoSansCJKtc-Regular.otf'));
    await font.load();
    tester.view.physicalSize = const Size(480, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final boundary = GlobalKey();
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          theme: ThemeData(fontFamily: 'JmsTestCjk', colorSchemeSeed: Colors.teal),
          locale: const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: body),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return boundary;
  }

  Future<void> capture(WidgetTester tester, GlobalKey key, String name) => tester.runAsync(() async {
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('artifacts/checks/m11/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });

  testWidgets('sleep controls support countdown, end-of-item and cancellation in Traditional Chinese', (tester) async {
    container.read(playBackModel.notifier).state = FixturePlayback();
    final boundary = await mount(tester, const SleepTimerDialog());
    await tester.enterText(find.byType(TextFormField), '1');
    await tester.tap(find.text('開始／重設倒數'));
    await tester.pump();
    expect(container.read(sleepTimerProvider).mode, SleepTimerMode.countdown);
    expect(find.textContaining('剩餘時間：'), findsOneWidget);
    await capture(tester, boundary, 'sleep-countdown');
    await tester.tap(find.text('播完本集停止'));
    await tester.pump();
    expect(container.read(sleepTimerProvider).blocksAutoNext, true);
    await tester.tap(find.text('取消計時'));
    await tester.pump();
    expect(container.read(sleepTimerProvider).mode, SleepTimerMode.off);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('backup export, preview cancellation, confirmed restore and bad input are complete flows',
      (tester) async {
    final boundary = await mount(tester, const SettingsBackupDialog());
    await tester.tap(find.text('匯出設定…'));
    await tester.pumpAndSettle();
    expect(files.saved, isNotNull);
    expect(utf8.decode(files.saved!).contains('account-sentinel'), false);
    files.picked = Uint8List.fromList(utf8.encode(jsonEncode({
      'schemaVersion': 1,
      'settings': {
        'client': {'amoledBlack': true},
        'player': {'ambientIntensity': 0.96, 'ambientSpread': 0.66}
      },
    })));
    await tester.tap(find.text('選擇備份還原…'));
    await tester.pumpAndSettle();
    expect(find.text('確認將變更的設定'), findsOneWidget);
    expect(find.text('光暈強度'), findsOneWidget);
    await capture(tester, boundary, 'backup-preview');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(preferences.containsKey(SettingsBundleStore.key), false);
    await tester.tap(find.text('選擇備份還原…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('確認還原'));
    await tester.pumpAndSettle();
    expect(find.text('設定已還原'), findsOneWidget);
    expect(container.read(clientSettingsProvider).amoledBlack, true);
    expect(container.read(videoPlayerSettingsProvider).ambientIntensity, 0.96);
    expect(SharedHelper(sharedPreferences: preferences).videoPlayerSettings.ambientSpread, 0.66);
    expect(preferences.getStringList('loginCredentialsKey'), ['account-sentinel']);
    expect(preferences.getBool('jms.update.prerelease'), true);
    final stored = preferences.getString(SettingsBundleStore.key);
    files.picked = Uint8List.fromList(utf8.encode('{broken'));
    await tester.tap(find.text('選擇備份還原…'));
    await tester.pumpAndSettle();
    expect(find.textContaining('備份損毀'), findsOneWidget);
    expect(preferences.getString(SettingsBundleStore.key), stored);
    files.picked = null;
    await tester.tap(find.text('選擇備份還原…'));
    await tester.pumpAndSettle();
    expect(find.text('已取消，未變更設定'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  test('Q2 ten sequential player reinitializations retain one stream and one settings listener', () async {
    final notifier = container.read(videoPlayerProvider.notifier);
    final media = container.read(videoPlayerProvider) as FixtureMedia;
    final settingsSubscriptions = <ProviderSubscription<VideoPlayerSettingsModel>>[];
    for (var iteration = 0; iteration < 10; iteration++) {
      await notifier.init();
      settingsSubscriptions.add(notifier.settingsChanged!);
    }
    expect(notifier.subscriptions.length, 1);
    expect(media.events.hasListener, true);
    expect(settingsSubscriptions.where((subscription) => !subscription.closed).length, 1);
    expect(settingsSubscriptions.take(9).every((subscription) => subscription.closed), true);
    container.invalidate(videoPlayerProvider);
    expect(media.events.hasListener, false);
    expect(settingsSubscriptions.every((subscription) => subscription.closed), true);
    await media.events.close();
  });
  test('Q2 concurrent reinitializations are serialized without retaining extra subscriptions', () async {
    final notifier = container.read(videoPlayerProvider.notifier);
    final media = container.read(videoPlayerProvider) as FixtureMedia;
    media.initGate = Completer<void>();
    final pending = List.generate(10, (_) => notifier.init());
    await Future<void>.delayed(Duration.zero);
    media.initGate!.complete();
    await Future.wait(pending);
    expect(media.maximumInitializations, 1);
    expect(notifier.subscriptions.length, 1);
    container.invalidate(videoPlayerProvider);
    await media.events.close();
  });
}
