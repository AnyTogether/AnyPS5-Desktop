#ifndef ANYPS5_RETRO_CORE_HOST_LINUX_H_
#define ANYPS5_RETRO_CORE_HOST_LINUX_H_

#include <flutter_linux/flutter_linux.h>

#include <memory>

class RetroCoreHostLinux {
 public:
  explicit RetroCoreHostLinux(FlPluginRegistrar* registrar);
  ~RetroCoreHostLinux();
  void Shutdown();

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

#endif  // ANYPS5_RETRO_CORE_HOST_LINUX_H_
