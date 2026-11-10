#include "layer_overlay.h"

#include <cairo.h>
#include <dlfcn.h>
#include <gtk/gtk.h>
#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/gdkwayland.h>
#endif

#include <cstdint>
#include <cstring>
#include <map>
#include <string>

namespace {

// gtk-layer-shell's enums (include/gtk-layer-shell.h), passed as ints.
constexpr int kLayerOverlay = 3;  // GTK_LAYER_SHELL_LAYER_OVERLAY: above full-screen windows
constexpr int kEdgeLeft = 0;      // GTK_LAYER_SHELL_EDGE_LEFT
constexpr int kEdgeTop = 2;       // GTK_LAYER_SHELL_EDGE_TOP

// The part of gtk-layer-shell's API the overlay uses, all there since 0.5 (Ubuntu 22.04 has
// 0.7).
struct LayerShell {
  gboolean (*is_supported)() = nullptr;
  void (*init_for_window)(GtkWindow*) = nullptr;
  void (*set_namespace)(GtkWindow*, const char*) = nullptr;
  void (*set_layer)(GtkWindow*, int) = nullptr;
  void (*set_anchor)(GtkWindow*, int, gboolean) = nullptr;
  void (*set_margin)(GtkWindow*, int, int) = nullptr;
  void (*set_exclusive_zone)(GtkWindow*, int) = nullptr;
};

// Loaded, and the compositor has the protocol; null otherwise.
LayerShell* layer_shell = nullptr;

// One surface: its window, its picture (premultiplied ARGB, as Dart sends it) and how it is
// drawn now.
struct Overlay {
  GtkWidget* window = nullptr;
  cairo_surface_t* picture = nullptr;
  int width = 0;
  int height = 0;
  double opacity = 1;
};

std::map<std::string, Overlay> overlays;
FlMethodChannel* overlay_channel = nullptr;

template <typename T>
bool find_symbol(void* library, const char* name, T* out) {
  *out = reinterpret_cast<T>(dlsym(library, name));
  return *out != nullptr;
}

gboolean draw_cb(GtkWidget* widget, cairo_t* cr, gpointer user_data) {
  Overlay* overlay = static_cast<Overlay*>(user_data);
  cairo_save(cr);
  cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
  cairo_set_source_rgba(cr, 0, 0, 0, 0);
  cairo_paint(cr);
  cairo_restore(cr);
  if (overlay->picture != nullptr) {
    cairo_set_source_surface(cr, overlay->picture, 0, 0);
    cairo_paint_with_alpha(cr, overlay->opacity);
  }
  return TRUE;
}

void destroy_overlay(Overlay* overlay) {
  if (overlay->window != nullptr) {
    gtk_widget_destroy(overlay->window);
    overlay->window = nullptr;
  }
  g_clear_pointer(&overlay->picture, cairo_surface_destroy);
  overlay->width = 0;
  overlay->height = 0;
}

// A layer surface on the overlay layer that never takes the keyboard (gtk-layer-shell's
// default) and lets every click through (an empty input region), anchored to the top edge
// (centred) or the top left corner.
GtkWidget* make_window(Overlay* overlay, int width, int height, gboolean top_left) {
  GtkWidget* widget = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  GtkWindow* window = GTK_WINDOW(widget);
  GdkVisual* visual = gdk_screen_get_rgba_visual(gtk_widget_get_screen(widget));
  if (visual != nullptr) {
    gtk_widget_set_visual(widget, visual);
  }
  gtk_widget_set_app_paintable(widget, TRUE);
  gtk_window_set_decorated(window, FALSE);
  gtk_window_set_resizable(window, FALSE);
  gtk_window_set_accept_focus(window, FALSE);
  gtk_window_set_focus_on_map(window, FALSE);
  layer_shell->init_for_window(window);
  layer_shell->set_namespace(window, "anyps5");
  layer_shell->set_layer(window, kLayerOverlay);
  // Placed where asked, whatever panels keep for themselves.
  layer_shell->set_exclusive_zone(window, -1);
  layer_shell->set_anchor(window, kEdgeTop, TRUE);
  if (top_left) {
    layer_shell->set_anchor(window, kEdgeLeft, TRUE);
  }
  gtk_widget_set_size_request(widget, width, height);
  cairo_region_t* nothing = cairo_region_create();
  gtk_widget_input_shape_combine_region(widget, nothing);
  cairo_region_destroy(nothing);
  g_signal_connect(widget, "draw", G_CALLBACK(draw_cb), overlay);
  return widget;
}

int int_arg(FlValue* args, const char* key, int fallback) {
  FlValue* value = fl_value_lookup_string(args, key);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_INT) {
    return fallback;
  }
  return static_cast<int>(fl_value_get_int(value));
}

