#include "retro_linux_platform.h"

#include <pulse/pulseaudio.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <limits>
#include <mutex>
#include <thread>

namespace anyps5::retro {
namespace {

class PulseAudio final : public Audio {
 public:
  bool Open(double rate) override {
    std::unique_lock<std::mutex> lock(mutex_);
    CloseLocked();
    if (!std::isfinite(rate) || rate < 8000 || rate > 192000) return false;
    sample_spec_ = {PA_SAMPLE_S16LE, static_cast<uint32_t>(std::lround(rate)), 2};
    loop_ = pa_threaded_mainloop_new();
    if (!loop_) return false;
    context_ = pa_context_new(pa_threaded_mainloop_get_api(loop_), "AnyPS5");
    if (!context_ || pa_context_connect(context_, nullptr, PA_CONTEXT_NOAUTOSPAWN, nullptr) < 0 ||
        pa_threaded_mainloop_start(loop_) < 0) {
      CloseLocked();
      return false;
    }
    started_ = true;

    // Startup is bounded. A missing audio service does not prevent the game from running.
    using Clock = std::chrono::steady_clock;
    const auto deadline = Clock::now() + std::chrono::milliseconds(500);
    while (Clock::now() < deadline) {
      pa_threaded_mainloop_lock(loop_);
      const auto context_state = pa_context_get_state(context_);
      if (!stream_ && context_state == PA_CONTEXT_READY) OpenStream();
      const auto stream_state = stream_ ? pa_stream_get_state(stream_) : PA_STREAM_UNCONNECTED;
      pa_threaded_mainloop_unlock(loop_);
      if (stream_state == PA_STREAM_READY) return true;
      if (!PA_CONTEXT_IS_GOOD(context_state) || stream_state == PA_STREAM_FAILED ||
          stream_state == PA_STREAM_TERMINATED) break;
      lock.unlock();
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
      lock.lock();
    }
    CloseLocked();
    return false;
  }

  void Write(const int16_t* stereo, size_t frames) override {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!stream_ || frames == 0) return;
    const size_t bytes_per_frame = sizeof(*stereo) * 2;
    pa_threaded_mainloop_lock(loop_);
    const size_t writable = pa_stream_get_state(stream_) == PA_STREAM_READY
                                ? pa_stream_writable_size(stream_) : static_cast<size_t>(-1);
    size_t accepted = writable == static_cast<size_t>(-1) ? 0 : std::min(frames, writable / bytes_per_frame);
    if (accepted && pa_stream_write(stream_, stereo, accepted * bytes_per_frame, nullptr, 0, PA_SEEK_RELATIVE) < 0)
      accepted = 0;
    pa_threaded_mainloop_unlock(loop_);
    dropped_frames_ += frames - accepted;
  }

  void Flush() override {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!stream_) return;
    pa_threaded_mainloop_lock(loop_);
    if (auto* operation = pa_stream_flush(stream_, nullptr, nullptr)) pa_operation_unref(operation);
    pa_threaded_mainloop_unlock(loop_);
  }

  int64_t dropped_frames() const override { return dropped_frames_; }

  void Close() override {
    std::lock_guard<std::mutex> lock(mutex_);
    CloseLocked();
  }

 private:
  void OpenStream() {
    stream_ = pa_stream_new(context_, "Emulated game", &sample_spec_, nullptr);
    if (!stream_) return;
    const auto target = static_cast<uint32_t>(pa_usec_to_bytes(40000, &sample_spec_));
    constexpr auto automatic = std::numeric_limits<uint32_t>::max();
    const pa_buffer_attr buffer{target * 2, target, automatic, automatic, automatic};
    if (pa_stream_connect_playback(stream_, nullptr, &buffer, PA_STREAM_ADJUST_LATENCY, nullptr, nullptr) < 0) {
      pa_stream_unref(stream_);
      stream_ = nullptr;
    }
  }

  void CloseLocked() {
    if (started_) pa_threaded_mainloop_stop(loop_);
    started_ = false;
    if (stream_) {
      pa_stream_disconnect(stream_);
      pa_stream_unref(stream_);
      stream_ = nullptr;
    }
    if (context_) {
      pa_context_disconnect(context_);
      pa_context_unref(context_);
      context_ = nullptr;
    }
    if (loop_) {
      pa_threaded_mainloop_free(loop_);
      loop_ = nullptr;
    }
  }

  std::mutex mutex_;
  std::atomic<int64_t> dropped_frames_{0};
  pa_sample_spec sample_spec_{};
  pa_threaded_mainloop* loop_ = nullptr;
  pa_context* context_ = nullptr;
  pa_stream* stream_ = nullptr;
  bool started_ = false;
};
}  // namespace

std::unique_ptr<Audio> CreateLinuxAudio() { return std::make_unique<PulseAudio>(); }

}  // namespace anyps5::retro
