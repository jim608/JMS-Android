// Test-only browser entrypoint. Production remote provider, dialog, transport,
// protocol and receiver are used unchanged. Only account persistence and the
// player port are replaced: this port forwards to a real HTML video/TextTrack.
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart'
    show UserPolicy;
import 'package:fladder/l10n/generated/app_localizations.dart';
import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/credentials_model.dart';
import 'package:fladder/providers/remote_control_provider.dart';
import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/services/remote_control/remote_control_models.dart';
import 'package:fladder/services/remote_control/remote_receiver.dart';
import 'package:fladder/util/application_info.dart';
import 'package:fladder/widgets/shared/remote_control_entry.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web/web.dart' as web;

const _item = 'remote-fixture-item';
const _playSession = 'fixture-play-1';
const _userId = 'remote-fixture-user';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final origin = Uri.base;
  if (origin.scheme != 'http' ||
      origin.host != '127.0.0.1' ||
      origin.userInfo.isNotEmpty ||
      origin.port <= 0) {
    throw StateError(
        'The remote probe requires an owned IPv4 loopback origin.');
  }
  final role = origin.queryParameters['role'];
  if (role != 'receiver' && role != 'phone') {
    throw StateError(
        'An explicit synthetic receiver or phone role is required.');
  }
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final player = _HtmlPlaybackPort(origin.resolve('/remote-fixture.mp4'));
  ui_web.platformViewRegistry
      .registerViewFactory('remote-fixture-video', (_) => player.video);
  runApp(ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      sharedUtilityProvider.overrideWith(
          (ref) => SharedUtility(ref: ref, sharedPreferences: preferences)),
      applicationInfoProvider.overrideWith((ref) => ApplicationInfo(
            name: 'JMS',
            version: 'remote-fixture',
            buildNumber: '0',
            platform: TargetPlatform.android,
          )),
      userProvider.overrideWith(() => _ProbeUser(role!, origin)),
      remotePlaybackPortProvider.overrideWithValue(player),
    ],
    child: MaterialApp(
      title: 'JMS local remote control probe',
      theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          fontFamily: 'OpenSans'),
      locale: const Locale('en'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: _Probe(role: role!, player: player),
    ),
  ));
}

class _ProbeUser extends User {
  _ProbeUser(this.role, this.origin);
  final String role;
  final Uri origin;
  bool foreign = false;

  AccountModel _account() => AccountModel(
        name: foreign ? 'Foreign fixture account' : 'Synthetic account',
        id: foreign ? 'foreign-fixture-user' : _userId,
        avatar: '',
        lastUsed: DateTime.utc(2026),
        policy: const UserPolicy(
          authenticationProviderId: 'fixture',
          passwordResetProviderId: 'fixture',
          enableMediaPlayback: true,
          isDisabled: false,
        ),
        credentials: CredentialsModel.internal(
          url: '${origin.origin}/',
          serverId: 'remote-fixture-server',
          serverName: 'Loopback remote fixture',
          token: foreign ? 'foreign-fixture-token' : '$role-fixture-token',
          deviceId: foreign ? 'foreign-fixture-device' : '$role-fixture-device',
        ),
      );

  @override
  AccountModel? build() => _account();

  void changeAccount() {
    foreign = !foreign;
    state = _account();
  }
}

class _HtmlPlaybackPort implements RemotePlaybackPort {
  _HtmlPlaybackPort(Uri media) : video = web.HTMLVideoElement() {
    video
      ..id = 'remote-fixture-video'
      ..src = media.toString()
      ..preload = 'auto'
      ..muted = true
      ..playsInline = true
      ..loop = true;
    video.style
      ..width = '100%'
      ..height = '100%'
      ..objectFit = 'contain';
  }

  final web.HTMLVideoElement video;
  final _tracks = <int, web.HTMLTrackElement>{};
  String sourceId = 'source-a';
  int subtitleIndex = -1;
  bool started = false;
  int mutations = 0;

  RemotePlaybackBinding get binding => RemotePlaybackBinding(
        itemId: _item,
        mediaSourceId: sourceId,
        playbackId: 'jms-remote-$_playSession',
      );

  @override
  RemotePlaybackSnapshot? get snapshot {
    if (!started || !video.duration.isFinite || video.duration <= 0) {
      return null;
    }
    return RemotePlaybackSnapshot(
      binding: binding,
      positionTicks: (video.currentTime * 10000000).round(),
      durationTicks: (video.duration * 10000000).round(),
      paused: video.paused,
      canSeek: true,
      subtitleIndex: subtitleIndex,
      playSessionId: _playSession,
    );
  }

  @override
  bool get blockedBySyncPlay => false;

  Future<void> start() async {
    await video.play().toDart;
    video.pause();
    started = true;
  }

  void _check(RemotePlaybackBinding expected) {
    if (!started || expected != binding) {
      throw StateError('Stale probe playback');
    }
  }

  @override
  Future<void> play(RemotePlaybackBinding expected) async {
    _check(expected);
    await video.play().toDart;
    mutations++;
  }

  @override
  Future<void> pause(RemotePlaybackBinding expected) async {
    _check(expected);
    video.pause();
    mutations++;
  }

  @override
  Future<void> seek(Duration position, RemotePlaybackBinding expected) async {
    _check(expected);
    video.currentTime = position.inMicroseconds / 1000000;
    await _until(() =>
        !video.seeking &&
        (video.currentTime - position.inMicroseconds / 1000000).abs() < .2);
    mutations++;
  }

