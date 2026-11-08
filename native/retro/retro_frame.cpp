#include "retro_frame.h"

#include "libretro_abi.h"

#include <limits>

namespace anyps5::retro {

std::shared_ptr<Frame> DecodeSoftwareFrame(const void* data, unsigned width, unsigned height,
                                           std::size_t pitch, int format) {
  if (!data || width == 0 || height == 0 || width > kMaxFrameSize || height > kMaxFrameSize ||
      format < kRgb1555 || format > kRgb565) {
    return nullptr;
  }
  const std::size_t bytes = format == kXrgb8888 ? 4 : 2;
  const auto row_bytes = width * bytes;
  if (pitch < row_bytes || (height > 1 && pitch > (std::numeric_limits<std::size_t>::max() - row_bytes) / (height - 1))) {
    return nullptr;
  }

  auto frame = std::make_shared<Frame>();
  frame->width = width;
  frame->height = height;
  frame->pixels.resize(static_cast<std::size_t>(width) * height * 4);
  auto* output = frame->pixels.data();
  const auto* input = static_cast<const uint8_t*>(data);
  for (unsigned row = 0; row < height; ++row) {
    const auto* source = input + row * pitch;
    for (unsigned column = 0; column < width; ++column, source += bytes, output += 4) {
      if (format == kXrgb8888) {
        output[0] = source[2];
        output[1] = source[1];
        output[2] = source[0];
      } else {
        const unsigned pixel = source[0] | (source[1] << 8);
        const bool rgb565 = format == kRgb565;
        const unsigned red = (pixel >> (rgb565 ? 11 : 10)) & 31;
        const unsigned green = (pixel >> 5) & (rgb565 ? 63 : 31);
        const unsigned blue = pixel & 31;
        output[0] = static_cast<uint8_t>((red << 3) | (red >> 2));
        output[1] = static_cast<uint8_t>(rgb565 ? (green << 2) | (green >> 4) : (green << 3) | (green >> 2));
        output[2] = static_cast<uint8_t>((blue << 3) | (blue >> 2));
      }
      output[3] = 255;
    }
  }
  return frame;
}

}  // namespace anyps5::retro
