// SPDX-License-Identifier: GPL-2.0-or-later
/** @file
 * Entry widget for typing color value in css form
 *//*
 * Authors:
 *   Tomasz Boczkowski <penginsbacon@gmail.com>
 *
 * Copyright (C) 2014 Authors
 * Released under GNU GPL v2+, read the file 'COPYING' for more information.
 */

#include <glibmm/i18n.h>

#include "color-entry.h"

#include "colors/manager.h"
#include "colors/spaces/gamut.h"
#include "colors/spaces/base.h"
#include "svg/css-ostringstream.h"

namespace Inkscape::UI::Widget {

ColorEntry::ColorEntry(std::shared_ptr<Colors::ColorSet> colors)
    : _colors(std::move(colors))
    , _updating(false)
    , _updating_color(false)
{
    set_name("ColorEntry");

    _color_changed_connection = _colors->signal_changed.connect(sigc::mem_fun(*this, &ColorEntry::_onColorChanged));
    signal_activate().connect(sigc::mem_fun(*this, &ColorEntry::_onColorChanged));
    set_icon_tooltip_text(_("Show color in RGBA hex format or its real value."));
    signal_icon_press().connect([this](Gtk::Entry::IconPosition) {
        _show_real = !_show_real;
        _onColorChanged();
    });
    _onColorChanged();

    set_tooltip_text(_("Value of the color in the stored color space."));
}

ColorEntry::~ColorEntry()
{
    _color_changed_connection.disconnect();
}

void ColorEntry::on_changed()
{
    if (_updating || _updating_color) {
        return;
    }

    auto text = get_text();
    auto new_color = Colors::Color::parse(text, true);

    _updating_color = true;
    if (new_color) {
        if (auto color = _colors->get()) {
            new_color->setOpacity(color->getOpacity());
        }
        _colors->setAll(*new_color);
    }
    _updating_color = false;
}


void ColorEntry::_onColorChanged()
{
    static auto rgb = Colors::Manager::get().find(Colors::Space::Type::RGB);

    if (_updating_color) {
        return;
    }

    if (_colors->isEmpty()) {
        set_text(_("N/A"));
        return;
    }

    auto color = _colors->getAverage();

    // Hide icon if space is already RGB, BEFORE converting to rgb
    if (color.getSpace() == rgb) {
        unset_icon(IconPosition::SECONDARY);
    } else {
        set_icon_from_icon_name(_show_real ? "object-visible" : "object-hidden", IconPosition::SECONDARY);
    }

    if (!_show_real) {
        color = *color.converted(rgb);
    }
    if (Colors::out_of_gamut(color, color.getSpace())) {
        _signal_out_of_gamut.emit(Glib::ustring::compose(_("Color %1 is out of gamut for %2.\nIt has been mapped to sRGB gamut."), color.toString().c_str(), color.getSpace()->getName().c_str()));
        _warning = true;
        color = Colors::to_gamut_css(color, color.getSpace());
    }
    else if (_warning) {
        // clear warning
        _warning = false;
        _signal_out_of_gamut.emit({});
    }
    auto text = color.toString(false);

    if (get_text().raw() != text) {
        _updating = true;
        set_text(text);
        _updating = false;
    }
}

} // namespace

/*
  Local Variables:
  mode:c++
  c-file-style:"stroustrup"
  c-file-offsets:((innamespace . 0)(inline-open . 0)(case-label . +))
  indent-tabs-mode:nil
  fill-column:99
  End:
*/
// vim: filetype=cpp:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:fileencoding=utf-8:textwidth=99 :
