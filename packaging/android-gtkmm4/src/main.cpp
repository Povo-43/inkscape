// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Inkscape for Android — GTK4 ネイティブ版 (gtkmm4)
 *
 * Inkscape 本体のユーザーインターフェースは gtkmm4 (GTK の C++
 * バインディング) で書かれている。このアプリは、GTK4 の Android
 * バックエンド上で gtkmm4 の UI を動かす。将来的に Inkscape 本体の
 * UI (src/ui/) を載せるための土台になる。
 *
 * 設計方針:
 *   - UI は gtkmm4 (Gtk::Application / Gtk::ApplicationWindow など)
 *   - キャンバスと SVG 入出力は C の実装 (ink-canvas / ink-document) を
 *     そのまま使い、必要に応じて C API を直接呼ぶ。
 *     これは Inkscape 本体が「C++ コア + gtkmm UI」である構成に近い。
 *   - 元の Inkscape C++ コードには一切手を加えていない。
 */

#include <gtkmm.h>

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
    "font-size=\"14\" fill=\"#555555\">gtkmm4 · GtkSvg renderer · Android</text>\n"
    "</svg>\n";

class InkApplication : public Gtk::Application
{
public:
  static Glib::RefPtr<InkApplication> create ()
  {
    return Glib::make_refptr_for_instance<InkApplication> (new InkApplication ());
  }

protected:
  InkApplication ()
    : Gtk::Application ("org.inkscape.AndroidGtkmm4",
                        Gio::Application::Flags::HANDLES_OPEN)
  {
  }

  void on_startup () override;
  void on_activate () override;
  void on_open (const Gio::Application::type_vec_files &files,
                const Glib::ustring &hint) override;

private:
  void build_window ();
  void load_document (const Glib::RefPtr<Gio::File> &file);
  void set_document (InkDocument *document);
  void update_status ();
  void show_error (const Glib::ustring &message);

  void action_open ();
  void action_export ();
  void action_about ();
  void action_zoom_in ();
  void action_zoom_out ();
  void action_zoom_fit ();
  void action_zoom_reset ();

  void start_save_dialog (double scale);
  void write_png (const Glib::RefPtr<Gio::File> &file);

  static void on_canvas_zoom_notify (GObject    *object,
                                     GParamSpec *pspec,
                                     gpointer    user_data);

  Gtk::ApplicationWindow *window_ = nullptr;
  Gtk::Label *title_label_ = nullptr;
  Gtk::Label *status_label_ = nullptr;
  Gtk::Button *export_button_ = nullptr;
  GtkWidget *canvas_ = nullptr; /* InkCanvas (C 実装) */
  InkDocument *document_ = nullptr;
  Glib::RefPtr<Gtk::FileDialog> open_dialog_;
  Glib::RefPtr<Gtk::FileDialog> save_dialog_;
  Glib::RefPtr<Gtk::CssProvider> css_;
  double export_scale_ = 2.0;
};

/* ------------------------------------------------------------------ *
 * 起動
 * ------------------------------------------------------------------ */

