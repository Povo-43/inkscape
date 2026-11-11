// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Inkscape for Android — GTK4 ネイティブ版 (実験的)
 *
 * これまでの Android 版は Kotlin + Android View で UI を組んでいたが、
 * このアプリは GTK4 の Android バックエンド (GTK 4.22 以降) を使って
 * GTK4 ウィジェットそのものを Android 上で動かす。
 *
 * レンダリングには GTK 4.22 で追加された GtkSvg (GdkPaintable 実装) を使う。
 * librsvg や resvg を別途リンクする必要がない。
 *
 * このファイルは Android 固有コードであり、元の Inkscape C++ コードには
 * 一切手を加えていない。将来的に Inkscape 本体 (gtkmm4) の UI へ
 * 段階的に置き換えていくための土台となる。
 */

#include <gtk/gtk.h>

#include <cstring>

#include "ink-canvas.h"
#include "ink-document.h"

namespace {

const char *kSampleSvg =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"420\" height=\"320\" "
    "viewBox=\"0 0 420 320\">\n"
    "  <defs>\n"
    "    <linearGradient id=\"bg\" x1=\"0\" y1=\"0\" x2=\"0\" y2=\"1\">\n"
    "      <stop offset=\"0\" stop-color=\"#ffffff\"/>\n"
    "      <stop offset=\"1\" stop-color=\"#e8eef7\"/>\n"
    "    </linearGradient>\n"
    "    <linearGradient id=\"pen\" x1=\"0\" y1=\"0\" x2=\"1\" y2=\"1\">\n"
    "      <stop offset=\"0\" stop-color=\"#4a90e2\"/>\n"
    "      <stop offset=\"1\" stop-color=\"#2c5282\"/>\n"
    "    </linearGradient>\n"
    "  </defs>\n"
    "  <rect width=\"420\" height=\"320\" fill=\"url(#bg)\"/>\n"
    "  <path d=\"M 30 260 L 110 190 L 170 230 L 250 140 L 330 200 L 390 150\" "
    "fill=\"none\" stroke=\"url(#pen)\" stroke-width=\"10\" "
    "stroke-linecap=\"round\" stroke-linejoin=\"round\"/>\n"
    "  <circle cx=\"250\" cy=\"140\" r=\"16\" fill=\"#e53935\"/>\n"
    "  <rect x=\"60\" y=\"60\" width=\"120\" height=\"80\" rx=\"12\" "
    "fill=\"#43a047\" opacity=\"0.85\"/>\n"
    "  <text x=\"210\" y=\"60\" text-anchor=\"middle\" font-family=\"sans-serif\" "
    "font-size=\"26\" fill=\"#222222\">Inkscape on GTK4</text>\n"
    "  <text x=\"210\" y=\"300\" text-anchor=\"middle\" font-family=\"sans-serif\" "
    "font-size=\"14\" fill=\"#555555\">SVG · GtkSvg renderer · Android</text>\n"
    "</svg>\n";

struct InkApp
{
  GtkApplication *application;
  GtkApplicationWindow *window;
  GtkWidget *canvas;
  GtkLabel *status;
  GtkLabel *title;
  GtkWidget *export_button;
  InkDocument *document;
  GtkFileDialog *open_dialog;
  GtkFileDialog *save_dialog;
};

InkApp ink;

void update_status ()
{
  if (ink.document == nullptr)
    {
      gtk_label_set_text (ink.status, "ドキュメントが開かれていません");
      return;
    }

  double zoom = ink_canvas_get_zoom (INK_CANVAS (ink.canvas));
  char *text = g_strdup_printf ("%s  ·  %.0f × %.0f px  ·  %d 要素  ·  %.0f%%",
                                ink_document_get_name (ink.document),
                                ink_document_get_width (ink.document),
                                ink_document_get_height (ink.document),
                                ink_document_get_element_count (ink.document),
                                zoom * 100.0);
  gtk_label_set_text (ink.status, text);
  g_free (text);
}

void show_error (const char *message)
{
  GtkAlertDialog *dialog = gtk_alert_dialog_new ("%s", message);
  gtk_alert_dialog_set_detail (dialog, message);
  gtk_alert_dialog_show (dialog, GTK_WINDOW (ink.window));
  g_object_unref (dialog);
}

void set_document (InkDocument *document)
{
  if (ink.document != nullptr)
    ink_document_free (ink.document);

  ink.document = document;

  if (document == nullptr)
    {
      ink_canvas_set_paintable (INK_CANVAS (ink.canvas), nullptr);
      gtk_label_set_text (ink.title, "Inkscape GTK4");
      gtk_widget_set_sensitive (ink.export_button, FALSE);
    }
  else
    {
      ink_canvas_set_paintable (INK_CANVAS (ink.canvas),
                                ink_document_get_paintable (document));
      gtk_label_set_text (ink.title, ink_document_get_name (document));
      gtk_widget_set_sensitive (ink.export_button, TRUE);
    }

  update_status ();
}

/* ------------------------------------------------------------------ *
 * アクション
 * ------------------------------------------------------------------ */

void on_open_finished (GtkFileDialog *dialog, GAsyncResult *result, gpointer)
{
  GError *error = nullptr;
  GFile *file = gtk_file_dialog_open_finish (dialog, result, &error);

  if (file == nullptr)
    {
      if (!g_error_matches (error, GTK_DIALOG_ERROR, GTK_DIALOG_ERROR_DISMISSED) &&
          !g_error_matches (error, G_IO_ERROR, G_IO_ERROR_CANCELLED))
        show_error (error ? error->message : "ファイルを開けませんでした。");
      g_clear_error (&error);
      return;
    }

  char *basename = g_file_get_basename (file);
  char *loading = g_strdup_printf ("読み込み中: %s", basename);
  gtk_label_set_text (ink.status, loading);
  g_free (loading);
  g_free (basename);

  InkDocument *document = ink_document_new_from_file (file, &error);
  g_object_unref (file);

  if (document == nullptr)
    {
      show_error (error ? error->message : "SVG を読み込めませんでした。");
      g_clear_error (&error);
      update_status ();
      return;
    }

  set_document (document);
}

void on_save_finished (GtkFileDialog *dialog, GAsyncResult *result, gpointer)
{
  GError *error = nullptr;
  GFile *file = gtk_file_dialog_save_finish (dialog, result, &error);

  if (file == nullptr)
    {
      if (!g_error_matches (error, GTK_DIALOG_ERROR, GTK_DIALOG_ERROR_DISMISSED) &&
          !g_error_matches (error, G_IO_ERROR, G_IO_ERROR_CANCELLED))
        show_error (error ? error->message : "保存先を選択できませんでした。");
      g_clear_error (&error);
      return;
    }

  GBytes *png = ink_document_render_png (ink.document, 2.0, &error);

  if (png == nullptr)
    {
      show_error (error ? error->message : "PNG を生成できませんでした。");
      g_clear_error (&error);
      g_object_unref (file);
      return;
    }

  gsize size = 0;
  const void *data = g_bytes_get_data (png, &size);

  gboolean ok = g_file_replace_contents (file, static_cast<const char *> (data), size,
                                         nullptr, FALSE,
                                         G_FILE_CREATE_REPLACE_DESTINATION,
                                         nullptr, nullptr, &error);
  g_bytes_unref (png);

  if (!ok)
    {
      show_error (error ? error->message : "PNG を保存できませんでした。");
      g_clear_error (&error);
    }
  else
    {
      char *basename = g_file_get_basename (file);
      char *message = g_strdup_printf ("PNG を書き出しました: %s", basename);
      gtk_label_set_text (ink.status, message);
      g_free (message);
      g_free (basename);
    }

  g_object_unref (file);
}

void action_open (GSimpleAction *, GVariant *, gpointer)
{
  if (ink.open_dialog == nullptr)
    {
      GtkFileFilter *filter = gtk_file_filter_new ();
      gtk_file_filter_set_name (filter, "SVG 画像 (*.svg, *.svgz)");
      gtk_file_filter_add_mime_type (filter, "image/svg+xml");
      gtk_file_filter_add_pattern (filter, "*.svg");
      gtk_file_filter_add_pattern (filter, "*.svgz");

      GListStore *filters = g_list_store_new (GTK_TYPE_FILE_FILTER);
      g_list_store_append (filters, filter);
      g_object_unref (filter);

      ink.open_dialog = gtk_file_dialog_new ();
      gtk_file_dialog_set_title (ink.open_dialog, "SVG を開く");
      gtk_file_dialog_set_filters (ink.open_dialog, G_LIST_MODEL (filters));
      g_object_unref (filters);
    }

  gtk_file_dialog_open (ink.open_dialog, GTK_WINDOW (ink.window), nullptr,
                        (GAsyncReadyCallback) on_open_finished, nullptr);
}

void action_export (GSimpleAction *, GVariant *, gpointer)
{
  if (ink.document == nullptr)
    return;

  if (ink.save_dialog == nullptr)
    {
      GtkFileFilter *filter = gtk_file_filter_new ();
      gtk_file_filter_set_name (filter, "PNG 画像 (*.png)");
      gtk_file_filter_add_mime_type (filter, "image/png");
      gtk_file_filter_add_pattern (filter, "*.png");

      GListStore *filters = g_list_store_new (GTK_TYPE_FILE_FILTER);
      g_list_store_append (filters, filter);
      g_object_unref (filter);

      ink.save_dialog = gtk_file_dialog_new ();
      gtk_file_dialog_set_title (ink.save_dialog, "PNG として書き出す");
      gtk_file_dialog_set_filters (ink.save_dialog, G_LIST_MODEL (filters));
      g_object_unref (filters);
    }

  const char *name = ink_document_get_name (ink.document);
  char *base = g_strdup (name ? name : "drawing.svg");
  char *dot = strrchr (base, '.');
  if (dot != nullptr)
    *dot = '\0';
  char *png_name = g_strdup_printf ("%s.png", base);
  gtk_file_dialog_set_initial_name (ink.save_dialog, png_name);
  g_free (png_name);
  g_free (base);

  gtk_file_dialog_save (ink.save_dialog, GTK_WINDOW (ink.window), nullptr,
                        (GAsyncReadyCallback) on_save_finished, nullptr);
}

void action_zoom_in (GSimpleAction *, GVariant *, gpointer)
{
  ink_canvas_zoom_in (INK_CANVAS (ink.canvas));
}

void action_zoom_out (GSimpleAction *, GVariant *, gpointer)
{
  ink_canvas_zoom_out (INK_CANVAS (ink.canvas));
}

void action_zoom_fit (GSimpleAction *, GVariant *, gpointer)
{
  ink_canvas_zoom_fit (INK_CANVAS (ink.canvas));
}

void action_zoom_reset (GSimpleAction *, GVariant *, gpointer)
{
  ink_canvas_zoom_reset (INK_CANVAS (ink.canvas));
}

void action_about (GSimpleAction *, GVariant *, gpointer)
{
  GtkAlertDialog *dialog = gtk_alert_dialog_new ("Inkscape GTK4 for Android");
  gtk_alert_dialog_set_detail (dialog,
                               "GTK4 ネイティブ版の実験的ビルドです。\n\n"
                               "UI: GTK4 (Android バックエンド)\n"
                               "レンダリング: GtkSvg (GTK 4.22+)\n"
                               "バージョン: 0.2.0\n\n"
                               "Inkscape 本体 (gtkmm4) への段階的な移植を進めています。");
  gtk_alert_dialog_show (dialog, GTK_WINDOW (ink.window));
  g_object_unref (dialog);
}

const GActionEntry kAppActions[] = {
  { "open", G_CALLBACK (action_open), nullptr, nullptr, nullptr, { 0, 0, 0 } },
  { "export", G_CALLBACK (action_export), nullptr, nullptr, nullptr, { 0, 0, 0 } },
  { "zoom-in", G_CALLBACK (action_zoom_in), nullptr, nullptr, nullptr, { 0, 0, 0 } },
  { "zoom-out", G_CALLBACK (action_zoom_out), nullptr, nullptr, nullptr, { 0, 0, 0 } },
  { "zoom-fit", G_CALLBACK (action_zoom_fit), nullptr, nullptr, nullptr, { 0, 0, 0 } },
  { "zoom-reset", G_CALLBACK (action_zoom_reset), nullptr, nullptr, nullptr, { 0, 0, 0 } },
  { "about", G_CALLBACK (action_about), nullptr, nullptr, nullptr, { 0, 0, 0 } },
};

/* ------------------------------------------------------------------ *
 * UI 構築
 * ------------------------------------------------------------------ */

GtkWidget *make_tool_button (const char *icon_name, const char *tooltip, const char *action)
{
  GtkWidget *button = gtk_button_new_from_icon_name (icon_name);
  gtk_widget_set_tooltip_text (button, tooltip);
  gtk_widget_set_hexpand (button, TRUE);
  gtk_widget_set_size_request (button, -1, 48);
  gtk_actionable_set_action_name (GTK_ACTIONABLE (button), action);
  return button;
}

void on_zoom_changed (GObject *, GParamSpec *, gpointer)
{
  update_status ();
}

void build_window (GtkApplication *application)
{
  GtkWidget *header = gtk_header_bar_new ();
  GtkWidget *menu_button = gtk_menu_button_new ();
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  GtkWidget *status_bar = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  GtkWidget *toolbar = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 6);

