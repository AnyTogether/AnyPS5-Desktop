#include "my_application.h"
#include "retro_core_host_linux.h"

#include <cstring>

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"
#include "layer_overlay.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  // "anyps5/window": the launcher asks for full screen and back (F11, its setting), and to
  // minimize (its window buttons in full screen).
  FlMethodChannel* window_channel;
  // The launcher's window (owned by the application).
  GtkWindow* window;
  // Full screen as the launcher last asked for it or heard of it: a change the window manager
  // makes on its own (its full-screen key) is told to the launcher.
  gboolean fullscreen;
  // The launcher's marker of this run ("removeAfterClose"), taken away at shutdown, once the
  // window has closed and Flutter has shut down.
  gchar* run_marker;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// The launcher's "setFullscreen" (a bool): the window full screen or back; "minimize" and
// "restore". GTK asks the window manager, which works on X11 and Wayland alike.
static void window_method_cb(FlMethodChannel* channel,
                             FlMethodCall* method_call, gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  GtkWindow* window = self->window;
  g_autoptr(FlMethodResponse) response = nullptr;
  if (strcmp(fl_method_call_get_name(method_call), "setFullscreen") == 0) {
    FlValue* args = fl_method_call_get_args(method_call);
    if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_BOOL) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "bad_arguments", "setFullscreen takes a bool", nullptr));
    } else {
      self->fullscreen = fl_value_get_bool(args);
      if (fl_value_get_bool(args)) {
        gtk_window_fullscreen(window);
      } else {
        gtk_window_unfullscreen(window);
      }
      g_autoptr(FlValue) result = fl_value_new_bool(TRUE);
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
    }
  } else if (strcmp(fl_method_call_get_name(method_call), "minimize") == 0) {
    // The launcher's own Minimize, full screen having no title bar.
    gtk_window_iconify(window);
    g_autoptr(FlValue) result = fl_value_new_bool(TRUE);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else if (strcmp(fl_method_call_get_name(method_call), "restore") == 0) {
    // Back from minimized once the game it stepped aside for has closed: in front again.
    gtk_window_deiconify(window);
    gtk_window_present(window);
    g_autoptr(FlValue) result = fl_value_new_bool(TRUE);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else if (strcmp(fl_method_call_get_name(method_call), "close") == 0) {
    // The launcher's own close (Quit, the window buttons' close): the close the title bar's
    // button makes (GTK sends it from idle, after this call returns). Flutter asks the
    // launcher, shuts down and the application's loop ends, instead of exit() from Dart with
    // the engine still running.
    gtk_window_close(window);
    g_autoptr(FlValue) result = fl_value_new_bool(TRUE);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else if (strcmp(fl_method_call_get_name(method_call), "removeAfterClose") == 0) {
    FlValue* args = fl_method_call_get_args(method_call);
    if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_STRING) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "bad_arguments", "removeAfterClose takes a path", nullptr));
    } else {
      g_free(self->run_marker);
      self->run_marker = g_strdup(fl_value_get_string(args));
      g_autoptr(FlValue) result = fl_value_new_bool(TRUE);
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
    }
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("anyps5/window: %s", error->message);
  }
}

// Full screen the window manager made or ended on its own (its full-screen key, a tiling
// rule): the launcher hears of it, so its window buttons and its setting follow.
static gboolean window_state_cb(GtkWidget* widget, GdkEventWindowState* event,
                                gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  if ((event->changed_mask & GDK_WINDOW_STATE_FULLSCREEN) == 0) {
    return FALSE;
  }
  const gboolean on =
      (event->new_window_state & GDK_WINDOW_STATE_FULLSCREEN) != 0;
  if (on == self->fullscreen || self->window_channel == nullptr) {
    return FALSE;
  }
  self->fullscreen = on;
  g_autoptr(FlValue) value = fl_value_new_bool(on);
  fl_method_channel_invoke_method(self->window_channel, "fullscreenChanged",
                                  value, nullptr, nullptr, nullptr);
  return FALSE;
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "AnyPS5");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "AnyPS5");
  }

  // The icon the .deb and the AppImage install into the icon theme.
  gtk_window_set_icon_name(window, "anyps5-desktop");
  gtk_window_set_default_size(window, 1600, 900);

  // --fullscreen (AnyPS5's Steam shortcuts pass it for Big Picture): the whole screen from
  // the start. Game Mode's gamescope fills the screen on its own.
  for (char** argument = self->dart_entrypoint_arguments;
       argument != nullptr && *argument != nullptr; argument++) {
    if (g_strcmp0(*argument, "--fullscreen") == 0) {
      self->fullscreen = TRUE;
      gtk_window_fullscreen(window);
      break;
    }
  }

  // The Glass look's see-through window: an RGBA visual where the screen composites, so the
  // pixels Flutter leaves transparent show the desktop. The launcher reads ANYPS5_RGBA_VISUAL
  // and keeps the window opaque without it (no compositor: transparent pixels would be black).
  gboolean rgba = FALSE;
  GdkScreen* rgba_screen = gtk_window_get_screen(window);
  GdkVisual* rgba_visual = gdk_screen_get_rgba_visual(rgba_screen);
  if (rgba_visual != nullptr && gdk_screen_is_composited(rgba_screen)) {
    gtk_widget_set_visual(GTK_WIDGET(window), rgba_visual);
    gtk_widget_set_app_paintable(GTK_WIDGET(window), TRUE);
    g_setenv("ANYPS5_RGBA_VISUAL", "1", TRUE);
    rgba = TRUE;
  }

  // Under Wayland, whether cards can go over the game (layer shell): said in the environment
  // before Flutter starts, as ANYPS5_RGBA_VISUAL is.
  layer_overlay_probe();

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Clear with an RGBA visual: every look but Glass's see-through window paints over all of it.
  gdk_rgba_parse(&background_color, rgba ? "#00000000" : "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));
  g_autoptr(FlPluginRegistrar) retro_registrar =
      fl_plugin_registry_get_registrar_for_plugin(FL_PLUGIN_REGISTRY(view), "AnyPS5RetroCore");
  auto* retro_core = new RetroCoreHostLinux(retro_registrar);
  // Stop notifications before the view's disposal releases its engine.
  g_signal_connect(view, "destroy", G_CALLBACK(+[](GtkWidget*, gpointer host) {
    static_cast<RetroCoreHostLinux*>(host)->Shutdown();
  }), retro_core);
  // Retain the texture owner until the view's engine has quiesced its renderer.
  g_object_set_data_full(G_OBJECT(view), "anyps5-retro-core", retro_core,
                         [](gpointer host) { delete static_cast<RetroCoreHostLinux*>(host); });

  g_autoptr(FlPluginRegistrar) window_registrar =
      fl_plugin_registry_get_registrar_for_plugin(FL_PLUGIN_REGISTRY(view),
                                                  "AnyPS5Window");
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_clear_object(&self->window_channel);
  self->window_channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(window_registrar), "anyps5/window",
      FL_METHOD_CODEC(codec));
  self->window = window;
  fl_method_channel_set_method_call_handler(self->window_channel,
                                            window_method_cb, self, nullptr);
  g_signal_connect(window, "window-state-event", G_CALLBACK(window_state_cb),
                   self);
  layer_overlay_register(fl_plugin_registrar_get_messenger(window_registrar));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

gchar* my_application_take_run_marker(MyApplication* self) {
  gchar* marker = self->run_marker;
  self->run_marker = nullptr;
  return marker;
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_pointer(&self->run_marker, g_free);
  g_clear_object(&self->window_channel);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
