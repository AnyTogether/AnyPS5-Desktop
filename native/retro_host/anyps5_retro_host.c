// The launcher's side of the emulator host's control stream and frame ring
// (anyps5-retro-host docs/protocol.md, version 1): starting the host with its
// stream, reading and writing whole messages on threads of their own, watching
// the host exit, and mapping the shared frame memory after the checks the
// protocol asks for. Everything that reads JSON or decides what a message
// means is Dart (lib/core/retro_host/); this file moves bytes and handles.
//
// Messages, end of stream, framing errors and the host's exit reach Dart
// through one callback, which Dart makes with NativeCallable.listener, so it
// can be called from these threads and never blocks them.
#if defined(__linux__)
#define _GNU_SOURCE
#endif
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#define ANYPS5_EXPORT __declspec(dllexport)
#else
#define ANYPS5_EXPORT __attribute__((visibility("default")))
#endif

// What the callback reports, as `kind`.
#define EVENT_MESSAGE 0
#define EVENT_END 1
#define EVENT_FRAMING 2
#define EVENT_EXITED 3

// The `extra` of EVENT_EXITED when the exit code could not be read: another
// part of the launcher reaped the host first (Linux without pidfd only).
#define EXIT_UNKNOWN INT64_MIN

#define MIN_MESSAGE 2
#define MAX_MESSAGE 1048576

typedef void (*anyps5_rh_callback)(int64_t token, int32_t kind, uint8_t* data, int32_t length, int64_t extra);

static void set_error(char* error, int32_t size, const char* text) {
  if (error && size > 0) snprintf(error, (size_t)size, "%s", text);
}

#if defined(_WIN32)

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

typedef struct Outgoing {
  struct Outgoing* next;
  int32_t length;
  uint8_t data[];
} Outgoing;

typedef struct Connection {
  int64_t token;
  anyps5_rh_callback callback;
  HANDLE process;
  HANDLE job;
  DWORD pid;
  HANDLE read_pipe;
  HANDLE write_pipe;
  HANDLE reader;
  HANDLE writer;
  HANDLE waiter;
  CRITICAL_SECTION lock;
  CONDITION_VARIABLE wake;
  Outgoing* first;
  Outgoing* last;
  int closing;
  volatile LONG64 write_started;
  int64_t exit_code;
} Connection;

static SRWLOCK g_spawn_lock = SRWLOCK_INIT;

static int read_exact(HANDLE pipe, uint8_t* out, DWORD size) {
  DWORD done = 0;
  while (done < size) {
    DWORD got = 0;
    if (!ReadFile(pipe, out + done, size - done, &got, NULL) || got == 0) return 0;
    done += got;
  }
  return 1;
}

static DWORD WINAPI reader_main(void* argument) {
  Connection* c = (Connection*)argument;
  for (;;) {
    uint8_t prefix[4];
    if (!read_exact(c->read_pipe, prefix, 4)) break;
    uint32_t length = (uint32_t)prefix[0] | (uint32_t)prefix[1] << 8 | (uint32_t)prefix[2] << 16 |
                      (uint32_t)prefix[3] << 24;
    if (length < MIN_MESSAGE || length > MAX_MESSAGE) {
      c->callback(c->token, EVENT_FRAMING, NULL, (int32_t)length, -1);
      return 0;
    }
    uint8_t* body = (uint8_t*)malloc(length);
    if (!body) {
      c->callback(c->token, EVENT_FRAMING, NULL, -1, -1);
      return 0;
    }
    if (!read_exact(c->read_pipe, body, length)) {
      free(body);
      break;
    }
    c->callback(c->token, EVENT_MESSAGE, body, (int32_t)length, -1);
  }
  c->callback(c->token, EVENT_END, NULL, 0, -1);
  return 0;
}

static DWORD WINAPI writer_main(void* argument) {
  Connection* c = (Connection*)argument;
  for (;;) {
    EnterCriticalSection(&c->lock);
    while (!c->first && !c->closing) SleepConditionVariableCS(&c->wake, &c->lock, INFINITE);
    if (!c->first) {
      LeaveCriticalSection(&c->lock);
      return 0;
    }
    Outgoing* item = c->first;
    c->first = item->next;
    if (!c->first) c->last = NULL;
    int closing = c->closing;
    LeaveCriticalSection(&c->lock);
    if (closing) {
      free(item);
      return 0;
    }
    InterlockedExchange64(&c->write_started, (LONG64)GetTickCount64());
    DWORD done = 0;
    int ok = 1;
    while (ok && done < (DWORD)item->length) {
      DWORD wrote = 0;
      ok = WriteFile(c->write_pipe, item->data + done, (DWORD)item->length - done, &wrote, NULL) && wrote > 0;
      done += wrote;
    }
    InterlockedExchange64(&c->write_started, 0);
    free(item);
    if (!ok) {
      InterlockedExchange64(&c->write_started, -1);
      return 0;
    }
  }
}

// Reports the exit after the reader has passed on everything the host wrote
// before it ended (or 2 seconds, if something else still holds its pipe), so a
// last reply is never overtaken by the exit.
static DWORD WINAPI waiter_main(void* argument) {
  Connection* c = (Connection*)argument;
  WaitForSingleObject(c->process, INFINITE);
  WaitForSingleObject(c->reader, 2000);
  DWORD code = 0;
  GetExitCodeProcess(c->process, &code);
  c->exit_code = (int64_t)code;
  c->callback(c->token, EVENT_EXITED, NULL, 0, (int64_t)code);
  return 0;
}

// Appends one argument to a command line the way CommandLineToArgvW and the
// C runtime read it back.
static int append_argument(wchar_t** line, size_t* used, size_t* room, const wchar_t* argument) {
  size_t length = wcslen(argument);
  size_t need = *used + 3 + length * 2 + 2;
  if (need > *room) {
    size_t grown = need * 2;
    wchar_t* bigger = (wchar_t*)realloc(*line, grown * sizeof(wchar_t));
    if (!bigger) return 0;
    *line = bigger;
    *room = grown;
  }
  wchar_t* out = *line + *used;
  if (*used) *out++ = L' ';
  *out++ = L'"';
  size_t slashes = 0;
  for (size_t i = 0; i < length; ++i) {
    if (argument[i] == L'\\') {
      ++slashes;
    } else if (argument[i] == L'"') {
      for (size_t s = 0; s < slashes + 1; ++s) *out++ = L'\\';
      slashes = 0;
    } else {
      slashes = 0;
    }
    *out++ = argument[i];
  }
  for (size_t s = 0; s < slashes; ++s) *out++ = L'\\';
  *out++ = L'"';
  *out = 0;
  *used = (size_t)(out - *line);
  return 1;
}

