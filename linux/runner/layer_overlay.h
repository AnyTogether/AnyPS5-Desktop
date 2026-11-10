#ifndef RUNNER_LAYER_OVERLAY_H_
#define RUNNER_LAYER_OVERLAY_H_

#include <flutter_linux/flutter_linux.h>

// Cards and the LIVE badge over the game under Wayland, where a client cannot place a window
// above another program's: a wlr-layer-shell surface on the overlay layer, drawn above
// full-screen windows. Compositors with the protocol: KDE Plasma, Sway, Hyprland and the other
// wlroots ones; GNOME has none, and keeps the system notification.
//
// gtk-layer-shell (GTK 3) is loaded at run time with dlopen, never linked: the launcher starts
// where it is not installed, and the system's copy always matches the system's GTK, which the
// library reaches into.

// Under Wayland, loads gtk-layer-shell and asks whether the compositor offers
// zwlr_layer_shell_v1. When it does, ANYPS5_LAYER_SHELL is set to the first monitor's scale
// factor, for the launcher to read. Call once GTK is up, before Flutter starts.
void layer_overlay_probe();

// "anyps5/overlay": "show", "update" and "hide" for one named surface ("card", "badge").
void layer_overlay_register(FlBinaryMessenger* messenger);

#endif  // RUNNER_LAYER_OVERLAY_H_
