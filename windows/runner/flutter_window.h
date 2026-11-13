#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>
#include <string>

#include "now_playing.h"
#include "retro_core_host.h"
#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

  // A borderless window over the whole monitor it is on, or back to the window it was (its
  // style and placement kept from before). Returns whether it could.
  bool SetFullscreen(bool on);

  // The launcher's marker of this run ("removeAfterClose"), for main to take away once the
  // window has closed and Flutter has shut down; empty when the launcher gave none.
  const std::wstring& run_marker() const { return run_marker_; }

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<RetroCoreHost> retro_core_;

  // "anyps5/window": the launcher asks for full screen and back (F11, its setting).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> window_channel_;

  // The system made the window full screen or a window on its own: the launcher hears of it
  // ("fullscreenChanged"), so its window buttons and its setting follow.
  void ReportFullscreen(bool on);

  // The title bar's Maximize turned into the launcher's full screen.
  void MaximizeToFullscreen();

  // "anyps5/now_playing": what a media player on this computer plays, for the quick menu's
  // card (now_playing.h). The launcher turns the watching on and off, asks for the track and
  // sends previous, play or pause and next; it hears "changed" with the track each time
  // Windows says it changed.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      now_playing_channel_;
  NowPlaying* now_playing_ = nullptr;

  // The track as the channel carries it: null with no session, else a map of title, artist,
  // player, playing and (when the player gave a cover) artwork.
  flutter::EncodableValue NowPlayingValue();

  std::wstring run_marker_;

  bool fullscreen_ = false;
  LONG_PTR windowed_style_ = 0;
  WINDOWPLACEMENT windowed_placement_{};
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
