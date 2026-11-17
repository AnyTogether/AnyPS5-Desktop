#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <algorithm>
#include <string>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");
  // The renderer: Skia, which draws the launcher's glass, blurs and layers through ANGLE far
  // faster than Impeller's OpenGL ES backend does on integrated GPUs (an Impeller frame of a
  // settings panel took dozens of offscreen passes). ANYPS5_RENDERER=impeller picks Impeller.
  wchar_t renderer[16] = {};
  const DWORD renderer_length =
      ::GetEnvironmentVariableW(L"ANYPS5_RENDERER", renderer, 16);
  project.set_impeller_switch(
      renderer_length > 0 && renderer_length < 16 &&
              _wcsicmp(renderer, L"impeller") == 0
          ? flutter::ImpellerSwitch::Enabled
          : flutter::ImpellerSwitch::Disabled);

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  // --fullscreen (AnyPS5's Steam shortcuts pass it for Big Picture): a borderless window over
  // the whole monitor from the start.
  const bool fullscreen =
      std::find(command_line_arguments.begin(), command_line_arguments.end(),
                "--fullscreen") != command_line_arguments.end();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  std::wstring run_marker;
  {
    FlutterWindow window(project);
    Win32Window::Point origin(10, 10);
    Win32Window::Size size(1600, 900);
    if (!window.Create(L"AnyPS5", origin, size)) {
      return EXIT_FAILURE;
    }
    window.SetQuitOnClose(true);
    if (fullscreen) {
      window.SetFullscreen(true);
    }

    ::MSG msg;
    while (::GetMessage(&msg, nullptr, 0, 0)) {
      ::TranslateMessage(&msg);
      ::DispatchMessage(&msg);
    }
    ShutdownLog("main: the message loop ended");
    run_marker = window.run_marker();
    StartExitWatchdog(run_marker);
    // The window (and Flutter with it) goes here, while COM is still there for the plugins
    // that shut down with it.
  }

  ShutdownLog("main: the window and Flutter are gone");
  ::CoUninitialize();
  // A clean close: the launcher's marker of this run goes, so the next start finds no crash.
  // A crash anywhere before this line leaves it, and the next start offers a report.
  if (!run_marker.empty()) {
    ::DeleteFileW(run_marker.c_str());
  }
  // The window, Flutter and Dart are closed, the preferences are written, Now playing and COM
  // are released and the marker is gone: what Windows would still do once this function
  // returns (the C runtime's exit handlers, unloading the DLLs, the plugins' global
  // destructors) is of no use, and has been seen to hang, leaving a window-less AnyPS5 process
  // in the background. The process ends here instead.
  ShutdownLog("main: ending the process");
  ::TerminateProcess(::GetCurrentProcess(), EXIT_SUCCESS);
  return EXIT_SUCCESS;
}