static wchar_t* widen(const char* text) {
  int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, NULL, 0);
  if (size <= 0) return NULL;
  wchar_t* wide = (wchar_t*)malloc((size_t)size * sizeof(wchar_t));
  if (wide && MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, wide, size) <= 0) {
    free(wide);
    return NULL;
  }
  return wide;
}

// The length of an environment entry's name. A name may start with '=', as
// the hidden per-drive current directories ("=C:=C:\dir") do.
static int entry_name_length(const wchar_t* entry) {
  const wchar_t* equals = entry[0] ? wcschr(entry + 1, L'=') : NULL;
  return (int)(equals ? equals - entry : (ptrdiff_t)wcslen(entry));
}

static int same_name(const wchar_t* a, const wchar_t* b) {
  return CompareStringOrdinal(a, entry_name_length(a), b, entry_name_length(b), TRUE) == CSTR_EQUAL;
}

static int compare_entries(const void* a, const void* b) {
  const wchar_t* x = *(const wchar_t* const*)a;
  const wchar_t* y = *(const wchar_t* const*)b;
  return CompareStringOrdinal(x, entry_name_length(x), y, entry_name_length(y), TRUE) - CSTR_EQUAL;
}

// The block CreateProcessW takes: the given entries, plus the launcher's own
// hidden entries whose names start with '=' (dart:io leaves those out, and
// CreateProcessW does not add the drives' current directories to a block it
// is given), sorted by name without regard to case as Windows requires.
static wchar_t* environment_block(const char* const* env, int32_t count) {
  wchar_t* own = GetEnvironmentStringsW();
  size_t hidden = 0;
  for (const wchar_t* entry = own; entry && *entry; entry += wcslen(entry) + 1) {
    if (entry[0] == L'=') ++hidden;
  }
  wchar_t** entries = (wchar_t**)calloc((size_t)count + hidden + 1, sizeof(wchar_t*));
  wchar_t* block = NULL;
  size_t total = 0;
  size_t length = 1;
  int ok = entries != NULL;
  for (int32_t i = 0; ok && i < count; ++i) {
    entries[total] = widen(env[i]);
    ok = entries[total] != NULL;
    if (ok) length += wcslen(entries[total++]) + 1;
  }
  for (const wchar_t* entry = own; ok && entry && *entry; entry += wcslen(entry) + 1) {
    if (entry[0] != L'=') continue;
    int given = 0;
    for (size_t i = 0; i < (size_t)count && !given; ++i) given = same_name(entries[i], entry);
    if (given) continue;
    size_t size = wcslen(entry) + 1;
    entries[total] = (wchar_t*)malloc(size * sizeof(wchar_t));
    ok = entries[total] != NULL;
    if (ok) {
      memcpy(entries[total++], entry, size * sizeof(wchar_t));
      length += size;
    }
  }
  if (ok) {
    qsort(entries, total, sizeof(wchar_t*), compare_entries);
    block = (wchar_t*)malloc((length + 1) * sizeof(wchar_t));
  }
  if (block) {
    size_t used = 0;
    for (size_t i = 0; i < total; ++i) {
      size_t size = wcslen(entries[i]) + 1;
      memcpy(block + used, entries[i], size * sizeof(wchar_t));
      used += size;
    }
    if (used == 0) block[used++] = 0;
    block[used] = 0;
  }
  for (size_t i = 0; entries && i < total; ++i) free(entries[i]);
  free(entries);
  if (own) FreeEnvironmentStringsW(own);
  return block;
}

static void close_handle(HANDLE* handle) {
  if (*handle && *handle != INVALID_HANDLE_VALUE) CloseHandle(*handle);
  *handle = NULL;
}