double float_arg(FlValue* args, const char* key, double fallback) {
  FlValue* value = fl_value_lookup_string(args, key);
  if (value == nullptr) {
    return fallback;
  }
  if (fl_value_get_type(value) == FL_VALUE_TYPE_FLOAT) {
    return fl_value_get_float(value);
  }
  if (fl_value_get_type(value) == FL_VALUE_TYPE_INT) {
    return static_cast<double>(fl_value_get_int(value));
  }
  return fallback;
}

const gchar* name_arg(FlValue* args) {
  FlValue* value = fl_value_lookup_string(args, "name");
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_STRING) {
    return nullptr;
  }
  return fl_value_get_string(value);
}

// "show": {name, width, height (pixels), scale, pixels (premultiplied BGRA, top row first),
// anchor ("top" or "topLeft"), left, top (margins in the desktop's own units), opacity}.
gboolean show(FlValue* args) {
  const gchar* name = name_arg(args);
  const int width = int_arg(args, "width", 0);
  const int height = int_arg(args, "height", 0);
  const double scale = float_arg(args, "scale", 1);
  FlValue* pixels = fl_value_lookup_string(args, "pixels");
  FlValue* anchor = fl_value_lookup_string(args, "anchor");
  if (name == nullptr || width <= 0 || height <= 0 || width > 8192 || height > 8192 ||
      scale <= 0 || pixels == nullptr ||
      fl_value_get_type(pixels) != FL_VALUE_TYPE_UINT8_LIST ||
      fl_value_get_length(pixels) != static_cast<size_t>(width) * height * 4) {
    return FALSE;
  }
  const gboolean top_left =
      anchor != nullptr && fl_value_get_type(anchor) == FL_VALUE_TYPE_STRING &&
      strcmp(fl_value_get_string(anchor), "topLeft") == 0;
  Overlay* overlay = &overlays[name];
  if (overlay->window != nullptr &&
      (overlay->width != width || overlay->height != height)) {
    destroy_overlay(overlay);
  }
  cairo_surface_t* picture =
      cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
  if (cairo_surface_status(picture) != CAIRO_STATUS_SUCCESS) {
    cairo_surface_destroy(picture);
    return FALSE;
  }
  // ARGB32 is premultiplied and native-endian: B, G, R, A in memory here, as sent.
  cairo_surface_flush(picture);
  const int stride = cairo_image_surface_get_stride(picture);
  unsigned char* target = cairo_image_surface_get_data(picture);
  const uint8_t* source = fl_value_get_uint8_list(pixels);
  for (int row = 0; row < height; row++) {
    memcpy(target + row * stride, source + row * width * 4, width * 4);
  }
  cairo_surface_mark_dirty(picture);
  cairo_surface_set_device_scale(picture, scale, scale);
  g_clear_pointer(&overlay->picture, cairo_surface_destroy);
  overlay->picture = picture;
  overlay->opacity = float_arg(args, "opacity", 1);
  if (overlay->window == nullptr) {
    const int logical_width = static_cast<int>(width / scale + 0.5);
    const int logical_height = static_cast<int>(height / scale + 0.5);
    overlay->window =
        make_window(overlay, logical_width, logical_height, top_left);
    overlay->width = width;
    overlay->height = height;
  }
  GtkWindow* window = GTK_WINDOW(overlay->window);
  layer_shell->set_margin(window, kEdgeTop, int_arg(args, "top", 0));
  if (top_left) {
    layer_shell->set_margin(window, kEdgeLeft, int_arg(args, "left", 0));
  }
  gtk_widget_show(overlay->window);
  gtk_widget_queue_draw(overlay->window);
  return TRUE;
}

