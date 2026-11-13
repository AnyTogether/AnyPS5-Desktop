#include "retro_session.h"

#include "retro_library.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <thread>
#include <utility>

#if defined(_WIN32)
#include <windows.h>
#endif

namespace anyps5::retro {
namespace {
constexpr char kPs3Resolution[] = "rpcs3_resolution_scale";

bool ResolutionOption(const std::string& key) {
  return key == "swanstation_GPU_ResolutionScale" || key == "pcsx2_upscale_multiplier";
}

constexpr auto kPs1Resolution = "swanstation_GPU_ResolutionScale";
constexpr auto kPs1Filter = "swanstation_GPU_TextureFilter";
constexpr auto kPs2Resolution = "pcsx2_upscale_multiplier";
constexpr auto kPs2Anisotropy = "pcsx2_anisotropic_filtering";
constexpr auto kPs2Trilinear = "pcsx2_trilinear_filtering";

bool Ps1GraphicsOption(const std::string& key) {
  return key == kPs1Resolution || key == kPs1Filter;
}

bool TrialOption(const std::string& key) {
  return Ps1GraphicsOption(key) || key == kPs2Resolution || key == kPs2Anisotropy || key == kPs2Trilinear ||
         key == kPs3Resolution || key == "rpcs3_anisotropic_filter";
}

bool LiveCoreOption(const std::string& key, bool hardware) {
  return key == "swanstation_Display_CropMode" || key == "pcsx2_deinterlace_mode" ||
         (hardware && (ResolutionOption(key) || TrialOption(key)));
}

bool BootCoreOption(const std::string& key) {
  static constexpr std::string_view keys[] = {
      "swanstation_GPU_Renderer", "swanstation_CPU_ExecutionMode",
      "swanstation_CDROM_PreCacheCHD", "swanstation_CDROM_ReadThread",
      "swanstation_CDROM_ReadaheadSectors", "pcsx2_renderer", "pcsx2_mtvu",
      "pcsx2_fastcdvd", "pcsx2_sw_renderer_threads", "pcsx2_disable_shader_cache",
      "rpcs3_ppu_decoder", "rpcs3_spu_decoder", "rpcs3_preferred_spu_threads",
      "rpcs3_llvm_threads", "rpcs3_shader_compiler_threads", "rpcs3_llvm_precompilation",
      "rpcs3_emulate_hdd_speed", "rpcs3_emulate_bdvd_speed", "rpcs3_disk_cache_size",
      "rpcs3_spu_cache", "rpcs3_master_volume", "rpcs3_language", "rpcs3_license_area",
      "rpcs3_enter_button",
  };
  return std::find(std::begin(keys), std::end(keys), key) != std::end(keys);
}

bool SupportedBootValue(const std::string& key, std::string_view value, std::string_view renderer) {
  if (key == "swanstation_GPU_Renderer") {
    return value == "Software" || (!renderer.empty() && value == renderer);
  }
  if (key == "pcsx2_renderer") {
    return value == "Software (SW)" || value == "Software (HW)" ||
           (!renderer.empty() && value == renderer);
  }
  return key != "rpcs3_disk_cache_size" || value != "wipe";
}

void RestoreCard(const std::filesystem::path& path, void* data, size_t size) {
  if (!data || !size || !std::filesystem::exists(path)) return;
  if (std::filesystem::file_size(path) != size) {
    throw std::runtime_error("The PlayStation memory card has an unexpected size");
  }
  std::ifstream file(path, std::ios::binary);
  if (!file.read(static_cast<char*>(data), static_cast<std::streamsize>(size))) {
    throw std::runtime_error("Could not read the PlayStation memory card");
  }
}

void StoreCard(const std::filesystem::path& path, const void* data, size_t size) {
  if (!data || !size) return;
  auto temporary = path;
  temporary += ".tmp";
  std::ofstream file(temporary, std::ios::binary | std::ios::trunc);
  file.write(static_cast<const char*>(data), static_cast<std::streamsize>(size));
  file.close();
  if (!file) throw std::runtime_error("Could not write the PlayStation memory card");
#if defined(_WIN32)
  if (!MoveFileExW(temporary.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
#else
  std::error_code error;
  std::filesystem::rename(temporary, path, error);
  if (error) {
#endif
    throw std::runtime_error("Could not write the PlayStation memory card");
  }
}
}  // namespace

Console ConsoleForCore(const std::string& path) {
  const auto name = std::filesystem::u8path(path).stem().u8string();
  if (name == "swanstation_libretro") return Console::kPs1;
  if (name == "pcsx2_libretro") return Console::kPs2;
  if (name == "rpcs3_libretro") return Console::kPs3;
  return Console::kUnknown;
}

class Session::Impl {
 public:
  Impl(SessionConfig config, std::unique_ptr<Video> video, std::unique_ptr<Audio> audio,
       std::function<void()> frame_available)
      : config_(std::move(config)), content_(std::filesystem::u8path(config_.disc).parent_path().u8string()),
        console_(ConsoleForCore(config_.core)), ps3_(console_ == Console::kPs3),
        frame_available_(std::move(frame_available)), video_(std::move(video)), audio_(std::move(audio)) {}

  ~Impl() { Stop(); Join(); }

  void Start() { worker_ = std::thread([this] { Run(); }); }

  bool ended() const { return ended_; }
  void Stop() { stop_ = true; }
  void Join() { if (worker_.joinable()) worker_.join(); }

  void Pause(bool pause) {
    if (paused_.exchange(pause) == pause) return;
    if (pause) {
      SetInput(0, {});
      audio_->Flush();
      std::lock_guard<std::mutex> lock(telemetry_mutex_);
      last_frame_at_ = {};
    }
  }

  bool ChangeDisc(unsigned index) {
    std::lock_guard<std::mutex> lock(settings_mutex_);
    if (stop_ || ended_ || !discs_ || discs_->busy ||
        index >= discs_->labels.size() || discs_->inserted == index)
      return false;
    discs_->busy = true;
    discs_->failed = false;
    pending_disc_ = index;
    return true;
  }

  void SetInput(uint16_t buttons, const std::array<int16_t, 4>& axes) {
    std::lock_guard<std::mutex> lock(input_mutex_);
    buttons_ = buttons;
    axes_ = axes;
  }

  SessionStatus Status() {
    std::lock_guard<std::mutex> lock(settings_mutex_);
    SessionStatus status;
    status.ready = frame_ready_;
    status.presented = presented_;
    status.ended = ended_;
    status.error = error_;
    status.aspect = aspect_;
    status.hardware = hardware_frame_;
    status.frame_width = static_cast<int32_t>(frame_width_.load());
    status.frame_height = static_cast<int32_t>(frame_height_.load());
    status.resolution_error = resolution_error_;
    status.graphics_pending = graphics_queued_ || graphics_applying_;
    if (std::chrono::steady_clock::now() < progress_until_) {
      status.progress_label = progress_label_;
      if (progress_percent_ >= 0) status.progress_percent = progress_percent_;
    }
    for (const auto& [key, option] : options_) {
      if (!option.graphics && !option.boot && !LiveCoreOption(key, hardware_frame_)) continue;
      status.options.emplace(key, OptionStatus{option.values, option.labels, option.title,
          option.values[option.selected], option.boot || (option.graphics && !TrialOption(key)),
          static_cast<int32_t>(option.pending.value_or(option.selected))});
    }
    status.telemetry = TuningTelemetry();
    status.discs = discs_;
    if (status.discs)
      status.discs->played = status.discs->inserted && status.telemetry.steps > disc_inserted_at_step_;
    return status;
  }

  std::shared_ptr<const Frame> AcquireFrame() {
    std::lock_guard<std::mutex> lock(frame_mutex_);
    if (frame_) presented_ = true;
    return frame_;
  }

  bool SetOption(const std::string& key, const std::string& value) {
    std::lock_guard<std::mutex> lock(settings_mutex_);
    const auto option = options_.find(key);
    if (option == options_.end() ||
        (!option->second.graphics && !option->second.boot && !LiveCoreOption(key, hardware_frame_))) return false;
    auto& data = option->second;
    const auto choice = std::find(data.values.begin(), data.values.end(), value);
    if (choice == data.values.end()) return false;
    const auto selected = static_cast<size_t>(choice - data.values.begin());
    if (graphics_applying_ || (graphics_queued_ && (key == kPs2Anisotropy || key == kPs2Trilinear))) return false;
    if (Ps1GraphicsOption(key) || key == kPs2Resolution) {
      data.pending = selected;
      graphics_queued_ = true;
      resolution_error_.clear();
    } else if (data.boot || (data.graphics && !TrialOption(key))) {
      data.pending = selected;
    } else if (selected != data.selected) {
      data.selected = selected;
      options_changed_ = true;
    }
    return true;
  }

  bool SetTuningOptions(const Options& expected, const Options& values) {
    if (!presented_ || !hardware_frame_ || values.empty() || expected.size() != values.size())
      return false;
    std::lock_guard<std::mutex> lock(settings_mutex_);
    if (graphics_applying_ || graphics_queued_) return false;
    std::vector<std::pair<Option*, size_t>> changes;
    bool checkpoint = false;
    for (const auto& [key, value] : values) {
      if (!TrialOption(key)) return false;
      checkpoint |= Ps1GraphicsOption(key) || key == kPs2Resolution;
      const auto current = expected.find(key);
      const auto option = options_.find(key);
      if (current == expected.end() || option == options_.end()) return false;
      auto& data = option->second;
      if (data.values[data.selected] != current->second) return false;
      const auto choice = std::find(data.values.begin(), data.values.end(), value);
      if (choice == data.values.end()) return false;
      changes.emplace_back(&data, static_cast<size_t>(choice - data.values.begin()));
    }
    for (const auto& change : changes) {
      if (checkpoint) change.first->pending = change.second;
      else change.first->selected = change.second;
    }
    if (checkpoint) {
      graphics_queued_ = true;
      resolution_error_.clear();
    } else {
      options_changed_ = true;
    }
    return true;
  }

 private:
  struct Option {
    std::vector<std::string> values;
    std::vector<std::string> labels;
    std::string title;
    bool graphics = false;
    bool boot = false;
    size_t selected = 0;
    std::optional<size_t> pending;
  };

  void SetCoreOptions(const CoreOptionsV2* options) {
    if (!ps3_ || !options || !options->definitions) return;
    std::lock_guard<std::mutex> lock(settings_mutex_);
    for (auto* row = options->definitions; row->key; ++row) {
      const std::string key = row->key;
      if (options_.count(key)) continue;
      Option option;
      if (row->title) option.title = row->title;
      option.graphics = row->category && std::strcmp(row->category, "gpu") == 0 &&
                        key != "rpcs3_renderer";
      option.boot = BootCoreOption(key);
      std::string preferred = row->default_value ? row->default_value : "";
      if (key == "rpcs3_renderer") preferred = "vulkan";
      if (option.graphics || option.boot) {
        const auto saved = config_.initial_graphics.find(key);
        if (saved != config_.initial_graphics.end()) preferred = saved->second;
      }
      for (const auto& value : row->values) {
        if (!value.value) break;
        if (!SupportedBootValue(key, value.value, hardware_available_ ? video_->PreferredRenderer() : std::string_view{})) continue;
        if (key == kPs3Resolution && std::atoi(value.value) > 200) continue;
        option.values.emplace_back(value.value);
        option.labels.emplace_back(value.label ? value.label : value.value);
      }
      auto choice = std::find(option.values.begin(), option.values.end(), preferred);
      if (choice == option.values.end() && row->default_value) {
        choice = std::find(option.values.begin(), option.values.end(), row->default_value);
      }
      if (choice != option.values.end()) option.selected = static_cast<size_t>(choice - option.values.begin());
      if (!option.values.empty()) options_.emplace(key, std::move(option));
    }
  }

  template <typename Reopen>
  void ApplyCheckpointGraphics(const DynamicLibrary& core, const Reopen& reopen, void (*step)(), bool ps1,
                               void*& card, size_t& card_size, const std::filesystem::path& card_path) {
    using Clock = std::chrono::steady_clock;
    struct Change { Option* option; size_t before; size_t after; };
    std::vector<Change> changes;
    {
      std::lock_guard<std::mutex> lock(settings_mutex_);
      if (!graphics_queued_) return;
      graphics_queued_ = false;
      constexpr std::array<const char*, 2> ps1_keys{kPs1Resolution, kPs1Filter};
      constexpr std::array<const char*, 3> ps2_keys{kPs2Resolution, kPs2Anisotropy, kPs2Trilinear};
      const auto* keys = ps1 ? ps1_keys.data() : ps2_keys.data();
      const auto count = ps1 ? ps1_keys.size() : ps2_keys.size();
      for (size_t index = 0; index < count; ++index) {
        const auto* key = keys[index];
        const auto found = options_.find(key);
        if (found == options_.end()) continue;
        auto& option = found->second;
        const auto pending = std::exchange(option.pending, std::nullopt);
        if (pending && *pending != option.selected)
          changes.push_back({&option, option.selected, *pending});
      }
      if (changes.empty()) return;
      graphics_applying_ = true;
    }
    const auto serialize_size = core.Get<size_t (*)()>("retro_serialize_size");
    const auto serialize = core.Get<bool (*)(void*, size_t)>("retro_serialize");
    const auto unserialize = core.Get<bool (*)(const void*, size_t)>("retro_unserialize");
    const auto size = serialize_size();
    std::vector<uint8_t> state(size);
    bool checkpoint_ready = size != 0 && serialize(state.data(), size);
    std::string failure = "The emulator could not apply those graphics settings.";
    if (checkpoint_ready && card) {
      try {
        StoreCard(card_path, card, card_size);
      } catch (const std::exception& error) {
        checkpoint_ready = false;
        failure = error.what();
      }
    }
    bool applied = false;
    if (checkpoint_ready) {
      const auto restore = [&](bool use_requested) {
        {
          std::lock_guard<std::mutex> lock(settings_mutex_);
          for (const auto& change : changes)
            change.option->selected = use_requested ? change.after : change.before;
          if (ps1) options_changed_ = true;
        }
        suppress_frame_ = true;
        if (ps1) step();
        const bool restored = (ps1 || reopen()) && unserialize(state.data(), size);
        suppress_frame_ = false;
        if (!restored) return false;
        const auto before = hardware_frames_;
        const auto deadline = Clock::now() + std::chrono::seconds(2);
        while (!stop_ && hardware_frames_ == before && Clock::now() < deadline) {
          step();
          if (hardware_frames_ == before)
            std::this_thread::sleep_for(std::chrono::milliseconds(4));
        }
        return stop_ || hardware_frames_ != before;
      };
      audio_->Flush();
      applied = restore(true);
      if (!applied && !restore(false))
        throw std::runtime_error("The emulator could not restore the game after changing graphics.");
      if (ps1) {
        card = core.Get<void* (*)(unsigned)>("retro_get_memory_data")(0);
        card_size = core.Get<size_t (*)(unsigned)>("retro_get_memory_size")(0);
      }
    }
    std::lock_guard<std::mutex> lock(settings_mutex_);
    graphics_applying_ = false;
    if (!applied) resolution_error_ = std::move(failure);
  }

  void Publish(const void* data, unsigned width, unsigned height, size_t pitch) {
    if (suppress_frame_ || !data || width == 0 || height == 0 || width > kMaxFrameSize || height > kMaxFrameSize)
      return;
    if (data == reinterpret_cast<const void*>(UINTPTR_MAX)) {
      try {
        if (auto frame = video_->Read(width, height, hardware_callbacks_)) SubmitFrame(std::move(frame), true);
      } catch (const std::exception& error) {
        std::lock_guard<std::mutex> lock(settings_mutex_);
        error_ = error.what();
        stop_ = true;
      }
      return;
    }
    if (auto frame = DecodeSoftwareFrame(data, width, height, pitch, pixel_format_)) {
      SubmitFrame(std::move(frame), false);
    }
  }

  Telemetry TuningTelemetry() {
    using Clock = std::chrono::steady_clock;
    std::lock_guard<std::mutex> lock(telemetry_mutex_);
    const auto now = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now().time_since_epoch()).count();
    return {now, video_frames_, steps_, audio_frames_, audio_->dropped_frames(),
            frame_intervals_, target_fps_, audio_rate_};
  }

  void RecordFrame() {
    using Clock = std::chrono::steady_clock;
    const auto now = Clock::now();
    std::lock_guard<std::mutex> lock(telemetry_mutex_);
    ++video_frames_;
    if (last_frame_at_ != Clock::time_point{}) {
      const auto millis = std::chrono::duration<double, std::milli>(now - last_frame_at_).count();
      static constexpr std::array<int, 13> limits{8, 12, 16, 20, 25, 35, 50, 75, 100, 150, 250, 500, 1000};
      const auto index = std::min(static_cast<size_t>(std::lower_bound(limits.begin(), limits.end(), millis) -
                                                     limits.begin()), limits.size() - 1);
      ++frame_intervals_[index];
    }
    last_frame_at_ = now;
  }

  void SubmitFrame(std::shared_ptr<Frame> frame, bool hardware) {
    if (!paused_) RecordFrame();
    if (hardware) ++hardware_frames_;
    hardware_frame_ = hardware;
    frame_width_ = static_cast<unsigned>(frame->width);
    frame_height_ = static_cast<unsigned>(frame->height);
    {
      std::lock_guard<std::mutex> lock(frame_mutex_);
      frame_ = std::move(frame);
    }
    frame_ready_ = true;
    frame_available_();
  }

  void SetAspect(float aspect) {
    if (std::isfinite(aspect) && aspect > 0.5f && aspect <= 4.f) aspect_ = aspect;
  }

  void SetVariables(const Variable* variables) {
    std::lock_guard<std::mutex> lock(settings_mutex_);
    for (; variables->key && variables->value; ++variables) {
      const std::string key = variables->key;
      const std::string declaration = variables->value;
      const auto delimiter = declaration.find("; ");
      if (delimiter == std::string::npos || options_.count(key)) continue;
      Option option;
      option.title = declaration.substr(0, delimiter);
      option.boot = BootCoreOption(key);
      std::istringstream list(declaration.substr(delimiter + 2));
      for (std::string value; std::getline(list, value, '|');) {
        if (!SupportedBootValue(key, value, hardware_available_ ? video_->PreferredRenderer() : std::string_view{})) continue;
        if (ResolutionOption(key) && !value.empty() && value[0] >= '0' && value[0] <= '9' &&
            std::stoi(value) > 4) continue;
        if (key.find("renderer") != std::string::npos || key.find("Renderer") != std::string::npos) {
          if (value == "Software" || value == "Software (HW)") option.selected = option.values.size();
        } else if (key.find("FastBoot") != std::string::npos || key == "pcsx2_fastboot") {
          if (value == "enabled" || value == "true") option.selected = option.values.size();
        }
        option.values.push_back(std::move(value));
      }
      if (hardware_available_ &&
          (key == "swanstation_GPU_Renderer" || key == "pcsx2_renderer")) {
        const auto hardware = std::find(option.values.begin(), option.values.end(), video_->PreferredRenderer());
        if (hardware != option.values.end())
          option.selected = static_cast<size_t>(hardware - option.values.begin());
      }
      if (hardware_available_ && ResolutionOption(key)) {
        const auto saved = std::find(option.values.begin(), option.values.end(), config_.initial_resolution);
        if (saved != option.values.end())
          option.selected = static_cast<size_t>(saved - option.values.begin());
      }
      if (!ResolutionOption(key) && (option.boot || (hardware_available_ && TrialOption(key)))) {
        const auto saved = config_.initial_graphics.find(key);
        if (saved != config_.initial_graphics.end()) {
          const auto choice = std::find(option.values.begin(), option.values.end(), saved->second);
          if (choice != option.values.end())
            option.selected = static_cast<size_t>(choice - option.values.begin());
        }
      }
      if (!option.values.empty()) options_.emplace(key, std::move(option));
    }
  }

  std::string DiscPath(unsigned index) const {
    std::array<char, 16384> path{};
    if (!disk_callbacks_.get_image_path ||
        !disk_callbacks_.get_image_path(index, path.data(), path.size())) return {};
    return {path.begin(), std::find(path.begin(), path.end(), '\0')};
  }

  void RefreshDiscs(bool failed = false) {
    const auto& disk = disk_callbacks_.basic;
    std::optional<DiscStatus> updated;
    if (disk.set_eject_state && disk.get_eject_state && disk.get_image_index &&
        disk.set_image_index && disk.get_num_images) {
      const auto count = disk.get_num_images();
      if (count >= 2 && count <= 128) {
        updated.emplace();
        updated->labels.resize(count);
        if (disk_callbacks_.get_image_label) {
          for (unsigned index = 0; index < count; ++index) {
            std::array<char, 1024> label{};
            if (disk_callbacks_.get_image_label(index, label.data(), label.size()))
              updated->labels[index].assign(label.begin(), std::find(label.begin(), label.end(), '\0'));
          }
        }
        const auto index = disk.get_image_index();
        if (!disk.get_eject_state() && index < count) {
          updated->inserted = index;
          updated->inserted_path = DiscPath(index);
        }
        updated->failed = failed;
      }
    }
    std::lock_guard<std::mutex> lock(settings_mutex_);
    // Preserve a request queued while the core was refreshing its state.
    if (updated) updated->busy = pending_disc_.has_value();
    if (updated && (!discs_ || updated->inserted != discs_->inserted ||
                    updated->inserted_path != discs_->inserted_path)) {
      disc_inserted_at_step_ = steps_;
    }
    discs_ = std::move(updated);
  }

  void ApplyDiscChange() {
    std::optional<unsigned> requested;
    {
      std::lock_guard<std::mutex> lock(settings_mutex_);
      requested = std::exchange(pending_disc_, std::nullopt);
    }
    if (!requested) return;
    const auto& disk = disk_callbacks_.basic;
    if (!disk.get_eject_state || !disk.get_image_index || !disk.set_eject_state ||
        !disk.set_image_index || !disk.get_num_images || *requested >= disk.get_num_images()) {
      RefreshDiscs(true);
      return;
    }
    const bool was_open = disk.get_eject_state();
    const auto previous = disk.get_image_index();
    const bool changed = (was_open || disk.set_eject_state(true)) &&
        disk.set_image_index(*requested) && disk.set_eject_state(false) &&
        !disk.get_eject_state() && disk.get_image_index() == *requested;
    if (!changed && (disk.get_eject_state() != was_open || disk.get_image_index() != previous)) {
      // Restore the previous disc only when its index is known to be selected.
      if (disk.get_image_index() != previous &&
          (disk.get_eject_state() || disk.set_eject_state(true)))
        disk.set_image_index(previous);
      if (disk.get_image_index() == previous && disk.get_eject_state() != was_open)
        disk.set_eject_state(was_open);
    }
    RefreshDiscs(!changed);
  }

  bool Environment(unsigned command, void* data) {
    if (command == kShutdown) {
      stop_ = true;
      return true;
    }
    if (!data) return false;
    switch (command) {
      case kMessageVersion:
        if (!ps3_) return false;
        *static_cast<unsigned*>(data) = 1;
        return true;
      case kFrontendCompileProgress:
        *static_cast<bool*>(data) = ps3_;
        return ps3_;
      case kExtendedMessage: {
        if (!ps3_) return false;
        const auto& message = *static_cast<const ExtendedMessage*>(data);
        if (message.type != 3 || message.target == 2 || !message.text ||
            message.progress < -1 || message.progress > 100)
          return false;
        std::lock_guard<std::mutex> lock(settings_mutex_);
        progress_label_ = message.text;
        progress_percent_ = message.progress;
        progress_until_ = std::chrono::steady_clock::now() +
            std::chrono::milliseconds(std::min(message.duration, 5000u));
        return true;
      }
      case kDiskControlVersion:
        if (ps3_) return false;
        *static_cast<unsigned*>(data) = 1;
        return true;
      case kSetDiskControl:
        if (ps3_) return false;
        disk_callbacks_ = {};
        disk_callbacks_.basic = *static_cast<const DiskControlCallbacks*>(data);
        return true;
      case kSetDiskControlExt:
        if (ps3_) return false;
        disk_callbacks_ = *static_cast<const DiskControlExtCallbacks*>(data);
        return true;
      case kSetHardware: {
        auto& callbacks = *static_cast<HardwareCallbacks*>(data);
        if (!hardware_available_ || !video_->Bind(callbacks)) return false;
        hardware_callbacks_ = callbacks;
        return true;
      }
      case kHardwareNegotiation:
      case kHardwareInterface:
        return video_->Environment(command, data, hardware_callbacks_.context_type);
      case kPreferredHardware:
        if (!hardware_available_) return false;
        *static_cast<int*>(data) = video_->PreferredContext();
        return true;
      case kCanDupe:
        *static_cast<bool*>(data) = true;
        return true;
      case kSystemDirectory:
        *static_cast<const char**>(data) = config_.system.c_str();
        return true;
      case kCorePath:
        *static_cast<const char**>(data) = config_.core.c_str();
        return true;
      case kContentDirectory:
        *static_cast<const char**>(data) = content_.c_str();
        return true;
      case kSaveDirectory:
        *static_cast<const char**>(data) = config_.saves.c_str();
        return true;
      case kPixelFormat: {
        const auto value = *static_cast<const int*>(data);
        if (value < 0 || value > 2) return false;
        pixel_format_ = value;
        return true;
      }
      case kGetVariable: {
        std::lock_guard<std::mutex> lock(settings_mutex_);
        auto& variable = *static_cast<Variable*>(data);
        const auto found = variable.key ? options_.find(variable.key) : options_.end();
        variable.value = found == options_.end() ? nullptr :
            found->second.values[found->second.selected].c_str();
        return true;
      }
      case kSetVariables:
        SetVariables(static_cast<const Variable*>(data));
        return true;
      case kVariableUpdate: {
        std::lock_guard<std::mutex> lock(settings_mutex_);
        *static_cast<bool*>(data) = std::exchange(options_changed_, false);
        return true;
      }
      case kInputDescriptors:
      case kSupportNoGame:
        return true;
      case kSetAv: {
        const auto& geometry = static_cast<const AvInfo*>(data)->geometry;
        video_->GeometryChanged(geometry);
        SetAspect(geometry.aspect);
        return true;
      }
      case kSetGeometry: {
        const auto& geometry = *static_cast<const Geometry*>(data);
        video_->GeometryChanged(geometry);
        SetAspect(geometry.aspect);
        return true;
      }
      case kFastForward:
        *static_cast<bool*>(data) = false;
        return true;
      case kAudioVideoEnable:
        *static_cast<unsigned*>(data) = 3;
        return true;
      case kCoreOptionsVersion:
        *static_cast<unsigned*>(data) = ps3_ ? 2u : 0u;
        return true;
      case kSetCoreOptionsV2:
        SetCoreOptions(static_cast<const CoreOptionsV2*>(data));
        return ps3_;
      case kSetCoreOptionsV2Intl:
        SetCoreOptions(static_cast<const CoreOptionsV2Intl*>(data)->english);
        return ps3_;
      default:
        return false;
    }
  }

  int16_t Input(unsigned port, unsigned device, unsigned index, unsigned id) {
    if (suppress_frame_) return 0;
    if (port != 0 || paused_) return 0;
    std::lock_guard<std::mutex> lock(input_mutex_);
    if (device == 1 && id < 16) return (buttons_ & (1u << id)) != 0;
    if (device == 5 && index < 2 && id < 2) return axes_[index * 2 + id];
    return 0;
  }

  void Run() {
    using Clock = std::chrono::steady_clock;
    using VoidFunction = void (*)();
    std::optional<DynamicLibrary> library;
    VoidFunction deinit = nullptr;
    VoidFunction unload = nullptr;
    bool initialized = false;
    bool loaded = false;
    Impl* idle = nullptr;
    if (!active_.compare_exchange_strong(idle, this)) {
      std::lock_guard<std::mutex> lock(settings_mutex_);
      error_ = "An embedded game is already running";
      ended_ = true;
      return;
    }
    try {
      hardware_available_ = video_->Open();
      if (ps3_ && !hardware_available_)
        throw std::runtime_error("PS3 requires a working Vulkan driver.");
      const auto path = std::filesystem::u8path(config_.core);
      const auto& core = library.emplace(path);
      if (core.Get<unsigned (*)()>("retro_api_version")() != 1)
        throw std::runtime_error("Unsupported emulator core API");
      const auto init = core.Get<VoidFunction>("retro_init");
      deinit = core.Get<VoidFunction>("retro_deinit");
      unload = core.Get<VoidFunction>("retro_unload_game");
      const auto load = core.Get<bool (*)(const GameInfo*)>("retro_load_game");
      const auto step = core.Get<VoidFunction>("retro_run");
      const auto av_info = core.Get<void (*)(AvInfo*)>("retro_get_system_av_info");
      core.Get<void (*)(bool (*)(unsigned, void*))>("retro_set_environment")(
          [](unsigned command, void* data) { return active_.load()->Environment(command, data); });
      const auto initial_disk_callbacks = disk_callbacks_;
      core.Get<void (*)(void (*)(const void*, unsigned, unsigned, size_t))>("retro_set_video_refresh")(
          [](const void* data, unsigned width, unsigned height, size_t pitch) {
            active_.load()->Publish(data, width, height, pitch);
          });
      core.Get<void (*)(void (*)(int16_t, int16_t))>("retro_set_audio_sample")(
          [](int16_t left, int16_t right) {
            auto* session = active_.load();
            const int16_t stereo[]{left, right};
            if (!session->paused_ && !session->suppress_frame_) {
              ++session->audio_frames_;
              session->audio_->Write(stereo, 1);
            }
          });
      core.Get<void (*)(size_t (*)(const int16_t*, size_t))>("retro_set_audio_sample_batch")(
          [](const int16_t* samples, size_t frames) {
            auto* session = active_.load();
            if (!session->paused_ && !session->suppress_frame_) {
              session->audio_frames_ += frames;
              session->audio_->Write(samples, frames);
            }
            return frames;
          });
      core.Get<void (*)(void (*)())>("retro_set_input_poll")([] {});
      core.Get<void (*)(int16_t (*)(unsigned, unsigned, unsigned, unsigned))>("retro_set_input_state")(
          [](unsigned port, unsigned device, unsigned index, unsigned id) {
            return active_.load()->Input(port, device, index, id);
          });
      const GameInfo game{config_.disc.c_str(), nullptr, 0, nullptr};
      const auto reopen = [&] {
        if (loaded) unload();
        if (initialized) deinit();
        loaded = initialized = false;
        video_->Clear();
        hardware_callbacks_ = {};
        disk_callbacks_ = initial_disk_callbacks;
        init();
        initialized = true;
        if (ps3_ && hardware_callbacks_.context_type != video_->PreferredContext())
          throw std::runtime_error("The PS3 core did not request a Vulkan context.");
        if (ps3_) {
          const auto controller = core.Get<void (*)(unsigned, unsigned)>("retro_set_controller_port_device");
          controller(0, 1);
          for (unsigned port = 1; port < 7; ++port) controller(port, 0);
        }
        const auto& initial_disc = config_.initial_disc;
        if (initial_disc &&
            (!disk_callbacks_.set_initial_image ||
             !disk_callbacks_.set_initial_image(initial_disc->index, initial_disc->path.c_str()))) {
          throw std::runtime_error("The core cannot boot the selected disc.");
        }
        loaded = load(&game);
        if (loaded && initial_disc) {
          const auto& disk = disk_callbacks_.basic;
          std::error_code error;
          if (!disk.get_image_index || disk.get_image_index() != initial_disc->index ||
              !disk.get_eject_state || disk.get_eject_state() ||
              !std::filesystem::equivalent(std::filesystem::u8path(DiscPath(initial_disc->index)),
                                           std::filesystem::u8path(initial_disc->path), error)) {
            throw std::runtime_error("The core did not boot the selected disc.");
          }
        }
        if (loaded && hardware_callbacks_.reset) {
          AvInfo av{};
          av_info(&av);
          video_->GeometryChanged(av.geometry);
          video_->Reset(hardware_callbacks_);
        }
        if (loaded) RefreshDiscs();
        return loaded;
      };
      const bool ps2 = console_ == Console::kPs2;
      const bool ps1 = console_ == Console::kPs1;
      const auto use_native_resolution = [&] {
        std::lock_guard<std::mutex> lock(settings_mutex_);
        const auto scale = options_.find(ps2 ? "pcsx2_upscale_multiplier" : "swanstation_GPU_ResolutionScale");
        return scale != options_.end() && std::exchange(scale->second.selected, 0) != 0;
      };
      if (!reopen() && (!use_native_resolution() || !reopen()))
        throw std::runtime_error("The core could not boot this disc. Check its BIOS and game files.");
      void* card = nullptr;
      size_t card_size = 0;
      std::filesystem::path card_path;
      const auto restore_card = [&] {
        if (!ps1) return;
        card = core.Get<void* (*)(unsigned)>("retro_get_memory_data")(0);
        card_size = core.Get<size_t (*)(unsigned)>("retro_get_memory_size")(0);
        card_path = std::filesystem::u8path(config_.saves) / std::filesystem::u8path(config_.disc).stem();
        card_path += ".srm";
        RestoreCard(card_path, card, card_size);
      };
      restore_card();
      AvInfo av{};
      av_info(&av);
      SetAspect(av.geometry.aspect);
      const bool audio_open = audio_->Open(av.sample_rate);
      const double fps = std::isfinite(av.fps) && av.fps > 30 && av.fps <= 120 ? av.fps : 60.0;
      {
        std::lock_guard<std::mutex> lock(telemetry_mutex_);
        target_fps_ = fps;
        audio_rate_ = audio_open ? av.sample_rate : 0;
      }
      const auto frame_time = std::chrono::duration_cast<Clock::duration>(std::chrono::duration<double>(1.0 / fps));
      auto next = Clock::now();
      auto hardware_deadline = next + std::chrono::seconds(8);
      while (!stop_) {
        ApplyDiscChange();
        if (ps1 || ps2)
          ApplyCheckpointGraphics(core, reopen, step, ps1, card, card_size, card_path);
        if (!ps3_ && hardware_callbacks_.reset && !frame_ready_ && Clock::now() > hardware_deadline) {
          if (!use_native_resolution()) {
            std::lock_guard<std::mutex> lock(settings_mutex_);
            auto& renderer = options_.at(ps2 ? "pcsx2_renderer" : "swanstation_GPU_Renderer");
            const auto software = std::find(renderer.values.begin(), renderer.values.end(),
                                            ps2 ? (video_->PreferredRenderer() == "D3D11" ? "Software (HW)" : "Software (SW)")
                                                : "Software");
            if (software == renderer.values.end())
              throw std::runtime_error("The core could not present hardware frames.");
            renderer.selected = static_cast<size_t>(software - renderer.values.begin());
          }
          audio_->Flush();
          if (card) StoreCard(card_path, card, card_size);
          if (!reopen()) throw std::runtime_error("The core could not restart after a graphics startup failure.");
          restore_card();
          hardware_deadline = Clock::now() + std::chrono::seconds(8);
        }
        if (paused_ && frame_ready_) {
          std::this_thread::sleep_for(std::chrono::milliseconds(5));
          next = Clock::now();
          continue;
        }
        step();
        if (!paused_) ++steps_;
        if (video_->UnsupportedSync())
          throw std::runtime_error("This RPCS3 core uses Vulkan synchronization AnyPS5 does not support.");
        next += frame_time;
        const auto now = Clock::now();
        if (next < now - frame_time) next = now;
        std::this_thread::sleep_until(next);
      }
      if (card) StoreCard(card_path, card, card_size);
    } catch (const std::exception& failure) {
      std::lock_guard<std::mutex> lock(settings_mutex_);
      error_ = failure.what();
    }
    if (loaded) unload();
    video_->BeforeCoreDeinit(hardware_callbacks_);
    if (initialized) deinit();
    video_->Close();
    audio_->Close();
    library.reset();
    active_ = nullptr;
    ended_ = true;
  }

  static std::atomic<Session::Impl*> active_;
  const SessionConfig config_;
  const std::string content_;
  const Console console_;
  const bool ps3_;
  const std::function<void()> frame_available_;
  std::thread worker_;
  std::unique_ptr<Video> video_;
  std::unique_ptr<Audio> audio_;
  HardwareCallbacks hardware_callbacks_{};
  DiskControlExtCallbacks disk_callbacks_{};
  bool hardware_available_ = false;
  uint64_t hardware_frames_ = 0;
  std::mutex telemetry_mutex_;
  std::chrono::steady_clock::time_point last_frame_at_{};
  std::array<int64_t, 13> frame_intervals_{};
  int64_t video_frames_ = 0;
  double target_fps_ = 0;
  double audio_rate_ = 0;
  std::atomic<int64_t> steps_{0};
  std::atomic<int64_t> audio_frames_{0};
  std::atomic<bool> hardware_frame_{false};
  std::atomic<unsigned> frame_width_{0}, frame_height_{0};
  std::atomic<bool> stop_{false}, paused_{false}, ended_{false}, frame_ready_{false}, presented_{false};
  std::atomic<int> pixel_format_{0};
  std::atomic<float> aspect_{4.f / 3.f};
  std::mutex frame_mutex_, input_mutex_, settings_mutex_;
  std::shared_ptr<Frame> frame_;
  uint16_t buttons_ = 0;
  std::array<int16_t, 4> axes_{};
  std::map<std::string, Option> options_;
  std::optional<DiscStatus> discs_;
  int64_t disc_inserted_at_step_ = 0;
  std::optional<unsigned> pending_disc_;
  bool options_changed_ = false;
  bool graphics_queued_ = false;
  bool graphics_applying_ = false;
  std::atomic<bool> suppress_frame_{false};
  std::chrono::steady_clock::time_point progress_until_{};
  std::string progress_label_;
  int32_t progress_percent_ = -1;
  std::string error_, resolution_error_;
};

std::atomic<Session::Impl*> Session::Impl::active_{nullptr};

Session::Session(SessionConfig config, std::unique_ptr<Video> video, std::unique_ptr<Audio> audio,
                 std::function<void()> frame_available)
    : impl_(std::make_unique<Impl>(std::move(config), std::move(video), std::move(audio),
                                   std::move(frame_available))) {}
Session::~Session() = default;
void Session::Start() { impl_->Start(); }
bool Session::ended() const { return impl_->ended(); }
void Session::Stop() { impl_->Stop(); }
void Session::Join() { impl_->Join(); }
void Session::Pause(bool pause) { impl_->Pause(pause); }
bool Session::ChangeDisc(unsigned index) { return impl_->ChangeDisc(index); }
void Session::SetInput(uint16_t buttons, const std::array<int16_t, 4>& axes) { impl_->SetInput(buttons, axes); }
bool Session::SetOption(const std::string& key, const std::string& value) { return impl_->SetOption(key, value); }
bool Session::SetTuningOptions(const Options& expected, const Options& values) {
  return impl_->SetTuningOptions(expected, values);
}
SessionStatus Session::Status() { return impl_->Status(); }
std::shared_ptr<const Frame> Session::AcquireFrame() { return impl_->AcquireFrame(); }

}  // namespace anyps5::retro
