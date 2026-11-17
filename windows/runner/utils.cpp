#include "utils.h"

#include <flutter_windows.h>
#include <io.h>
#include <stdio.h>
#include <windows.h>

#include <atomic>
#include <climits>
#include <cstdio>
#include <iostream>
#include <thread>

void CreateAndAttachConsole() {
  if (::AllocConsole()) {
    FILE *unused;
    if (freopen_s(&unused, "CONOUT$", "w", stdout)) {
      _dup2(_fileno(stdout), 1);
    }
    if (freopen_s(&unused, "CONOUT$", "w", stderr)) {
      _dup2(_fileno(stdout), 2);
    }
    std::ios::sync_with_stdio();
    FlutterDesktopResyncOutputStreams();
  }
}

std::vector<std::string> GetCommandLineArguments() {
  // Convert the UTF-16 command line arguments to UTF-8 for the Engine to use.
  int argc;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return std::vector<std::string>();
  }

  std::vector<std::string> command_line_arguments;

  // Skip the first argument as it's the binary name.
  for (int i = 1; i < argc; i++) {
    command_line_arguments.push_back(Utf8FromUtf16(argv[i]));
  }

  ::LocalFree(argv);

  return command_line_arguments;
}

std::string Utf8FromUtf16(const wchar_t* utf16_string) {
  if (utf16_string == nullptr) {
    return std::string();
  }
  // First, find the length of the string with a safe upper bound (CWE-126).
  // UNICODE_STRING_MAX_CHARS (32767) is the maximum length of a UNICODE_STRING.
  int input_length = static_cast<int>(wcsnlen(utf16_string, UNICODE_STRING_MAX_CHARS));
  // Now use that bounded length to determine the required buffer size.
  // When an explicit length is passed, WideCharToMultiByte does not include
  // the null terminator in its returned size.
  int target_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      input_length, nullptr, 0, nullptr, nullptr);
  std::string utf8_string;
  if (target_length == 0 || static_cast<size_t>(target_length) > utf8_string.max_size()) {
    return utf8_string;
  }
  utf8_string.resize(target_length);
  int converted_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      input_length, utf8_string.data(), target_length, nullptr, nullptr);
  if (converted_length == 0) {
    return std::string();
  }
  return utf8_string;
}

std::wstring Utf16FromUtf8(const std::string& utf8_string) {
  if (utf8_string.empty() ||
      utf8_string.size() > static_cast<size_t>(INT_MAX)) {
    return std::wstring();
  }
  const int input_length = static_cast<int>(utf8_string.size());
  const int target_length = ::MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, utf8_string.data(), input_length, nullptr, 0);
  if (target_length <= 0) {
    return std::wstring();
  }
  std::wstring utf16_string(static_cast<size_t>(target_length), L'\0');
  const int converted = ::MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, utf8_string.data(), input_length,
      utf16_string.data(), target_length);
  return converted == target_length ? utf16_string : std::wstring();
}

namespace {

// The shutdown log's path; empty until SetShutdownLog.
std::wstring g_shutdown_log;

}  // namespace

void SetShutdownLog(const std::wstring& run_marker) {
  const size_t slash = run_marker.find_last_of(L"\\/");
  if (slash == std::wstring::npos) {
    return;
  }
  const std::wstring folder = run_marker.substr(0, slash + 1);
  const std::wstring current = folder + L"shutdown.log";
  const std::wstring previous = folder + L"shutdown.previous.log";
  // The log of the run before is kept, not deleted.
  if (!::MoveFileExW(current.c_str(), previous.c_str(), MOVEFILE_REPLACE_EXISTING)) {
    ::DeleteFileW(current.c_str());
  }
  g_shutdown_log = current;
}

void ShutdownLog(const char* what) {
  if (g_shutdown_log.empty()) {
    return;
  }
  char line[256];
  const int length =
      _snprintf_s(line, sizeof(line), _TRUNCATE, "%llu ms, thread %lu: %s\r\n",
                  static_cast<unsigned long long>(::GetTickCount64()),
                  static_cast<unsigned long>(::GetCurrentThreadId()), what);
  if (length <= 0) {
    return;
  }
  HANDLE file = ::CreateFileW(g_shutdown_log.c_str(), FILE_APPEND_DATA,
                              FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                              OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return;
  }
  DWORD written = 0;
  ::WriteFile(file, line, static_cast<DWORD>(length), &written, nullptr);
  ::CloseHandle(file);
}

void StartExitWatchdog(const std::wstring& run_marker) {
  static std::atomic<bool> started{false};
  if (started.exchange(true)) {
    return;
  }
  ShutdownLog("exit watchdog started");
  try {
    std::thread([run_marker]() {
      ::Sleep(5000);
      ShutdownLog("exit watchdog fired: the shutdown is hung, ending the process");
      if (!run_marker.empty()) {
        ::DeleteFileW(run_marker.c_str());
      }
      ::TerminateProcess(::GetCurrentProcess(), 0);
    }).detach();
  } catch (...) {
    // No thread: the shutdown goes on without the safety net.
  }
}
