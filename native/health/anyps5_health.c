// The launcher's stall watchdog (lib/core/launcher_health.dart) reads the interface's thread with
// this while that thread is stuck: its id, and on Windows (x64) its CPU time and its stack.
//
// The stack: the thread is held (SuspendThread) only while its registers and the top of its stack
// are copied into memory set aside beforehand, with nothing allocated or locked in between, then
// let go. Its frames are unwound from that copy (RtlVirtualUnwind) and named after their module
// on a thread of their own, which the caller waits for a limited time: a stuck thread that holds a
// lock the unwinding needs cannot hold the watchdog too. Linux reads the thread from /proc in Dart.

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#ifndef PSAPI_VERSION
#define PSAPI_VERSION 2
#endif
#include <windows.h>
#include <psapi.h>
#define ANYPS5_EXPORT __declspec(dllexport)
#else
#include <pthread.h>
#include <unistd.h>
#if defined(__linux__)
#include <sys/syscall.h>
#endif
#define ANYPS5_EXPORT __attribute__((visibility("default")))
#endif

#if defined(_WIN32) && defined(_M_X64)
static void prepare(void);
#endif

// The id of the calling thread: the kernel's thread id (Linux), the Win32 thread id (Windows).
// Called at start, while nothing is stuck: what a sample needs from the loader is looked up now.
ANYPS5_EXPORT int64_t anyps5_health_thread_id(void) {
#ifdef _WIN32
#if defined(_M_X64)
  prepare();
#endif
  return (int64_t)GetCurrentThreadId();
#elif defined(__APPLE__)
  uint64_t id = 0;
  pthread_threadid_np(NULL, &id);
  return (int64_t)id;
#elif defined(__linux__)
  return (int64_t)syscall(SYS_gettid);
#else
  return -1;
#endif
}

// The CPU time thread `id` has used, user and kernel, in ms; -1 when it cannot be read (and on
// anything but Windows).
ANYPS5_EXPORT int64_t anyps5_health_cpu_ms(int64_t id) {
#ifdef _WIN32
  HANDLE thread = OpenThread(THREAD_QUERY_LIMITED_INFORMATION, FALSE, (DWORD)id);
  if (thread == NULL) return -1;
  FILETIME created, exited, kernel, user;
  int64_t ms = -1;
  if (GetThreadTimes(thread, &created, &exited, &kernel, &user)) {
    ULARGE_INTEGER k, u;
    k.LowPart = kernel.dwLowDateTime;
    k.HighPart = kernel.dwHighDateTime;
    u.LowPart = user.dwLowDateTime;
    u.HighPart = user.dwHighDateTime;
    ms = (int64_t)((k.QuadPart + u.QuadPart) / 10000);
  }
  CloseHandle(thread);
  return ms;
#else
  (void)id;
  return -1;
#endif
}

#if defined(_WIN32) && defined(_M_X64)

#define FRAMES 24
#define STACK_COPY (128 * 1024)
#define TEXT 4096

typedef LONG(NTAPI *QueryThread)(HANDLE, int, PVOID, ULONG, PULONG);

typedef struct {
  LONG ExitStatus;
  PVOID TebBaseAddress;
  PVOID UniqueProcess;
  PVOID UniqueThread;
  ULONG_PTR AffinityMask;
  LONG Priority;
  LONG BasePriority;
} ThreadBasic;

// One sample at a time, in memory set aside here: nothing is allocated while the thread is held.
static volatile LONG busy = 0;
static __declspec(align(16)) CONTEXT held;
static unsigned char copy[STACK_COPY + 64];
static DWORD64 copied_from;
static SIZE_T copied;
static char text[TEXT];
static int lines;
static QueryThread query = NULL;

static void prepare(void) {
  if (query != NULL) return;
  HMODULE ntdll = GetModuleHandleA("ntdll.dll");
  if (ntdll != NULL) query = (QueryThread)(void *)GetProcAddress(ntdll, "NtQueryInformationThread");
}

// "ntdll.dll +0x9d1b4", or the allocation the code lies in when it is in no module (Dart's code).
static void name(DWORD64 address, char *out, size_t size) {
  MEMORY_BASIC_INFORMATION region;
  if (VirtualQuery((LPCVOID)address, &region, sizeof region) == 0) {
    snprintf(out, size, "? 0x%llx", (unsigned long long)address);
    return;
  }
  DWORD64 base = (DWORD64)region.AllocationBase;
  if (region.Type == MEM_IMAGE) {
    char path[MAX_PATH];
    // The mapped file's name comes from the kernel, without the loader's lock.
    DWORD length = GetMappedFileNameA(GetCurrentProcess(), (LPVOID)address, path, MAX_PATH);
    const char *file = "?";
    if (length > 0) {
      path[length < MAX_PATH ? length : MAX_PATH - 1] = 0;
      const char *slash = strrchr(path, '\\');
      file = slash ? slash + 1 : path;
    }
    snprintf(out, size, "%s +0x%llx", file, (unsigned long long)(address - base));
  } else {
    snprintf(out, size, "(no module, Dart code?) 0x%llx +0x%llx", (unsigned long long)base,
             (unsigned long long)(address - base));
  }
}

static int in_copy(DWORD64 address, SIZE_T bytes) {
  DWORD64 low = (DWORD64)copy, high = (DWORD64)copy + copied;
  return address >= low && address + bytes <= high;
}

// An address on the thread's real stack, moved to the copy; other values stay as they are.
static DWORD64 moved(DWORD64 value) {
  if (value >= copied_from && value < copied_from + copied) return value - copied_from + (DWORD64)copy;
  return value;
}

