// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Inkscape for Android — GTK4 ネイティブ版
 *
 * ホスト (デスクトップ GTK4) 上で SVG の読み込みと PNG 書き出しを検証する
 * 小さなテストプログラム。Android では実行しない。
 *
 * 使い方:
 *   render-test <input.svg> <output.png>
 *
 * 検証内容:
 *   - ink_document_new_from_file が成功する
 *   - 幅・高さが正の値になる
 *   - ink_document_render_png が PNG シグネチャと IHDR を持つデータを返す
 *   - PNG の幅・高さが期待値と一致する
 */

#include <gtk/gtk.h>

#include <cmath>
#include <cstdio>
#include <cstring>

#include "ink-document.h"

namespace {

bool
check_png (GBytes *png, int expected_width, int expected_height)
{
  gsize len = 0;
  const guint8 *data = static_cast<const guint8 *> (g_bytes_get_data (png, &len));

  static const guint8 signature[8] = { 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };

  if (len < 33)
    {
      std::fprintf (stderr, "PNG が短すぎます: %zu バイト\n", (size_t) len);
      return false;
    }

  if (std::memcmp (data, signature, sizeof (signature)) != 0)
    {
      std::fprintf (stderr, "PNG シグネチャが一致しません\n");
      return false;
    }

  if (std::memcmp (data + 12, "IHDR", 4) != 0)
    {
      std::fprintf (stderr, "IHDR チャンクがありません\n");
      return false;
    }

  /* IHDR はビッグエンディアンの 32bit 幅・高さを持つ */
  guint32 width = (guint32 (data[16]) << 24) | (guint32 (data[17]) << 16) |
                  (guint32 (data[18]) << 8) | guint32 (data[19]);
  guint32 height = (guint32 (data[20]) << 24) | (guint32 (data[21]) << 16) |
                   (guint32 (data[22]) << 8) | guint32 (data[23]);

  std::printf ("PNG: %u × %u px, %zu バイト\n", width, height, (size_t) len);

  if (int (width) != expected_width || int (height) != expected_height)
    {
      std::fprintf (stderr, "PNG のサイズが想定と違います: %u × %u (期待 %d × %d)\n",
                    width, height, expected_width, expected_height);
      return false;
    }

  return true;
}

} // namespace

int
main (int argc, char **argv)
{
  if (argc != 3)
    {
      std::fprintf (stderr, "使い方: %s <input.svg> <output.png>\n", argv[0]);
      return 2;
    }

  /* GtkSvg は GTK の初期化を必要とする。表示は使わないが、
   * フォントなどの初期化のために gtk_init を呼ぶ。 */
  if (!gtk_init_check ())
    {
      std::fprintf (stderr, "GTK を初期化できませんでした (DISPLAY を確認してください)\n");
      return 2;
    }

  GError *error = nullptr;
  GFile *file = g_file_new_for_path (argv[1]);
  InkDocument *document = ink_document_new_from_file (file, &error);
  g_object_unref (file);

  if (document == nullptr)
    {
      std::fprintf (stderr, "SVG を読み込めませんでした: %s\n",
                    error ? error->message : "(不明なエラー)");
      g_clear_error (&error);
      return 1;
    }

  double width = ink_document_get_width (document);
  double height = ink_document_get_height (document);
  int elements = ink_document_get_element_count (document);

  std::printf ("読み込み: %s — %.0f × %.0f px, %d 要素\n",
               ink_document_get_name (document), width, height, elements);

  bool ok = width > 0.0 && height > 0.0 && elements > 0;

  if (!ok)
    std::fprintf (stderr, "ドキュメントのメタデータが不正です\n");

  if (ok)
    {
      GBytes *png = ink_document_render_png (document, 1.0, &error);

      if (png == nullptr)
        {
          std::fprintf (stderr, "PNG を生成できませんでした: %s\n",
                        error ? error->message : "(不明なエラー)");
          g_clear_error (&error);
          ok = false;
        }
      else
        {
          ok = check_png (png, int (std::lround (width)), int (std::lround (height)));

          if (ok)
            {
              gsize len = 0;
              const void *data = g_bytes_get_data (png, &len);

              if (!g_file_set_contents (argv[2], static_cast<const char *> (data),
                                        gssize (len), &error))
                {
                  std::fprintf (stderr, "PNG を書き込めませんでした: %s\n",
                                error ? error->message : "(不明なエラー)");
                  g_clear_error (&error);
                  ok = false;
                }
              else
                {
                  std::printf ("書き出し: %s\n", argv[2]);
                }
            }

          g_bytes_unref (png);
        }
    }

  ink_document_free (document);

  return ok ? 0 : 1;
}
