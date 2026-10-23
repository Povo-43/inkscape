// SPDX-License-Identifier: GPL-2.0-or-later
#ifndef INKSCAPE_UI_MACOS_WINDOW_ANIMATION_H
#define INKSCAPE_UI_MACOS_WINDOW_ANIMATION_H

typedef struct _GtkWindow GtkWindow;

namespace Inkscape::UI::MacOS {
// Call after realization and before the native surface is destroyed.
void enable_window_animation(GtkWindow *window);
void disable_window_animation(GtkWindow *window);
} // namespace Inkscape::UI::MacOS

#endif
