import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/credentials_model.dart';
import 'package:fladder/providers/remote_control_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/services/remote_control/remote_control_models.dart';
import 'package:fladder/services/remote_control/remote_receiver.dart';
import 'package:fladder/widgets/shared/remote_control_entry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _account = AccountModel(
    name: 'Synthetic owner',
    id: 'owner',
    avatar: '',
    lastUsed: DateTime.utc(2026),
    credentials: CredentialsModel.internal(
        url: 'https://fixture.example.invalid',
        token: 'synthetic-only',
        serverId: 'server',
        deviceId: 'phone'));

RemoteTarget _target(
        {String id = 'tesla',
        String? name,
        bool idle = false,
        bool paused = false,
        int? subtitleIndex = 8}) =>
    RemoteTarget(
      id: id,
      deviceId: id,
      name: name ?? (id == 'tesla' ? 'Tesla browser' : 'Living room'),
      userId: 'owner',
      serverId: 'server',
      binding: idle
          ? null
          : RemotePlaybackBinding(
              itemId: 'item-$id',
              mediaSourceId: 'source-$id',
              playbackId: 'jms-remote-occurrence-$id'),
      paused: paused,
      canSeek: !idle,
      positionTicks: 100000000,
      durationTicks: 3000000000,
      subtitleIndex: subtitleIndex,
    );

const _subtitles = [
  RemoteSubtitle(
      sourceId: 'source-tesla', index: 8, label: 'English CC', language: 'eng'),
  RemoteSubtitle(
      sourceId: 'source-tesla',
      index: 16,
      label: 'Original Chinese',
      language: 'zho'),
];

RemoteControlState _state(
    {RemoteTarget? target,
    List<RemoteTarget>? targets,
    RemoteCommandStatus status = RemoteCommandStatus.idle}) {
  final selected = target ?? _target();
  return RemoteControlState(
      targets: targets ?? [selected, _target(id: 'living-room')],
      target: selected,
      subtitles: _subtitles,
      status: status);
}

class _User extends User {
  _User(this.signedIn);
  final bool signedIn;
  @override
  AccountModel? build() => signedIn ? _account : null;
}

class _Controls extends RemoteControlNotifier {
  _Controls(super.ref, RemoteControlState initial) {
    state = RemoteControlViewState(controller: initial);
  }
  int starts = 0;
  int stops = 0;
  int refreshes = 0;
  final selected = <RemoteTarget?>[];
  final actions = <RemoteAction>[];
  final receiving = <bool>[];
  @override
  Future<void> startController() async {
    starts++;
    state = state.copyWith(controllerOpen: true);
  }

  @override
  Future<void> stopController() async {
    stops++;
    // The production notifier awaits subscription cancellation before notifying
    // listeners, so dialog disposal never synchronously rebuilds its own tree.
    await Future<void>.value();
    state = state.copyWith(
        controller: const RemoteControlState(), controllerOpen: false);
  }

  @override
  Future<void> refresh() async {
    refreshes++;
  }

  @override
  Future<void> selectTarget(RemoteTarget? target) async {
    selected.add(target);
    final current = state.controller;
    state = state.copyWith(
        controller: RemoteControlState(
            targets: current.targets,
            target: target,
            subtitles: current.subtitles));
  }

  @override
  Future<void> dispatch(RemoteAction action) async {
    actions.add(action);
    publishStatus(RemoteCommandStatus.pending);
  }

  @override
  Future<void> setReceiving(bool value) async {
    receiving.add(value);
    state = state.copyWith(
        receivingEnabled: value,
        receiverStatus:
            value ? RemoteReceiverState.enabled : RemoteReceiverState.disabled);
  }

  void publish(RemoteControlState next) =>
      state = state.copyWith(controller: next);
  void publishStatus(RemoteCommandStatus status) {
    final current = state.controller;
    publish(RemoteControlState(
        targets: current.targets,
        target: current.target,
        subtitles: current.subtitles,
        status: status));
  }
}

class _Fixture {
  _Fixture({bool signedIn = true, RemoteControlState? initial}) {
    container = ProviderContainer(overrides: [
      userProvider.overrideWith(() => _User(signedIn)),
      remoteControlProvider
          .overrideWith((ref) => _Controls(ref, initial ?? _state())),
    ]);
  }
  late final ProviderContainer container;
  _Controls get controls =>
      container.read(remoteControlProvider.notifier) as _Controls;
  RemoteControlViewState get state => container.read(remoteControlProvider);
}

Finder get _deviceField => find
    .byWidgetPredicate((widget) => widget is DropdownButtonFormField<String>);
