#ifndef ANYPS5_RETRO_VULKAN_VIDEO_H_
#define ANYPS5_RETRO_VULKAN_VIDEO_H_

#include "retro_session.h"

namespace anyps5::retro {
std::unique_ptr<Video> CreateVulkanVideo();
}  // namespace anyps5::retro

#endif  // ANYPS5_RETRO_VULKAN_VIDEO_H_
