#include <glib/gstdio.h>

#include "my_application.h"

// NVIDIA's own driver under Wayland: the window goes through XWayland. Flutter 3.47's Linux
// embedder hands each frame to GTK through an EGLImage on Wayland, with only a glFlush between
// the two OpenGL contexts (fl_view_renderer.cc, fl_compositor_opengl.cc). With NVIDIA's driver
// the window can then keep showing an old frame, or crash, after a resize such as the launcher
// going full screen (flutter/flutter#191775 and #195821). Under X11 the engine copies the frame
// through memory instead and never shares it between contexts. GDK_BACKEND, when set, decides
// as always; ANYPS5_NATIVE_WAYLAND=1 keeps native Wayland. Nothing is set in the environment,
// so the games the launcher starts are not moved to X11.
static void prefer_x11_with_nvidia_on_wayland() {
  if (g_getenv("GDK_BACKEND") != nullptr ||
      g_strcmp0(g_getenv("ANYPS5_NATIVE_WAYLAND"), "1") == 0) {
    return;
  }
  const gchar* wayland = g_getenv("WAYLAND_DISPLAY");
  const gchar* x11 = g_getenv("DISPLAY");
  if (wayland == nullptr || *wayland == '\0' || x11 == nullptr || *x11 == '\0') {
    return;
  }
  // There with NVIDIA's kernel module (closed or open), not with nouveau.
  if (!g_file_test("/proc/driver/nvidia/version", G_FILE_TEST_EXISTS)) {
    return;
  }
  // X11 first, anything else if XWayland cannot be reached.
  gdk_set_allowed_backends("x11,*");
  g_message(
      "NVIDIA driver under Wayland: the window runs through XWayland "
      "(ANYPS5_NATIVE_WAYLAND=1 keeps native Wayland)");
}

int main(int argc, char** argv) {
  prefer_x11_with_nvidia_on_wayland();
  g_autofree gchar* run_marker = nullptr;
  int status;
  {
    g_autoptr(MyApplication) app = my_application_new();
    status = g_application_run(G_APPLICATION(app), argc, argv);
    run_marker = my_application_take_run_marker(app);
  }
  // A clean close: the launcher's marker of this run goes, so the next start finds no crash. A
  // crash anywhere before this line leaves it, and the next start offers a report.
  if (run_marker != nullptr) {
    g_remove(run_marker);
  }
  return status;
}
