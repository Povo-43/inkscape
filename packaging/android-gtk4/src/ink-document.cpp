// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Inkscape for Android — GTK4 ネイティブ版
 *
 * SVG ドキュメントの読み込みと PNG への書き出し。
 *
 * 表示には GTK 4.22 で追加された GtkSvg (GdkPaintable 実装) を使う。
 * これにより librsvg や resvg を追加でリンクする必要がない。
 */

#include "ink-document.h"

#include <math.h>
#include <string.h>

struct _InkDocument
{
  GBytes *bytes;
  char *name;
  GtkSvg *svg;
  double width;
  double height;
  int element_count;
};

/* ------------------------------------------------------------------------- *
 * 補助関数
 * ------------------------------------------------------------------------- */

static gboolean
is_gzip_data (const guint8 *data,
              gsize         len)
{
  return len >= 2 && data[0] == 0x1f && data[1] == 0x8b;
}

/*
 * SVGZ (.svgz) を伸長する。GtkSvg は gzip 圧縮された入力を扱わないため、
 * 読み込み時にここで解凍する。
 */
static GBytes *
maybe_decompress (GBytes  *bytes,
                  GError **error)
{
  const guint8 *data;
  gsize len;
  GZlibDecompressor *decompressor;
  GInputStream *mem;
  GInputStream *converted;
  GOutputStream *out;
  gssize copied;
  GByteArray *result;

  data = static_cast<const guint8 *> (g_bytes_get_data (bytes, &len));

  if (!is_gzip_data (data, len))
    return g_bytes_ref (bytes);

  decompressor = g_zlib_decompressor_new (G_ZLIB_COMPRESSOR_FORMAT_GZIP);
  mem = g_memory_input_stream_new_from_bytes (bytes);
  converted = g_converter_input_stream_new (mem, G_CONVERTER (decompressor));
  out = g_memory_output_stream_new_resizable ();

  g_object_unref (mem);
  g_object_unref (decompressor);

  copied = g_output_stream_splice (out,
                                   converted,
                                   G_OUTPUT_STREAM_SPLICE_CLOSE_SOURCE,
                                   NULL,
                                   error);
  g_object_unref (converted);

  if (copied < 0)
    {
      g_object_unref (out);
      return NULL;
    }

  result = static_cast<GByteArray *> (
      g_memory_output_stream_get_data (G_MEMORY_OUTPUT_STREAM (out)));

  {
    GBytes *out_bytes = g_bytes_new (result->data, result->len);
    g_object_unref (out);
    return out_bytes;
  }
}

/*
 * SVG の要素数をざっくり数える。XML 宣言・コメント・DOCTYPE は除外する。
 * 完全なパーサではなく、ステータス表示用の目安。
 */
static int
count_svg_elements (const char *data,
                    gsize       len)
{
  int count = 0;
  gsize i = 0;

  while (i < len)
    {
      if (data[i] != '<')
        {
          i++;
          continue;
        }

      if (i + 1 >= len)
        break;

      if (data[i + 1] == '?' || data[i + 1] == '!')
        {
          /* XML 宣言 / コメント / DOCTYPE / CDATA をスキップ */
          if (i + 3 < len && g_str_has_prefix (data + i, "<!--"))
            {
              const char *end = g_strstr_len (data + i + 4, (gssize) (len - i - 4), "-->");
              i = end ? (gsize) (end - data) + 3 : len;
            }
          else
            {
              const char *end = static_cast<const char *> (memchr (data + i, '>', len - i));
              i = end ? (gsize) (end - data) + 1 : len;
            }
          continue;
        }

      if (g_ascii_isalpha (data[i + 1]) || data[i + 1] == '_')
        count++;

      /* タグの終わりまで進める (属性内の '>' は考慮しない簡易版) */
      {
        const char *end = static_cast<const char *> (memchr (data + i, '>', len - i));
        i = end ? (gsize) (end - data) + 1 : len;
      }
    }

  return count;
}

/* ------------------------------------------------------------------------- *
 * 構築 / 破棄
 * ------------------------------------------------------------------------- */

InkDocument *
ink_document_new_from_bytes (GBytes  *bytes,
                             const char *name,
                             GError **error)
{
  InkDocument *self;
  GBytes *svg_bytes;
  const char *data;
  gsize len;

  g_return_val_if_fail (bytes != NULL, NULL);

  svg_bytes = maybe_decompress (bytes, error);
  if (svg_bytes == NULL)
    return NULL;

  data = static_cast<const char *> (g_bytes_get_data (svg_bytes, &len));

  self = g_new0 (InkDocument, 1);
  self->bytes = g_bytes_ref (svg_bytes);
  self->name = g_strdup (name ? name : "Untitled.svg");
  self->svg = gtk_svg_new_from_bytes (svg_bytes);
  self->element_count = count_svg_elements (data, len);

  g_bytes_unref (svg_bytes);

  if (self->svg == NULL)
    {
      g_set_error_literal (error, GTK_SVG_ERROR, GTK_SVG_ERROR_INVALID_SYNTAX,
                           "SVG を解析できませんでした。");
      ink_document_free (self);
      return NULL;
    }

  self->width = gdk_paintable_get_intrinsic_width (GDK_PAINTABLE (self->svg));
  self->height = gdk_paintable_get_intrinsic_height (GDK_PAINTABLE (self->svg));

  if (self->width <= 0.0 || self->height <= 0.0)
    {
      g_set_error_literal (error, GTK_SVG_ERROR, GTK_SVG_ERROR_MISSING_ATTRIBUTE,
                           "SVG の幅・高さを判別できませんでした。");
      ink_document_free (self);
      return NULL;
    }

  return self;
}

