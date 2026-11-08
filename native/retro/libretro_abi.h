#ifndef ANYPS5_LIBRETRO_ABI_H_
#define ANYPS5_LIBRETRO_ABI_H_

#include <cstddef>
#include <cstdint>

namespace anyps5::retro {

// Layouts and command values from the libretro v1 C ABI.
struct GameInfo {
  const char* path;
  const void* data;
  std::size_t size;
  const char* meta;
};
struct DiskControlCallbacks {
  bool (*set_eject_state)(bool);
  bool (*get_eject_state)();
  unsigned (*get_image_index)();
  bool (*set_image_index)(unsigned);
  unsigned (*get_num_images)();
  bool (*replace_image_index)(unsigned, const GameInfo*);
  bool (*add_image_index)();
};
struct DiskControlExtCallbacks {
  DiskControlCallbacks basic;
  bool (*set_initial_image)(unsigned, const char*);
  bool (*get_image_path)(unsigned, char*, std::size_t);
  bool (*get_image_label)(unsigned, char*, std::size_t);
};
struct Variable {
  const char* key;
  const char* value;
};
struct ExtendedMessage {
  const char* text;
  unsigned duration, priority;
  int level, target, type;
  int8_t progress;
};
struct CoreOptionValue {
  const char* value;
  const char* label;
};
struct CoreOptionDefinition {
  const char* key;
  const char* title;
  const char* category_title;
  const char* description;
  const char* category_description;
  const char* category;
  CoreOptionValue values[128];
  const char* default_value;
};
struct CoreOptionsV2 {
  const void* categories;
  const CoreOptionDefinition* definitions;
};
struct CoreOptionsV2Intl {
  const CoreOptionsV2* english;
  const CoreOptionsV2* localized;
};
struct Geometry {
  unsigned width, height, max_width, max_height;
  float aspect;
};
struct AvInfo {
  Geometry geometry;
  double fps, sample_rate;
};
struct HardwareCallbacks {
  int context_type;
  void (*reset)();
  uintptr_t (*framebuffer)();
  void (*(*proc_address)(const char*))();
  bool depth, stencil, bottom_left_origin;
  unsigned version_major, version_minor;
  bool cache_context;
  void (*destroy)();
  bool debug_context;
};

enum EnvironmentCommand {
  kCanDupe = 3, kShutdown = 7, kSystemDirectory = 9, kPixelFormat = 10,
  kInputDescriptors = 11, kSetDiskControl = 13, kGetVariable = 15, kSetVariables = 16,
  kVariableUpdate = 17, kSupportNoGame = 18, kCorePath = 19,
  kContentDirectory = 30, kSaveDirectory = 31, kSetAv = 32,
  kSetGeometry = 37, kAudioVideoEnable = 47 | 0x10000, kFastForward = 49,
  kCoreOptionsVersion = 52, kSetHardware = 14, kHardwareInterface = 41 | 0x10000,
  kHardwareNegotiation = 43 | 0x10000,
  kPreferredHardware = 56, kDiskControlVersion = 57, kSetDiskControlExt = 58,
  kSetCoreOptionsV2 = 67, kSetCoreOptionsV2Intl = 68,
  kMessageVersion = 59, kExtendedMessage = 60,
  kFrontendCompileProgress = 0x20000 | 0x4150,
};
enum PixelFormat {
  kRgb1555 = 0,
  kXrgb8888 = 1,
  kRgb565 = 2,
};

}  // namespace anyps5::retro

#endif  // ANYPS5_LIBRETRO_ABI_H_
