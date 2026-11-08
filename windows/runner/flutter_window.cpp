#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <flutter/plugin_registrar_windows.h>

#include <optional>
#include <variant>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

// Posted when the window was maximized some way other than the system menu's command (Aero
// Snap's drag to the top): turned into full screen once that is done.
constexpr UINT kMaximizedMessage = WM_APP + 1;

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  auto* engine = flutter_controller_->engine();
  auto* registrar = flutter::PluginRegistrarManager::GetInstance()
                        ->GetRegistrar<flutter::PluginRegistrarWindows>(
                            engine->GetRegistrarForPlugin("AnyPS5RetroCore"));
  retro_core_ = std::make_unique<RetroCoreHost>(engine->messenger(), registrar->texture_registrar());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "anyps5/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "setFullscreen") {
          const auto* on = std::get_if<bool>(call.arguments());
          if (on == nullptr) {
            result->Error("bad_arguments", "setFullscreen takes a bool");
            return;
          }
          result->Success(flutter::EncodableValue(SetFullscreen(*on)));
          return;
        }
        // The launcher's own Minimize, full screen having no title bar.
        if (call.method_name() == "minimize") {
          HWND hwnd = GetHandle();
          if (hwnd != nullptr) {
            ::ShowWindow(hwnd, SW_MINIMIZE);
          }
          result->Success(flutter::EncodableValue(hwnd != nullptr));
          return;
        }
        // Back from minimized once the game it stepped aside for has closed.
        if (call.method_name() == "restore") {
          HWND hwnd = GetHandle();
          if (hwnd != nullptr) {
            if (::IsIconic(hwnd)) {
              ::ShowWindow(hwnd, SW_RESTORE);
            }
            ::SetForegroundWindow(hwnd);
          }
          result->Success(flutter::EncodableValue(hwnd != nullptr));
          return;
        }
        // The launcher's own close (Quit, the window buttons' close in full screen): the same
        // close the title bar's button makes, posted so it runs after this call returns.
        // Flutter asks the launcher, shuts down, the window goes and the message loop ends;
        // exit() from Dart, the engine still drawing, crashed in full screen.
        if (call.method_name() == "close") {
          HWND hwnd = GetHandle();
          const bool posted =
              hwnd != nullptr && ::PostMessage(hwnd, WM_CLOSE, 0, 0) != 0;
          result->Success(flutter::EncodableValue(posted));
          return;
        }
        // The launcher's marker of this run: main takes it away after a clean close.
        if (call.method_name() == "removeAfterClose") {
          const auto* path = std::get_if<std::string>(call.arguments());
          if (path == nullptr) {
            result->Error("bad_arguments", "removeAfterClose takes a path");
            return;
          }
          run_marker_ = Utf16FromUtf8(*path);
          result->Success(flutter::EncodableValue(!run_marker_.empty()));
          return;
        }
        result->NotImplemented();
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

bool FlutterWindow::SetFullscreen(bool on) {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return false;
  }
  if (on == fullscreen_) {
    return true;
  }
  if (on) {
    // A maximized window first goes back to its normal size: kept maximized (WS_MAXIMIZE) under
    // the popup style, Windows can put it back on the work area under the taskbar, and the
    // window it returns to would be maximized again, and so full screen again.
    if (::IsZoomed(hwnd)) {
      ::ShowWindow(hwnd, SW_RESTORE);
    }
    MONITORINFO monitor{sizeof(MONITORINFO)};
    if (!::GetMonitorInfo(::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
                          &monitor)) {
      return false;
    }
    windowed_style_ = ::GetWindowLongPtr(hwnd, GWL_STYLE);
    windowed_placement_.length = sizeof(WINDOWPLACEMENT);
    ::GetWindowPlacement(hwnd, &windowed_placement_);
    ::SetWindowLongPtr(hwnd, GWL_STYLE,
                       (windowed_style_ & ~WS_OVERLAPPEDWINDOW) | WS_POPUP);
    const RECT& area = monitor.rcMonitor;
    ::SetWindowPos(hwnd, HWND_TOP, area.left, area.top,
                   area.right - area.left, area.bottom - area.top,
                   SWP_FRAMECHANGED | SWP_NOOWNERZORDER);
  } else {
    ::SetWindowLongPtr(hwnd, GWL_STYLE,
                       windowed_style_ != 0
                           ? windowed_style_
                           : ((::GetWindowLongPtr(hwnd, GWL_STYLE) & ~WS_POPUP) |
                              WS_OVERLAPPEDWINDOW));
    if (windowed_placement_.length == sizeof(WINDOWPLACEMENT)) {
      // Back to a plain window: never minimized or maximized again on the way out.
      windowed_placement_.showCmd = SW_SHOWNORMAL;
      ::SetWindowPlacement(hwnd, &windowed_placement_);
    }
    ::SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER |
                       SWP_FRAMECHANGED);
  }
  fullscreen_ = on;
  return true;
}

void FlutterWindow::ReportFullscreen(bool on) {
  if (window_channel_) {
    window_channel_->InvokeMethod(
        "fullscreenChanged", std::make_unique<flutter::EncodableValue>(on));
  }
}

void FlutterWindow::MaximizeToFullscreen() {
  if (!fullscreen_ && SetFullscreen(true)) {
    ReportFullscreen(true);
  }
}

void FlutterWindow::OnDestroy() {
  retro_core_.reset();
  window_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  switch (message) {
    // The title bar's Maximize (its button, a double click on it, the system menu, Win+Up):
    // the launcher's full screen, with no title bar left, instead of a maximized window that
    // keeps its (dark) title bar along the top and that the launcher did not know of.
    case WM_SYSCOMMAND:
      if ((wparam & 0xFFF0) == SC_MAXIMIZE) {
        MaximizeToFullscreen();
        return 0;
      }
      break;
    // Maximized another way (Aero Snap's drag to the top): the same, once it is done.
    case WM_SIZE:
      if (wparam == SIZE_MAXIMIZED && !fullscreen_) {
        ::PostMessage(hwnd, kMaximizedMessage, 0, 0);
      }
      break;
    case kMaximizedMessage:
      if (::IsZoomed(hwnd)) {
        MaximizeToFullscreen();
      }
      return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
