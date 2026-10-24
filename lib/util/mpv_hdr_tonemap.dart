import 'dart:async';
import 'dart:convert';

typedef HdrPropertyReader = Future<String> Function(String name);
typedef HdrNativeCommand = Future<void> Function(List<String> arguments);

/// Server classification is required as well as decoded PQ metadata. PQ alone
/// must not silently classify a Dolby Vision base layer as ordinary HDR10.
class MpvHdrSource {
  const MpvHdrSource({this.range = '', this.dolbyVision = false, this.transcoded = false});

  final String range;
  final bool dolbyVision;
  final bool transcoded;

  String? get skipReason {
    if (dolbyVision || range.toUpperCase().contains('DOVI')) return 'Dolby Vision is not supported by this SDR policy';
    if (range.toUpperCase() == 'SDR') return 'SDR bypass';
    if (range.toUpperCase() != 'HDR10') return 'Input is not confirmed plain HDR10 ($range)';
    if (transcoded) return 'Transcoded output is not independently classified as HDR10';
    return null;
  }
}

class MpvHdrDecision {
  const MpvHdrDecision(this.reason, {this.applied = false, this.cancelled = false, this.failed = false});
  final String reason;
  final bool applied;
  final bool cancelled;
  final bool failed;
}

/// Load ordering is testable without a real player/texture. A paused open can
/// still render, so only confirmed candidates (and transitions from our filter)
/// keep the texture covered through native output confirmation and a frame
/// barrier. Unsupported/SDR inputs otherwise retain the existing fast path.
Future<void> openMpvWithHdr({
  required MpvHdrToneMapper mapper,
  required MpvHdrSource source,
  required bool play,
  required bool Function() isCurrent,
  required void Function(bool ready) surfaceReady,
  required Future<void> Function() pause,
  required Future<void> Function(bool play) open,
  required Future<void> Function() resume,
  required Future<void> Function() stop,
  required Future<void> Function() frameBarrier,
  bool Function()? shouldResume,
  bool forceSurfaceGate = false,
}) async {
  if (!isCurrent()) return;
  final generation = mapper.begin();
  bool current() => isCurrent() && mapper.current(generation);
  final gate = source.skipReason == null || mapper.applied || forceSurfaceGate;
  var failedAndStopped = false;
  var failureGeneration = -1;
  var safeToUncover = false;
  try {
    if (gate) {
      surfaceReady(false);
      // Publish the black cover before a paused native open can render its
      // first (not-yet-tone-mapped) frame. A timeout must fail closed.
      await frameBarrier();
      if (!current()) return;
      await pause();
    }
    if (!current() || !await mapper.resetForMedia(generation) || !current()) return;
    await open(gate ? false : play);
    if (!current()) return;
    final result = await mapper.prepare(generation, source);
    if (!current() || result.cancelled) return;
    if (result.failed) throw StateError(result.reason);
    if (gate) {
      await frameBarrier();
      if (!current()) return;
      if (shouldResume?.call() ?? play) await resume();
    }
    safeToUncover = true;
  } catch (_) {
    if (current()) {
      // The cover itself may have failed to commit. Stop native output before
      // removing a previously valid SDR conversion, including on timeout.
      await stop();
      if (current()) {
        failedAndStopped = true;
        try {
          final clearing = mapper.clear(reason: 'load failed');
          failureGeneration = mapper._generation;
          await clearing;
          safeToUncover = true;
        } catch (_) {}
      }
    }
    rethrow;
  } finally {
    if (safeToUncover &&
        isCurrent() &&
        (mapper.current(generation) || (failedAndStopped && mapper.current(failureGeneration)))) {
      surfaceReady(true);
    }
  }
}

Future<void> stopMpvWithHdr({
  required MpvHdrToneMapper mapper,
  required bool Function() isCurrent,
  required Future<void> Function() stop,
  required void Function(bool ready) surfaceReady,
  String reason = 'stopped',
  bool forceCover = false,
  bool uncover = true,
}) async {
  if (!isCurrent()) return;
  var generation = mapper.begin();
  if (mapper.applied || forceCover) surfaceReady(false);
  var stopped = false;
  var cleaned = false;
  try {
    await stop();
    stopped = true;
    if (isCurrent() && mapper.current(generation)) {
      final clearing = mapper.clear(reason: reason);
      generation = mapper._generation;
      await clearing;
      cleaned = true;
    }
  } finally {
    if (uncover && stopped && cleaned && isCurrent() && mapper.current(generation)) surfaceReady(true);
  }
}

/// A small, serialised owner of one labelled vf entry. It never sets the vf
/// property or removes/reorders somebody else's filters.
class MpvHdrToneMapper {
  MpvHdrToneMapper({
    required this.softwareRenderer,
    required this.read,
    required this.command,
    this.attempts = 40,
    this.pollInterval = const Duration(milliseconds: 25),
    Future<void> Function(Duration)? delay,
  }) : delay = delay ?? Future<void>.delayed;

