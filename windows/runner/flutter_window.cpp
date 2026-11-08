#include "flutter_window.h"

#include <dwmapi.h>
#include <dxgi.h>
#include <flutter/standard_method_codec.h>
#include <flutter/plugin_registrar_windows.h>
#include <wrl/client.h>

#include <algorithm>
#include <cstdint>
#include <limits>
#include <optional>
#include <variant>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

// Posted when the window was maximized some way other than the system menu's command (Aero
// Snap's drag to the top): turned into full screen once that is done.
constexpr UINT kMaximizedMessage = WM_APP + 1;

std::optional<MONITORINFOEXW> ReadMonitor(HMONITOR monitor) {
  MONITORINFOEXW info{};
  info.cbSize = sizeof(info);
  if (monitor == nullptr || !::GetMonitorInfoW(monitor, &info) ||
      info.szDevice[0] == L'\0' || info.rcMonitor.right <= info.rcMonitor.left ||
      info.rcMonitor.bottom <= info.rcMonitor.top ||
      info.rcWork.right <= info.rcWork.left ||
      info.rcWork.bottom <= info.rcWork.top) {
    return std::nullopt;
  }
  return info;
}

BOOL CALLBACK CollectDisplay(HMONITOR monitor, HDC, LPRECT, LPARAM parameter) {
  auto* displays = reinterpret_cast<std::vector<MONITORINFOEXW>*>(parameter);
  if (const auto info = ReadMonitor(monitor)) {
    displays->push_back(*info);
  }
  return TRUE;
}

std::vector<MONITORINFOEXW> Displays() {
  std::vector<MONITORINFOEXW> displays;
  if (!::EnumDisplayMonitors(nullptr, nullptr, CollectDisplay,
                             reinterpret_cast<LPARAM>(&displays))) {
    return {};
  }
  return displays;
}

flutter::EncodableList DisplayList() {
  flutter::EncodableList values;
  for (const auto& display : Displays()) {
    const RECT& rect = display.rcMonitor;
    values.emplace_back(flutter::EncodableMap{
        {flutter::EncodableValue("id"),
         flutter::EncodableValue(Utf8FromUtf16(display.szDevice))},
        {flutter::EncodableValue("width"),
         flutter::EncodableValue(
             static_cast<std::int32_t>(rect.right - rect.left))},
        {flutter::EncodableValue("height"),
         flutter::EncodableValue(
             static_cast<std::int32_t>(rect.bottom - rect.top))},
        {flutter::EncodableValue("primary"),
         flutter::EncodableValue((display.dwFlags & MONITORINFOF_PRIMARY) != 0)},
    });
  }
  return values;
}

struct GameWindowSearch {
  DWORD pid;
  HWND window = nullptr;
  std::int64_t area = 0;
};

BOOL CALLBACK FindGameWindow(HWND window, LPARAM parameter) {
  auto* search = reinterpret_cast<GameWindowSearch*>(parameter);
  DWORD pid = 0;
  ::GetWindowThreadProcessId(window, &pid);
  if (pid != search->pid || !::IsWindowVisible(window) || ::IsIconic(window) ||
      ::GetWindow(window, GW_OWNER) != nullptr ||
      (::GetWindowLongPtr(window, GWL_EXSTYLE) & WS_EX_TOOLWINDOW) != 0) {
    return TRUE;
  }
  DWORD cloaked = 0;
  if (SUCCEEDED(::DwmGetWindowAttribute(window, DWMWA_CLOAKED, &cloaked,
                                        sizeof(cloaked))) &&
      cloaked != 0) {
    return TRUE;
  }
  RECT rect{};
  if (::GetWindowRect(window, &rect) && rect.right > rect.left &&
      rect.bottom > rect.top) {
    const auto area = static_cast<std::int64_t>(rect.right - rect.left) *
                      (rect.bottom - rect.top);
    if (area > search->area) {
      search->window = window;
      search->area = area;
    }
  }
  return TRUE;
}

HWND LargestGameWindow(DWORD pid) {
  GameWindowSearch search{pid};
  if (!::EnumWindows(FindGameWindow, reinterpret_cast<LPARAM>(&search))) {
    return nullptr;
  }
  return search.window;
}

bool GameBehindLauncher(HWND game, HWND launcher, const RECT& bounds) {
  HWND window = game;
  for (int guard = 0; guard < 512; ++guard) {
    window = ::GetWindow(window, GW_HWNDPREV);
    if (window == launcher) {
      return true;
    }
    if (window == nullptr) {
      return false;
    }
    if (!::IsWindowVisible(window) || ::IsIconic(window)) {
      continue;
    }
    DWORD cloaked = 0;
    if (SUCCEEDED(::DwmGetWindowAttribute(window, DWMWA_CLOAKED, &cloaked,
                                          sizeof(cloaked))) && cloaked != 0) {
      continue;
    }
    RECT frame{};
    RECT overlap{};
    if (::GetWindowRect(window, &frame) && ::IntersectRect(&overlap, &frame, &bounds)) {
      return false;
    }
  }
  return false;
}

