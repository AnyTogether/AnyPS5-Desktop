#include "retro_core_host.h"
#include "libretro_abi.h"
#include "retro_frame.h"
#include "retro_session.h"

#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <mmsystem.h>
#include <wrl/client.h>

#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <mutex>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using List = flutter::EncodableList;

using namespace anyps5::retro;
struct D3D11Interface {
  int type = 3;
  unsigned version = 1;
  void* handle = nullptr;
  ID3D11Device* device = nullptr;
  ID3D11DeviceContext* context = nullptr;
  D3D_FEATURE_LEVEL feature_level{};
  decltype(&D3DCompile) compile = D3DCompile;
};
constexpr int kD3D11 = 7;


struct FrameLease {
  std::shared_ptr<const Frame> frame;
  FlutterDesktopPixelBuffer buffer;
};

class HardwareVideo {
 public:
  bool Open() {
    // LRPS2 selects Shader Model 5.1 at feature level 11.1, which its D3D11 renderer cannot use.
    constexpr D3D_FEATURE_LEVEL levels[]{D3D_FEATURE_LEVEL_11_0};
    if (FAILED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                                 D3D11_CREATE_DEVICE_BGRA_SUPPORT, levels, ARRAYSIZE(levels),
                                 D3D11_SDK_VERSION, &device_, &render_interface.feature_level,
                                 &context_))) return false;
    render_interface.handle = this;
    render_interface.device = device_.Get();
    render_interface.context = context_.Get();
    return true;
  }

  std::shared_ptr<Frame> Read(unsigned width, unsigned height) {
    Microsoft::WRL::ComPtr<ID3D11ShaderResourceView> view;
    context_->PSGetShaderResources(0, 1, &view);
    if (!view) return nullptr;
    Microsoft::WRL::ComPtr<ID3D11Resource> resource;
    Microsoft::WRL::ComPtr<ID3D11Texture2D> source;
    view->GetResource(&resource);
    if (FAILED(resource.As(&source))) return nullptr;
    D3D11_TEXTURE2D_DESC desc{};
    source->GetDesc(&desc);
    const auto format = desc.Format;
    const bool bgra = format == DXGI_FORMAT_B8G8R8A8_UNORM ||
                      format == DXGI_FORMAT_B8G8R8X8_UNORM;
    if ((!bgra && format != DXGI_FORMAT_R8G8B8A8_UNORM) || desc.SampleDesc.Count != 1 ||
        width > desc.Width || height > desc.Height) return nullptr;
    if (!staging_ || width != width_ || height != height_ || format != format_) {
      D3D11_TEXTURE2D_DESC staging{width, height, 1, 1, format, {1, 0},
                                  D3D11_USAGE_STAGING, 0, D3D11_CPU_ACCESS_READ, 0};
      if (FAILED(device_->CreateTexture2D(&staging, nullptr, staging_.ReleaseAndGetAddressOf())))
        return nullptr;
      width_ = width;
      height_ = height;
      format_ = format;
    }
    auto frame = std::make_shared<Frame>();
    frame->width = width;
    frame->height = height;
    frame->pixels.resize(static_cast<size_t>(width) * height * 4);
    const D3D11_BOX box{0, 0, 0, width, height, 1};
    context_->CopySubresourceRegion(staging_.Get(), 0, 0, 0, 0, source.Get(), 0, &box);
    D3D11_MAPPED_SUBRESOURCE mapped{};
    if (FAILED(context_->Map(staging_.Get(), 0, D3D11_MAP_READ, 0, &mapped))) return nullptr;
    const auto* input = static_cast<const uint8_t*>(mapped.pData);
    for (unsigned row = 0; row < height; ++row) {
      const auto* source_row = input + static_cast<size_t>(row) * mapped.RowPitch;
      auto* output = frame->pixels.data() + static_cast<size_t>(row) * width * 4;
      for (unsigned column = 0; column < width; ++column, output += 4, source_row += 4) {
        output[0] = source_row[bgra ? 2 : 0];
        output[1] = source_row[1];
        output[2] = source_row[bgra ? 0 : 2];
        output[3] = 255;
      }
    }
    context_->Unmap(staging_.Get(), 0);
    return frame;
  }

  D3D11Interface render_interface;

  void Clear() {
    if (!context_) return;
    staging_.Reset();
    context_->ClearState();
    context_->Flush();
  }

 private:
  Microsoft::WRL::ComPtr<ID3D11Device> device_;
  Microsoft::WRL::ComPtr<ID3D11DeviceContext> context_;
  Microsoft::WRL::ComPtr<ID3D11Texture2D> staging_;
  unsigned width_ = 0, height_ = 0;
  DXGI_FORMAT format_ = DXGI_FORMAT_UNKNOWN;
};

