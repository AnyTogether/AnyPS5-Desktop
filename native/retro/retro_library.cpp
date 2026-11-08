#include "retro_library.h"

#include <stdexcept>
#include <string>

#if defined(_WIN32)
#include <windows.h>
#else
#include <dlfcn.h>
#endif

namespace anyps5::retro {

DynamicLibrary::DynamicLibrary(const std::filesystem::path& path) {
#if defined(_WIN32)
  handle_ = LoadLibraryExW(path.c_str(), nullptr, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
#else
  handle_ = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
#endif
  if (!handle_) throw std::runtime_error("Could not load the configured emulator core");
}

DynamicLibrary::~DynamicLibrary() {
#if defined(_WIN32)
  FreeLibrary(static_cast<HMODULE>(handle_));
#else
  dlclose(handle_);
#endif
}

DynamicLibrary::Address DynamicLibrary::Lookup(const char* name) const {
#if defined(_WIN32)
  const auto address = GetProcAddress(static_cast<HMODULE>(handle_), name);
#else
  const auto address = dlsym(handle_, name);
#endif
  if (!address) throw std::runtime_error(std::string("Core is missing ") + name);
  Address function;
  static_assert(sizeof(function) == sizeof(address));
  std::memcpy(&function, &address, sizeof(function));
  return function;
}

}  // namespace anyps5::retro