  static const label = 'jms_hdr10_sdr_v1';
  static String filterForPeak(double peakNits) {
    if (!peakNits.isFinite || peakNits <= 0 || peakNits > 10000) throw ArgumentError.value(peakNits, 'peakNits');
    // zscale removes color-dependent AVFrame side data before tonemap. Capture
    // the physical peak first; FFmpeg's auto fallback is not the source peak.
    final peak = peakNits / 100;
    return '@$label:lavfi=['
        'zscale=pin=2020:tin=smpte2084:min=2020_ncl:rin=limited:t=linear:npl=100,'
        'format=gbrpf32le,zscale=p=709,tonemap=tonemap=hable:desat=0:peak=$peak,'
        'zscale=t=709:m=709:r=limited,format=yuv420p]';
  }

  final bool softwareRenderer;
  final HdrPropertyReader read;
  final HdrNativeCommand command;
  final int attempts;
  final Duration pollInterval;
  final Future<void> Function(Duration) delay;
  int _generation = 0;
  bool _mayOwnFilter = false;
  bool _applied = false;
  Future<void> _mutations = Future.value();
  Map<String, String> _diagnostics = {'HDR SDR policy': 'not evaluated'};

  bool get applied => _applied;
  Map<String, String> get diagnostics => Map.unmodifiable(_diagnostics);
  bool current(int generation) => generation == _generation;

  int begin() => ++_generation;

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _mutations.then((_) => action());
    _mutations = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<void> _remove() async {
    if (!_mayOwnFilter) return;
    await command(['vf', 'remove', '@$label']);
    if ((await read('vf')).contains(label)) throw StateError('The labelled HDR filter was not removed');
    _mayOwnFilter = false;
    _applied = false;
  }

  Future<void> clear({String reason = 'stopped'}) async {
    final generation = ++_generation;
    await _serial(_remove);
    if (current(generation)) _diagnostics = {'HDR SDR policy': reason};
  }

  Future<bool> resetForMedia(int generation) async {
    if (!current(generation)) return false;
    await _serial(_remove);
    return current(generation);
  }

  Future<MpvHdrDecision> prepare(int generation, MpvHdrSource source) async {
    const cancelled = MpvHdrDecision('Superseded media generation', cancelled: true);
    if (!current(generation)) return cancelled;
    await _serial(_remove);
    if (!current(generation)) return cancelled;
    String? skip = !softwareRenderer ? 'Renderer is not a confirmed software SDR texture path' : source.skipReason;
    if (skip != null) {
      _diagnostics = {'HDR SDR policy': skip};
      return MpvHdrDecision(skip);
    }
    _diagnostics = {'HDR SDR policy': 'Waiting for decoded HDR10 metadata', 'HDR source classification': source.range};
    Map<String, String> metadata = {};
    try {
      for (var attempt = 0; attempt < attempts; attempt++) {
        metadata = await _readMetadata();
        if (!current(generation)) return cancelled;
        if (metadata['gamma']?.isNotEmpty == true && metadata['gamma'] != 'auto') break;
        await delay(pollInterval);
        if (!current(generation)) return cancelled;
      }
      skip = _metadataSkip(metadata);
      if (skip != null) {
        _diagnostics = {'HDR SDR policy': skip, ...metadata};
        return MpvHdrDecision(skip);
      }
      final peakNits = _peak(metadata)!;
      return await _serial(() async {
        if (!current(generation)) return cancelled;
        try {
          final userFilters = await read('vf');
          if (!current(generation)) return cancelled;
          final unsafeFilters = _filterSkip(userFilters);
          if (unsafeFilters != null) {
            _diagnostics = {'HDR SDR policy': unsafeFilters, ...metadata};
            return MpvHdrDecision(unsafeFilters);
          }
          _mayOwnFilter = true;
          // Prepend, so the declared PQ input has not already been transformed
          // by a user's existing video filters. Their order/content is retained.
          await command(['vf', 'pre', filterForPeak(peakNits)]);
          if (!current(generation)) {
            await _remove();
            return cancelled;
          }
          for (var attempt = 0; attempt < attempts; attempt++) {
            final values = await Future.wait([
              read('vf'),
              read('video-out-params/primaries'),
              read('video-out-params/gamma'),
              read('video-out-params/colormatrix'),
              read('video-out-params/colorlevels'),
            ]);
            if (!current(generation)) {
              await _remove();
              return cancelled;
            }
            if (values[0].contains(label) &&
                values[1] == 'bt.709' &&
                values[2] == 'bt.1886' &&
                values[3] == 'bt.709' &&
                values[4] == 'limited') {
              _applied = true;
              _diagnostics = {
                'HDR SDR policy': 'HDR10/PQ to SDR applied',
                ...metadata,
                'HDR filter label': label,
                'HDR peak policy': '${metadata['max-cll']} max-cll / ${metadata['max-luma']} max-luma; '
                    'selected $peakNits nit / npl=100 = ${peakNits / 100}; explicit before linearization',
                'HDR output': 'BT.709 / BT.1886 / limited, 8-bit YUV before software RGB texture',
              };
              return const MpvHdrDecision('HDR10/PQ to SDR applied', applied: true);
            }
            await delay(pollInterval);
          }
          throw StateError('The labelled HDR filter did not confirm an SDR output frame');
        } catch (error) {
          try {
            await _remove();
          } catch (_) {
            // Keep ownership for a subsequent stop/dispose cleanup attempt.
          }
          if (!current(generation)) return cancelled;
          _diagnostics = {'HDR SDR policy': 'Failed: $error', ...metadata};
          return MpvHdrDecision('HDR to SDR filter failed: $error', failed: true);
        }
      });
    } catch (error) {
      if (!current(generation)) return cancelled;
      _diagnostics = {'HDR SDR policy': 'Metadata unavailable: $error'};
      return const MpvHdrDecision('Decoded HDR metadata unavailable');
    }
  }

