// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Inkscape for Android — gtkmm4 スタック検証用の最小アプリ
 *
 * Inkscape 本体の UI は gtkmm4 (GTK の C++ バインディング) で書かれている。
 * このアプリは、GTK4 の Android バックエンド上で sigc++ / glibmm /
 * cairomm / pangomm / gtkmm のクロスビルドが成立することを確認するための
 * プローブである。
 *
 * まだ Inkscape のコードは含まない。スタックが動作したら、この上に
 * Inkscape の UI (src/ui 以下) を載せていく計画。
 */

#include <gtkmm.h>

namespace {

class InkGtkmmApplication : public Gtk::Application
{
public:
  static Glib::RefPtr<InkGtkmmApplication> create ()
  {
    return Glib::make_refptr_for_instance<InkGtkmmApplication> (new InkGtkmmApplication ());
  }

protected:
  InkGtkmmApplication ()
    : Gtk::Application ("org.inkscape.AndroidGtkmm4")
  {
  }

  void on_activate () override
  {
    auto *window = new Gtk::ApplicationWindow ();
    window->set_title ("Inkscape GTK4 (gtkmm)");
    window->set_default_size (800, 600);

    auto *box = Gtk::make_managed<Gtk::Box> (Gtk::Orientation::VERTICAL, 12);
    box->set_margin (24);
    box->set_valign (Gtk::Align::CENTER);

    auto *title = Gtk::make_managed<Gtk::Label> ();
    title->set_markup ("<big><b>Inkscape on gtkmm4</b></big>");
    box->append (*title);

    auto *detail = Gtk::make_managed<Gtk::Label> (
        "GTK4 + gtkmm (C++) スタックが Android で動作しています。\n"
        "sigc++ / glibmm / cairomm / pangomm / gtkmm");
    detail->set_justify (Gtk::Justification::CENTER);
    detail->add_css_class ("dim-label");
    box->append (*detail);

    auto *button = Gtk::make_managed<Gtk::Button> ("閉じる");
    button->set_halign (Gtk::Align::CENTER);
    button->signal_clicked ().connect ([window] { window->close (); });
    box->append (*button);

    window->set_child (*box);

    window->signal_hide ().connect ([window] { delete window; });

    add_window (*window);
    window->present ();
  }
};

} // namespace

extern "C" int
main (int argc, char **argv)
{
  Glib::RefPtr<InkGtkmmApplication> application = InkGtkmmApplication::create ();
  return application->run (argc, argv);
}
