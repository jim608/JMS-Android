import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'discord_presence_client.dart';
import 'discord_transport_types.dart';

/// Only a local named pipe is permitted; remote UNC paths are rejected.
DiscordIpcTransport openWindowsDiscordPipe(String path,
    {required Duration timeout}) {
  if (!Platform.isWindows ||
      !RegExp(r'^\\\\[?.]\\pipe\\[a-zA-Z0-9_-]{1,100}$').hasMatch(path)) {
    throw const DiscordIpcException(DiscordIpcFailure.unavailable);
  }
  final name = path.toNativeUtf16();
  final mode = calloc<Uint32>()..value = PIPE_READMODE_BYTE | PIPE_NOWAIT;
  var handle = INVALID_HANDLE_VALUE;
  try {
    handle = CreateFile(
        name, GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, 0, 0);
    if (handle == INVALID_HANDLE_VALUE ||
        SetNamedPipeHandleState(handle, mode, nullptr, nullptr) == 0) {
      throw const DiscordIpcException(DiscordIpcFailure.unavailable);
    }
    return _WindowsDiscordTransport(handle, timeout);
  } catch (_) {
    if (handle != INVALID_HANDLE_VALUE) CloseHandle(handle);
    throw const DiscordIpcException(DiscordIpcFailure.unavailable);
  } finally {
    calloc.free(name);
    calloc.free(mode);
  }
}

class _WindowsDiscordTransport implements DiscordIpcTransport {
  _WindowsDiscordTransport(this._handle, Duration timeout)
      : _writeTimeout = timeout < const Duration(seconds: 1)
            ? timeout
            : const Duration(seconds: 1) {
    _incoming = StreamController<Uint8List>(onListen: () {
      _poll = Timer.periodic(
          const Duration(milliseconds: 20), (_) => _readAvailable());
    });
  }

  final int _handle;
  final Duration _writeTimeout;
  late final StreamController<Uint8List> _incoming;
  Timer? _poll;
  bool _closed = false;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  void _readAvailable() {
    if (_closed || _incoming.isPaused) return;
    final available = calloc<Uint32>();
    final count = calloc<Uint32>();
    final buffer = calloc<Uint8>(4096);
    try {
      // Bounded work per tick. PIPE_NOWAIT also protects the read/peek race.
      for (var batch = 0; batch < 4 && !_closed; batch++) {
        if (PeekNamedPipe(_handle, nullptr, 0, nullptr, available, nullptr) ==
            0) {
          _fail();
          return;
        }
        if (available.value == 0) return;
        final length = available.value < 4096 ? available.value : 4096;
        if (ReadFile(_handle, buffer, length, count, nullptr) == 0) {
          if (GetLastError() == ERROR_NO_DATA) return;
          _fail();
          return;
        }
        if (count.value == 0) return;
        _incoming.add(Uint8List.fromList(buffer.asTypedList(count.value)));
      }
    } finally {
      calloc.free(available);
      calloc.free(count);
      calloc.free(buffer);
    }
  }

  void _fail() {
    if (_closed) return;
    _incoming
        .addError(const DiscordIpcException(DiscordIpcFailure.unavailable));
    unawaited(close());
  }

  @override
  Future<void> write(Uint8List bytes) async {
    if (_closed) throw const DiscordIpcException(DiscordIpcFailure.closed);
    final buffer = calloc<Uint8>(bytes.length);
    final written = calloc<Uint32>();
    buffer.asTypedList(bytes.length).setAll(0, bytes);
    final clock = Stopwatch()..start();
    try {
      var offset = 0;
      while (offset < bytes.length) {
        if (_closed) throw const DiscordIpcException(DiscordIpcFailure.closed);
        if (clock.elapsed >= _writeTimeout) {
          throw const DiscordIpcException(DiscordIpcFailure.timeout);
        }
        written.value = 0;
        final remaining = bytes.length - offset;
        final length = remaining < 4096 ? remaining : 4096;
        if (WriteFile(_handle, buffer + offset, length, written, nullptr) ==
            0) {
          throw const DiscordIpcException(DiscordIpcFailure.unavailable);
        }
        // A nonblocking byte pipe may accept a partial write, including zero.
        offset += written.value;
        if (offset < bytes.length) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }
    } on DiscordIpcException {
      await close();
      rethrow;
    } finally {
      calloc.free(buffer);
      calloc.free(written);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _poll?.cancel();
    CloseHandle(_handle);
    // Do not await a paused subscriber while releasing the OS handle.
    unawaited(_incoming.close());
  }
}