class StereoOutput final : public Audio {
 public:
  ~StereoOutput() { Close(); }

  bool Open(double rate) override {
    std::lock_guard<std::mutex> lock(mutex_);
    CloseLocked();
    if (!std::isfinite(rate) || rate < 8000 || rate > 192000) return false;
    const DWORD sample_rate = static_cast<DWORD>(std::lround(rate));
    WAVEFORMATEX format{WAVE_FORMAT_PCM, 2, sample_rate, sample_rate * 4, 4, 16, 0};
    return waveOutOpen(&device_, WAVE_MAPPER, &format, 0, 0, CALLBACK_NULL) == MMSYSERR_NOERROR;
  }

  void Flush() override {
    std::lock_guard<std::mutex> lock(mutex_);
    if (device_) waveOutReset(device_);
    pending_count_ = 0;
  }

  void Write(const int16_t* stereo, size_t frames) override {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!device_) return;
    while (frames > 0) {
      const size_t count = std::min(frames, pending_.size() / 2 - pending_count_);
      std::copy_n(stereo, count * 2, pending_.data() + pending_count_ * 2);
      pending_count_ += count;
      stereo += count * 2;
      frames -= count;
      if (pending_count_ == pending_.size() / 2) Submit();
    }
  }

  int64_t dropped_frames() const override { return dropped_frames_; }

  void Close() override {
    std::lock_guard<std::mutex> lock(mutex_);
    CloseLocked();
  }

 private:
  struct Slot {
    std::array<int16_t, 1024> samples{};
    WAVEHDR header{};
  };

  void Submit() {
    pending_count_ = 0;
    for (auto& slot : slots_) {
      if ((slot.header.dwFlags & WHDR_INQUEUE) != 0) continue;
      if ((slot.header.dwFlags & WHDR_PREPARED) != 0) {
        if (waveOutUnprepareHeader(device_, &slot.header, sizeof(WAVEHDR)) != MMSYSERR_NOERROR) continue;
      }
      slot.samples = pending_;
      slot.header = {};
      slot.header.lpData = reinterpret_cast<char*>(slot.samples.data());
      slot.header.dwBufferLength = static_cast<DWORD>(sizeof(slot.samples));
      if (waveOutPrepareHeader(device_, &slot.header, sizeof(WAVEHDR)) == MMSYSERR_NOERROR &&
          waveOutWrite(device_, &slot.header, sizeof(WAVEHDR)) == MMSYSERR_NOERROR) {
        return;
      }
      break;
    }
    dropped_frames_ += pending_.size() / 2;
  }

  void CloseLocked() {
    if (device_) {
      waveOutReset(device_);
      for (auto& slot : slots_) {
        if ((slot.header.dwFlags & WHDR_PREPARED) != 0) {
          waveOutUnprepareHeader(device_, &slot.header, sizeof(WAVEHDR));
        }
        slot.header = {};
      }
      waveOutClose(device_);
      device_ = nullptr;
    }
    pending_count_ = 0;
  }

  std::mutex mutex_;
  HWAVEOUT device_ = nullptr;
  std::array<Slot, 8> slots_{};
  std::array<int16_t, 1024> pending_{};
  size_t pending_count_ = 0;
  std::atomic<int64_t> dropped_frames_{0};
};

const std::string* StringField(const Map& map, const char* name) {
  const auto found = map.find(Value(name));
  return found == map.end() ? nullptr : std::get_if<std::string>(&found->second);
}

class WindowsVideo final : public Video {
 public:
  bool Open() override { return hardware_.Open(); }
  int PreferredContext() const override { return kD3D11; }
  std::string_view PreferredRenderer() const override { return "D3D11"; }
  bool Bind(HardwareCallbacks& callbacks) override {
    if (callbacks.context_type != PreferredContext()) return false;
    callbacks.framebuffer = []() -> uintptr_t { return 0; };
    callbacks.proc_address = [](const char*) -> void (*)() { return nullptr; };
    return true;
  }
  bool Environment(unsigned command, void* data, int context) override {
    if (command != kHardwareInterface || context != kD3D11) return false;
    *static_cast<const D3D11Interface**>(data) = &hardware_.render_interface;
    return true;
  }
  void Reset(const HardwareCallbacks& callbacks) override { callbacks.reset(); }
  void Clear() override { hardware_.Clear(); }
  void Close() override { hardware_.Clear(); }
  std::shared_ptr<Frame> Read(unsigned width, unsigned height, const HardwareCallbacks& callbacks) override {
    return callbacks.context_type == kD3D11 ? hardware_.Read(width, height) : nullptr;
  }

