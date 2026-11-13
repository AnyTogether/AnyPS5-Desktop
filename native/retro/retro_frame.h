#ifndef ANYPS5_RETRO_FRAME_H_
#define ANYPS5_RETRO_FRAME_H_

#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>

namespace anyps5::retro {

inline constexpr unsigned kMaxFrameSize = 4096;

struct Frame {
  std::vector<uint8_t> pixels;
  std::size_t width = 0;
  std::size_t height = 0;
};

// Convert one Libretro software frame to an owned, tightly packed RGBA image.
std::shared_ptr<Frame> DecodeSoftwareFrame(const void* data, unsigned width, unsigned height,
                                           std::size_t pitch, int format);

}  // namespace anyps5::retro

#endif  // ANYPS5_RETRO_FRAME_H_
