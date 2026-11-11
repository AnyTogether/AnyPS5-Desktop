// libanyps5_mpv.so: the clip player's way to the system's libmpv.
//
// media_kit_video's plugin calls seven libmpv functions to draw a clip into a Flutter texture.
// Linked to libmpv itself, the plugin (and with it the launcher, which links every plugin) could
// not start where the system has no libmpv, or another version of it (Ubuntu 22.04 has
// libmpv.so.1, newer systems libmpv.so.2). The Linux packages do not carry a libmpv: the
// launcher is GPL-2.0-only and the distributions' libmpv builds are not (Ubuntu's links GPL-3
// libraries). So linux/CMakeLists.txt links the plugin to this library instead, which has the
// same seven functions and opens the system's libmpv when the first of them is called.
//
// Which libmpv: the one the process has loaded already (media_kit opens it from Dart before any
// clip reaches the plugin, and the plugin must use that same one), else the first that loads of
// LIBMPV_LIBRARY_PATH, libmpv.so, libmpv.so.2 and libmpv.so.1, media_kit's order. Without one,
// each function fails as libmpv does for a handle it cannot use; the launcher never gets that far
// (lib/core/libmpv.dart says how to install libmpv instead).
//
// The libmpv C API these use is the same in libmpv.so.1 (mpv 0.34) and libmpv.so.2.

#include <dlfcn.h>
#include <link.h>
#include <mpv/client.h>
#include <mpv/render.h>

#include <cstdlib>
#include <cstring>
#include <initializer_list>
#include <string>

#define ANYPS5_EXPORT extern "C" __attribute__((visibility("default")))

namespace {

// The path of a libmpv the process has loaded (dl_iterate_phdr), into |found|.
int FindLoaded(struct dl_phdr_info* info, size_t, void* found) {
  const char* name = info->dlpi_name;
  if (name == nullptr || name[0] == '\0') return 0;
  const char* slash = std::strrchr(name, '/');
  const char* base = slash == nullptr ? name : slash + 1;
  if (std::strncmp(base, "libmpv.so", 9) != 0) return 0;
  *static_cast<std::string*>(found) = name;
  return 1;
}

void* OpenLibmpv() {
  // dlopen only after dl_iterate_phdr has returned: it holds the loader's lock meanwhile.
  std::string loaded;
  dl_iterate_phdr(FindLoaded, &loaded);
  if (!loaded.empty()) {
    if (void* handle = dlopen(loaded.c_str(), RTLD_NOW | RTLD_NOLOAD)) return handle;
  }
  const char* custom = std::getenv("LIBMPV_LIBRARY_PATH");
  if (custom != nullptr && custom[0] != '\0') {
    if (void* handle = dlopen(custom, RTLD_NOW)) return handle;
  }
  for (const char* name : {"libmpv.so", "libmpv.so.2", "libmpv.so.1"}) {
    if (void* handle = dlopen(name, RTLD_NOW)) return handle;
  }
  return nullptr;
}

void* Libmpv() {
  static void* const handle = OpenLibmpv();
  return handle;
}

// The system libmpv's own |name| (dlsym on its handle, never this library's), or null.
template <typename Function>
Function Find(const char* name) {
  void* handle = Libmpv();
  return handle == nullptr ? nullptr : reinterpret_cast<Function>(dlsym(handle, name));
}

}  // namespace

ANYPS5_EXPORT int mpv_set_option_string(mpv_handle* ctx, const char* name, const char* data) {
  static const auto real = Find<decltype(&mpv_set_option_string)>("mpv_set_option_string");
  return real == nullptr ? MPV_ERROR_UNINITIALIZED : real(ctx, name, data);
}

ANYPS5_EXPORT int mpv_get_property(mpv_handle* ctx, const char* name, mpv_format format, void* data) {
  static const auto real = Find<decltype(&mpv_get_property)>("mpv_get_property");
  return real == nullptr ? MPV_ERROR_UNINITIALIZED : real(ctx, name, format, data);
}

ANYPS5_EXPORT void mpv_free_node_contents(mpv_node* node) {
  static const auto real = Find<decltype(&mpv_free_node_contents)>("mpv_free_node_contents");
  if (real != nullptr) real(node);
}

ANYPS5_EXPORT int mpv_render_context_create(mpv_render_context** res, mpv_handle* mpv, mpv_render_param* params) {
  static const auto real = Find<decltype(&mpv_render_context_create)>("mpv_render_context_create");
  if (real == nullptr) {
    if (res != nullptr) *res = nullptr;
    return MPV_ERROR_UNINITIALIZED;
  }
  return real(res, mpv, params);
}

ANYPS5_EXPORT void mpv_render_context_set_update_callback(mpv_render_context* ctx,
                                                          mpv_render_update_fn callback,
                                                          void* callback_ctx) {
  static const auto real =
      Find<decltype(&mpv_render_context_set_update_callback)>("mpv_render_context_set_update_callback");
  if (real != nullptr) real(ctx, callback, callback_ctx);
}

ANYPS5_EXPORT int mpv_render_context_render(mpv_render_context* ctx, mpv_render_param* params) {
  static const auto real = Find<decltype(&mpv_render_context_render)>("mpv_render_context_render");
  return real == nullptr ? MPV_ERROR_UNINITIALIZED : real(ctx, params);
}

ANYPS5_EXPORT void mpv_render_context_free(mpv_render_context* ctx) {
  static const auto real = Find<decltype(&mpv_render_context_free)>("mpv_render_context_free");
  if (real != nullptr) real(ctx);
}
