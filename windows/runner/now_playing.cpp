#include "now_playing.h"

#include <winrt/base.h>

#include <winrt/Windows.ApplicationModel.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.Control.h>
#include <winrt/Windows.Storage.Streams.h>

#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

namespace control = winrt::Windows::Media::Control;
namespace streams = winrt::Windows::Storage::Streams;

using Manager = control::GlobalSystemMediaTransportControlsSessionManager;
using Session = control::GlobalSystemMediaTransportControlsSession;
using Status = control::GlobalSystemMediaTransportControlsSessionPlaybackStatus;

// No cover is bigger than this; a larger one is left out.
constexpr uint64_t kMostArtwork = 4 * 1024 * 1024;

// What the thread is asked to do, after the three commands of now_playing.h.
enum Job {
  kJobWatch = 16,
  kJobUnwatch,
  kJobSession,
  kJobRefresh,
};

struct Snapshot {
  bool present = false;
  bool playing = false;
  std::string title;
  std::string artist;
  std::string player;
  std::vector<uint8_t> artwork;

  bool operator==(const Snapshot& other) const {
    return present == other.present && playing == other.playing &&
           title == other.title && artist == other.artist &&
           player == other.player && artwork == other.artwork;
  }
};

char* Copy(const std::string& text) {
  char* out = static_cast<char*>(std::malloc(text.size() + 1));
  if (out != nullptr) {
    std::memcpy(out, text.c_str(), text.size() + 1);
  }
  return out;
}

// The player's name as Windows lists the app; else what its app user model ID ends in, without
// ".exe" ("Spotify.exe", "Family_publisher!App").
std::string PlayerName(const winrt::hstring& id) {
  try {
    auto info =
        winrt::Windows::ApplicationModel::AppInfo::GetFromAppUserModelId(id);
    if (info) {
      const winrt::hstring name = info.DisplayInfo().DisplayName();
      if (!name.empty()) {
        return winrt::to_string(name);
      }
    }
  } catch (...) {
    // An app Windows has no entry for, or a Windows before this call.
  }
  std::string text = winrt::to_string(id);
  const size_t bang = text.rfind('!');
  if (bang != std::string::npos && bang + 1 < text.size()) {
    text = text.substr(bang + 1);
  }
  if (text.size() > 4 &&
      _stricmp(text.c_str() + text.size() - 4, ".exe") == 0) {
    text.resize(text.size() - 4);
  }
  return text;
}

std::vector<uint8_t> ReadThumbnail(
    const streams::IRandomAccessStreamReference& reference) {
  std::vector<uint8_t> bytes;
  if (!reference) {
    return bytes;
  }
  try {
    auto stream = reference.OpenReadAsync().get();
    const uint64_t size = stream.Size();
    if (size == 0 || size > kMostArtwork) {
      return bytes;
    }
    streams::DataReader reader(stream);
    const uint32_t loaded =
        reader.LoadAsync(static_cast<uint32_t>(size)).get();
    bytes.resize(loaded);
    if (loaded > 0) {
      reader.ReadBytes(bytes);
    }
  } catch (...) {
    bytes.clear();
  }
  return bytes;
}

}  // namespace

struct NowPlaying {
  NowPlaying(NowPlayingChanged changed, void* context)
      : changed_(changed), context_(context) {
    worker_ = std::thread([this] { Run(); });
  }