 private:
  HardwareVideo hardware_;
};

std::optional<Options> ReadOptions(const Map* options) {
  if (!options) return std::nullopt;
  Options result;
  for (const auto& [key, value] : *options) {
    const auto* text_key = std::get_if<std::string>(&key);
    const auto* text_value = std::get_if<std::string>(&value);
    if (!text_key || !text_value) return std::nullopt;
    result.emplace(*text_key, *text_value);
  }
  return result;
}

Map EncodeStatus(const SessionStatus& status) {
  Map options;
  for (const auto& [key, option] : status.options) {
    options.emplace(Value(key), Value(Map{
        {Value("values"), Value(List(option.values.begin(), option.values.end()))},
        {Value("labels"), Value(List())},
        {Value("title"), Value(option.title)},
        {Value("restart"), Value(option.restart)},
        {Value("selected"), Value(option.selected)},
        {Value("activeValue"), Value(option.active_value)},
    }));
  }
  const auto& telemetry = status.telemetry;
  return {
      {Value("ready"), Value(status.ready)},
      {Value("presented"), Value(status.presented)},
      {Value("ended"), Value(status.ended)},
      {Value("error"), Value(status.error)},
      {Value("aspect"), Value(status.aspect)},
      {Value("hardware"), Value(status.hardware)},
      {Value("frameWidth"), Value(status.frame_width)},
      {Value("frameHeight"), Value(status.frame_height)},
      {Value("resolutionError"), Value(status.resolution_error)},
      {Value("graphicsPending"), Value(status.graphics_pending)},
      {Value("progressLabel"), Value()},
      {Value("progressPercent"), Value()},
      {Value("options"), Value(std::move(options))},
      {Value("tuningTelemetry"), Value(Map{
          {Value("clockMs"), Value(telemetry.clock_ms)},
          {Value("frames"), Value(telemetry.frames)},
          {Value("steps"), Value(telemetry.steps)},
          {Value("audioFrames"), Value(telemetry.audio_frames)},
          {Value("droppedAudioFrames"), Value(telemetry.dropped_audio_frames)},
          {Value("frameIntervals"), Value(List(telemetry.frame_intervals.begin(), telemetry.frame_intervals.end()))},
          {Value("targetFps"), Value(telemetry.target_fps)},
          {Value("audioRate"), Value(telemetry.audio_rate)},
      })},
  };
}
}  // namespace

class RetroCoreSession {
 public:
  RetroCoreSession(flutter::TextureRegistrar* registrar, SessionConfig config)
      : registrar_(registrar),
        texture_(flutter::PixelBufferTexture([this](size_t, size_t) { return CopyFrame(); })),
        session_(config, std::make_unique<WindowsVideo>(),
                 std::make_unique<StereoOutput>(), [this] { registrar_->MarkTextureFrameAvailable(texture_id_); }) {}

  bool Start() {
    texture_id_ = registrar_->RegisterTexture(&texture_);
    if (texture_id_ < 0) return false;
    session_.Start();
    return true;
  }

  int64_t texture_id() const { return texture_id_; }
  Session& session() { return session_; }

 private:
  const FlutterDesktopPixelBuffer* CopyFrame() {
    auto frame = session_.AcquireFrame();
    if (!frame) return nullptr;
    auto* lease = new FrameLease{std::move(frame), {}};
    lease->buffer = {lease->frame->pixels.data(), lease->frame->width, lease->frame->height,
                     [](void* data) { delete static_cast<FrameLease*>(data); }, lease};
    return &lease->buffer;
  }

  flutter::TextureRegistrar* registrar_;
  flutter::TextureVariant texture_;
  int64_t texture_id_ = -1;
  Session session_;
};

RetroCoreHost::RetroCoreHost(flutter::BinaryMessenger* messenger, flutter::TextureRegistrar* textures)
    : textures_(textures), channel_(messenger, "anyps5/retro_core", &flutter::StandardMethodCodec::GetInstance()) {
  channel_.SetMethodCallHandler([this](const auto& call, auto result) { Handle(call, std::move(result)); });
}

RetroCoreHost::~RetroCoreHost() {
  channel_.SetMethodCallHandler(nullptr);
  if (session_) {
    session_->session().Stop();
    Release();
  }
}