  ink.application = application;
  ink.window = GTK_APPLICATION_WINDOW (gtk_application_window_new (application));

  gtk_window_set_title (GTK_WINDOW (ink.window), "Inkscape GTK4");
  gtk_window_set_default_size (GTK_WINDOW (ink.window), 900, 700);

  /* ヘッダーバー */
  ink.title = GTK_LABEL (gtk_label_new ("Inkscape GTK4"));
  gtk_label_set_ellipsize (ink.title, PANGO_ELLIPSIZE_MIDDLE);
  gtk_header_bar_set_title_widget (GTK_HEADER_BAR (header), GTK_WIDGET (ink.title));

  GMenu *menu = g_menu_new ();
  g_menu_append (menu, "SVG を開く…", "app.open");
  g_menu_append (menu, "PNG として書き出す…", "app.export");
  g_menu_append (menu, "ページにフィット", "app.zoom-fit");
  g_menu_append (menu, "100% 表示", "app.zoom-reset");
  g_menu_append (menu, "バージョン情報", "app.about");

  gtk_menu_button_set_icon_name (GTK_MENU_BUTTON (menu_button), "open-menu-symbolic");
  gtk_menu_button_set_menu_model (GTK_MENU_BUTTON (menu_button), G_MENU_MODEL (menu));
  gtk_widget_set_tooltip_text (menu_button, "メニュー");
  gtk_header_bar_pack_end (GTK_HEADER_BAR (header), menu_button);
  g_object_unref (menu);

