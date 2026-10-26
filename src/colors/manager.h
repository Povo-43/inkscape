// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Colors::Manager - Look after the systems in built color spaces
 *
 * Copyright 2023-2026
 *    * Martin Owens <doctormo@geek-2.com>
 *
 * Released under GNU GPL v2+, read the file 'COPYING' for more information.
 */

#ifndef SEEN_COLORS_MANAGER_H
#define SEEN_COLORS_MANAGER_H

#include <cstring>
#include <map>
#include <memory>
#include <optional>
#include <sigc++/signal.h>
#include <sigc++/connection.h>
#include <vector>

#include "spaces/components.h"

namespace Inkscape::Colors {
namespace Space {
enum class Type;
class AnySpace;
} // namespace Space
class Color;
class Parser;

class Picker
{
public:
    Picker(Space::Type type, Space::Type wheel_type, std::string name, std::string iconname)
        : _type(type)
        , _wheel_type(wheel_type)
        , _name(std::move(name))
        , _iconname(std::move(iconname))
    {}

    Space::Type getType() { return _type; }
    Space::Type getWheelType() { return _wheel_type; }
    std::string const getName() { return _name; }
    std::string const getIconName() { return _iconname; }

    bool isVisible() const { return _is_visible; }
    void setVisible(bool visible) { _is_visible = visible; _changed_signal.emit(); }

    Space::Type formatOutputType() const {
        return _format_output_type != Space::Type::NONE
            ? _format_output_type
            : (_type == Space::Type::CMS
                ? Space::Type::NONE
                : Space::Type::DOCUMENT);
    }
    void setFormatOutputType(Space::Type type) { _format_output_type = type; _changed_signal.emit(); }

    sigc::connection connectChanged(const sigc::slot<void()> &slot) { return _changed_signal.connect(slot); }
private:
    Space::Type _type;
    Space::Type _wheel_type;
    std::string _name;
    std::string _iconname;

    bool _is_visible = true;
    Space::Type _format_output_type = Space::Type::NONE;
    sigc::signal<void()> _changed_signal;
};

class Manager
{
private:
    Manager(Manager const &) = delete;
    void operator=(Manager const &) = delete;

public:

    static Manager &get()
    {
        static Manager instance;
        return instance;
    }

    std::vector<std::shared_ptr<Space::AnySpace>> const &spaces() { return _spaces; }
    std::shared_ptr<Space::AnySpace> find(Space::Type type) const;
    std::shared_ptr<Space::AnySpace> find(std::string const &name) const;
    std::shared_ptr<Space::AnySpace> findSvgColorSpace(std::string const &input) const;
    std::shared_ptr<Space::AnySpace> findById(int id) const;

    std::vector<std::shared_ptr<Picker>> const &pickers() { return _pickers; }
    std::shared_ptr<Picker> findPicker(Space::Type type) const;
protected:
    Manager();
    ~Manager() = default;

    void addSpace(Space::AnySpace *space);
    void addPicker(Space::AnySpace *space, Space::Type wheel);
    void addSpaceAndPicker(Space::AnySpace *space, Space::Type wheel);

private:
    std::vector<std::shared_ptr<Space::AnySpace>> _spaces;
    std::vector<std::shared_ptr<Picker>> _pickers;

    struct cmpCaseInsensitive {
        bool operator()(const std::string& a, const std::string& b) const {
            return strcasecmp(a.c_str(), b.c_str()) < 0;
        }
    };
    std::map<std::string, std::shared_ptr<Space::AnySpace>, cmpCaseInsensitive> _svg_names_lookup;
};

} // namespace Inkscape::Colors

#endif // SEEN_COLORS_MANAGER_H

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