ANYPS5_EXPORT void* anyps5_rh_start(const char* const* argv, int32_t argc, const char* const* env, int32_t envc,
                                    int64_t token, anyps5_rh_callback callback, char* error, int32_t error_size) {
  if (argc < 1) {
    set_error(error, error_size, "No host program was given.");
    return NULL;
  }
  Connection* c = (Connection*)calloc(1, sizeof(Connection));
  if (!c) {
    set_error(error, error_size, "Out of memory.");
    return NULL;
  }
  c->token = token;
  c->callback = callback;
  InitializeCriticalSection(&c->lock);
  InitializeConditionVariable(&c->wake);
  HANDLE host_read = NULL;
  HANDLE host_write = NULL;
  wchar_t* line = NULL;
  wchar_t* program = NULL;
  wchar_t* block = NULL;
  LPPROC_THREAD_ATTRIBUTE_LIST attributes = NULL;
  int started = 0;
  SECURITY_ATTRIBUTES plain = {sizeof(SECURITY_ATTRIBUTES), NULL, FALSE};
  if (!CreatePipe(&host_read, &c->write_pipe, &plain, 0) || !CreatePipe(&c->read_pipe, &host_write, &plain, 0)) {
    set_error(error, error_size, "The control stream's pipes could not be made.");
    goto fail;
  }
  size_t used = 0;
  size_t room = 0;
  program = widen(argv[0]);
  if (!program) {
    set_error(error, error_size, "The host program's path is not valid UTF-8.");
    goto fail;
  }
  for (int32_t i = 0; i < argc; ++i) {
    wchar_t* argument = widen(argv[i]);
    int ok = argument && append_argument(&line, &used, &room, argument);
    free(argument);
    if (!ok) {
      set_error(error, error_size, "An argument is not valid UTF-8.");
      goto fail;
    }
  }
  wchar_t numbers[96];
  _snwprintf(numbers, 96, L" --ipc-read %llu --ipc-write %llu --parent-pid %lu", (unsigned long long)(uintptr_t)host_read,
             (unsigned long long)(uintptr_t)host_write, (unsigned long)GetCurrentProcessId());
  numbers[95] = 0;
  wchar_t* longer = (wchar_t*)realloc(line, (used + wcslen(numbers) + 1) * sizeof(wchar_t));
  if (!longer) {
    set_error(error, error_size, "Out of memory.");
    goto fail;
  }
  line = longer;
  wcscpy(line + used, numbers);
  if (envc > 0) {
    block = environment_block(env, envc);
    if (!block) {
      set_error(error, error_size, "The host's environment is not valid UTF-8.");
      goto fail;
    }
  }
  SIZE_T size = 0;
  InitializeProcThreadAttributeList(NULL, 1, 0, &size);
  attributes = (LPPROC_THREAD_ATTRIBUTE_LIST)malloc(size);
  HANDLE inherited[2] = {host_read, host_write};
  if (!attributes || !InitializeProcThreadAttributeList(attributes, 1, 0, &size) ||
      !UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, inherited, sizeof inherited, NULL,
                                 NULL)) {
    set_error(error, error_size, "The handle list could not be made.");
    goto fail;
  }
  STARTUPINFOEXW startup;
  ZeroMemory(&startup, sizeof startup);
  startup.StartupInfo.cb = sizeof startup;
  startup.lpAttributeList = attributes;
  PROCESS_INFORMATION info;
  ZeroMemory(&info, sizeof info);
  AcquireSRWLockExclusive(&g_spawn_lock);
  SetHandleInformation(host_read, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
  SetHandleInformation(host_write, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
  BOOL created = CreateProcessW(program, line, NULL, NULL, TRUE,
                                CREATE_SUSPENDED | EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT |
                                    CREATE_NO_WINDOW,
                                block, NULL, &startup.StartupInfo, &info);
  DWORD created_error = GetLastError();
  SetHandleInformation(host_read, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(host_write, HANDLE_FLAG_INHERIT, 0);
  ReleaseSRWLockExclusive(&g_spawn_lock);
  close_handle(&host_read);
  close_handle(&host_write);
  if (!created) {
    char text[96];
    snprintf(text, sizeof text, "The host could not be started (Windows error %lu).", (unsigned long)created_error);
    set_error(error, error_size, text);
    goto fail;
  }
  c->process = info.hProcess;
  c->pid = info.dwProcessId;
  started = 1;
  c->job = CreateJobObjectW(NULL, NULL);
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits;
  ZeroMemory(&limits, sizeof limits);
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!c->job || !SetInformationJobObject(c->job, JobObjectExtendedLimitInformation, &limits, sizeof limits) ||
      !AssignProcessToJobObject(c->job, c->process)) {
    CloseHandle(info.hThread);
    set_error(error, error_size, "The host could not be put in a job object.");
    goto fail;
  }
  ResumeThread(info.hThread);
  CloseHandle(info.hThread);
  c->reader = CreateThread(NULL, 0, reader_main, c, 0, NULL);
  c->writer = CreateThread(NULL, 0, writer_main, c, 0, NULL);
  c->waiter = CreateThread(NULL, 0, waiter_main, c, 0, NULL);
  if (!c->reader || !c->writer || !c->waiter) {
    set_error(error, error_size, "The host's threads could not be started.");
    goto fail;
  }
  DeleteProcThreadAttributeList(attributes);
  free(attributes);
  free(line);
  free(program);
  free(block);
  return c;
fail:
  if (attributes) {
    DeleteProcThreadAttributeList(attributes);
    free(attributes);
  }
  free(line);
  free(program);
  free(block);
  close_handle(&host_read);
  close_handle(&host_write);
  if (started) TerminateProcess(c->process, 1);
  close_handle(&c->write_pipe);
  close_handle(&c->read_pipe);
  EnterCriticalSection(&c->lock);
  c->closing = 1;
  WakeAllConditionVariable(&c->wake);
  LeaveCriticalSection(&c->lock);
  if (c->writer) WaitForSingleObject(c->writer, INFINITE);
  if (c->reader) WaitForSingleObject(c->reader, INFINITE);
  if (c->waiter) WaitForSingleObject(c->waiter, INFINITE);
  close_handle(&c->writer);
  close_handle(&c->reader);
  close_handle(&c->waiter);
  close_handle(&c->job);
  close_handle(&c->process);
  DeleteCriticalSection(&c->lock);
  free(c);
  return NULL;
}

ANYPS5_EXPORT int64_t anyps5_rh_pid(void* handle) { return (int64_t)((Connection*)handle)->pid; }

ANYPS5_EXPORT void anyps5_rh_kill(void* handle) { TerminateProcess(((Connection*)handle)->process, 1); }

ANYPS5_EXPORT int64_t anyps5_rh_write_age_ms(void* handle) {
  Connection* c = (Connection*)handle;
  LONG64 started = InterlockedCompareExchange64(&c->write_started, 0, 0);
  if (started < 0) return -1;
  if (started == 0) return 0;
  return (int64_t)(GetTickCount64() - (ULONGLONG)started);
}

// Cancels the thread's synchronous I/O until it has finished: a cancel only
// reaches a call already in progress, so one made just before the thread's next
// ReadFile or WriteFile would be missed.
static void stop_thread(HANDLE thread) {
  while (WaitForSingleObject(thread, 20) == WAIT_TIMEOUT) CancelSynchronousIo(thread);
}

// Gives the host's exit code as EVENT_EXITED does, since that event may still be
// on its way to Dart when the callback is closed.
ANYPS5_EXPORT int64_t anyps5_rh_close(void* handle) {
  Connection* c = (Connection*)handle;
  TerminateJobObject(c->job, 1);
  TerminateProcess(c->process, 1);
  WaitForSingleObject(c->process, INFINITE);
  EnterCriticalSection(&c->lock);
  c->closing = 1;
  WakeAllConditionVariable(&c->wake);
  LeaveCriticalSection(&c->lock);
  stop_thread(c->writer);
  stop_thread(c->reader);
  WaitForSingleObject(c->waiter, INFINITE);
  while (c->first) {
    Outgoing* next = c->first->next;
    free(c->first);
    c->first = next;
  }
  close_handle(&c->writer);
  close_handle(&c->reader);
  close_handle(&c->waiter);
  close_handle(&c->write_pipe);
  close_handle(&c->read_pipe);
  close_handle(&c->job);
  close_handle(&c->process);
  DeleteCriticalSection(&c->lock);
  const int64_t code = c->exit_code;
  free(c);
  return code;
}

static int queue(Connection* c, const uint8_t* data, int32_t length) {
  Outgoing* item = (Outgoing*)malloc(sizeof(Outgoing) + (size_t)length);
  if (!item) return 0;
  item->next = NULL;
  item->length = length;
  memcpy(item->data, data, (size_t)length);
  EnterCriticalSection(&c->lock);
  if (c->last) c->last->next = item;
  else c->first = item;
  c->last = item;
  WakeConditionVariable(&c->wake);
  LeaveCriticalSection(&c->lock);
  return 1;
}

ANYPS5_EXPORT void* anyps5_rh_map_ring(void* handle, int64_t host_handle, int64_t bytes, char* error,
                                       int32_t error_size) {
  Connection* c = (Connection*)handle;
  HANDLE section = NULL;
  if (!DuplicateHandle(c->process, (HANDLE)(uintptr_t)host_handle, GetCurrentProcess(), &section,
                       FILE_MAP_READ | FILE_MAP_WRITE, FALSE, 0)) {
    set_error(error, error_size, "DuplicateHandle failed for the ring's section.");
    return NULL;
  }
  void* view = MapViewOfFile(section, FILE_MAP_READ | FILE_MAP_WRITE, 0, 0, (SIZE_T)bytes);
  CloseHandle(section);
  if (!view) {
    set_error(error, error_size, "MapViewOfFile failed for the ring.");
    return NULL;
  }
  MEMORY_BASIC_INFORMATION region;
  if (VirtualQuery(view, &region, sizeof region) != sizeof region || region.State != MEM_COMMIT ||
      region.RegionSize < (SIZE_T)bytes) {
    UnmapViewOfFile(view);
    set_error(error, error_size, "The ring's section is not committed for its whole size.");
    return NULL;
  }
  return view;
}

ANYPS5_EXPORT void anyps5_rh_unmap_ring(void* base, int64_t bytes) {
  (void)bytes;
  UnmapViewOfFile(base);
}

ANYPS5_EXPORT void anyps5_rh_close_descriptor(int64_t descriptor) { (void)descriptor; }

ANYPS5_EXPORT uint32_t anyps5_rh_load(void* address) {
  return (uint32_t)InterlockedCompareExchange((volatile LONG*)address, 0, 0);
}

ANYPS5_EXPORT void anyps5_rh_store(void* address, uint32_t value) {
  InterlockedExchange((volatile LONG*)address, (LONG)value);
}

#else

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <dlfcn.h>
#include <poll.h>
#include <spawn.h>
#include <sys/syscall.h>
extern char** environ;

typedef struct Outgoing {
  struct Outgoing* next;
  int32_t length;
  uint8_t data[];
} Outgoing;

typedef struct Connection {
  int64_t token;
  anyps5_rh_callback callback;
  pid_t pid;
  int socket;
  pthread_t reader;
  pthread_t writer;
  pthread_t waiter;
  int threads;
  pthread_mutex_t lock;
  pthread_cond_t wake;
  Outgoing* first;
  Outgoing* last;
  int closing;
  int exited;
  int reader_done;
  int pidfd;
  int lost;
  int64_t write_started;
  int64_t exit_code;
} Connection;

static int64_t now_ms(void) {
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static void close_received(int* descriptors, int count) {
  for (int i = 0; i < count; ++i) close(descriptors[i]);
}

// Reads `size` bytes of one part of a message (its length, or its body).
// Descriptors may only come with the first byte of a length (protocol.md
// "Framing"); `first` says this read holds it. Returns 1, 0 at end of stream,
// or -1 for a framing error.
static int read_part(Connection* c, uint8_t* out, size_t size, int first, int* descriptors, int* count) {
  size_t done = 0;
  while (done < size) {
    union {
      struct cmsghdr header;
      char space[CMSG_SPACE(4 * sizeof(int))];
    } control;
    struct iovec piece = {out + done, size - done};
    struct msghdr message;
    memset(&message, 0, sizeof message);
    message.msg_iov = &piece;
    message.msg_iovlen = 1;
    message.msg_control = control.space;
    message.msg_controllen = sizeof control.space;
#if defined(MSG_CMSG_CLOEXEC)
    ssize_t got = recvmsg(c->socket, &message, MSG_CMSG_CLOEXEC);
#else
    ssize_t got = recvmsg(c->socket, &message, 0);
#endif
    if (got < 0 && errno == EINTR) continue;
    if (got < 0) {
      close_received(descriptors, *count);
      *count = 0;
      return 0;
    }
    int received[4];
    int held = 0;
    for (struct cmsghdr* item = CMSG_FIRSTHDR(&message); item; item = CMSG_NXTHDR(&message, item)) {
      if (item->cmsg_level == SOL_SOCKET && item->cmsg_type == SCM_RIGHTS) {
        int n = (int)((item->cmsg_len - CMSG_LEN(0)) / sizeof(int));
        for (int i = 0; i < n && held < 4; ++i) {
          memcpy(&received[held], CMSG_DATA(item) + i * sizeof(int), sizeof(int));
#if !defined(MSG_CMSG_CLOEXEC)
          fcntl(received[held], F_SETFD, FD_CLOEXEC);
#endif
          ++held;
        }
      } else {
        close_received(received, held);
        close_received(descriptors, *count);
        *count = 0;
        return -1;
      }
    }
    if (message.msg_flags & MSG_CTRUNC) {
      close_received(received, held);
      close_received(descriptors, *count);
      *count = 0;
      return -1;
    }
    if (held) {
      if (!(first && done == 0) || *count + held > 1) {
        close_received(received, held);
        close_received(descriptors, *count);
        *count = 0;
        return -1;
      }
      descriptors[(*count)++] = received[0];
    }
    if (got <= 0) return 0;
    done += (size_t)got;
  }
  return 1;
}

static void read_messages(Connection* c);

static void* reader_main(void* argument) {
  Connection* c = (Connection*)argument;
  read_messages(c);
  pthread_mutex_lock(&c->lock);
  c->reader_done = 1;
  pthread_cond_broadcast(&c->wake);
  pthread_mutex_unlock(&c->lock);
  return NULL;
}

static void read_messages(Connection* c) {
  for (;;) {
    int descriptors[1];
    int count = 0;
    uint8_t prefix[4];
    int result = read_part(c, prefix, 4, 1, descriptors, &count);
    if (result <= 0) {
      close_received(descriptors, count);
      c->callback(c->token, result < 0 ? EVENT_FRAMING : EVENT_END, NULL, 0, -1);
      return;
    }
    uint32_t length = (uint32_t)prefix[0] | (uint32_t)prefix[1] << 8 | (uint32_t)prefix[2] << 16 |
                      (uint32_t)prefix[3] << 24;
    if (length < MIN_MESSAGE || length > MAX_MESSAGE) {
      close_received(descriptors, count);
      c->callback(c->token, EVENT_FRAMING, NULL, (int32_t)length, -1);
      return;
    }
    uint8_t* body = (uint8_t*)malloc(length);
    if (!body) {
      close_received(descriptors, count);
      c->callback(c->token, EVENT_FRAMING, NULL, -1, -1);
      return;
    }
    result = read_part(c, body, length, 0, descriptors, &count);
    if (result <= 0) {
      free(body);
      close_received(descriptors, count);
      c->callback(c->token, result < 0 ? EVENT_FRAMING : EVENT_END, NULL, 0, -1);
      return;
    }
    c->callback(c->token, EVENT_MESSAGE, body, (int32_t)length, count ? descriptors[0] : -1);
  }
}

static void* writer_main(void* argument) {
  Connection* c = (Connection*)argument;
#if defined(MSG_NOSIGNAL)
  const int flags = MSG_NOSIGNAL;
#else
  const int flags = 0;
#endif
  for (;;) {
    pthread_mutex_lock(&c->lock);
    while (!c->first && !c->closing) pthread_cond_wait(&c->wake, &c->lock);
    if (!c->first) {
      pthread_mutex_unlock(&c->lock);
      return NULL;
    }
    Outgoing* item = c->first;
    c->first = item->next;
    if (!c->first) c->last = NULL;
    if (c->closing) {
      pthread_mutex_unlock(&c->lock);
      free(item);
      return NULL;
    }
    c->write_started = now_ms();
    pthread_mutex_unlock(&c->lock);
    size_t done = 0;
    int ok = 1;
    while (ok && done < (size_t)item->length) {
      ssize_t wrote = send(c->socket, item->data + done, (size_t)item->length - done, flags);
      if (wrote < 0 && errno == EINTR) continue;
      ok = wrote > 0;
      if (ok) done += (size_t)wrote;
    }
    free(item);
    pthread_mutex_lock(&c->lock);
    c->write_started = ok ? 0 : -1;
    pthread_mutex_unlock(&c->lock);
    if (!ok) return NULL;
  }
}

#if defined(__linux__)
#if !defined(SYS_pidfd_open)
#define SYS_pidfd_open 434
#endif
#if !defined(SYS_pidfd_send_signal)
#define SYS_pidfd_send_signal 424
#endif
#if !defined(P_PIDFD)
#define P_PIDFD 3
#endif
#endif

static int64_t exit_code(const siginfo_t* info) {
  return info->si_code == CLD_EXITED ? info->si_status : -(int64_t)info->si_status;
}

// Waits for the host to end and reports its exit code, after the reader has
// passed on everything the host wrote before it ended (or 2 seconds, if
// something else still holds the host's end of the stream), so a last reply is
// never overtaken by the exit.
//
// Linux: the Dart VM reaps its own children with a plain wait() whenever a
// dart:io process is running (runtime/bin/process_linux.cc), and that can take
// any child, the host included. So the host is watched through a pidfd: its
// exit is seen even when the VM reaps it first, the exit code is read with
// WNOWAIT while it is still there, and anyps5_rh_kill signals through the
// pidfd, which can never reach a later process given the same id. When the VM
// reaps the host before that read, its exit code is lost: it is then
// EXIT_UNKNOWN. On Linux 5.3, which has pidfd_open but not waitid(P_PIDFD), the
// pidfd still shows the exit, but the code is EXIT_UNKNOWN and the host is left
// for the VM to reap: waiting by id could reach a later process. macOS: the VM
// waits only for its own process ids (kqueue), so the host is this file's to
// reap.
static void* waiter_main(void* argument) {
  Connection* c = (Connection*)argument;
  int64_t code = EXIT_UNKNOWN;
  siginfo_t info;
  memset(&info, 0, sizeof info);
#if defined(__linux__)
  if (c->pidfd >= 0) {
    struct pollfd ready = {c->pidfd, POLLIN, 0};
    while (poll(&ready, 1, -1) < 0 && errno == EINTR) {
    }
    int result;
    do result = waitid((idtype_t)P_PIDFD, (id_t)c->pidfd, &info, WEXITED | WNOWAIT);
    while (result < 0 && errno == EINTR);
    const int by_pidfd = !(result < 0 && errno == EINVAL);
    if (result == 0) code = exit_code(&info);
    pthread_mutex_lock(&c->lock);
    c->exited = 1;
    pthread_mutex_unlock(&c->lock);
    if (by_pidfd) {
      while (waitid((idtype_t)P_PIDFD, (id_t)c->pidfd, &info, WEXITED) < 0 && errno == EINTR) {
      }
    }
  } else if (c->lost) {
    // Its end of the stream is all there is to go by: the reader's end of
    // stream, waited for below without a limit, stands for its exit.
  } else
#endif
  {
    int result;
    do result = waitid(P_PID, (id_t)c->pid, &info, WEXITED | WNOWAIT);
    while (result < 0 && errno == EINTR);
    if (result == 0) code = exit_code(&info);
    pthread_mutex_lock(&c->lock);
    c->exited = 1;
    pthread_mutex_unlock(&c->lock);
    int status;
    while (waitpid(c->pid, &status, 0) < 0 && errno == EINTR) {
    }
  }
  struct timespec until;
  clock_gettime(CLOCK_REALTIME, &until);
  until.tv_sec += 2;
  pthread_mutex_lock(&c->lock);
  while (!c->reader_done) {
    if (c->lost) {
      pthread_cond_wait(&c->wake, &c->lock);
    } else if (pthread_cond_timedwait(&c->wake, &c->lock, &until) == ETIMEDOUT) {
      break;
    }
  }
  pthread_mutex_unlock(&c->lock);
  c->exit_code = code;
  c->callback(c->token, EVENT_EXITED, NULL, 0, code);
  return NULL;
}

// What protocol.md asks of the start on Linux and macOS: the host's end of the
// stream as descriptor 3, an empty signal mask, and SIGTERM at its default.
// macOS also gives the host no other descriptor (POSIX_SPAWN_CLOEXEC_DEFAULT);
// on Linux every descriptor of the launcher's is close-on-exec, and the host
// closes any above 3 itself. `host_end` is never 3 (see anyps5_rh_start).
// Linux also gives the host's pidfd: made with the process by pidfd_spawn
// (glibc 2.39 and later, when the kernel has what it needs), or opened just
// after it with pidfd_open and kept only if its process is this launcher's
// child (open_pidfd).
#if defined(__linux__)
// Opens a pidfd for `pid` just after posix_spawn, and keeps it only if its
// process is the host. If the host ended at once and the VM reaped it, the id
// may already belong to another process, perhaps another child of the
// launcher. A pidfd fixes its process once opened, so the check after the open
// is sound: the host is the process whose descriptor 3 is the launcher's
// socket (`socket_inode`). Returns the pidfd; else -1 with *lost set when the
// host's identity cannot be had, also where /proc hides a child's descriptors
// (ptrace_scope 2 or 3): it is then never signalled or waited for by its id.
// *lost stays clear when the kernel has no pidfd at all (Linux before 5.3).
static int open_pidfd(pid_t pid, unsigned long socket_inode, int* lost) {
  *lost = 0;
  int fd = (int)syscall(SYS_pidfd_open, pid, 0);
  if (fd < 0) {
    *lost = errno != ENOSYS;
    return -1;
  }
  fcntl(fd, F_SETFD, FD_CLOEXEC);
  char path[64];
  char target[64];
  char expected[64];
  snprintf(path, sizeof path, "/proc/%ld/fd/3", (long)pid);
  snprintf(expected, sizeof expected, "socket:[%lu]", socket_inode);
  ssize_t length = readlink(path, target, sizeof target - 1);
  if (length > 0) {
    target[length] = 0;
    if (strcmp(target, expected) == 0) return fd;
  }
  close(fd);
  *lost = 1;
  return -1;
}
#endif

static int spawn_now(char* const* argv, char* const* envp, int host_end, pid_t* pid, int* pidfd, int* lost) {
  posix_spawn_file_actions_t actions;
  posix_spawnattr_t attributes;
  posix_spawn_file_actions_init(&actions);
  posix_spawnattr_init(&attributes);
  posix_spawn_file_actions_adddup2(&actions, host_end, 3);
  sigset_t empty;
  sigset_t defaults;
  sigemptyset(&empty);
  sigemptyset(&defaults);
  sigaddset(&defaults, SIGTERM);
  posix_spawnattr_setsigmask(&attributes, &empty);
  posix_spawnattr_setsigdefault(&attributes, &defaults);
  short flags = POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF;
#if defined(__APPLE__)
  flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
  posix_spawnattr_setflags(&attributes, flags);
  int failure;
  *pidfd = -1;
  *lost = 0;
#if defined(__linux__)
  typedef int (*pidfd_spawn_t)(int*, const char*, const posix_spawn_file_actions_t*, const posix_spawnattr_t*,
                               char* const*, char* const*);
  typedef pid_t (*pidfd_getpid_t)(int);
  pidfd_spawn_t pidfd_spawn_call = (pidfd_spawn_t)dlsym(RTLD_DEFAULT, "pidfd_spawn");
  pidfd_getpid_t pidfd_getpid_call = (pidfd_getpid_t)dlsym(RTLD_DEFAULT, "pidfd_getpid");
  failure = ENOSYS;
  if (pidfd_spawn_call && pidfd_getpid_call) {
    failure = pidfd_spawn_call(pidfd, argv[0], &actions, &attributes, argv, envp);
    if (!failure) {
      fcntl(*pidfd, F_SETFD, FD_CLOEXEC);
      *pid = pidfd_getpid_call(*pidfd);
      if (*pid <= 0) {
        failure = errno ? errno : ESRCH;
        siginfo_t info;
        syscall(SYS_pidfd_send_signal, *pidfd, SIGKILL, NULL, 0);
        while (waitid((idtype_t)P_PIDFD, (id_t)*pidfd, &info, WEXITED) < 0 && errno == EINTR) {
        }
        close(*pidfd);
        *pidfd = -1;
      }
    }
  }
  if (failure == ENOSYS || failure == EINVAL) {
    failure = posix_spawn(pid, argv[0], &actions, &attributes, argv, envp);
    if (!failure) {
      struct stat socket_info;
      unsigned long inode = fstat(host_end, &socket_info) == 0 ? (unsigned long)socket_info.st_ino : 0;
      *pidfd = open_pidfd(*pid, inode, lost);
    }
  }
#else
  failure = posix_spawn(pid, argv[0], &actions, &attributes, argv, envp);
#endif
  posix_spawn_file_actions_destroy(&actions);
  posix_spawnattr_destroy(&attributes);
  return failure;
}

#if defined(__linux__)

// Linux starts the host on one thread that lives as long as the launcher,
// because PR_SET_PDEATHSIG, which the host sets, fires when the thread that
// started it exits (protocol.md "Starting the host"). One job at a time; only
// the spawner thread clears the slot, once the job is done.
typedef struct Spawn {
  char* const* argv;
  char* const* envp;
  int host_end;
  pid_t pid;
  int pidfd;
  int lost;
  int failure;
  int done;
} Spawn;

static pthread_mutex_t g_spawn_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_spawn_wake = PTHREAD_COND_INITIALIZER;
static Spawn* g_spawn_job;
static pthread_once_t g_spawner_once = PTHREAD_ONCE_INIT;
static int g_spawner_ready;

static void* spawner_main(void* argument) {
  (void)argument;
  pthread_mutex_lock(&g_spawn_lock);
  for (;;) {
    while (!g_spawn_job) pthread_cond_wait(&g_spawn_wake, &g_spawn_lock);
    Spawn* job = g_spawn_job;
    pthread_mutex_unlock(&g_spawn_lock);
    job->failure = spawn_now(job->argv, job->envp, job->host_end, &job->pid, &job->pidfd, &job->lost);
    pthread_mutex_lock(&g_spawn_lock);
    job->done = 1;
    g_spawn_job = NULL;
    pthread_cond_broadcast(&g_spawn_wake);
  }
  return NULL;
}

static void start_spawner(void) {
  pthread_t thread;
  pthread_attr_t attributes;
  pthread_attr_init(&attributes);
  pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
  g_spawner_ready = pthread_create(&thread, &attributes, spawner_main, NULL) == 0;
  pthread_attr_destroy(&attributes);
}

static pid_t spawn_host(char* const* argv, char* const* envp, int host_end, int* failure, int* pidfd, int* lost) {
  pthread_once(&g_spawner_once, start_spawner);
  if (!g_spawner_ready) {
    *failure = EAGAIN;
    return -1;
  }
  Spawn job;
  memset(&job, 0, sizeof job);
  job.argv = argv;
  job.envp = envp;
  job.host_end = host_end;
  pthread_mutex_lock(&g_spawn_lock);
  while (g_spawn_job) pthread_cond_wait(&g_spawn_wake, &g_spawn_lock);
  g_spawn_job = &job;
  pthread_cond_broadcast(&g_spawn_wake);
  while (!job.done) pthread_cond_wait(&g_spawn_wake, &g_spawn_lock);
  pthread_mutex_unlock(&g_spawn_lock);
  *failure = job.failure;
  *pidfd = job.pidfd;
  *lost = job.lost;
  return job.failure ? -1 : job.pid;
}

#else

static pid_t spawn_host(char* const* argv, char* const* envp, int host_end, int* failure, int* pidfd, int* lost) {
  pid_t pid = -1;
  *failure = spawn_now(argv, envp, host_end, &pid, pidfd, lost);
  return *failure ? -1 : pid;
}

#endif

// Kills the host: through its pidfd where there is one, never by id when its
// identity was lost, and by id only where the kernel has no pidfd.
static void signal_host(pid_t pid, int pidfd, int lost) {
#if defined(__linux__)
  if (pidfd >= 0) {
    syscall(SYS_pidfd_send_signal, pidfd, SIGKILL, NULL, 0);
    return;
  }
#else
  (void)pidfd;
#endif
  if (!lost) kill(pid, SIGKILL);
}

ANYPS5_EXPORT void* anyps5_rh_start(const char* const* argv, int32_t argc, const char* const* env, int32_t envc,
                                    int64_t token, anyps5_rh_callback callback, char* error, int32_t error_size) {
  if (argc < 1) {
    set_error(error, error_size, "No host program was given.");
    return NULL;
  }
  int ends[2];
#if defined(__APPLE__)
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, ends) != 0) {
    set_error(error, error_size, "The control stream's socket pair could not be made.");
    return NULL;
  }
  fcntl(ends[0], F_SETFD, FD_CLOEXEC);
  fcntl(ends[1], F_SETFD, FD_CLOEXEC);
  int on = 1;
  setsockopt(ends[0], SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
#else
  if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, ends) != 0) {
    set_error(error, error_size, "The control stream's socket pair could not be made.");
    return NULL;
  }
