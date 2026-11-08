#ifndef ANYPS5_RETRO_LIBRARY_H_
#define ANYPS5_RETRO_LIBRARY_H_

#include <cstring>
#include <filesystem>
#include <type_traits>

namespace anyps5::retro {

class DynamicLibrary {
 public:
  explicit DynamicLibrary(const std::filesystem::path& path);
  ~DynamicLibrary();

  DynamicLibrary(const DynamicLibrary&) = delete;
  DynamicLibrary& operator=(const DynamicLibrary&) = delete;

  template <typename Function>
  Function Get(const char* name) const {
    static_assert(std::is_pointer_v<Function> && std::is_function_v<std::remove_pointer_t<Function>>);
    const auto address = Lookup(name);
    Function function;
    static_assert(sizeof(function) == sizeof(address));
    std::memcpy(&function, &address, sizeof(function));
    return function;
  }

 private:
  using Address = void (*)();
  Address Lookup(const char* name) const;

  void* handle_;
};

}  // namespace anyps5::retro

#endif  // ANYPS5_RETRO_LIBRARY_H_