// "update": {name, opacity, top}: a card coming in or going.
gboolean update(FlValue* args) {
  const gchar* name = name_arg(args);
  if (name == nullptr) {
    return FALSE;
  }
  auto found = overlays.find(name);
  if (found == overlays.end() || found->second.window == nullptr) {
    return FALSE;
  }
  Overlay* overlay = &found->second;
  overlay->opacity = float_arg(args, "opacity", overlay->opacity);
  FlValue* top = fl_value_lookup_string(args, "top");
  if (top != nullptr && fl_value_get_type(top) == FL_VALUE_TYPE_INT) {
    layer_shell->set_margin(GTK_WINDOW(overlay->window), kEdgeTop,
                            static_cast<int>(fl_value_get_int(top)));
  }
  gtk_widget_queue_draw(overlay->window);
  return TRUE;
}

// "hide": {name}.
gboolean hide(FlValue* args) {
  const gchar* name = name_arg(args);
  if (name == nullptr) {
    return FALSE;
  }
  auto found = overlays.find(name);
  if (found != overlays.end()) {
    destroy_overlay(&found->second);
  }
  return TRUE;
}

void overlay_method_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                       gpointer user_data) {
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;
  if (strcmp(method, "show") != 0 && strcmp(method, "update") != 0 &&
      strcmp(method, "hide") != 0) {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  } else {
    gboolean done = FALSE;
    if (layer_shell != nullptr && args != nullptr &&
        fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
      if (strcmp(method, "show") == 0) {
        done = show(args);
      } else if (strcmp(method, "update") == 0) {
        done = update(args);
      } else {
        done = hide(args);
      }
    }
    g_autoptr(FlValue) result = fl_value_new_bool(done);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  }
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("anyps5/overlay: %s", error->message);
  }
}

}  // namespace

void layer_overlay_probe() {
#ifdef GDK_WINDOWING_WAYLAND
  GdkDisplay* display = gdk_display_get_default();
  if (display == nullptr || !GDK_IS_WAYLAND_DISPLAY(display)) {
    return;
  }
  void* library = dlopen("libgtk-layer-shell.so.0", RTLD_NOW | RTLD_LOCAL);
  if (library == nullptr) {
    return;
  }
  LayerShell* shell = new LayerShell();
  if (!find_symbol(library, "gtk_layer_is_supported", &shell->is_supported) ||
      !find_symbol(library, "gtk_layer_init_for_window",
                   &shell->init_for_window) ||
      !find_symbol(library, "gtk_layer_set_namespace", &shell->set_namespace) ||
      !find_symbol(library, "gtk_layer_set_layer", &shell->set_layer) ||
      !find_symbol(library, "gtk_layer_set_anchor", &shell->set_anchor) ||
      !find_symbol(library, "gtk_layer_set_margin", &shell->set_margin) ||
      !find_symbol(library, "gtk_layer_set_exclusive_zone",
                   &shell->set_exclusive_zone)) {
    // Older than 0.5: nothing of it has run yet, so it can go.
    delete shell;
    dlclose(library);
    return;
  }
  // From here the library may have hooked into GDK's Wayland connection: it stays loaded.
  if (!shell->is_supported()) {
    delete shell;
    return;
  }
  layer_shell = shell;
  GdkMonitor* monitor = gdk_display_get_primary_monitor(display);
  if (monitor == nullptr && gdk_display_get_n_monitors(display) > 0) {
    monitor = gdk_display_get_monitor(display, 0);
  }
  const int scale =
      monitor != nullptr ? gdk_monitor_get_scale_factor(monitor) : 1;
  g_autofree gchar* value = g_strdup_printf("%d", scale > 0 ? scale : 1);
  g_setenv("ANYPS5_LAYER_SHELL", value, TRUE);
#endif
}

void layer_overlay_register(FlBinaryMessenger* messenger) {
  if (overlay_channel != nullptr) {
    return;
  }
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  overlay_channel = fl_method_channel_new(messenger, "anyps5/overlay",
                                          FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(overlay_channel, overlay_method_cb,
                                            nullptr, nullptr);
}