#endif
  int high = fcntl(ends[1], F_DUPFD_CLOEXEC, 10);
  if (high < 0) {
    close(ends[0]);
    close(ends[1]);
    set_error(error, error_size, "The control stream's socket could not be moved.");
    return NULL;
  }
  close(ends[1]);
  ends[1] = high;
  char parent[24];
  snprintf(parent, sizeof parent, "%ld", (long)getpid());
  const char** arguments = (const char**)calloc((size_t)argc + 5, sizeof(char*));
  const char** environment = NULL;
  if (envc > 0) environment = (const char**)calloc((size_t)envc + 1, sizeof(char*));
  if (!arguments || (envc > 0 && !environment)) {
    free(arguments);
    free(environment);
    close(ends[0]);
    close(ends[1]);
    set_error(error, error_size, "Out of memory.");
    return NULL;
  }
  for (int32_t i = 0; i < argc; ++i) arguments[i] = argv[i];
  arguments[argc] = "--ipc-fd";
  arguments[argc + 1] = "3";
  arguments[argc + 2] = "--parent-pid";
  arguments[argc + 3] = parent;
  for (int32_t i = 0; i < envc; ++i) environment[i] = env[i];
  char* const* envp = envc > 0 ? (char* const*)environment : environ;
  int failure = 0;
  int pidfd = -1;
  int lost = 0;
  pid_t pid = spawn_host((char* const*)arguments, envp, ends[1], &failure, &pidfd, &lost);
  free(arguments);
  free(environment);
  close(ends[1]);
  if (pid < 0) {
    char text[128];
    snprintf(text, sizeof text, "The host could not be started: %s.", strerror(failure));
    set_error(error, error_size, text);
    close(ends[0]);
    return NULL;
  }
  Connection* c = (Connection*)calloc(1, sizeof(Connection));
  if (!c) {
    signal_host(pid, pidfd, lost);
    if (pidfd >= 0) close(pidfd);
    close(ends[0]);
    set_error(error, error_size, "Out of memory.");
    return NULL;
  }
  c->token = token;
  c->callback = callback;
  c->pid = pid;
  c->socket = ends[0];
  c->pidfd = pidfd;
  c->lost = lost;
  pthread_mutex_init(&c->lock, NULL);
  pthread_cond_init(&c->wake, NULL);
  if (pthread_create(&c->waiter, NULL, waiter_main, c) == 0) c->threads |= 1;
  if (pthread_create(&c->reader, NULL, reader_main, c) == 0) c->threads |= 2;
  if (pthread_create(&c->writer, NULL, writer_main, c) == 0) c->threads |= 4;
  if (c->threads != 7) {
    set_error(error, error_size, "The host's threads could not be started.");
    signal_host(pid, pidfd, lost);
    shutdown(c->socket, SHUT_RDWR);
    pthread_mutex_lock(&c->lock);
    if (!(c->threads & 2)) c->reader_done = 1;
    c->closing = 1;
    pthread_cond_broadcast(&c->wake);
    pthread_mutex_unlock(&c->lock);
    if (c->threads & 1) pthread_join(c->waiter, NULL);
    if (c->threads & 2) pthread_join(c->reader, NULL);
    if (c->threads & 4) pthread_join(c->writer, NULL);
    close(c->socket);
    if (c->pidfd >= 0) close(c->pidfd);
    pthread_mutex_destroy(&c->lock);
    pthread_cond_destroy(&c->wake);
    free(c);
    return NULL;
  }
  return c;
}