  gtk_window_set_titlebar (GTK_WINDOW (ink.window), header);

  /* キャンバス */
  ink.canvas = ink_canvas_new ();
  g_signal_connect (ink.canvas, "notify::zoom", G_CALLBACK (on_zoom_changed), nullptr);

  /* ステータス行 */
  ink.status = GTK_LABEL (gtk_label_new ("ドキュメントが開かれていません"));
  gtk_label_set_ellipsize (ink.status, PANGO_ELLIPSIZE_END);
  gtk_label_set_xalign (ink.status, 0.0f);
  gtk_widget_set_margin_start (GTK_WIDGET (ink.status), 12);
  gtk_widget_set_margin_end (GTK_WIDGET (ink.status), 12);
  gtk_widget_set_margin_top (GTK_WIDGET (ink.status), 4);
  gtk_widget_set_margin_bottom (GTK_WIDGET (ink.status), 4);
  gtk_widget_add_css_class (GTK_WIDGET (ink.status), "dim-label");
  gtk_box_append (GTK_BOX (status_bar), GTK_WIDGET (ink.status));

  /* ツールバー (タッチ操作向けの大きなボタン) */
  gtk_box_set_homogeneous (GTK_BOX (toolbar), TRUE);
  gtk_widget_set_margin_start (toolbar, 6);
  gtk_widget_set_margin_end (toolbar, 6);
  gtk_widget_set_margin_top (toolbar, 4);
  gtk_widget_set_margin_bottom (toolbar, 6);