  @override
  Future<void> setSubtitle(int index, RemotePlaybackBinding expected) async {
    _check(expected);
    if (index != -1 &&
        !(sourceId == 'source-a' ? {3, 7} : {3}).contains(index)) {
      throw StateError('Unknown probe subtitle');
    }
    for (final track in _tracks.values) {
      track.track.mode = 'disabled';
    }
    if (index >= 0) {
      final track = _tracks.putIfAbsent(index, () {
        final element = web.HTMLTrackElement()
          ..kind = 'subtitles'
          ..label = '$sourceId-$index'
          ..srclang = 'en'
          ..src = '${Uri.base.origin}/subtitles/$sourceId/$index.vtt';
        video.appendChild(element);
        return element;
      });
      track.track.mode = 'showing';
      await _until(() => track.readyState == web.HTMLTrackElement.LOADED);
      _check(expected);
    }
    subtitleIndex = index;
    mutations++;
  }

  Future<void> _until(bool Function() test) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!test()) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('Probe DOM operation timed out');
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  void switchSource() {
    for (final track in _tracks.values) {
      track.track.mode = 'disabled';
      track.remove();
    }
    _tracks.clear();
    subtitleIndex = -1;
    sourceId = sourceId == 'source-a' ? 'source-b' : 'source-a';
  }

  String get cueText {
    if (subtitleIndex < 0) return '';
    final cues = _tracks[subtitleIndex]?.track.activeCues;
    if (cues == null) return '';
    return List.generate(
        cues.length, (index) => (cues[index] as web.VTTCue).text).join('\n');
  }
}

class _Probe extends ConsumerStatefulWidget {
  const _Probe({required this.role, required this.player});
  final String role;
  final _HtmlPlaybackPort player;
  @override
  ConsumerState<_Probe> createState() => _ProbeState();
}

class _ProbeState extends ConsumerState<_Probe> {
  final _status = web.HTMLScriptElement()
    ..id = 'remote-probe-state'
    ..type = 'application/json';
  SemanticsHandle? _semantics;
  Timer? _timer;
  JSFunction? _accountEvent;
  String? _failure;

  @override
  void initState() {
    super.initState();
    web.document.body?.appendChild(_status);
    _semantics = WidgetsBinding.instance.ensureSemantics();
    // The test can change its synthetic identity while the production modal is
    // open, including during an outstanding request. This does not dispatch a
    // remote action or replace any production account-generation guard.
    _accountEvent = ((web.Event _) {
      (ref.read(userProvider.notifier) as _ProbeUser).changeAccount();
    }).toJS;
    web.window.addEventListener('jms-remote-probe-account', _accountEvent);
    _timer = Timer.periodic(const Duration(milliseconds: 150), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _status.remove();
    web.window.removeEventListener('jms-remote-probe-account', _accountEvent);
    _semantics?.dispose();
    widget.player.video.pause();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remote = ref.watch(remoteControlProvider);
    final controller = remote.controller;
    final player = widget.player;
    final state = jsonEncode({
      'role': widget.role,
      'user': ref.watch(userProvider)?.id,
      'started': player.started,
      'source': player.sourceId,
      'subtitle': player.subtitleIndex,
      'cue': player.cueText,
      'mutations': player.mutations,
      'paused': player.video.paused,
      'position': player.video.currentTime,
      'receiver': remote.receiverStatus.name,
      'receiving': remote.receivingEnabled,
      'status': controller.status.name,
      'targets': controller.targets.map((target) => target.id).toList(),
      'targetSources': {
        for (final target in controller.targets)
          target.id: target.binding?.mediaSourceId,
      },
      'target': controller.target?.id,
      'targetSource': controller.target?.binding?.mediaSourceId,
      'subtitles': controller.subtitles
          .map((subtitle) =>
              '${subtitle.sourceId}:${subtitle.index}:${subtitle.label}')
          .toList(),
      'failure': _failure,
    });
    // Modal routes intentionally hide underlying Flutter semantics. Keep this
    // read-only test status available while driving the production dialog.
    _status.textContent = state;
    return Scaffold(
      appBar: AppBar(
          title: Text('Local ${widget.role} probe'),
          actions: const [RemoteControlEntry()]),
      body: SingleChildScrollView(
          child: Column(children: [
        if (widget.role == 'receiver') ...[
          const SizedBox(
              height: 220,
              child: HtmlElementView(viewType: 'remote-fixture-video')),
          FilledButton(
            onPressed: player.started
                ? null
                : () async {
                    try {
                      await player.start();
                    } catch (_) {
                      _failure = 'media-start-failed';
                    }
                    if (mounted) setState(() {});
                  },
            child: const Text('Start fixture'),
          ),
          TextButton(
              onPressed: () => setState(player.switchSource),
              child: const Text('Switch source')),
        ],
        TextButton(
          onPressed: () =>
              (ref.read(userProvider.notifier) as _ProbeUser).changeAccount(),
          child: const Text('Change account'),
        ),
        Semantics(
            container: true,
            label: 'remote-probe $state',
            child: ExcludeSemantics(
                child: Text(
              'Synthetic loopback probe | ${widget.role} | ${player.sourceId}',
            ))),
      ])),
    );
  }
}