Finder get _subtitleField =>
    find.byWidgetPredicate((widget) => widget is DropdownButtonFormField<int>);
Finder get _playButton =>
    find.byWidgetPredicate((widget) => widget is FilledButton);

Future<void> _mount(WidgetTester tester, _Fixture fixture) async {
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    fixture.container.dispose();
  });
  await tester.pumpWidget(UncontrolledProviderScope(
      container: fixture.container,
      child: const MaterialApp(
          locale: Locale('en'),
          home: Scaffold(body: Center(child: RemoteControlEntry())))));
  await tester.pumpAndSettle();
}

Future<void> _open(WidgetTester tester, _Fixture fixture) async {
  await _mount(tester, fixture);
  await tester.tap(find.byTooltip('Remote control'));
  await tester.pumpAndSettle();
  expect(find.byType(RemoteControlDialog), findsOneWidget);
}

void main() {
  testWidgets('logged-out users have no remote control entry', (tester) async {
    final fixture = _Fixture(signedIn: false);
    await _mount(tester, fixture);
    expect(find.byType(IconButton), findsNothing);
    expect(find.byTooltip('Remote control'), findsNothing);
    expect(find.byType(RemoteControlDialog), findsNothing);
  });

  testWidgets(
      'active playback enables controls while an idle device stays disabled',
      (tester) async {
    final fixture = _Fixture();
    await _open(tester, fixture);
    expect(fixture.controls.starts, 1);
    expect(tester.widget<FilledButton>(_playButton).onPressed, isNotNull);
    expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNotNull);
    expect(
        tester.widget<DropdownButtonFormField<int>>(_subtitleField).onChanged,
        isNotNull);
    final idle = _target(id: 'idle', idle: true);
    fixture.controls.publish(_state(target: idle, targets: [idle]));
    await tester.pump();
    expect(find.text('Open a video on the playback device first.'),
        findsOneWidget);
    expect(tester.widget<FilledButton>(_playButton).onPressed, isNull);
    expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
    expect(
        tester.widget<DropdownButtonFormField<int>>(_subtitleField).onChanged,
        isNull);
    expect(fixture.controls.actions, isEmpty);
  });

  testWidgets(
      'device chooser selects the named target rather than the first session',
      (tester) async {
    final fixture = _Fixture();
    await _open(tester, fixture);
    await tester.tap(_deviceField);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Living room').last);
    await tester.pumpAndSettle();
    expect(fixture.controls.selected.single?.id, 'living-room');
    expect(fixture.state.controller.target?.deviceId, 'living-room');
    expect(
        tester
            .widget<DropdownButtonFormField<String>>(_deviceField)
            .initialValue,
        'living-room');
  });

  testWidgets('an unconfirmed subtitle selection is not displayed as Off',
      (tester) async {
    final fixture =
        _Fixture(initial: _state(target: _target(subtitleIndex: null)));
    await _open(tester, fixture);
    expect(
        tester
            .widget<DropdownButtonFormField<int>>(_subtitleField)
            .initialValue,
        isNull);
    expect(fixture.controls.actions, isEmpty);
    fixture.controls.publishStatus(RemoteCommandStatus.unknown);
    await tester.pump();
    expect(
        tester
            .widget<DropdownButtonFormField<int>>(_subtitleField)
            .initialValue,
        isNull);
    expect(find.textContaining('The result is unknown'), findsOneWidget);
    expect(find.text('Confirmed by the playback device.'), findsNothing);
  });

  testWidgets(
      'switching devices clears optimistic intent even when both devices share a playback binding',
      (tester) async {
    final first = _target();
    final second = RemoteTarget(
        id: 'second-device',
        deviceId: 'second-device',
        name: 'Second device',
        userId: first.userId,
        serverId: first.serverId,
        binding: first.binding,
        paused: false,
        canSeek: true,
        positionTicks: first.positionTicks,
        durationTicks: first.durationTicks,
        subtitleIndex: first.subtitleIndex);
    final fixture =
        _Fixture(initial: _state(target: first, targets: [first, second]));
    await _open(tester, fixture);
    await tester.ensureVisible(_playButton);
    await tester.pumpAndSettle();
    await tester.tap(_playButton);
    await tester.pump();
    expect(find.descendant(of: _playButton, matching: find.text('Play')),
        findsOneWidget);
    await tester.ensureVisible(_deviceField);
    await tester.pumpAndSettle();
    await tester.tap(_deviceField);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Second device').last);
    await tester.pumpAndSettle();
    expect(fixture.controls.selected.single?.id, 'second-device');
    expect(find.descendant(of: _playButton, matching: find.text('Pause')),
        findsOneWidget);
    expect(find.descendant(of: _playButton, matching: find.text('Play')),
        findsNothing);
  });

  testWidgets(
      'choosing Off sends exactly subtitle index minus one and waits for confirmation',
      (tester) async {
    final fixture = _Fixture();
    await _open(tester, fixture);
    await tester.ensureVisible(_subtitleField);
    await tester.pumpAndSettle();
    await tester.tap(_subtitleField);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Off').last);
    await tester.pumpAndSettle();
    expect(fixture.controls.actions, [const RemoteAction.subtitle(-1)]);
    expect(find.text('Sent; waiting for the playback device.'), findsOneWidget);
    expect(find.text('Confirmed by the playback device.'), findsNothing);
    fixture.controls.publishStatus(RemoteCommandStatus.unknown);
    await tester.pump();
    expect(
        tester
            .widget<DropdownButtonFormField<int>>(_subtitleField)
            .initialValue,
        8);
    expect(find.text('Confirmed by the playback device.'), findsNothing);
  });

  testWidgets(
      'pending and accepted commands never appear confirmed until a confirmed report',
      (tester) async {
    final fixture = _Fixture();
    await _open(tester, fixture);
    for (final status in [
      RemoteCommandStatus.pending,
      RemoteCommandStatus.accepted
    ]) {
      fixture.controls.publishStatus(status);
      await tester.pump();
      expect(
          find.text('Sent; waiting for the playback device.'), findsOneWidget);
      expect(find.text('Confirmed by the playback device.'), findsNothing);
    }
    fixture.controls.publishStatus(RemoteCommandStatus.confirmed);
    await tester.pump();
    expect(find.text('Confirmed by the playback device.'), findsOneWidget);
  });

  testWidgets(
      'receiver opt-in survives dialog close while controller UI is cleared',
      (tester) async {
    final fixture = _Fixture();
    await _open(tester, fixture);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(fixture.controls.receiving, [true]);
    expect(fixture.state.receivingEnabled, true);
    await tester.tap(find.text('Close remote control'));
    await tester.pumpAndSettle();
    expect(find.byType(RemoteControlDialog), findsNothing);
    expect(fixture.controls.stops, 1);
    expect(fixture.state.controllerOpen, false);
    expect(fixture.state.controller.target, isNull);
    expect(fixture.state.receivingEnabled, true);
    expect(fixture.controls.receiving, [true]);
    expect(find.byIcon(Icons.connected_tv), findsOneWidget);
  });

  testWidgets(
      'a slider drag sends no seek while moving and one seek on release',
      (tester) async {
    final fixture = _Fixture();
    await _open(tester, fixture);
    final slider = find.byType(Slider);
    await tester.ensureVisible(slider);
    await tester.pumpAndSettle();
    final rectangle = tester.getRect(slider);
    final gesture =
        await tester.startGesture(rectangle.centerLeft + const Offset(28, 0));
    await gesture.moveBy(const Offset(70, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(50, 0));
    await tester.pump();
    expect(fixture.controls.actions, isEmpty);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(fixture.controls.actions, hasLength(1));
    expect(fixture.controls.actions.single.type, RemoteActionType.seek);
    expect(
        fixture.controls.actions.single.position, greaterThan(Duration.zero));
  });

  testWidgets(
      'rapid play and pause intents stay usable while an earlier command is pending',
      (tester) async {
    final fixture = _Fixture();
    await _open(tester, fixture);
    await tester.ensureVisible(_playButton);
    await tester.pumpAndSettle();
    await tester.tap(_playButton);
    await tester.pump();
    expect(fixture.controls.actions, [const RemoteAction.pause()]);
    expect(tester.widget<FilledButton>(_playButton).onPressed, isNotNull);
    await tester.tap(_playButton);
    await tester.pump();
    expect(fixture.controls.actions,
        [const RemoteAction.pause(), const RemoteAction.play()]);
    expect(find.text('Confirmed by the playback device.'), findsNothing);
  });

  testWidgets(
      '320 by 640 phone layout scrolls to subtitle and status controls without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = _Fixture(
        initial: _state(
            target: _target(
                name: 'Tesla browser with a very long readable device name')));
    await _open(tester, fixture);
    expect(tester.takeException(), isNull);
    expect(find.byType(SingleChildScrollView), findsWidgets);
    await tester.ensureVisible(_subtitleField);
    await tester.pumpAndSettle();
    expect(_subtitleField.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(_subtitleField);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Off').last);
    await tester.pumpAndSettle();
    expect(fixture.controls.actions, [const RemoteAction.subtitle(-1)]);
    expect(tester.takeException(), isNull);
  });
}
