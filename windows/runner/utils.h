#ifndef RUNNER_UTILS_H_
#define RUNNER_UTILS_H_

#include <string>
#include <vector>

// Creates a console for the process, and redirects stdout and stderr to
// it for both the runner and the Flutter library.
void CreateAndAttachConsole();

// Takes a null-terminated wchar_t* encoded in UTF-16 and returns a std::string
// encoded in UTF-8. Returns an empty std::string on failure.
std::string Utf8FromUtf16(const wchar_t* utf16_string);

// Takes a std::string encoded in UTF-8 and returns a std::wstring encoded in
// UTF-16. Returns an empty std::wstring on failure.
std::wstring Utf16FromUtf8(const std::string& utf8_string);

// Gets the command line arguments passed in as a std::vector<std::string>,
// encoded in UTF-8. Returns an empty std::vector<std::string> on failure.
std::vector<std::string> GetCommandLineArguments();

// The launcher's shutdown log, next to |run_marker|: shutdown.log. The log of the run before
// is kept as shutdown.previous.log, so a close that hung and was ended by the exit watchdog
// can still be told of after the restart. Call it once, when the launcher gives the marker.
void SetShutdownLog(const std::wstring& run_marker);

// Adds one line (the tick count, the thread and |what|) to the shutdown log. The file is opened
// and closed for each line, so what was written survives TerminateProcess. Does nothing before
// SetShutdownLog.
void ShutdownLog(const char* what);

// Starts, once, a thread that ends the process five seconds later if it is still there: a
// shutdown that hung (after the window closed, in the final clean-up of the libraries) must not
// leave an AnyPS5 process behind in the background. |run_marker| is removed first: a close
// that hung and was ended here is no crash, and the marker would make the next start offer a
// crash report. Call it once the exit is approved, so nothing before that counts.
void StartExitWatchdog(const std::wstring& run_marker);

#endif  // RUNNER_UTILS_H_
