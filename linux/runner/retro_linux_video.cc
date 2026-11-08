#include "retro_linux_platform.h"

#include <epoxy/gl.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <stdexcept>

namespace anyps5::retro {
namespace {
constexpr int kOpenGlCore = 3;
constexpr int kOpenGl = 1;

class EglVideo final : public Video {
 public:
  bool Open() override {
    const auto get_platform_display = reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(
        eglGetProcAddress("eglGetPlatformDisplayEXT"));
    const auto query_devices = reinterpret_cast<PFNEGLQUERYDEVICESEXTPROC>(eglGetProcAddress("eglQueryDevicesEXT"));
    if (get_platform_display && query_devices) {
      std::array<EGLDeviceEXT, 8> devices{};
      EGLint count = 0;
      if (query_devices(devices.size(), devices.data(), &count)) {
        for (int i = 0; i < count && i < static_cast<int>(devices.size()); ++i) {
          if (TryOpen(get_platform_display(EGL_PLATFORM_DEVICE_EXT, devices[i], nullptr))) return true;
        }
      }
    }
    return get_platform_display &&
        TryOpen(get_platform_display(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, nullptr));
  }

  int PreferredContext() const override { return kOpenGlCore; }
  std::string_view PreferredRenderer() const override { return "OpenGL"; }

  bool Bind(HardwareCallbacks& callbacks) override {
    if (callbacks.context_type != kOpenGlCore && callbacks.context_type != kOpenGl) return false;
    if (callbacks.version_major * 10 + callbacks.version_minor > static_cast<unsigned>(epoxy_gl_version()))
      return false;
    callbacks.framebuffer = []() -> uintptr_t {
      if (!active_) return 0;
      const auto width = active_->required_width_.load();
      const auto height = active_->required_height_.load();
      return active_->Resize(width, height) ? active_->framebuffer_ : 0;
    };
    callbacks.proc_address = [](const char* name) -> void (*)() { return eglGetProcAddress(name); };
    return true;
  }

  bool Environment(unsigned, void*, int) override { return false; }

  void GeometryChanged(const Geometry& geometry) override {
    if (geometry.max_width && geometry.max_width <= kMaxFrameSize) required_width_ = geometry.max_width;
    if (geometry.max_height && geometry.max_height <= kMaxFrameSize) required_height_ = geometry.max_height;
  }

  void Reset(const HardwareCallbacks& callbacks) override {
    if (!Resize(required_width_, required_height_))
      throw std::runtime_error("Could not allocate the emulator's OpenGL framebuffer");
    callbacks.reset();
  }

  void Clear() override {}

  void Close() override {
    // Unload/deinit release the game's GL objects. The context-destroy callback
    // is for replacing a context while content is live, not for an unloaded VM.
    if (context_ == EGL_NO_CONTEXT) return;
    glDeleteRenderbuffers(1, &depth_);
    glDeleteRenderbuffers(1, &color_);
    glDeleteFramebuffers(1, &framebuffer_);
    active_ = nullptr;
    ReleaseContext();
  }

  std::shared_ptr<Frame> Read(unsigned width, unsigned height, const HardwareCallbacks& callbacks) override {
    if (!framebuffer_ || width > width_ || height > height_) return nullptr;
    auto frame = std::make_shared<Frame>();
    frame->width = width;
    frame->height = height;
    frame->pixels.resize(static_cast<size_t>(width) * height * 4);

    GLint read_buffer = 0;
    GLint pack_buffer = 0;
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &read_buffer);
    glGetIntegerv(GL_PIXEL_PACK_BUFFER_BINDING, &pack_buffer);
    constexpr std::array<GLenum, 4> pack_keys{GL_PACK_ALIGNMENT, GL_PACK_ROW_LENGTH,
                                              GL_PACK_SKIP_PIXELS, GL_PACK_SKIP_ROWS};
    std::array<GLint, pack_keys.size()> pack{};
    for (size_t i = 0; i < pack.size(); ++i) {
      glGetIntegerv(pack_keys[i], &pack[i]);
      glPixelStorei(pack_keys[i], i == 0 ? 1 : 0);
    }
    glBindFramebuffer(GL_READ_FRAMEBUFFER, framebuffer_);
    glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
    glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, frame->pixels.data());
    glBindBuffer(GL_PIXEL_PACK_BUFFER, pack_buffer);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, read_buffer);
    for (size_t i = 0; i < pack.size(); ++i) glPixelStorei(pack_keys[i], pack[i]);

