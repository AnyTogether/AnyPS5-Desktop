@DefaultAsset('package:anyps5_desktop/core/retro_host/retro_host_native.dart')
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

// native/retro_host/anyps5_retro_host.c, built by hook/build.dart: starting the emulator host with
// its control stream, the stream's reader and writer threads, and the frame ring's memory.

/// What the native callback reports, as its `kind`.
abstract final class RetroHostEvent {
  /// A whole message body: `data` and `length`, and `extra` the descriptor that came with it on
  /// Linux and macOS, or -1. Dart owns `data` and frees it with [retroHostFree].
  static const message = 0;

  /// The control stream ended.
  static const end = 1;

  /// The stream broke a framing rule (protocol.md "Framing"); `length` is the length that was out
  /// of range, when that was the cause.
  static const framing = 2;

  /// The host process ended; `extra` is its exit code, minus the signal that ended it, or
  /// [exitUnknown]. It comes after every message the host wrote before it ended, unless something
  /// else still holds the host's end of the stream: then it comes 2 seconds after the exit.
  static const exited = 3;

  /// The exit code could not be read: on Linux, the Dart VM reaped the host before the client read
  /// it (docs/RETRO_HOST_CLIENT.md).
  static const exitUnknown = -9223372036854775808;
}

typedef RetroHostCallbackNative = Void Function(
  Int64 token,
  Int32 kind,
  Pointer<Uint8> data,
  Int32 length,
  Int64 extra,
);

@Native<
  Pointer<Void> Function(
    Pointer<Pointer<Utf8>>,
    Int32,
    Pointer<Pointer<Utf8>>,
    Int32,
    Int64,
    Pointer<NativeFunction<RetroHostCallbackNative>>,
    Pointer<Utf8>,
    Int32,
  )
>(symbol: 'anyps5_rh_start')
external Pointer<Void> retroHostStart(
  Pointer<Pointer<Utf8>> argv,
  int argc,
  Pointer<Pointer<Utf8>> env,
  int envc,
  int token,
  Pointer<NativeFunction<RetroHostCallbackNative>> callback,
  Pointer<Utf8> error,
  int errorSize,
);

@Native<Int64 Function(Pointer<Void>)>(symbol: 'anyps5_rh_pid')
external int retroHostPid(Pointer<Void> connection);

@Native<Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32)>(symbol: 'anyps5_rh_send')
external int retroHostSend(Pointer<Void> connection, Pointer<Uint8> data, int length);

/// How long the write in progress has been waiting, in milliseconds: 0 with none, -1 once a write
/// has failed.
@Native<Int64 Function(Pointer<Void>)>(symbol: 'anyps5_rh_write_age_ms')
external int retroHostWriteAgeMs(Pointer<Void> connection);

@Native<Void Function(Pointer<Void>)>(symbol: 'anyps5_rh_kill')
external void retroHostKill(Pointer<Void> connection);

/// Kills the host if it still runs, waits for it and for the stream's threads, and frees the
/// connection; gives the exit code as [RetroHostEvent.exited] does. It blocks, so callers run it
/// off the UI isolate.
@Native<Int64 Function(Pointer<Void>)>(symbol: 'anyps5_rh_close')
external int retroHostClose(Pointer<Void> connection);

@Native<Void Function(Pointer<Void>)>(symbol: 'anyps5_rh_free')
external void retroHostFree(Pointer<Void> data);

/// Maps a ring after protocol.md's memory checks. On Linux and macOS [memory] is the descriptor,
/// which this closes; on Windows it is the section handle's value in the host process.
@Native<Pointer<Void> Function(Pointer<Void>, Int64, Int64, Pointer<Utf8>, Int32)>(symbol: 'anyps5_rh_map_ring')
external Pointer<Void> retroHostMapRing(
  Pointer<Void> connection,
  int memory,
  int bytes,
  Pointer<Utf8> error,
  int errorSize,
);

@Native<Void Function(Pointer<Void>, Int64)>(symbol: 'anyps5_rh_unmap_ring')
external void retroHostUnmapRing(Pointer<Void> base, int bytes);

@Native<Void Function(Int64)>(symbol: 'anyps5_rh_close_descriptor')
external void retroHostCloseDescriptor(int descriptor);

/// A sequentially consistent load of the 32-bit value at [address].
@Native<Uint32 Function(Pointer<Void>)>(symbol: 'anyps5_rh_load', isLeaf: true)
external int retroHostLoad(Pointer<Void> address);

/// A sequentially consistent store of [value] at [address].
@Native<Void Function(Pointer<Void>, Uint32)>(symbol: 'anyps5_rh_store', isLeaf: true)
external void retroHostStore(Pointer<Void> address, int value);