void
InkApplication::on_startup ()
{
  Gtk::Application::on_startup ();

  add_action ("open", sigc::mem_fun (*this, &InkApplication::action_open));
  add_action ("export", sigc::mem_fun (*this, &InkApplication::action_export));
  add_action ("about", sigc::mem_fun (*this, &InkApplication::action_about));
  add_action ("zoom-in", sigc::mem_fun (*this, &InkApplication::action_zoom_in));
  add_action ("zoom-out", sigc::mem_fun (*this, &InkApplication::action_zoom_out));
  add_action ("zoom-fit", sigc::mem_fun (*this, &InkApplication::action_zoom_fit));
  add_action ("zoom-reset", sigc::mem_fun (*this, &InkApplication::action_zoom_reset));

  set_accels_for_action ("app.open", {"<Control>o"});
  set_accels_for_action ("app.export", {"<Control>e"});
  set_accels_for_action ("app.zoom-in", {"<Control>plus", "<Control>equal"});
  set_accels_for_action ("app.zoom-out", {"<Control>minus"});
  set_accels_for_action ("app.zoom-fit", {"<Control>0"});
  set_accels_for_action ("app.zoom-reset", {"<Control>1"});

  css_ = Gtk::CssProvider::create ();
  css_->load_from_string ("inkcanvas { background-color: #2b2b2b; }\n"
                          ".dim-label { opacity: 0.7; font-size: 0.9em; }\n");

  if (auto display = Gdk::Display::get_default ())
    Gtk::StyleContext::add_provider_for_display (display, css_,
                                                 GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
}

void
InkApplication::on_activate ()
{
  if (window_ == nullptr)
    build_window ();

  window_->present ();
}

void
InkApplication::on_open (const Gio::Application::type_vec_files &files,
                         const Glib::ustring                         &hint)
{
  (void) hint;

  if (files.empty ())
    return;

  if (window_ == nullptr)
    build_window ();

  load_document (files[0]);
  window_->present ();
}

/* ------------------------------------------------------------------ *
 * ウィンドウ構築
 * ------------------------------------------------------------------ */

Gtk::Button *
make_tool_button (const Glib::ustring &icon_name,
                  const Glib::ustring &tooltip,
                  const Glib::ustring &action)
{
  auto *button = Gtk::make_managed<Gtk::Button> ();
  button->set_icon_name (icon_name);
  button->set_tooltip_text (tooltip);
  button->set_hexpand (true);
  button->set_size_request (-1, 48);
  button->set_action_name (action);
  return button;
}

void
InkApplication::build_window ()
{
  window_ = Gtk::make_managed<Gtk::ApplicationWindow> ();
  window_->set_title ("Inkscape GTK4");
  window_->set_default_size (900, 700);
  add_window (*window_);

  /* ヘッダーバー */
  auto *header = Gtk::make_managed<Gtk::HeaderBar> ();

  title_label_ = Gtk::make_managed<Gtk::Label> ("Inkscape GTK4");
  title_label_->set_ellipsize (Pango::EllipsizeMode::MIDDLE);
  header->set_title_widget (*title_label_);

  auto menu = Gio::Menu::create ();
  menu->append ("SVG を開く…", "app.open");
  menu->append ("PNG として書き出す…", "app.export");
  menu->append ("ページにフィット", "app.zoom-fit");
  menu->append ("100% 表示", "app.zoom-reset");
  menu->append ("バージョン情報", "app.about");

  auto *menu_button = Gtk::make_managed<Gtk::MenuButton> ();
  menu_button->set_icon_name ("open-menu-symbolic");
  menu_button->set_menu_model (menu);
  menu_button->set_tooltip_text ("メニュー");
  header->pack_end (*menu_button);

  window_->set_titlebar (*header);

  /* 本体 */
  auto *box = Gtk::make_managed<Gtk::Box> (Gtk::Orientation::VERTICAL, 0);

  /* キャンバス: C 実装のウィジェットをそのまま使う */
  canvas_ = ink_canvas_new ();
  gtk_widget_set_hexpand (canvas_, TRUE);
  gtk_widget_set_vexpand (canvas_, TRUE);
  g_signal_connect (canvas_, "notify::zoom",
                    G_CALLBACK (InkApplication::on_canvas_zoom_notify), this);
  gtk_box_append (GTK_BOX (box->gobj ()), canvas_);

  /* ステータス行 */
  auto *status_bar = Gtk::make_managed<Gtk::Box> (Gtk::Orientation::VERTICAL, 0);

  status_label_ = Gtk::make_managed<Gtk::Label> ("ドキュメントが開かれていません");
  status_label_->set_ellipsize (Pango::EllipsizeMode::END);
  status_label_->set_xalign (0.0f);
  status_label_->set_margin_start (12);
  status_label_->set_margin_end (12);
  status_label_->set_margin_top (4);
  status_label_->set_margin_bottom (4);
  status_label_->add_css_class ("dim-label");
  status_bar->append (*status_label_);

  /* ツールバー */
  auto *toolbar = Gtk::make_managed<Gtk::Box> (Gtk::Orientation::HORIZONTAL, 6);
  toolbar->set_homogeneous (true);
  toolbar->set_margin_start (6);
  toolbar->set_margin_end (6);
  toolbar->set_margin_top (4);
  toolbar->set_margin_bottom (6);

  toolbar->append (*make_tool_button ("document-open-symbolic", "SVG を開く", "app.open"));
  toolbar->append (*make_tool_button ("zoom-out-symbolic", "縮小", "app.zoom-out"));
  toolbar->append (*make_tool_button ("view-fullscreen-symbolic", "ページにフィット", "app.zoom-fit"));
  toolbar->append (*make_tool_button ("zoom-in-symbolic", "拡大", "app.zoom-in"));

  export_button_ = make_tool_button ("document-save-as-symbolic", "PNG として書き出す", "app.export");
  export_button_->set_sensitive (false);
  toolbar->append (*export_button_);

  box->append (*status_bar);
  box->append (*toolbar);

  window_->set_child (*box);

  /* ウィンドウが閉じられたらポインタを無効化する
   * (managed ウィジェットなので C++ オブジェクトは gtkmm が破棄する)。 */
  signal_window_removed ().connect ([this] (Gtk::Window *window) {
    if (window == window_)
      {
        window_ = nullptr;
        title_label_ = nullptr;
        status_label_ = nullptr;
        export_button_ = nullptr;
        canvas_ = nullptr;
      }
  });

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
}

/* ------------------------------------------------------------------ *
 * ドキュメント
 * ------------------------------------------------------------------ */

void
InkApplication::set_document (InkDocument *document)
{
  if (document_ != nullptr)
    ink_document_free (document_);

  document_ = document;

  if (document == nullptr)
    {
      if (canvas_ != nullptr)
        ink_canvas_set_paintable (INK_CANVAS (canvas_), nullptr);
      if (title_label_ != nullptr)
        title_label_->set_text ("Inkscape GTK4");
      if (export_button_ != nullptr)
        export_button_->set_sensitive (false);
    }
  else
    {
      if (canvas_ != nullptr)
        ink_canvas_set_paintable (INK_CANVAS (canvas_),
                                  ink_document_get_paintable (document));
      if (title_label_ != nullptr)
        title_label_->set_text (ink_document_get_name (document));
      if (export_button_ != nullptr)
        export_button_->set_sensitive (true);
    }

  update_status ();
}

void
InkApplication::update_status ()
{
  if (status_label_ == nullptr)
    return;

  if (document_ == nullptr)
    {
      status_label_->set_text ("ドキュメントが開かれていません");
      return;
    }

  double zoom = canvas_ != nullptr ? ink_canvas_get_zoom (INK_CANVAS (canvas_)) : 1.0;

  char *text = g_strdup_printf ("%s  ·  %.0f × %.0f px  ·  %d 要素  ·  %.0f%%",
                                ink_document_get_name (document_),
                                ink_document_get_width (document_),
                                ink_document_get_height (document_),
                                ink_document_get_element_count (document_),
                                zoom * 100.0);
  status_label_->set_text (text);
  g_free (text);
}

void
InkApplication::on_canvas_zoom_notify (GObject    *object,
                                       GParamSpec *pspec,
                                       gpointer    user_data)
{
  (void) object;
  (void) pspec;
  static_cast<InkApplication *> (user_data)->update_status ();
}

void
InkApplication::show_error (const Glib::ustring &message)
{
  auto dialog = Gtk::AlertDialog::create (message);
  dialog->set_detail (message);
  dialog->show (*window_);
}

void
InkApplication::load_document (const Glib::RefPtr<Gio::File> &file)
{
  GError *error = nullptr;
  InkDocument *document = ink_document_new_from_file (file->gobj (), &error);

  if (document == nullptr)
    {
      show_error (error != nullptr ? error->message : "SVG を読み込めませんでした。");
      g_clear_error (&error);
      return;
    }

  set_document (document);
}

/* ------------------------------------------------------------------ *
 * アクション
 * ------------------------------------------------------------------ */

void
InkApplication::action_open ()
{
  if (!open_dialog_)
    {
      auto filter = Gtk::FileFilter::create ();
      filter->set_name ("SVG 画像 (*.svg, *.svgz)");
      filter->add_mime_type ("image/svg+xml");
      filter->add_pattern ("*.svg");
      filter->add_pattern ("*.svgz");

      auto filters = Gio::ListStore<Gtk::FileFilter>::create ();
      filters->append (filter);

      open_dialog_ = Gtk::FileDialog::create ();
      open_dialog_->set_title ("SVG を開く");
      open_dialog_->set_filters (filters);
    }

  open_dialog_->open (*window_, [this] (const Glib::RefPtr<Gio::AsyncResult> &result) {
    Glib::RefPtr<Gio::File> file;

    try
      {
        file = open_dialog_->open_finish (result);
      }
    catch (const Gtk::DialogError &error)
      {
        if (error.code () != Gtk::DialogError::DISMISSED)
          show_error (error.what ());
        return;
      }

    load_document (file);
  });
}

void
InkApplication::action_export ()
{
  if (document_ == nullptr)
    return;

  double width = ink_document_get_width (document_);
  double height = ink_document_get_height (document_);

  char *detail = g_strdup_printf ("%s (%.0f × %.0f px)\n\n"
                                  "1× = %.0f × %.0f px\n"
                                  "2× = %.0f × %.0f px\n"
                                  "4× = %.0f × %.0f px",
                                  ink_document_get_name (document_),
                                  width, height,
                                  width, height,
                                  width * 2.0, height * 2.0,
                                  width * 4.0, height * 4.0);

  auto dialog = Gtk::AlertDialog::create ("書き出し倍率を選択");
  dialog->set_detail (detail);
  dialog->set_buttons ({"キャンセル", "1×", "2×", "4×"});
  dialog->set_cancel_button (0);
  dialog->set_default_button (2);

  dialog->choose (*window_, [this, dialog] (const Glib::RefPtr<Gio::AsyncResult> &result) {
    int choice = -1;

    try
      {
        choice = dialog->choose_finish (result);
      }
    catch (const Gtk::DialogError &)
      {
        return;
      }

    double scale = 0.0;

    switch (choice)
      {
      case 1: scale = 1.0; break;
      case 2: scale = 2.0; break;
      case 3: scale = 4.0; break;
      default: return;
      }

    start_save_dialog (scale);
  });

  g_free (detail);
}

void
InkApplication::start_save_dialog (double scale)
{
  export_scale_ = scale;

  if (!save_dialog_)
    {
      auto filter = Gtk::FileFilter::create ();
      filter->set_name ("PNG 画像 (*.png)");
      filter->add_mime_type ("image/png");
      filter->add_pattern ("*.png");

      auto filters = Gio::ListStore<Gtk::FileFilter>::create ();
      filters->append (filter);

      save_dialog_ = Gtk::FileDialog::create ();
      save_dialog_->set_title ("PNG として書き出す");
      save_dialog_->set_filters (filters);
    }

  const char *name = ink_document_get_name (document_);
  Glib::ustring base = name != nullptr ? name : "drawing.svg";
  auto dot = base.rfind ('.');
  if (dot != Glib::ustring::npos)
    base.erase (dot);

  save_dialog_->set_initial_name (base + ".png");

  save_dialog_->save (*window_, [this] (const Glib::RefPtr<Gio::AsyncResult> &result) {
    Glib::RefPtr<Gio::File> file;

    try
      {
        file = save_dialog_->save_finish (result);
      }
    catch (const Gtk::DialogError &error)
      {
        if (error.code () != Gtk::DialogError::DISMISSED)
          show_error (error.what ());
        return;
      }

    write_png (file);
  });
}

void
InkApplication::write_png (const Glib::RefPtr<Gio::File> &file)
{
  GError *error = nullptr;
  GBytes *png = ink_document_render_png (document_, export_scale_, &error);

  if (png == nullptr)
    {
      show_error (error != nullptr ? error->message : "PNG を生成できませんでした。");
      g_clear_error (&error);
      return;
    }

  gsize size = 0;
  const void *data = g_bytes_get_data (png, &size);

  gboolean ok = g_file_replace_contents (file->gobj (),
                                         static_cast<const char *> (data), size,
                                         nullptr, FALSE,
                                         G_FILE_CREATE_REPLACE_DESTINATION,
                                         nullptr, nullptr, &error);
  g_bytes_unref (png);

  if (!ok)
    {
      show_error (error != nullptr ? error->message : "PNG を保存できませんでした。");
      g_clear_error (&error);
      return;
    }

  char *basename = g_file_get_basename (file->gobj ());
  char *message = g_strdup_printf ("PNG を書き出しました: %s (%.0f × %.0f px)",
                                   basename,
                                   ink_document_get_width (document_) * export_scale_,
                                   ink_document_get_height (document_) * export_scale_);
  if (status_label_ != nullptr)
    status_label_->set_text (message);
  g_free (message);
  g_free (basename);
}

void
InkApplication::action_zoom_in ()
{
  if (canvas_ != nullptr)
    ink_canvas_zoom_in (INK_CANVAS (canvas_));
}

void
InkApplication::action_zoom_out ()
{
  if (canvas_ != nullptr)
    ink_canvas_zoom_out (INK_CANVAS (canvas_));
}

void
InkApplication::action_zoom_fit ()
{
  if (canvas_ != nullptr)
    ink_canvas_zoom_fit (INK_CANVAS (canvas_));
}

void
InkApplication::action_zoom_reset ()
{
  if (canvas_ != nullptr)
    ink_canvas_zoom_reset (INK_CANVAS (canvas_));
}

void
InkApplication::action_about ()
{
  auto dialog = Gtk::AlertDialog::create ("Inkscape GTK4 for Android (gtkmm)");
  dialog->set_detail ("gtkmm4 版の実験的ビルドです。\n\n"
                      "UI: gtkmm4 (GTK の C++ バインディング)\n"
                      "レンダリング: GtkSvg (GTK 4.22+)\n"
                      "バージョン: 0.4.0\n\n"
                      "Inkscape 本体 (gtkmm4) へ段階的に移植しています。");
  dialog->show (*window_);
}

} // namespace

/*
 * Android では meson の android_exe_type: 'application' により、
 * この main が JNI 経由で呼ばれる。
 */
extern "C" int
main (int argc, char **argv, char **envp)
{
  (void) envp;

  Glib::RefPtr<InkApplication> application = InkApplication::create ();

  return application->run (argc, argv);
}