RECT CenterWindowInArea(const RECT& window, const RECT& area) {
  const LONG area_width = area.right - area.left;
  const LONG area_height = area.bottom - area.top;
  const LONG width = std::clamp(window.right - window.left, 1L, area_width);
  const LONG height = std::clamp(window.bottom - window.top, 1L, area_height);
  const LONG left = area.left + (area_width - width) / 2;
  const LONG top = area.top + (area_height - height) / 2;
  return {left, top, left + width, top + height};
}

std::optional<DWORD> DecodePid(const flutter::EncodableValue& value) {
  std::int64_t pid = 0;
  if (const auto* narrow = std::get_if<std::int32_t>(&value)) {
    pid = *narrow;
  } else if (const auto* wide = std::get_if<std::int64_t>(&value)) {
    pid = *wide;
  }
  if (pid <= 0 || pid > std::numeric_limits<DWORD>::max()) {
    return std::nullopt;
  }
  return static_cast<DWORD>(pid);
}

flutter::EncodableList RetroAdapters() {
  Microsoft::WRL::ComPtr<IDXGIFactory1> factory;
  if (FAILED(::CreateDXGIFactory1(IID_PPV_ARGS(factory.GetAddressOf())))) {
    return {};
  }

  flutter::EncodableList adapters;
  for (UINT index = 0;; ++index) {
    Microsoft::WRL::ComPtr<IDXGIAdapter1> adapter;
    const HRESULT status = factory->EnumAdapters1(index, adapter.GetAddressOf());
    if (status == DXGI_ERROR_NOT_FOUND) {
      return adapters;
    }
    DXGI_ADAPTER_DESC1 description{};
    if (FAILED(status) || FAILED(adapter->GetDesc1(&description))) {
      return {};
    }
    if ((description.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0) {
      continue;
    }
    const std::string name = Utf8FromUtf16(description.Description);
    if (name.empty() ||
        description.DedicatedVideoMemory >
            static_cast<SIZE_T>(std::numeric_limits<std::int64_t>::max())) {
      return {};
    }
    adapters.emplace_back(flutter::EncodableMap{
        {flutter::EncodableValue("name"), flutter::EncodableValue(name)},
        {flutter::EncodableValue("dedicatedBytes"),
         flutter::EncodableValue(
             static_cast<std::int64_t>(description.DedicatedVideoMemory))},
    });
  }
}

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
        if (call.method_name() == "displays") {
          result->Success(flutter::EncodableValue(DisplayList()));
          return;
        }
        if (call.method_name() == "gameWindowReady") {
          const auto* argument = call.arguments();
          const auto pid = argument == nullptr ? std::nullopt
                                               : DecodePid(*argument);
          result->Success(
              flutter::EncodableValue(pid && LargestGameWindow(*pid) != nullptr));
          return;
        }
        if (call.method_name() == "moveToDisplay") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (args == nullptr) {
            result->Success(flutter::EncodableValue(false));
            return;
          }
          const auto id = args->find(flutter::EncodableValue("id"));
          const auto* device = id == args->end()
                                   ? nullptr
                                   : std::get_if<std::string>(&id->second);
          const auto pid = args->find(flutter::EncodableValue("pid"));
          const auto process =
              pid == args->end() ? std::nullopt : DecodePid(pid->second);
          result->Success(flutter::EncodableValue(
              device != nullptr && (pid == args->end() || process) &&
              MoveToDisplay(Utf16FromUtf8(*device), process)));
          return;
        }
        if (call.method_name() == "retroMenuRegion") {
          result->Success(flutter::EncodableValue(SetRetroMenuRegion(call.arguments())));
          return;
        }
        if (call.method_name() == "retroAdapters") {
          result->Success(flutter::EncodableValue(RetroAdapters()));
          return;
        }
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

