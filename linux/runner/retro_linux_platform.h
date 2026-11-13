#ifndef ANYPS5_RETRO_LINUX_PLATFORM_H_
#define ANYPS5_RETRO_LINUX_PLATFORM_H_

#include "retro_session.h"

namespace anyps5::retro {

std::unique_ptr<Video> CreateLinuxVideo();
std::unique_ptr<Audio> CreateLinuxAudio();

}  // namespace anyps5::retro

#endif  // ANYPS5_RETRO_LINUX_PLATFORM_H_
