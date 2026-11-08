#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>
#include <thread>

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
// Independent declarations keep the fixture an ABI check for the frontend.
struct DiskControl {
  bool (*set_eject)(bool);
  bool (*get_eject)();
  unsigned (*get_index)();
  bool (*set_index)(unsigned);
  unsigned (*count)();
  bool (*replace)(unsigned, const GameInfo*);
  bool (*add)();
  bool (*set_initial)(unsigned, const char*);
  bool (*get_path)(unsigned, char*, std::size_t);
  bool (*get_label)(unsigned, char*, std::size_t);
};

bool (*environment)(unsigned, void*);
std::atomic<unsigned> lifecycle{0};
std::atomic<bool> wrong_disk_thread{false}, fail_next_recovery{false};
std::atomic<unsigned> run_count{0};
std::thread::id worker;
bool multidisc = false;
bool legacy_disk_control = false;
bool ejected = false;
unsigned image = 0;
std::string initial_path;

void CheckDiskThread() {
  if (std::this_thread::get_id() != worker) wrong_disk_thread = true;
}

bool SetEject(bool value) {
  CheckDiskThread();
  // Disc three simulates missing media. Closing the tray with the old
  // disc is still allowed so the frontend can recover.
  if (!value && image == 2) return false;
  if (!value && image == 1 && fail_next_recovery.exchange(false)) return false;
  ejected = value;
  return true;
}

bool GetEject() { CheckDiskThread(); return ejected; }
unsigned GetIndex() { CheckDiskThread(); return image; }
bool SetIndex(unsigned index) {
  CheckDiskThread();
  if (!ejected || index >= 3) return false;
  image = index;
  return true;
}
unsigned Count() { CheckDiskThread(); return multidisc ? 3 : 1; }
bool Replace(unsigned, const GameInfo*) { return false; }
bool Add() { return false; }
bool GetLabel(unsigned index, char* label, std::size_t size) {
  CheckDiskThread();
  if (index >= 3 || size < 7) return false;
  const char* labels[] = {"Disc A", "Disc B", "Disc C"};
  std::memcpy(label, labels[index], 7);
  return true;
}
bool SetInitialImage(unsigned index, const char* path) {
  CheckDiskThread();
  if (run_count != 0 || index >= 3) return false;
  image = index;
  initial_path = path;
  return true;
}
bool GetImagePath(unsigned index, char* path, std::size_t size) {
  CheckDiskThread();
  if (!multidisc || index != image || initial_path.size() >= size) return false;
  std::memcpy(path, initial_path.c_str(), initial_path.size() + 1);
  return true;
}
void RegisterDiskControl() {
  unsigned version = 0;
  DiskControl callbacks{
      SetEject, GetEject, GetIndex, SetIndex, Count, Replace, Add, SetInitialImage, GetImagePath, GetLabel};
  if (!legacy_disk_control && environment(57, &version) && version >= 1)
    environment(58, &callbacks);
  else
    environment(13, &callbacks);
}
}  // namespace

extern "C" TEST_EXPORT unsigned retro_api_version() { return 1; }

extern "C" TEST_EXPORT bool retro_load_game(const GameInfo* info) {
  if (!info || info->data || info->size != 0) return false;
  const bool playlist = std::strcmp(info->path, "test.m3u") == 0;
  if (!playlist && std::strcmp(info->path, "test.cue") != 0) return false;
  if (info->meta) return std::strcmp(info->meta, "test metadata") == 0;
  multidisc = playlist;
  ++lifecycle;
  return true;
}

extern "C" TEST_EXPORT void retro_init() {
  ++lifecycle;
  worker = std::this_thread::get_id();
  wrong_disk_thread = false;
  image = 0;
  initial_path.clear();
  ejected = false;
  run_count = 0;
  if (!legacy_disk_control) RegisterDiskControl();
}
extern "C" TEST_EXPORT void retro_unload_game() { ++lifecycle; }
extern "C" TEST_EXPORT void retro_deinit() { ++lifecycle; }
extern "C" TEST_EXPORT unsigned test_lifecycle_count() { return lifecycle; }

extern "C" TEST_EXPORT bool test_wrong_disk_thread() { return wrong_disk_thread; }
extern "C" TEST_EXPORT void test_use_legacy_disk_control() { legacy_disk_control = true; }

extern "C" TEST_EXPORT unsigned test_run_count() { return run_count; }
extern "C" TEST_EXPORT void test_fail_next_recovery() { fail_next_recovery = true; }

extern "C" TEST_EXPORT void retro_set_environment(decltype(environment) callback) {
  environment = callback;
  if (legacy_disk_control) RegisterDiskControl();
}
extern "C" TEST_EXPORT void retro_set_video_refresh(decltype(video) callback) { video = callback; }
extern "C" TEST_EXPORT void retro_set_input_state(decltype(input) callback) { input = callback; }
extern "C" TEST_EXPORT void retro_set_input_poll(void (*)()) {}
extern "C" TEST_EXPORT void retro_set_audio_sample(void (*)(int16_t, int16_t)) {}
extern "C" TEST_EXPORT void retro_set_audio_sample_batch(decltype(audio) callback) { audio = callback; }

extern "C" TEST_EXPORT void retro_get_system_av_info(AvInfo* info) {
  *info = {1, 1, 1, 1, 1.0f, 60.0, 48000.0};
}

extern "C" TEST_EXPORT void retro_run() {
  ++run_count;
  const uint8_t pixel[] = {0, static_cast<uint8_t>(input(0, 1, 0, 0) ? 0x7c : 0)};
  const int16_t stereo[] = {123, -123};
  video(pixel, 1, 1, sizeof(pixel));
  audio(stereo, 1);
}