bool FlutterWindow::SetRetroMenuRegion(const flutter::EncodableValue* arguments) {
  const HWND launcher = GetHandle();
  if (launcher == nullptr) {
    return false;
  }
  const auto clear = [this, launcher]() {
    if (!retro_menu_clipped_) {
      return true;
    }
    if (::SetWindowRgn(launcher, nullptr, TRUE) == 0) {
      return false;
    }
    retro_menu_clipped_ = false;
    return true;
  };
  if (arguments == nullptr || arguments->IsNull()) {
    return clear();
  }
  const auto* fields = std::get_if<flutter::EncodableList>(arguments);
  if (!fullscreen_ || fields == nullptr || fields->size() != 5) {
    clear();
    return false;
  }
  const auto pid = DecodePid(fields->front());
  const HWND game = pid ? LargestGameWindow(*pid) : nullptr;
  const HMONITOR display = ::MonitorFromWindow(launcher, MONITOR_DEFAULTTONULL);
  const auto monitor = ReadMonitor(display);
  RECT game_bounds{};
  RECT launcher_bounds{};
  if (!monitor || game == nullptr || ::MonitorFromWindow(game, MONITOR_DEFAULTTONULL) != display ||
      !::GetWindowRect(game, &game_bounds) || !::GetWindowRect(launcher, &launcher_bounds) ||
      !::EqualRect(&launcher_bounds, &monitor->rcMonitor) ||
      !::EqualRect(&game_bounds, &monitor->rcMonitor) ||
      !GameBehindLauncher(game, launcher, monitor->rcMonitor)) {
    clear();
    return false;
  }
  RECT region{};
  LONG* edges[] = {&region.left, &region.top, &region.right, &region.bottom};
  for (size_t index = 0; index < 4; ++index) {
    const auto* edge = std::get_if<std::int32_t>(&(*fields)[index + 1]);
    if (edge == nullptr) {
      clear();
      return false;
    }
    *edges[index] = *edge;
  }
  if (region.left < 0 || region.top < 0 || region.right <= region.left || region.bottom <= region.top ||
      region.right > launcher_bounds.right - launcher_bounds.left ||
      region.bottom > launcher_bounds.bottom - launcher_bounds.top) {
    clear();
    return false;
  }
  const HRGN clip = ::CreateRectRgnIndirect(&region);
  if (clip == nullptr) {
    clear();
    return false;
  }
  if (::SetWindowRgn(launcher, clip, TRUE) == 0) {
    ::DeleteObject(clip);
    clear();
    return false;
  }
  retro_menu_clipped_ = true;
  return true;
}

bool FlutterWindow::MoveToDisplay(const std::wstring& id,
                                  std::optional<DWORD> pid) {
  if (id.empty()) {
    return false;
  }
  const auto displays = Displays();
  const auto target = std::find_if(displays.begin(), displays.end(),
                                   [&id](const auto& display) {
                                     return id == display.szDevice;
                                   });
  if (target == displays.end()) {
    return false;
  }

  const HWND window = pid ? LargestGameWindow(*pid) : GetHandle();
  RECT current{};
  if (window == nullptr || ::IsIconic(window) ||
      !::GetWindowRect(window, &current) || current.right <= current.left ||
      current.bottom <= current.top) {
    return false;
  }
  const auto source =
      ReadMonitor(::MonitorFromWindow(window, MONITOR_DEFAULTTONULL));
  const bool fullscreen = (!pid && fullscreen_) ||
                          (source && ::EqualRect(&current, &source->rcMonitor));
  const RECT placed = fullscreen ? target->rcMonitor
                                 : CenterWindowInArea(current, target->rcWork);
  if (pid) {
    DWORD owner = 0;
    ::GetWindowThreadProcessId(window, &owner);
    if (owner != *pid) {
      return false;
    }
  }
  const UINT flags = SWP_NOACTIVATE | SWP_NOZORDER | SWP_NOOWNERZORDER |
                     (pid ? SWP_ASYNCWINDOWPOS : 0);
  const auto place = [&]() {
    return ::SetWindowPos(window, nullptr, placed.left, placed.top,
                          placed.right - placed.left, placed.bottom - placed.top,
                          flags) != 0;
  };
  const UINT original_dpi = pid ? 0 : ::GetDpiForWindow(window);
  bool moved = place();
  if (moved && !pid && original_dpi != ::GetDpiForWindow(window)) {
    moved = place();
  }
  if (moved && !pid && fullscreen_) {
    fullscreen_monitor_moved_ = true;
  }
  return moved;
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
    std::optional<RECT> restored;
    if (fullscreen_monitor_moved_ &&
        windowed_placement_.length == sizeof(WINDOWPLACEMENT)) {
      if (const auto monitor =
              ReadMonitor(::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST))) {
        restored = CenterWindowInArea(windowed_placement_.rcNormalPosition,
                                     monitor->rcWork);
      }
    }
    fullscreen_monitor_moved_ = false;
    if (restored) {
      ::SetWindowPos(hwnd, nullptr, restored->left, restored->top,
                     restored->right - restored->left,
                     restored->bottom - restored->top,
                     SWP_NOACTIVATE | SWP_NOZORDER | SWP_NOOWNERZORDER |
                         SWP_FRAMECHANGED);
      fullscreen_ = false;
      return true;
    }
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
