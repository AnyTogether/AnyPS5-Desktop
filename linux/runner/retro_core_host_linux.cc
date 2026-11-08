#include "retro_core_host_linux.h"

#include "retro_linux_platform.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <string_view>
#include <utility>

namespace {
using namespace anyps5::retro;

struct TextureState {
  std::mutex mutex;
  Session* session = nullptr;
  std::shared_ptr<const Frame> lease;
};

struct RetroTexture {
  FlPixelBufferTexture parent_instance;
  TextureState* state;
};

struct RetroTextureClass {
  FlPixelBufferTextureClass parent_class;
};

G_DEFINE_TYPE(RetroTexture, retro_texture, fl_pixel_buffer_texture_get_type())

static gboolean CopyPixels(FlPixelBufferTexture* texture, const uint8_t** pixels,
                           uint32_t* width, uint32_t* height, GError**) {
  auto* state = reinterpret_cast<RetroTexture*>(texture)->state;
  std::lock_guard<std::mutex> lock(state->mutex);
  state->lease = state->session ? state->session->AcquireFrame() : nullptr;
  if (!state->lease) {
    // Flutter may paint the texture before the first frame or after release.
    static constexpr uint8_t black[] = {0, 0, 0, 255};
    *pixels = black;
    *width = *height = 1;
    return TRUE;
  }
  *pixels = state->lease->pixels.data();
  *width = static_cast<uint32_t>(state->lease->width);
  *height = static_cast<uint32_t>(state->lease->height);
  return TRUE;
}

static void FinalizeTexture(GObject* object) {
  delete reinterpret_cast<RetroTexture*>(object)->state;
  G_OBJECT_CLASS(retro_texture_parent_class)->finalize(object);
}

static void retro_texture_class_init(RetroTextureClass* klass) {
  FL_PIXEL_BUFFER_TEXTURE_CLASS(klass)->copy_pixels = CopyPixels;
  G_OBJECT_CLASS(klass)->finalize = FinalizeTexture;
}

static void retro_texture_init(RetroTexture* texture) {
  texture->state = new TextureState();
}

const char* StringField(FlValue* fields, const char* key) {
  if (!fields || fl_value_get_type(fields) != FL_VALUE_TYPE_MAP) return nullptr;
  auto* value = fl_value_lookup_string(fields, key);
  return value && fl_value_get_type(value) == FL_VALUE_TYPE_STRING ? fl_value_get_string(value) : nullptr;
}

FlValue* ReadField(FlValue* fields, const char* key) {
  return fields && fl_value_get_type(fields) == FL_VALUE_TYPE_MAP ? fl_value_lookup_string(fields, key) : nullptr;
}

std::optional<Options> ReadOptions(FlValue* values) {
  if (!values || fl_value_get_type(values) != FL_VALUE_TYPE_MAP) return std::nullopt;
  Options options;
  for (size_t i = 0; i < fl_value_get_length(values); ++i) {
    auto* key = fl_value_get_map_key(values, i);
    auto* value = fl_value_get_map_value(values, i);
    if (fl_value_get_type(key) != FL_VALUE_TYPE_STRING || fl_value_get_type(value) != FL_VALUE_TYPE_STRING)
      return std::nullopt;
    options.emplace(fl_value_get_string(key), fl_value_get_string(value));
  }
  return options;
}

FlValue* Strings(const std::vector<std::string>& values) {
  auto* result = fl_value_new_list();
  for (const auto& value : values) fl_value_append_take(result, fl_value_new_string(value.c_str()));
  return result;
}

FlValue* EncodeStatus(const SessionStatus& status) {
  auto* result = fl_value_new_map();
  fl_value_set_string_take(result, "ready", fl_value_new_bool(status.ready));
  fl_value_set_string_take(result, "presented", fl_value_new_bool(status.presented));
  fl_value_set_string_take(result, "ended", fl_value_new_bool(status.ended));
  fl_value_set_string_take(result, "error", fl_value_new_string(status.error.c_str()));
  fl_value_set_string_take(result, "aspect", fl_value_new_float(status.aspect));
  fl_value_set_string_take(result, "hardware", fl_value_new_bool(status.hardware));
  fl_value_set_string_take(result, "frameWidth", fl_value_new_int(status.frame_width));
  fl_value_set_string_take(result, "frameHeight", fl_value_new_int(status.frame_height));
  fl_value_set_string_take(result, "resolutionError", fl_value_new_string(status.resolution_error.c_str()));
  fl_value_set_string_take(result, "graphicsPending", fl_value_new_bool(status.graphics_pending));
  fl_value_set_string_take(result, "progressLabel", fl_value_new_null());
  fl_value_set_string_take(result, "progressPercent", fl_value_new_null());

  auto* options = fl_value_new_map();
  for (const auto& [key, option] : status.options) {
    auto* item = fl_value_new_map();
    fl_value_set_string_take(item, "values", Strings(option.values));
    fl_value_set_string_take(item, "labels", fl_value_new_list());
    fl_value_set_string_take(item, "title", fl_value_new_string(option.title.c_str()));
    fl_value_set_string_take(item, "restart", fl_value_new_bool(option.restart));
    fl_value_set_string_take(item, "selected", fl_value_new_int(option.selected));
    fl_value_set_string_take(item, "activeValue", fl_value_new_string(option.active_value.c_str()));
    fl_value_set_string_take(options, key.c_str(), item);
  }
  fl_value_set_string_take(result, "options", options);

  const auto& telemetry = status.telemetry;
  auto* tuning = fl_value_new_map();
  fl_value_set_string_take(tuning, "clockMs", fl_value_new_int(telemetry.clock_ms));
  fl_value_set_string_take(tuning, "frames", fl_value_new_int(telemetry.frames));
  fl_value_set_string_take(tuning, "steps", fl_value_new_int(telemetry.steps));
  fl_value_set_string_take(tuning, "audioFrames", fl_value_new_int(telemetry.audio_frames));
  fl_value_set_string_take(tuning, "droppedAudioFrames", fl_value_new_int(telemetry.dropped_audio_frames));
  auto* intervals = fl_value_new_list();
  for (const auto count : telemetry.frame_intervals) fl_value_append_take(intervals, fl_value_new_int(count));
  fl_value_set_string_take(tuning, "frameIntervals", intervals);
  fl_value_set_string_take(tuning, "targetFps", fl_value_new_float(telemetry.target_fps));
  fl_value_set_string_take(tuning, "audioRate", fl_value_new_float(telemetry.audio_rate));
  fl_value_set_string_take(result, "tuningTelemetry", tuning);
  return result;
}

void Success(FlMethodCall* call, FlValue* result = nullptr) {
  g_autoptr(FlValue) owned_result = result;
  fl_method_call_respond_success(call, owned_result, nullptr);
}

void SetInput(Session& session, FlValue* input) {
  if (!input || fl_value_get_type(input) != FL_VALUE_TYPE_LIST || fl_value_get_length(input) != 5) return;
  auto* mask = fl_value_get_list_value(input, 0);
  if (fl_value_get_type(mask) != FL_VALUE_TYPE_INT) return;
  std::array<int16_t, 4> axes{};
  for (size_t i = 0; i < axes.size(); ++i) {
    auto* axis = fl_value_get_list_value(input, i + 1);
    if (fl_value_get_type(axis) == FL_VALUE_TYPE_INT)
      axes[i] = static_cast<int16_t>(std::clamp<int64_t>(fl_value_get_int(axis), -32768, 32767));
  }
  session.SetInput(static_cast<uint16_t>(fl_value_get_int(mask)), axes);
}
}  // namespace

