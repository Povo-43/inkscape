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
 * 一切手を加えていない。
 */

#include <gtk/gtk.h>

#include <cstring>

namespace {

// 動作確認用の埋め込み SVG。
// グラデーション、図形、テキストを含む。
const char *kSampleSvg =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"400\" height=\"400\" "
    "viewBox=\"0 0 400 400\">\n"
    "  <defs>\n"
    "    <linearGradient id=\"bg\" x1=\"0\" y1=\"0\" x2=\"0\" y2=\"1\">\n"
    "      <stop offset=\"0\" stop-color=\"#2b2b2b\"/>\n"
    "      <stop offset=\"1\" stop-color=\"#4a4a4a\"/>\n"
    "    </linearGradient>\n"
    "  </defs>\n"
    "  <rect x=\"0\" y=\"0\" width=\"400\" height=\"400\" fill=\"url(#bg)\"/>\n"
    "  <circle cx=\"200\" cy=\"150\" r=\"80\" fill=\"#4a90e2\" "
    "stroke=\"#2c5282\" stroke-width=\"6\"/>\n"
    "  <rect x=\"120\" y=\"270\" width=\"160\" height=\"80\" rx=\"12\" "
    "fill=\"#e53935\"/>\n"
    "  <path d=\"M 60 360 L 140 300 L 220 350 L 300 290 L 340 360 Z\" "
    "fill=\"#43a047\"/>\n"
    "  <text x=\"200\" y=\"60\" text-anchor=\"middle\" font-size=\"28\" "
    "fill=\"#ffffff\">Inkscape on GTK4</text>\n"
    "</svg>\n";

void on_activate(GtkApplication *app, gpointer user_data)
{
    (void)user_data;

    GtkWidget *window = gtk_application_window_new(app);
    gtk_window_set_title(GTK_WINDOW(window), "Inkscape GTK4");
    gtk_window_set_default_size(GTK_WINDOW(window), 900, 700);

    // GtkSvg は GTK 4.22 で追加された SVG ペインタブル。
    GBytes *bytes = g_bytes_new_static(kSampleSvg, std::strlen(kSampleSvg));
    GdkPaintable *svg = GDK_PAINTABLE(gtk_svg_new_from_bytes(bytes));
    g_bytes_unref(bytes);

    GtkWidget *picture = gtk_picture_new_for_paintable(svg);
    gtk_picture_set_can_shrink(GTK_PICTURE(picture), TRUE);
    gtk_widget_set_hexpand(picture, TRUE);
    gtk_widget_set_vexpand(picture, TRUE);

    // ヘッダーバー: GTK4 らしいタイトルバー
    GtkWidget *header = gtk_header_bar_new();
    gtk_header_bar_set_title_widget(GTK_HEADER_BAR(header),
                                    gtk_label_new("Inkscape GTK4"));
    gtk_window_set_titlebar(GTK_WINDOW(window), header);

    // ステータス表示 (どのレンダラーで描いているか)
    GtkWidget *status = gtk_label_new("GTK4 / GtkSvg renderer");
    gtk_widget_set_margin_top(status, 6);
    gtk_widget_set_margin_bottom(status, 6);

    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_box_append(GTK_BOX(box), picture);
    gtk_box_append(GTK_BOX(box), status);

    gtk_window_set_child(GTK_WINDOW(window), box);
    gtk_window_present(GTK_WINDOW(window));
}

} // namespace

/*
 * Android では meson の android_exe_type: 'application' により、
 * この main が JNI 経由で呼ばれる。第三引数 (envp) は省略可能だが、
 * 将来の環境変数設定のために受け取っておく。
 */
extern "C" int main(int argc, char **argv, char **envp)
{
    (void)envp;

    GtkApplication *app = gtk_application_new("org.inkscape.AndroidGtk4",
                                              G_APPLICATION_DEFAULT_FLAGS);
    g_signal_connect(app, "activate", G_CALLBACK(on_activate), nullptr);

    int status = g_application_run(G_APPLICATION(app), argc, argv);
    g_object_unref(app);
    return status;
}