static DWORD WINAPI unwind(LPVOID unused) {
  (void)unused;
  CONTEXT context = held;
  context.Rsp = moved(context.Rsp);
  context.Rbp = moved(context.Rbp);
  size_t used = 0;
  text[0] = 0;
  for (int index = 0; index < FRAMES; index++) {
    DWORD64 pc = context.Rip;
    if (pc == 0) break;
    char frame[MAX_PATH + 64];
    name(pc, frame, sizeof frame);
    int wrote = snprintf(text + used, TEXT - used, "%d  %s\n", index, frame);
    if (wrote < 0 || (size_t)wrote >= TEXT - used) break;
    used += (size_t)wrote;
    lines = index + 1;
    __try {
      DWORD64 image = 0;
      PRUNTIME_FUNCTION function = RtlLookupFunctionEntry(pc, &image, NULL);
      MEMORY_BASIC_INFORMATION region;
      int module = VirtualQuery((LPCVOID)pc, &region, sizeof region) != 0 && region.Type == MEM_IMAGE;
      if (function != NULL) {
        PVOID handler = NULL;
        DWORD64 establisher = 0;
        RtlVirtualUnwind(UNW_FLAG_NHANDLER, image, pc, function, &context, &handler, &establisher, NULL);
      } else if (!module && in_copy(context.Rbp, 16)) {
        // Dart's code keeps a frame pointer chain: the caller's rbp, then the return address.
        DWORD64 frame_at = context.Rbp;
        context.Rip = *(DWORD64 *)(frame_at + 8);
        context.Rsp = frame_at + 16;
        context.Rbp = *(DWORD64 *)frame_at;
      } else if (in_copy(context.Rsp, 8)) {
        // A leaf function: the return address is on top of the stack.
        context.Rip = *(DWORD64 *)context.Rsp;
        context.Rsp += 8;
      } else {
        break;
      }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
      break;
    }
    // What was restored from the copy points at the real stack: back to the copy.
    context.Rbp = moved(context.Rbp);
    if (!in_copy(context.Rsp, 8)) break;
  }
  InterlockedExchange(&busy, 0);
  return 0;
}

#endif

// Thread `id`'s stack, a frame a line, into `out` (`size` bytes, ended with a 0): the number of
// frames, or -1 with the reason in `out`. Waits at most `wait_ms` for the frames to be named.
ANYPS5_EXPORT int32_t anyps5_health_stack(int64_t id, char *out, int32_t size, int32_t wait_ms) {
  if (out == NULL || size <= 0) return -1;
  out[0] = 0;
#if defined(_WIN32) && defined(_M_X64)
  prepare();
  // A thread that held itself would never be let go.
  if ((DWORD)id == GetCurrentThreadId()) {
    snprintf(out, (size_t)size, "the thread is the watchdog's own");
    return -1;
  }
  if (InterlockedCompareExchange(&busy, 1, 0) != 0) {
    snprintf(out, (size_t)size, "an earlier sample is still being unwound");
    return -1;
  }
  HANDLE thread = OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION, FALSE, (DWORD)id);
  if (thread == NULL) {
    snprintf(out, (size_t)size, "the thread could not be opened (error %lu)", GetLastError());
    InterlockedExchange(&busy, 0);
    return -1;
  }
  // Where the thread's stack ends: its TEB's StackBase, read before it is held.
  DWORD64 stack_base = 0;
  ThreadBasic basic;
  if (query != NULL && query(thread, 0, &basic, sizeof basic, NULL) >= 0 && basic.TebBaseAddress != NULL) {
    stack_base = (DWORD64)((NT_TIB *)basic.TebBaseAddress)->StackBase;
  }
  memset(&held, 0, sizeof held);
  held.ContextFlags = CONTEXT_FULL;
  copied = 0;
  int got = 0;
  if (SuspendThread(thread) != (DWORD)-1) {
    // GetThreadContext also waits until the thread is really held.
    if (GetThreadContext(thread, &held)) {
      got = 1;
      DWORD64 sp = held.Rsp;
      if (stack_base > sp) {
        SIZE_T length = (SIZE_T)(stack_base - sp);
        if (length > STACK_COPY) length = STACK_COPY;
        __try {
          memcpy(copy, (const void *)sp, length);
          copied = length;
        } __except (EXCEPTION_EXECUTE_HANDLER) {
          copied = 0;
        }
      }
      copied_from = sp;
    }
    ResumeThread(thread);
  }
  CloseHandle(thread);
  if (!got) {
    snprintf(out, (size_t)size, "the thread could not be held");
    InterlockedExchange(&busy, 0);
    return -1;
  }
  lines = 0;
  HANDLE worker = CreateThread(NULL, 0, unwind, NULL, 0, NULL);
  if (worker == NULL) {
    snprintf(out, (size_t)size, "no thread to unwind it on");
    InterlockedExchange(&busy, 0);
    return -1;
  }
  DWORD waited = WaitForSingleObject(worker, wait_ms > 0 ? (DWORD)wait_ms : 0);
  CloseHandle(worker);
  if (waited != WAIT_OBJECT_0) {
    // The worker clears `busy` itself whenever it finishes.
    snprintf(out, (size_t)size, "unwinding it did not finish in %d ms", wait_ms);
    return -1;
  }
  snprintf(out, (size_t)size, "%s", text);
  return lines;
#else
  (void)id;
  (void)wait_ms;
  snprintf(out, (size_t)size, "not read on this system");
  return -1;
#endif
}