    if (callbacks.bottom_left_origin) {
      const auto stride = static_cast<size_t>(width) * 4;
      auto top = frame->pixels.begin();
      auto bottom = frame->pixels.end() - stride;
      for (; top < bottom; top += stride, bottom -= stride) std::swap_ranges(top, top + stride, bottom);
    }
    for (size_t i = 3; i < frame->pixels.size(); i += 4) frame->pixels[i] = 255;
    return frame;
  }

 private:
  bool TryOpen(EGLDisplay display) {
    if (display == EGL_NO_DISPLAY || !eglInitialize(display, nullptr, nullptr)) return false;
    display_ = display;
    const EGLint config_attributes[] = {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT, EGL_NONE};
    EGLConfig config{};
    EGLint count = 0;
    if (!eglBindAPI(EGL_OPENGL_API) ||
        !eglChooseConfig(display_, config_attributes, &config, 1, &count) || count == 0) {
      ReleaseContext();
      return false;
    }
    const EGLint pbuffer_attributes[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
    surface_ = eglCreatePbufferSurface(display_, config, pbuffer_attributes);
    if (surface_ == EGL_NO_SURFACE) {
      ReleaseContext();
      return false;
    }
    constexpr std::array<int, 2> versions{42, 33};
    for (int version : versions) {
      const EGLint attributes[] = {EGL_CONTEXT_MAJOR_VERSION, version / 10, EGL_CONTEXT_MINOR_VERSION, version % 10,
                                   EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT, EGL_NONE};
      context_ = eglCreateContext(display_, config, EGL_NO_CONTEXT, attributes);
      if (context_ == EGL_NO_CONTEXT) continue;
      if (eglMakeCurrent(display_, surface_, surface_, context_)) {
        active_ = this;
        return true;
      }
      eglDestroyContext(display_, context_);
      context_ = EGL_NO_CONTEXT;
    }
    ReleaseContext();
    return false;
  }

  bool Resize(unsigned width, unsigned height) {
    if (framebuffer_ && width <= width_ && height <= height_) return true;
    width = std::max(width, width_);
    height = std::max(height, height_);
    GLint draw_buffer = 0;
    GLint renderbuffer = 0;
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &draw_buffer);
    glGetIntegerv(GL_RENDERBUFFER_BINDING, &renderbuffer);
    if (!framebuffer_) {
      glGenFramebuffers(1, &framebuffer_);
      glGenRenderbuffers(1, &color_);
      glGenRenderbuffers(1, &depth_);
    }
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffer_);
    glBindRenderbuffer(GL_RENDERBUFFER, color_);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, width, height);
    glFramebufferRenderbuffer(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, color_);
    glBindRenderbuffer(GL_RENDERBUFFER, depth_);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, width, height);
    glFramebufferRenderbuffer(GL_DRAW_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_RENDERBUFFER, depth_);
    const bool complete = glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
    glBindRenderbuffer(GL_RENDERBUFFER, renderbuffer);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, draw_buffer);
    if (!complete) return false;
    width_ = width;
    height_ = height;
    return true;
  }

  void ReleaseContext() {
    if (display_ == EGL_NO_DISPLAY) return;
    eglMakeCurrent(display_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (context_ != EGL_NO_CONTEXT) eglDestroyContext(display_, context_);
    if (surface_ != EGL_NO_SURFACE) eglDestroySurface(display_, surface_);
    eglTerminate(display_);
    display_ = EGL_NO_DISPLAY;
    context_ = EGL_NO_CONTEXT;
    surface_ = EGL_NO_SURFACE;
  }

  static thread_local EglVideo* active_;
  EGLDisplay display_ = EGL_NO_DISPLAY;
  EGLContext context_ = EGL_NO_CONTEXT;
  EGLSurface surface_ = EGL_NO_SURFACE;
  GLuint framebuffer_ = 0, color_ = 0, depth_ = 0;
  unsigned width_ = 0, height_ = 0;
  std::atomic<unsigned> required_width_{1024}, required_height_{512};
};

thread_local EglVideo* EglVideo::active_ = nullptr;
}  // namespace

std::unique_ptr<Video> CreateLinuxVideo() { return std::make_unique<EglVideo>(); }

}  // namespace anyps5::retro
