// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Inkscape for Android — GTK4 ネイティブ版
 *
 * SVG ドキュメントの読み込みと PNG への書き出し。
 */

#pragma once

#include <gtk/gtk.h>

G_BEGIN_DECLS

typedef struct _InkDocument InkDocument;

InkDocument  *ink_document_new_from_bytes (GBytes       *bytes,
                                           const char   *name,
                                           GError      **error);

InkDocument  *ink_document_new_from_file  (GFile        *file,
                                           GError      **error);

void          ink_document_free           (InkDocument  *self);

const char   *ink_document_get_name       (InkDocument  *self);

GdkPaintable *ink_document_get_paintable  (InkDocument  *self);

double        ink_document_get_width      (InkDocument  *self);

double        ink_document_get_height     (InkDocument  *self);

int           ink_document_get_element_count (InkDocument *self);

/* SVG を PNG にレンダリングする。scale は 1.0 で 96dpi 相当。 */
GBytes       *ink_document_render_png     (InkDocument  *self,
                                           double        scale,
                                           GError      **error);

G_END_DECLS