  ~NowPlaying() {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      quit_ = true;
    }
    wake_.notify_all();
    if (worker_.joinable()) {
      worker_.join();
    }
  }

  void Push(int job) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (quit_) {
        return;
      }
      // A burst of the same event (a new song changes its properties several times) is read
      // once.
      if (job == kJobRefresh && !jobs_.empty() && jobs_.back() == kJobRefresh) {
        return;
      }
      jobs_.push_back(job);
    }
    wake_.notify_one();
  }

  Snapshot Current() {
    std::lock_guard<std::mutex> lock(mutex_);
    return snapshot_;
  }

 private:
  void Run() {
    bool apartment = false;
    try {
      winrt::init_apartment(winrt::apartment_type::multi_threaded);
      apartment = true;
    } catch (...) {
    }
    for (;;) {
      int job = 0;
      {
        std::unique_lock<std::mutex> lock(mutex_);
        wake_.wait(lock, [this] { return quit_ || !jobs_.empty(); });
        if (quit_) {
          break;
        }
        job = jobs_.front();
        jobs_.pop_front();
      }
      try {
        Handle(job);
      } catch (...) {
        // Windows has no media sessions (an older Windows, a stripped one) or the player
        // left in the middle: no session, said once.
        Publish(Snapshot{});
      }
    }
    try {
      Unhook();
      UnhookManager();
    } catch (...) {
    }
    session_ = nullptr;
    manager_ = nullptr;
    if (apartment) {
      winrt::uninit_apartment();
    }
  }

  void Handle(int job) {
    switch (job) {
      case kJobWatch:
        watching_ = true;
        EnsureManager();
        if (manager_ && !manager_hooked_) {
          manager_token_ = manager_.CurrentSessionChanged(
              [this](auto&&, auto&&) { Push(kJobSession); });
          manager_hooked_ = true;
        }
        Attach();
        Refresh();
        break;
      case kJobUnwatch:
        watching_ = false;
        Unhook();
        UnhookManager();
        session_ = nullptr;
        artwork_key_.clear();
        artwork_.clear();
        Publish(Snapshot{});
        break;
      case kJobSession:
        if (watching_) {
          Attach();
          Refresh();
        }
        break;
      case kJobRefresh:
        if (watching_) {
          Refresh();
        }
        break;
      case kNowPlayingPlayPause:
      case kNowPlayingNext:
      case kNowPlayingPrevious: {
        EnsureManager();
        Session current{nullptr};
        if (manager_) {
          current = manager_.GetCurrentSession();
        }
        if (!current) {
          break;
        }
        if (job == kNowPlayingPlayPause) {
          current.TryTogglePlayPauseAsync().get();
        } else if (job == kNowPlayingNext) {
          current.TrySkipNextAsync().get();
        } else {
          current.TrySkipPreviousAsync().get();
        }
        break;
      }
    }
  }

  void EnsureManager() {
    if (!manager_) {
      manager_ = Manager::RequestAsync().get();
    }
  }

  // The session Windows calls the current one, with its events.
  void Attach() {
    Unhook();
    session_ = nullptr;
    if (manager_) {
      session_ = manager_.GetCurrentSession();
    }
    if (!session_) {
      return;
    }
    properties_token_ = session_.MediaPropertiesChanged(
        [this](auto&&, auto&&) { Push(kJobRefresh); });
    playback_token_ = session_.PlaybackInfoChanged(
        [this](auto&&, auto&&) { Push(kJobRefresh); });
    session_hooked_ = true;
  }

  void Unhook() {
    if (session_ && session_hooked_) {
      session_.MediaPropertiesChanged(properties_token_);
      session_.PlaybackInfoChanged(playback_token_);
    }
    session_hooked_ = false;
  }

  void UnhookManager() {
    if (manager_ && manager_hooked_) {
      manager_.CurrentSessionChanged(manager_token_);
    }
    manager_hooked_ = false;
  }

  void Refresh() {
    Snapshot next;
    if (session_) {
      auto info = session_.GetPlaybackInfo();
      Status status = Status::Closed;
      if (info) {
        status = info.PlaybackStatus();
      }
      if (status == Status::Playing || status == Status::Paused) {
        auto properties = session_.TryGetMediaPropertiesAsync().get();
        std::string title;
        if (properties) {
          title = winrt::to_string(properties.Title());
        }
        if (!title.empty()) {
          next.present = true;
          next.playing = status == Status::Playing;
          next.title = title;
          next.artist = winrt::to_string(properties.Artist());
          const winrt::hstring id = session_.SourceAppUserModelId();
          if (id != player_id_ || player_name_.empty()) {
            player_id_ = id;
            player_name_ = PlayerName(id);
          }
          next.player = player_name_;
          // The cover is read once for a song; again while it has none (players often give
          // it a moment after the title).
          const std::string key =
              next.player + "\n" + next.title + "\n" + next.artist;
          if (key != artwork_key_ || artwork_.empty()) {
            artwork_ = ReadThumbnail(properties.Thumbnail());
            artwork_key_ = key;
          }
          next.artwork = artwork_;
        }
      }
    }
    Publish(std::move(next));
  }

  void Publish(Snapshot next) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (next == snapshot_) {
        return;
      }
      snapshot_ = std::move(next);
    }
    if (changed_ != nullptr) {
      changed_(context_);
    }
  }

  const NowPlayingChanged changed_;
  void* const context_;

  std::mutex mutex_;
  std::condition_variable wake_;
  std::deque<int> jobs_;
  bool quit_ = false;
  Snapshot snapshot_;

  // The thread's own.
  Manager manager_{nullptr};
  Session session_{nullptr};
  winrt::event_token manager_token_{};
  winrt::event_token properties_token_{};
  winrt::event_token playback_token_{};
  bool manager_hooked_ = false;
  bool session_hooked_ = false;
  bool watching_ = false;
  winrt::hstring player_id_;
  std::string player_name_;
  std::string artwork_key_;
  std::vector<uint8_t> artwork_;

  std::thread worker_;
};

extern "C" {

NowPlaying* NowPlayingCreate(NowPlayingChanged changed, void* context) {
  try {
    return new NowPlaying(changed, context);
  } catch (...) {
    return nullptr;
  }
}

void NowPlayingDestroy(NowPlaying* now_playing) {
  try {
    delete now_playing;
  } catch (...) {
  }
}

void NowPlayingWatch(NowPlaying* now_playing, int on) {
  if (now_playing != nullptr) {
    now_playing->Push(on ? kJobWatch : kJobUnwatch);
  }
}

void NowPlayingCommand(NowPlaying* now_playing, int command) {
  if (now_playing != nullptr &&
      (command == kNowPlayingPlayPause || command == kNowPlayingNext ||
       command == kNowPlayingPrevious)) {
    now_playing->Push(command);
  }
}

void NowPlayingRead(NowPlaying* now_playing, NowPlayingTrack* track) {
  if (track == nullptr) {
    return;
  }
  std::memset(track, 0, sizeof(*track));
  if (now_playing == nullptr) {
    return;
  }
  try {
    const Snapshot current = now_playing->Current();
    if (!current.present) {
      return;
    }
    track->present = 1;
    track->playing = current.playing ? 1 : 0;
    track->title = Copy(current.title);
    track->artist = Copy(current.artist);
    track->player = Copy(current.player);
    if (!current.artwork.empty()) {
      track->artwork =
          static_cast<uint8_t*>(std::malloc(current.artwork.size()));
      if (track->artwork != nullptr) {
        std::memcpy(track->artwork, current.artwork.data(),
                    current.artwork.size());
        track->artwork_size = current.artwork.size();
      }
    }
  } catch (...) {
    NowPlayingFree(track);
  }
}

void NowPlayingFree(NowPlayingTrack* track) {
  if (track == nullptr) {
    return;
  }
  std::free(track->title);
  std::free(track->artist);
  std::free(track->player);
  std::free(track->artwork);
  std::memset(track, 0, sizeof(*track));
}

}  // extern "C"