ANYPS5_EXPORT int64_t anyps5_rh_pid(void* handle) { return (int64_t)((Connection*)handle)->pid; }

ANYPS5_EXPORT void anyps5_rh_kill(void* handle) {
  Connection* c = (Connection*)handle;
  pthread_mutex_lock(&c->lock);
  if (!c->exited) signal_host(c->pid, c->pidfd, c->lost);
  pthread_mutex_unlock(&c->lock);
}

ANYPS5_EXPORT int64_t anyps5_rh_write_age_ms(void* handle) {
  Connection* c = (Connection*)handle;
  pthread_mutex_lock(&c->lock);
  int64_t started = c->write_started;
  pthread_mutex_unlock(&c->lock);
  if (started < 0) return -1;
  return started ? now_ms() - started : 0;
}

// Gives the host's exit code as EVENT_EXITED does, since that event may still be
// on its way to Dart when the callback is closed.
ANYPS5_EXPORT int64_t anyps5_rh_close(void* handle) {
  Connection* c = (Connection*)handle;
  anyps5_rh_kill(c);
  shutdown(c->socket, SHUT_RDWR);
  pthread_join(c->waiter, NULL);
  pthread_mutex_lock(&c->lock);
  c->closing = 1;
  pthread_cond_broadcast(&c->wake);
  pthread_mutex_unlock(&c->lock);
  pthread_join(c->reader, NULL);
  pthread_join(c->writer, NULL);
  while (c->first) {
    Outgoing* next = c->first->next;
    free(c->first);
    c->first = next;
  }
  close(c->socket);
  if (c->pidfd >= 0) close(c->pidfd);
  pthread_mutex_destroy(&c->lock);
  pthread_cond_destroy(&c->wake);
  const int64_t code = c->exit_code;
  free(c);
  return code;
}

