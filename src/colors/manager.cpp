// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Colors::Manager - Look after the systems in built color spaces
 *
 * Copyright 2023-2026
 *    * Martin Owens <doctormo@geek-2.com>
 *
 * Released under GNU GPL v2+, read the file 'COPYING' for more information.
 */

#include "manager.h"

#include <algorithm>
#include <glib.h>

#include "colors/color.h"

// Each Internal space should be imported here.
#include "spaces/alpha.h"
#include "spaces/cms.h"
#include "spaces/cmyk.h"
#include "spaces/gray.h"
#include "spaces/hsl.h"
#include "spaces/hsluv.h"
#include "spaces/hsv.h"
#include "spaces/lab.h"
#include "spaces/lch.h"
#include "spaces/linear-rgb.h"
#include "spaces/luv.h"
#include "spaces/named.h"
#include "spaces/okhsl.h"
#include "spaces/okhsv.h"
#include "spaces/oklab.h"
#include "spaces/oklch.h"
#include "spaces/rgb.h"
#include "spaces/xyz.h"

namespace Inkscape::Colors {

Manager::Manager()
{
    // Regular SVG 1.1 Colors
    addSpaceAndPicker(new Space::RGB(), Space::Type::RGB);
    addSpace(new Space::NamedColor());

    // Color module 4 and 5 support
    addSpaceAndPicker(new Space::HSL(), Space::Type::HSL);
    addSpaceAndPicker(new Space::HSV(), Space::Type::HSV);
    addSpaceAndPicker(new Space::DeviceCMYK(), Space::Type::NONE);
    addSpaceAndPicker(new Space::HSLuv(), Space::Type::HSLUV);
    addSpaceAndPicker(new Space::OkHsl(), Space::Type::OKHSL);
    addSpaceAndPicker(new Space::OkLch(), Space::Type::OKHSL);

    // Color pickers not available for these
    addSpace(new Space::Gray());
    addSpace(new Space::Lab());
    addSpace(new Space::LinearRGB());
    addSpace(new Space::Lch());
    addSpace(new Space::Luv());
    addSpace(new Space::OkHsv());
    addSpace(new Space::OkLab());
    addSpace(new Space::XYZ());
    addSpace(new Space::XYZ50());

    // Image rendering spaces
    addSpace(new Space::Alpha());

    // CMS empty which is just for registering a color picker type
    auto cms = Space::CMS("cms", 0);
    addPicker(&cms, Space::Type::NONE);
}

/**
 * Add the given space and assume ownership over it.
 *
 * @arg space - A pointer to the new Color Space object.
 * @arg svg_matches - A list of matching strings for looking up this space as an attribute, first item is used in output.
 *
 */
void Manager::addSpace(Space::AnySpace *space)
{
    if (find(space->getType())) {
        throw ColorError("Can not add the same color space twice.");
    }
    _spaces.emplace_back(space);
    for (auto &match : space->getSvgNames()) {
        if (_svg_names_lookup.find(match) != _svg_names_lookup.end()) {
            throw ColorError("Can not add the same svg attribute name twice.");
        }
        _svg_names_lookup[match] = _spaces.back();
    }
}

/**
 * Add the given space as a template for a color picker, allowing the user to choose
 * colors using this color space format in the user interface.
 *
 * These pickers are actually categories, but for most of all of the pickers there
 * is a one to one correspondence between the internal color space and the picker.
 *
 * Only for CMS spaces so far would the same picker be used for multiple spaces.
 */
void Manager::addPicker(Space::AnySpace *space, Space::Type wheel)
{
    _pickers.emplace_back(new Picker(space->getType(), wheel, space->getName(), space->getIcon()));
}

/**
 * Combined call to addSpace and addPicker
 */
void Manager::addSpaceAndPicker(Space::AnySpace *space, Space::Type wheel)
{
    addSpace(space);
    addPicker(space, wheel);
}

/**
 * Finds the first global color space matching the given type
 *
 * @arg type - The type enum to match
 */
std::shared_ptr<Space::AnySpace> Manager::find(Space::Type type) const
{
    auto it = std::find_if(_spaces.begin(), _spaces.end(), [type](auto &v) { return v->getType() == type; });
    return it != _spaces.end() ? *it : nullptr;
}

/**
 * Finds the global space matching the given name
 *
 * @arg name - The name of the space as given by getName
 */
std::shared_ptr<Space::AnySpace> Manager::find(std::string const &name) const
{
    auto it = std::find_if(_spaces.begin(), _spaces.end(), [name](auto &v) { return v->getName() == name; });
    return it != _spaces.end() ? *it : nullptr;
}

/**
 * Find a global space matching the svg color space name used in attributes that
 * specify just the color space without a color, we support more than just
 * the standard set for SVG interpolation values for this field.
 *
 * @arg input - The color space string to find/match, case insensitive
 */
std::shared_ptr<Space::AnySpace> Manager::findSvgColorSpace(std::string const &input) const
{
    auto it = _svg_names_lookup.find(input);
    if (it != _svg_names_lookup.end()) {
        return it->second;
    }
    return {};
}

/**
 * Find any color space by a unique integer id attached at creation time. Used for
 * some historical data-model driven UI which can't use void pointers.
 */
std::shared_ptr<Space::AnySpace> Manager::findById(int id) const
{
    auto it = std::find_if(_spaces.begin(), _spaces.end(), [id](auto &v) { return v->getId() == id; });
    return it != _spaces.end() ? *it : nullptr;
}

/**
 * Finds the color picker with this color type, there should only ever be one
 */
std::shared_ptr<Picker> Manager::findPicker(Space::Type type) const
{
    auto it = std::find_if(_pickers.begin(), _pickers.end(), [type](auto &v) { return v->getType() == type; });
    return it != _pickers.end() ? *it : nullptr;
}

} // namespace Inkscape::Colors

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
