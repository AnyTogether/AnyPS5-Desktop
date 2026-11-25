@DefaultAsset('package:anyps5_desktop/core/launcher_health_native.dart')
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

// native/health/anyps5_health.c, built by hook/build.dart: what the stall watchdog reads of the
// interface's thread.

/// The calling thread's id: the kernel's (Linux), the Win32 one (Windows).
@Native<Int64 Function()>(symbol: 'anyps5_health_thread_id', isLeaf: true)
external int healthThreadId();

/// The CPU time thread [id] has used in ms, or -1 (always on Linux: /proc has it).
@Native<Int64 Function(Int64)>(symbol: 'anyps5_health_cpu_ms', isLeaf: true)
external int healthCpuMs(int id);

/// Thread [id]'s stack, a frame a line, into [out]: the frames, or -1 with the reason in [out].
/// Waits at most [waitMs] for the frames to be named.
@Native<Int32 Function(Int64, Pointer<Utf8>, Int32, Int32)>(symbol: 'anyps5_health_stack')
external int healthStack(int id, Pointer<Utf8> out, int size, int waitMs);
