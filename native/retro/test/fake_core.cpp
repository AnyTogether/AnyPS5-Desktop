#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>

#if defined(_WIN32)
#define TEST_EXPORT __declspec(dllexport)
#else
#define TEST_EXPORT __attribute__((visibility("default")))
#endif

namespace {
struct GameInfo {
  const char* path;
  const void* data;
  std::size_t size;
  const char* meta;
};
struct AvInfo {
  unsigned width, height, max_width, max_height;
  float aspect;
  double fps, sample_rate;
};

void (*video)(const void*, unsigned, unsigned, std::size_t);
int16_t (*input)(unsigned, unsigned, unsigned, unsigned);
std::size_t (*audio)(const int16_t*, std::size_t);
std::atomic<unsigned> lifecycle{0};
}  // namespace

extern "C" TEST_EXPORT unsigned retro_api_version() { return 1; }

extern "C" TEST_EXPORT bool retro_load_game(const GameInfo* info) {
  if (!info || std::strcmp(info->path, "test.cue") != 0 || info->data || info->size != 0) return false;
  if (info->meta) return std::strcmp(info->meta, "test metadata") == 0;
  ++lifecycle;
  return true;
}

extern "C" TEST_EXPORT void retro_init() { ++lifecycle; }
extern "C" TEST_EXPORT void retro_unload_game() { ++lifecycle; }
extern "C" TEST_EXPORT void retro_deinit() { ++lifecycle; }
extern "C" TEST_EXPORT unsigned test_lifecycle_count() { return lifecycle; }

extern "C" TEST_EXPORT void retro_set_environment(bool (*)(unsigned, void*)) {}
extern "C" TEST_EXPORT void retro_set_video_refresh(decltype(video) callback) { video = callback; }
extern "C" TEST_EXPORT void retro_set_input_state(decltype(input) callback) { input = callback; }
extern "C" TEST_EXPORT void retro_set_input_poll(void (*)()) {}
extern "C" TEST_EXPORT void retro_set_audio_sample(void (*)(int16_t, int16_t)) {}
extern "C" TEST_EXPORT void retro_set_audio_sample_batch(decltype(audio) callback) { audio = callback; }

extern "C" TEST_EXPORT void retro_get_system_av_info(AvInfo* info) {
  *info = {1, 1, 1, 1, 1.0f, 60.0, 48000.0};
}

extern "C" TEST_EXPORT void retro_run() {
  const uint8_t pixel[] = {0, static_cast<uint8_t>(input(0, 1, 0, 0) ? 0x7c : 0)};
  const int16_t stereo[] = {123, -123};
  video(pixel, 1, 1, sizeof(pixel));
  audio(stereo, 1);
}