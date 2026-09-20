import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/providers/settings/video_player_settings_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/util/build_info.dart';
import 'package:fladder/util/localization_helper.dart';
import 'package:fladder/util/playback_diagnostics.dart';
import 'package:fladder/widgets/shared/ambient_blur.dart';
import 'package:fladder/widgets/shared/ambient_controls.dart';
import 'package:fladder/widgets/shared/ambient_sample_preview.dart';

class PlaybackDiagnostics extends ConsumerStatefulWidget {
  final AmbientBlurDiagnostics ambient;
  final ValueNotifier<AmbientComposition> composition;

  const PlaybackDiagnostics({super.key, required this.ambient, required this.composition});

  @override
  ConsumerState<PlaybackDiagnostics> createState() => _PlaybackDiagnosticsState();
}

class _PlaybackDiagnosticsState extends ConsumerState<PlaybackDiagnostics> with WidgetsBindingObserver {
  final _frames = PlaybackFrameSamples();
  Timer? _timer;
  bool _visible = false;
  bool _reading = false;
  bool _active = true;
  Map<String, String> _values = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    SchedulerBinding.instance.removeTimingsCallback(_frames.add);
    widget.ambient.enabled = false;
  }

  void _start() {
    _stop();
    if (!_visible || !_active) return;
    _frames.clear();
    widget.ambient.enabled = true;
    SchedulerBinding.instance.addTimingsCallback(_frames.add);
    _read();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _read());
  }

  Future<void> _read() async {
    if (_reading || !_active || !_visible) return;
    _reading = true;
    try {
      final values = await ref.read(videoPlayerProvider).playbackDiagnostics();
      if (!mounted || !_visible || !_active) return;
      if (!kIsWeb) {
        values['process RSS (not GPU memory)'] = '${(ProcessInfo.currentRss / 1048576).toStringAsFixed(1)} MiB';
      }
      setState(() => _values = values.map((key, value) => MapEntry(key, safeDiagnosticValue(value))));
    } catch (_) {
      if (mounted && _visible) setState(() => _values = {'runtime': 'unknown'});
    } finally {
      _reading = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    _start();
  }

  @override
  void dispose() {
    _stop();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = ref.watch(videoPlayerSettingsProvider.select((settings) => settings.ambientBlur));
    final refreshRate = View.of(context).display.refreshRate;
    final ambient = widget.ambient;
    String milliseconds(int? micros) => micros == null ? 'unknown' : '${(micros / 1000).toStringAsFixed(2)} ms';
    return Align(
      alignment: Alignment.topRight,
      child: SafeArea(
        child: Material(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(8),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 390, maxHeight: MediaQuery.sizeOf(context).height * 0.7),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  tooltip: context.localized.jmsPlaybackDiagnostics,
                  icon: Icon(_visible ? Icons.close : Icons.monitor_heart_outlined, color: Colors.white),
                  onPressed: () {
                    setState(() => _visible = !_visible);
                    _start();
                  },
                ),
                if (_visible)
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(10),
                      child: DefaultTextStyle(
                        style: const TextStyle(color: Colors.white, fontSize: 11),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(JmsBuildInfo.id),
                            if (enabled) ...[
                              const AmbientControls(),
                              Text(context.localized.jmsAmbientPreview),
                              ValueListenableBuilder<AmbientSamplePreview?>(
                                valueListenable: ambient.preview,
                                builder: (context, sample, child) => sample == null
                                    ? Text(context.localized.jmsAmbientWaiting)
                                    : RepaintBoundary(
                                        child: CustomPaint(
                                            size: const Size(128, 72), painter: AmbientPreviewPainter(sample))),
                              ),
                              Text('source: ${ambient.source}; ${ambient.sampleStatus}; ${ambient.contentChange}'),
                              Text(
                                  'preview age: ${ambient.preview.value == null ? 'unknown' : '${DateTime.now().difference(ambient.preview.value!.capturedAt).inSeconds}s'}; '
                                  'available background: ${ambient.backgroundFraction < 0 ? 'unknown' : '${(ambient.backgroundFraction * 100).toStringAsFixed(1)}%'}'),
                              if (ambient.backgroundFraction >= 0 && ambient.backgroundFraction < 0.01)
                                Text(context.localized.jmsAmbientNoSpace),
                            ],
                            const Text('media_kit fork: ${JmsBuildInfo.mediaKitRevision}'),
                            Text(context.localized.jmsDiagnosticHelp),
                            for (final entry in _values.entries) Text('${entry.key}: ${entry.value}'),
                            Text('display: ${refreshRate > 0 ? '${refreshRate.toStringAsFixed(1)} Hz' : 'unknown'}'),
                            Text('Flutter last 600 frames: ${_frames.summary(refreshRate)}'),
                            Text('ambient: ${enabled ? (ambient.running ? 'running' : 'suspended') : 'off'}; '
                                'copy: toImage → blur → toImage; ${ambient.size} px'),
                            Text(
                                'capture: ${milliseconds(ambient.captureMicros)}; blur/image: ${milliseconds(ambient.blurMicros)}'),
                            Text(
                                'samples ${ambient.captures}; failures ${ambient.failures}; in-flight ${ambient.inFlight}'),
                            Text('images allocated/released: ${ambient.allocated}/${ambient.released}; '
                                'retained ${ambient.retainedBytes} B; peak estimate ${ambient.peakImageBytes} B (not GPU)'),
                            ValueListenableBuilder<AmbientComposition>(
                              valueListenable: widget.composition,
                              builder: (context, mode, child) => DropdownButton<AmbientComposition>(
                                isExpanded: true,
                                value: mode,
                                items: [
                                  DropdownMenuItem(
                                      value: AmbientComposition.direct,
                                      child: Text(context.localized.jmsAmbientDirect)),
                                  DropdownMenuItem(
                                      value: AmbientComposition.previous,
                                      child: Text(context.localized.jmsAmbientPrevious)),
                                  DropdownMenuItem(
                                      value: AmbientComposition.legacy,
                                      child: Text(context.localized.jmsAmbientLegacy)),
                                ],
                                onChanged: (value) {
                                  if (value != null) widget.composition.value = value;
                                  _frames.clear();
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