class RetroCoreHostLinux::Impl {
 public:
  explicit Impl(FlPluginRegistrar* registrar)
      : registrar_(FL_TEXTURE_REGISTRAR(g_object_ref(fl_plugin_registrar_get_texture_registrar(registrar)))),
        platform_context_(g_main_context_ref_thread_default()) {
    g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
    channel_ = fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar), "anyps5/retro_core",
                                     FL_METHOD_CODEC(codec));
    fl_method_channel_set_method_call_handler(channel_, OnCall, this, nullptr);
  }

  ~Impl() {
    Shutdown();
    if (registered_) fl_texture_registrar_unregister_texture(registrar_, FL_TEXTURE(texture_));
    g_clear_object(&texture_);
    g_clear_object(&channel_);
    g_clear_object(&registrar_);
    g_main_context_unref(platform_context_);
  }

  void Shutdown() {
    if (shutting_down_) return;
    shutting_down_ = true;
    fl_method_channel_set_method_call_handler(channel_, nullptr, nullptr, nullptr);
    if (session_) session_->Stop();
    Release();
  }

 private:
  static void OnCall(FlMethodChannel*, FlMethodCall* call, gpointer context) {
    auto* self = static_cast<Impl*>(context);
    try {
      self->Handle(call);
    } catch (const std::exception& error) {
      fl_method_call_respond_error(call, "retroCore", error.what(), nullptr, nullptr);
    }
  }

  void Handle(FlMethodCall* call) {
    const std::string_view method(fl_method_call_get_name(call));
    auto* args = fl_method_call_get_args(call);
    if (method == "start") {
      Start(call, args);
      return;
    }
    if (!session_) {
      Success(call);
    } else if (method == "status") {
      Success(call, EncodeStatus(session_->Status()));
    } else if (method == "stop") {
      session_->Stop();
      Success(call);
    } else if (method == "release") {
      if (session_->ended()) Release();
      Success(call);
    } else if (method == "pause") {
      if (args && fl_value_get_type(args) == FL_VALUE_TYPE_BOOL) session_->Pause(fl_value_get_bool(args));
      Success(call);
    } else if (method == "input") {
      SetInput(*session_, args);
      Success(call);
    } else if (method == "option") {
      const auto* key = StringField(args, "key");
      const auto* value = StringField(args, "value");
      Success(call, fl_value_new_bool(key && value && session_->SetOption(key, value)));
    } else if (method == "tuningOptions") {
      const auto expected = ReadOptions(ReadField(args, "expected"));
      const auto values = ReadOptions(ReadField(args, "values"));
      Success(call, fl_value_new_bool(expected && values && session_->SetTuningOptions(*expected, *values)));
    } else {
      fl_method_call_respond_not_implemented(call, nullptr);
    }
  }

  static gboolean NotifyFrame(gpointer context) {
    auto* self = static_cast<Impl*>(context);
    {
      std::lock_guard<std::mutex> lock(self->notification_mutex_);
      if (auto* dispatched = std::exchange(self->notification_, nullptr)) g_source_unref(dispatched);
    }
    fl_texture_registrar_mark_texture_frame_available(self->registrar_, FL_TEXTURE(self->texture_));
    return G_SOURCE_REMOVE;
  }

  void ScheduleFrame() {
    std::lock_guard<std::mutex> lock(notification_mutex_);
    if (!notifications_enabled_ || notification_) return;
    // Flutter marks external textures on the platform thread. Attaching a
    // source, unlike invoke, cannot execute this callback inline on the worker.
    notification_ = g_idle_source_new();
    g_source_set_callback(notification_, NotifyFrame, this, nullptr);
    g_source_attach(notification_, platform_context_);
  }
  void Start(FlMethodCall* call, FlValue* args) {
    if (session_ && session_->ended()) Release();
    if (session_) {
      fl_method_call_respond_error(call, "busy", "An embedded game is already running", nullptr, nullptr);
      return;
    }
    const auto* core = StringField(args, "core");
    const auto* disc = StringField(args, "disc");
    const auto* system = StringField(args, "system");
    const auto* saves = StringField(args, "saves");
    const auto* resolution = StringField(args, "internalResolution");
    if (!core || !disc || !system || !saves) {
      fl_method_call_respond_error(call, "argument", "The core, disc and storage paths are required", nullptr, nullptr);
      return;
    }
    if (ConsoleForCore(core) != Console::kPs1 && ConsoleForCore(core) != Console::kPs2) {
      fl_method_call_respond_error(call, "unsupportedCore", "This emulator core is unavailable on Linux", nullptr, nullptr);
      return;
    }
    try {
      // Keep one registration for this view. A raster callback can still hold
      // the previous frame while a session releases or the next one starts.
      if (!texture_) texture_ = static_cast<RetroTexture*>(g_object_new(retro_texture_get_type(), nullptr));
      if (!registered_) registered_ = fl_texture_registrar_register_texture(registrar_, FL_TEXTURE(texture_));
      if (!registered_) throw std::runtime_error("Could not register the game surface");
      session_ = std::make_unique<Session>(
          SessionConfig{core, disc, system, saves, resolution ? resolution : "",
                        ReadOptions(ReadField(args, "graphics")).value_or(Options{})},
          CreateLinuxVideo(), CreateLinuxAudio(),
          [this] { ScheduleFrame(); });
      {
        std::lock_guard<std::mutex> lock(texture_->state->mutex);
        texture_->state->session = session_.get();
      }
      {
        std::lock_guard<std::mutex> lock(notification_mutex_);
        notifications_enabled_ = true;
      }
      session_->Start();
      Success(call, fl_value_new_int(fl_texture_get_id(FL_TEXTURE(texture_))));
    } catch (const std::exception& error) {
      if (session_) session_->Stop();
      Release();
      fl_method_call_respond_error(call, "start", error.what(), nullptr, nullptr);
    }
  }

  void Release() {
    {
      std::lock_guard<std::mutex> lock(notification_mutex_);
      notifications_enabled_ = false;
      if (auto* pending = std::exchange(notification_, nullptr)) {
        g_source_destroy(pending);
        g_source_unref(pending);
      }
    }
    if (session_) session_->Join();
    if (texture_) {
      std::lock_guard<std::mutex> lock(texture_->state->mutex);
      texture_->state->session = nullptr;
    }
    session_.reset();
  }

  FlTextureRegistrar* registrar_;
  GMainContext* platform_context_;
  FlMethodChannel* channel_;
  std::unique_ptr<Session> session_;
  RetroTexture* texture_ = nullptr;
  std::mutex notification_mutex_;
  GSource* notification_ = nullptr;
  bool notifications_enabled_ = false;
  bool registered_ = false;
  bool shutting_down_ = false;
};

RetroCoreHostLinux::RetroCoreHostLinux(FlPluginRegistrar* registrar)
    : impl_(std::make_unique<Impl>(registrar)) {}
RetroCoreHostLinux::~RetroCoreHostLinux() = default;
void RetroCoreHostLinux::Shutdown() { impl_->Shutdown(); }
