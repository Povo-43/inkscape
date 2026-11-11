// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Inkscape for Android — GTK4 ネイティブ版
 *
 * SVG ドキュメントを表示するためのキャンバスウィジェット。
 * ピンチズーム・ドラッグでのパン・ホイールズームに対応する。
 */

#pragma once

#include <gtk/gtk.h>

G_BEGIN_DECLS

#define INK_TYPE_CANVAS (ink_canvas_get_type ())

G_DECLARE_FINAL_TYPE (InkCanvas, ink_canvas, INK, CANVAS, GtkWidget)

GtkWidget     *ink_canvas_new           (void);

void           ink_canvas_set_paintable (InkCanvas   *self,
                                         GdkPaintable *paintable);

GdkPaintable  *ink_canvas_get_paintable (InkCanvas   *self);

/* 1.0 = SVG の 1 ユーザー単位を 1 論理ピクセルで表示する。 */
void           ink_canvas_set_zoom      (InkCanvas   *self,
                                         double       zoom);

double         ink_canvas_get_zoom      (InkCanvas   *self);

void           ink_canvas_zoom_fit      (InkCanvas   *self);

void           ink_canvas_zoom_reset    (InkCanvas   *self);

void           ink_canvas_zoom_in       (InkCanvas   *self);

void           ink_canvas_zoom_out      (InkCanvas   *self);

G_END_DECLS