  GtkWidget *open_button = make_tool_button ("document-open-symbolic", "SVG を開く", "app.open");
  GtkWidget *zoom_out_button = make_tool_button ("zoom-out-symbolic", "縮小", "app.zoom-out");
  GtkWidget *zoom_fit_button = make_tool_button ("zoom-original-symbolic", "ページにフィット", "app.zoom-fit");
  GtkWidget *zoom_in_button = make_tool_button ("zoom-in-symbolic", "拡大", "app.zoom-in");
  ink.export_button = make_tool_button ("document-save-as-symbolic", "PNG として書き出す", "app.export");
  gtk_widget_set_sensitive (ink.export_button, FALSE);

  gtk_box_append (GTK_BOX (toolbar), open_button);
  gtk_box_append (GTK_BOX (toolbar), zoom_out_button);
  gtk_box_append (GTK_BOX (toolbar), zoom_fit_button);
  gtk_box_append (GTK_BOX (toolbar), zoom_in_button);
  gtk_box_append (GTK_BOX (toolbar), ink.export_button);

  gtk_box_append (GTK_BOX (box), ink.canvas);
  gtk_box_append (GTK_BOX (box), status_bar);
  gtk_box_append (GTK_BOX (box), toolbar);

  gtk_window_set_child (GTK_WINDOW (ink.window), box);

