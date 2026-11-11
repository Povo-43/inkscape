// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Inkscape for Android — GTK4 ネイティブ版
 *
 * SVG ドキュメントを表示するためのキャンバスウィジェット。
 * ピンチズーム・ドラッグでのパン・ホイールズームに対応する。
 *
 * Inkscape 本体 (actions-canvas-transform.cpp) のキャンバス変換アクション
 * (ズーム・回転・反転) に合わせた API を提供する。
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

/* ズームプリセット (Inkscape の canvas-zoom-* アクションに対応) */
void           ink_canvas_zoom_fit      (InkCanvas   *self);   /* ページにフィット */
void           ink_canvas_zoom_page     (InkCanvas   *self);   /* ページにフィット (同義) */
void           ink_canvas_zoom_page_width (InkCanvas *self);   /* ページ幅にフィット */
void           ink_canvas_zoom_center_page (InkCanvas *self);  /* ページを中央に (100%) */
void           ink_canvas_zoom_reset    (InkCanvas   *self);   /* 100% 表示 */
void           ink_canvas_zoom_1_2      (InkCanvas   *self);   /* 50% 表示 */
void           ink_canvas_zoom_1_1      (InkCanvas   *self);   /* 100% 表示 */
void           ink_canvas_zoom_2_1      (InkCanvas   *self);   /* 200% 表示 */
void           ink_canvas_zoom_in       (InkCanvas   *self);   /* ズームイン */
void           ink_canvas_zoom_out      (InkCanvas   *self);   /* ズームアウト */

/* 回転 (Inkscape の canvas-rotate-* アクションに対応) */
void           ink_canvas_rotate_cw     (InkCanvas   *self);   /* 時計回り回転 */
void           ink_canvas_rotate_ccw    (InkCanvas   *self);   /* 反時計回り回転 */
void           ink_canvas_rotate_reset  (InkCanvas   *self);   /* 回転リセット */

/* 反転 (Inkscape の canvas-flip-* アクションに対応) */
void           ink_canvas_flip_horizontal (InkCanvas *self);   /* 水平反転 */
void           ink_canvas_flip_vertical   (InkCanvas *self);   /* 垂直反転 */
void           ink_canvas_flip_reset      (InkCanvas *self);   /* 反転リセット */

G_END_DECLS