  Future<Map<String, String>> _readMetadata() async {
    const keys = [
      'gamma',
      'primaries',
      'colormatrix',
      'colorlevels',
      'max-cll',
      'max-luma',
      'sig-peak',
      'dolby-vision-profile',
      'dovi-profile'
    ];
    final values = await Future.wait(keys.map((name) => read('video-dec-params/$name')));
    return Map.fromIterables(keys, values.map((value) => value.trim().toLowerCase()));
  }

  String? _metadataSkip(Map<String, String> metadata) {
    if (metadata['gamma'] != 'pq' ||
        metadata['primaries'] != 'bt.2020' ||
        metadata['colormatrix'] != 'bt.2020-ncl' ||
        metadata['colorlevels'] != 'limited') {
      return 'Decoded color metadata does not confirm PQ/BT.2020/limited';
    }
    for (final key in ['dolby-vision-profile', 'dovi-profile']) {
      final value = metadata[key] ?? '';
      if (value.isNotEmpty && value != '0' && value != 'no' && value != 'none' && value != 'unknown') {
        return 'Decoded Dolby Vision metadata is excluded';
      }
    }
    if (_peak(metadata) == null) return 'HDR peak metadata is unknown or invalid';
    return null;
  }

  double? _peak(Map<String, String> metadata) {
    final cllText = metadata['max-cll'] ?? '';
    final cll = double.tryParse(cllText);
    if (cll != null && cll != 0) return cll.isFinite && cll > 0 && cll <= 10000 ? cll : null;
    if (cll == null && cllText.isNotEmpty && cllText != 'unknown' && cllText != 'auto') return null;
    final mastering = double.tryParse(metadata['max-luma'] ?? '');
    return mastering != null && mastering.isFinite && mastering > 0 && mastering <= 10000 ? mastering : null;
  }

  String? _filterSkip(String filters) {
    if (filters.contains(label)) return 'Existing filter uses the reserved JMS HDR label; not replaced';
    final value = filters.trim();
    if (value.isEmpty || value == '[]') return null;
    const spatialOnly = {'crop', 'hflip', 'vflip', 'flip', 'mirror', 'rotate'};
    try {
      final entries = jsonDecode(value);
      if (entries is List && entries.every((entry) => entry is Map && spatialOnly.contains(entry['name']))) return null;
    } on FormatException {
      // Native string properties normally print the filter-list option syntax.
    }
    for (final entry in value.split(',')) {
      final match = RegExp(r'^(?:@[A-Za-z0-9_-]+:)?([A-Za-z0-9_-]+)(?:=.*)?$').firstMatch(entry.trim());
      if (match == null || !spatialOnly.contains(match[1])) {
        return 'Existing video filters may alter color; automatic HDR conversion skipped';
      }
    }
    return null;
  }
}

/// Subscribe, then check the current state: a paused HDR preparation may have
/// emitted all duration/buffering events before the caller starts listening.
class MpvLoadReadiness {
  MpvLoadReadiness({required this.isCurrent, required this.isReady, required this.onReady});
  final bool Function() isCurrent;
  final bool Function() isReady;
  final void Function() onReady;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  bool _completed = false;

  void observe(Iterable<Stream<Object?>> streams) {
    for (final stream in streams) {
      _subscriptions.add(stream.listen((_) => _check()));
    }
    _check();
  }

  void _check() {
    if (_completed || !isCurrent() || !isReady()) return;
    _completed = true;
    cancel();
    onReady();
  }

  void cancel() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
  }
}
