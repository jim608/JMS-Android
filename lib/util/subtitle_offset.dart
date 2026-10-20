import 'package:flutter/foundation.dart';

/// Signed playback-local offsets: positive values show subtitles later.
class SubtitleOffsetController extends ChangeNotifier {
  SubtitleOffsetController({
    required Future<void> Function(String property, String value) write,
    Future<String> Function(String property)? read,
    Future<void> Function()? refresh,
    bool supportsSecondary = true,
  })  : _write = write,
        _read = read,
        _refresh = refresh,
        _supportsSecondary = supportsSecondary;

  static const step = Duration(milliseconds: 100);
  static const limit = Duration(seconds: 60);

  bool _supportsSecondary;
  bool get supportsSecondary => _supportsSecondary;

  /// Called after capability discovery, before opening media. The controller
  /// also exists during init/dispose, before a native player can be queried.
  void setSecondarySupported(bool supported) {
    if (_closed || _supportsSecondary == supported) return;
    _supportsSecondary = supported;
    if (!supported) {
      _secondaryAvailable = false;
      _secondary = Duration.zero;
    }
    notifyListeners();
  }

  final Future<void> Function(String property, String value) _write;
  final Future<String> Function(String property)? _read;
  final Future<void> Function()? _refresh;
  Future<void> _tail = Future.value();
  int _generation = 0;
  int _pending = 0;
  Duration _primary = Duration.zero;
  Duration _secondary = Duration.zero;
  bool _failed = false;
  bool _primaryAvailable = false;
  bool _secondaryAvailable = false;
  bool _closed = false;

  Duration get primary => _primary;
  Duration get secondary => _secondary;
  bool get busy => _pending > 0;
  bool get failed => _failed;
  bool get primaryAvailable => _primaryAvailable;
  bool get secondaryAvailable => _secondaryAvailable;
  Future<void> get idle => _tail;

  void setAvailable({required bool primary, required bool secondary}) {
    if (_closed) return;
    secondary = secondary && supportsSecondary;
    if (_primaryAvailable == primary && _secondaryAvailable == secondary) {
      return;
    }
    _primaryAvailable = primary;
    _secondaryAvailable = secondary;
    notifyListeners();
  }

  Future<bool> setOffset(Duration offset, {bool secondary = false}) {
    if (secondary && !supportsSecondary) return Future.value(false);
    final milliseconds = offset.inMilliseconds
        .clamp(-limit.inMilliseconds, limit.inMilliseconds);
    final value = Duration(milliseconds: milliseconds);
    return _enqueue(_generation, (current) async {
      await _apply(secondary ? 'secondary-sub-delay' : 'sub-delay',
          (milliseconds / 1000).toStringAsFixed(3));
      if (!current()) return;
      if (secondary) {
        _secondary = value;
      } else {
        _primary = value;
      }
      await _refresh?.call();
    });
  }

  /// Cancel old results immediately; restore the engine before opening new media.
  Future<bool> resetForMedia() {
    clear();
    return _enqueue(_generation, (current) async {
      await _apply('sub-delay', '0.000');
      if (!current()) return;
      if (supportsSecondary) await _apply('secondary-sub-delay', '0.000');
    });
  }

  /// Invalidates queued work when the player is stopped or replaced.
  void clear() {
    if (_closed) return;
    _generation++;
    _primary = Duration.zero;
    _secondary = Duration.zero;
    _failed = false;
    _primaryAvailable = false;
    _secondaryAvailable = false;
    notifyListeners();
  }

  Future<void> _apply(String property, String value) async {
    await _write(property, value);
    final read = _read;
    if (read == null) return;
    final actual = double.tryParse(await read(property));
    if (actual == null || (actual - double.parse(value)).abs() > 0.0005) {
      throw StateError('Subtitle timing readback did not match');
    }
  }

  Future<bool> _enqueue(
      int generation, Future<void> Function(bool Function() current) action) {
    if (_closed) return Future.value(false);
    bool current() => !_closed && generation == _generation;
    _pending++;
    notifyListeners();
    final result = _tail.then((_) async {
      if (!current()) return false;
      try {
        await action(current);
        if (!current()) return false;
        _failed = false;
        return true;
      } catch (_) {
        if (current()) _failed = true;
        return false;
      }
    }).whenComplete(() {
      _pending--;
      if (!_closed) notifyListeners();
    });
    _tail = result.then<void>((_) {});
    return result;
  }

  @override
  void dispose() {
    _closed = true;
    _generation++;
    super.dispose();
  }
}