  /* 起動時はサンプル SVG を表示する */
  GBytes *sample = g_bytes_new_static (kSampleSvg, std::strlen (kSampleSvg));
  GError *error = nullptr;
  InkDocument *document = ink_document_new_from_bytes (sample, "welcome.svg", &error);
  g_bytes_unref (sample);

  if (document != nullptr)
    set_document (document);
  else
    {
      if (error != nullptr)
        g_warning ("サンプル SVG を読み込めませんでした: %s", error->message);
      g_clear_error (&error);
      update_status ();
    }

  gtk_window_present (GTK_WINDOW (ink.window));
}

void on_activate (GtkApplication *application, gpointer)
{
  if (ink.window != nullptr)
    {
      gtk_window_present (GTK_WINDOW (ink.window));
      return;
    }

  build_window (application);
}

void on_startup (GtkApplication *application, gpointer)
{
  static const char *accels_open[] = { "<Control>o", nullptr };
  static const char *accels_export[] = { "<Control>e", nullptr };
  static const char *accels_zoom_in[] = { "<Control>plus", "<Control>equal", nullptr };
  static const char *accels_zoom_out[] = { "<Control>minus", nullptr };
  static const char *accels_zoom_fit[] = { "<Control>0", nullptr };
  static const char *accels_zoom_reset[] = { "<Control>1", nullptr };

  g_action_map_add_action_entries (G_ACTION_MAP (application), kAppActions,
                                   G_N_ELEMENTS (kAppActions), nullptr);

  gtk_application_set_accels_for_action (application, "app.open", accels_open);
  gtk_application_set_accels_for_action (application, "app.export", accels_export);
  gtk_application_set_accels_for_action (application, "app.zoom-in", accels_zoom_in);
  gtk_application_set_accels_for_action (application, "app.zoom-out", accels_zoom_out);
  gtk_application_set_accels_for_action (application, "app.zoom-fit", accels_zoom_fit);
  gtk_application_set_accels_for_action (application, "app.zoom-reset", accels_zoom_reset);

  GtkCssProvider *css = gtk_css_provider_new ();
  gtk_css_provider_load_from_string (css,
                                     "inkcanvas { background-color: #2b2b2b; }\n"
                                     ".dim-label { opacity: 0.7; font-size: 0.9em; }\n");
  gtk_style_context_add_provider_for_display (gdk_display_get_default (),
                                              GTK_STYLE_PROVIDER (css),
                                              GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
  g_object_unref (css);
}

} // namespace

/*
 * Android では meson の android_exe_type: 'application' により、
 * この main が JNI 経由で呼ばれる。
 */
extern "C" int main (int argc, char **argv, char **envp)
{
  (void) envp;

  GtkApplication *application = gtk_application_new ("org.inkscape.AndroidGtk4",
                                                     G_APPLICATION_DEFAULT_FLAGS);
  g_signal_connect (application, "startup", G_CALLBACK (on_startup), nullptr);
  g_signal_connect (application, "activate", G_CALLBACK (on_activate), nullptr);

  int status = g_application_run (G_APPLICATION (application), argc, argv);

  if (ink.document != nullptr)
    ink_document_free (ink.document);
  g_clear_object (&ink.open_dialog);
  g_clear_object (&ink.save_dialog);
  g_object_unref (application);

  return status;
}