void RetroCoreHost::Release() {
  auto session = std::move(session_);
  session->session().Join();
  const auto id = session->texture_id();
  if (id >= 0) textures_->UnregisterTexture(id, [session] {});
}

void RetroCoreHost::Handle(const flutter::MethodCall<Value>& call,
                           std::unique_ptr<flutter::MethodResult<Value>> result) {
  const auto& method = call.method_name();
  const auto* arguments = call.arguments();
  if (method == "start") {
    if (session_ && session_->session().ended()) Release();
    if (session_) {
      result->Error("busy", "An embedded game is already running");
      return;
    }
    const auto* fields = std::get_if<Map>(arguments);
    const auto* core = fields ? StringField(*fields, "core") : nullptr;
    const auto* disc = fields ? StringField(*fields, "disc") : nullptr;
    const auto* system = fields ? StringField(*fields, "system") : nullptr;
    const auto* saves = fields ? StringField(*fields, "saves") : nullptr;
    const auto* resolution = fields ? StringField(*fields, "internalResolution") : nullptr;
    if (!core || !disc || !system || !saves) {
      result->Error("argument", "The core, disc and storage paths are required");
      return;
    }
    if (ConsoleForCore(*core) != Console::kPs1 && ConsoleForCore(*core) != Console::kPs2) {
      result->Error("unsupportedCore", "This emulator core is unavailable");
      return;
    }
    try {
      std::map<std::string, std::string> graphics;
      const auto values = fields->find(Value("graphics"));
      if (values != fields->end()) {
        if (const auto* saved = std::get_if<Map>(&values->second)) {
          for (const auto& entry : *saved) {
            const auto* key = std::get_if<std::string>(&entry.first);
            const auto* value = std::get_if<std::string>(&entry.second);
            if (key && value) graphics.emplace(*key, *value);
          }
        }
      }
      session_ = std::make_shared<RetroCoreSession>(textures_, SessionConfig{*core, *disc, *system, *saves,
          resolution ? *resolution : "", std::move(graphics)});
      if (!session_->Start()) throw std::runtime_error("Could not register the game surface");
      result->Success(Value(session_->texture_id()));
    } catch (const std::exception& failure) {
      if (session_) Release();
      result->Error("start", failure.what());
    }
    return;
  }
  if (!session_) {
    result->Success();
    return;
  }
  if (method == "status") {
    result->Success(Value(EncodeStatus(session_->session().Status())));
  } else if (method == "stop") {
    session_->session().Stop();
    result->Success();
  } else if (method == "release") {
    if (session_->session().ended()) Release();
    result->Success();
  } else if (method == "pause") {
    const auto* pause = std::get_if<bool>(arguments);
    if (pause) session_->session().Pause(*pause);
    result->Success();
  } else if (method == "input") {
    const auto* input = std::get_if<List>(arguments);
    if (input && input->size() == 5) {
      std::array<int16_t, 4> axes{};
      for (size_t index = 0; index < axes.size(); ++index) {
        if (const auto* axis = std::get_if<int32_t>(&(*input)[index + 1])) {
          axes[index] = static_cast<int16_t>(std::clamp(*axis, -32768, 32767));
        }
      }
      if (const auto* mask = std::get_if<int32_t>(&input->front())) {
        session_->session().SetInput(static_cast<uint16_t>(*mask), axes);
      }
    }
    result->Success();
  } else if (method == "tuningOptions") {
    const auto* fields = std::get_if<Map>(arguments);
    if (!fields) {
      result->Success(Value(false));
      return;
    }
    const auto expected = fields->find(Value("expected"));
    const auto values = fields->find(Value("values"));
    const auto* expected_options = expected == fields->end() ? nullptr : std::get_if<Map>(&expected->second);
    const auto* candidate_options = values == fields->end() ? nullptr : std::get_if<Map>(&values->second);
    const auto expected_strings = ReadOptions(expected_options);
    const auto candidate_strings = ReadOptions(candidate_options);
    result->Success(Value(expected_strings && candidate_strings &&
                          session_->session().SetTuningOptions(*expected_strings, *candidate_strings)));
  } else if (method == "option") {
    const auto* fields = std::get_if<Map>(arguments);
    const auto* key = fields ? StringField(*fields, "key") : nullptr;
    const auto* value = fields ? StringField(*fields, "value") : nullptr;
    result->Success(Value(key && value && session_->session().SetOption(*key, *value)));
  } else {
    result->NotImplemented();
  }
}