InkDocument *
ink_document_new_from_file (GFile  *file,
                            GError **error)
{
  char *contents = NULL;
  gsize length = 0;
  char *basename;
  GBytes *bytes;
  InkDocument *self;

  if (!g_file_load_contents (file, NULL, &contents, &length, NULL, error))
    return NULL;

  bytes = g_bytes_new_take (contents, length);
  basename = g_file_get_basename (file);
  self = ink_document_new_from_bytes (bytes, basename, error);
  g_free (basename);
  g_bytes_unref (bytes);

  return self;
}

void
ink_document_free (InkDocument *self)
{
  if (self == NULL)
    return;

  g_clear_object (&self->svg);
  g_clear_pointer (&self->bytes, g_bytes_unref);
  g_free (self->name);
  g_free (self);
}

const char *
ink_document_get_name (InkDocument *self)
{
  return self ? self->name : NULL;
}

GdkPaintable *
ink_document_get_paintable (InkDocument *self)
{
  return self ? GDK_PAINTABLE (self->svg) : NULL;
}

double
ink_document_get_width (InkDocument *self)
{
  return self ? self->width : 0.0;
}

double
ink_document_get_height (InkDocument *self)
{
  return self ? self->height : 0.0;
}

int
ink_document_get_element_count (InkDocument *self)
{
  return self ? self->element_count : 0;
}

/* ------------------------------------------------------------------------- *
 * PNG 書き出し
 * ------------------------------------------------------------------------- */

static cairo_status_t
write_png_to_byte_array (void               *closure,
                         const unsigned char *data,
                         unsigned int         length)
{
  g_byte_array_append (static_cast<GByteArray *> (closure), data, length);
  return CAIRO_STATUS_SUCCESS;
}

GBytes *
ink_document_render_png (InkDocument *self,
                         double       scale,
                         GError     **error)
{
  GtkSnapshot *snapshot;
  GskRenderNode *node;
  cairo_surface_t *surface;
  cairo_t *cr;
  GByteArray *png;
  cairo_status_t status;
  int width, height;
  const double max_dimension = 8192.0;

  g_return_val_if_fail (self != NULL, NULL);

  if (self->svg == NULL || self->width <= 0.0 || self->height <= 0.0)
    {
      g_set_error_literal (error, GTK_SVG_ERROR, GTK_SVG_ERROR_FAILED_RENDERING,
                           "ドキュメントが読み込まれていません。");
      return NULL;
    }

  if (scale <= 0.0)
    scale = 1.0;

  /* 出力が大きくなりすぎないように上限を設ける */
  if (self->width * scale > max_dimension || self->height * scale > max_dimension)
    scale = MIN (max_dimension / self->width, max_dimension / self->height);

  width = MAX (1, (int) ceil (self->width * scale));
  height = MAX (1, (int) ceil (self->height * scale));

  snapshot = gtk_snapshot_new ();
  gdk_paintable_snapshot (GDK_PAINTABLE (self->svg), snapshot, width, height);
  node = gtk_snapshot_free_to_node (snapshot);

  if (node == NULL)
    {
      g_set_error_literal (error, GTK_SVG_ERROR, GTK_SVG_ERROR_FAILED_RENDERING,
                           "SVG をラスタライズできませんでした。");
      return NULL;
    }

  surface = cairo_image_surface_create (CAIRO_FORMAT_ARGB32, width, height);
  cr = cairo_create (surface);
  gsk_render_node_draw (node, cr);
  cairo_destroy (cr);
  gsk_render_node_unref (node);

  status = cairo_surface_status (surface);
  if (status != CAIRO_STATUS_SUCCESS)
    {
      g_set_error (error, GTK_SVG_ERROR, GTK_SVG_ERROR_FAILED_RENDERING,
                   "PNG サーフェスを作成できませんでした: %s",
                   cairo_status_to_string (status));
      cairo_surface_destroy (surface);
      return NULL;
    }

  png = g_byte_array_new ();
  status = cairo_surface_write_to_png_stream (surface, write_png_to_byte_array, png);
  cairo_surface_destroy (surface);

  if (status != CAIRO_STATUS_SUCCESS)
    {
      g_set_error (error, GTK_SVG_ERROR, GTK_SVG_ERROR_FAILED_RENDERING,
                   "PNG を書き出せませんでした: %s",
                   cairo_status_to_string (status));
      g_byte_array_unref (png);
      return NULL;
    }

  {
    gsize png_len = png->len;
    guint8 *png_data = g_byte_array_free (png, FALSE);
    return g_bytes_new_take (png_data, png_len);
  }
}