static int queue(Connection* c, const uint8_t* data, int32_t length) {
  Outgoing* item = (Outgoing*)malloc(sizeof(Outgoing) + (size_t)length);
  if (!item) return 0;
  item->next = NULL;
  item->length = length;
  memcpy(item->data, data, (size_t)length);
  pthread_mutex_lock(&c->lock);
  if (c->last) c->last->next = item;
  else c->first = item;
  c->last = item;
  // The exit watcher waits on the same condition in lost mode, so a signal
  // could wake it instead of the writer.
  pthread_cond_broadcast(&c->wake);
  pthread_mutex_unlock(&c->lock);
  return 1;
}

ANYPS5_EXPORT void* anyps5_rh_map_ring(void* handle, int64_t descriptor, int64_t bytes, char* error,
                                       int32_t error_size) {
  (void)handle;
  int fd = (int)descriptor;
  struct stat info;
  void* base = NULL;
  if (fstat(fd, &info) != 0) {
    set_error(error, error_size, "fstat failed on the ring's descriptor.");
    goto done;
  }
#if defined(__APPLE__)
  long page = sysconf(_SC_PAGESIZE);
  int access = fcntl(fd, F_GETFL);
  if (access < 0 || (access & O_ACCMODE) != O_RDWR) {
    set_error(error, error_size, "The ring's descriptor is not open for reading and writing.");
    goto done;
  }
  if (info.st_size < bytes || info.st_size >= bytes + page) {
    set_error(error, error_size, "The ring's memory does not have the size its message gives.");
    goto done;
  }
  if (ftruncate(fd, (off_t)bytes) == 0) {
    set_error(error, error_size, "The ring's memory could be resized, so it is not a fixed shared memory object.");
    goto done;
  }
#else
  if (info.st_size != bytes) {
    set_error(error, error_size, "The ring's memory does not have the size its message gives.");
    goto done;
  }
#if !defined(F_GET_SEALS)
#define F_GET_SEALS 1034
#define F_SEAL_SEAL 0x0001
#define F_SEAL_SHRINK 0x0002
#endif
  int seals = fcntl(fd, F_GET_SEALS);
  if (seals < 0 || (seals & (F_SEAL_SHRINK | F_SEAL_SEAL)) != (F_SEAL_SHRINK | F_SEAL_SEAL)) {
    set_error(error, error_size, "The ring's memory is not sealed against shrinking.");
    goto done;
  }
#endif
  base = mmap(NULL, (size_t)bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  if (base == MAP_FAILED) {
    base = NULL;
    set_error(error, error_size, "mmap failed for the ring.");
  }
done:
  close(fd);
  return base;
}

ANYPS5_EXPORT void anyps5_rh_unmap_ring(void* base, int64_t bytes) { munmap(base, (size_t)bytes); }

ANYPS5_EXPORT void anyps5_rh_close_descriptor(int64_t descriptor) {
  if (descriptor >= 0) close((int)descriptor);
}

ANYPS5_EXPORT uint32_t anyps5_rh_load(void* address) {
  return __atomic_load_n((uint32_t*)address, __ATOMIC_SEQ_CST);
}

ANYPS5_EXPORT void anyps5_rh_store(void* address, uint32_t value) {
  __atomic_store_n((uint32_t*)address, value, __ATOMIC_SEQ_CST);
}

#endif

ANYPS5_EXPORT int32_t anyps5_rh_send(void* handle, const uint8_t* data, int32_t length) {
  return queue((Connection*)handle, data, length);
}

ANYPS5_EXPORT void anyps5_rh_free(void* data) { free(data); }
