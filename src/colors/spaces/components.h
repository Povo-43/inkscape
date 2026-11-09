// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Authors:
 *   Jon A. Cruz <jon@joncruz.org>
 *   Martin Owens <doctormo@geek-2.com>
 *
 * Copyright (C) 2013-2023 Authors
 *
 * Released under GNU GPL v2+, read the file 'COPYING' for more information.
 */

#ifndef SEEN_COLORS_COMPONENTS_H
#define SEEN_COLORS_COMPONENTS_H

#include <lcms2.h>
#include <map>
#include <string>
#include <vector>

#include "enum.h"

namespace Inkscape::Colors::Space {

enum class Type;

// Unit impacts component presentation in the UI and dictates what its scale is
enum class Unit {
    EightBit,   // one byte, values from 0..255, unitless
    Percent,    // 0..100%
    Degree,     // 0..360 degree
    Linear1024, // 0..1024 for linear RGB
    Chroma40    // an oddball 0..40 for OkLch hue encoding
};

struct Component
{
    Component(Type type, unsigned int index, std::string id, std::string name, std::string tip, Unit unit = Unit::EightBit);
    Component(std::string id, std::string name, std::string tip, Unit unit = Unit::EightBit);

    Type type;
    unsigned int index;
    std::string id;
    std::string name;
    std::string tip;
    unsigned scale;
    Unit unit = Unit::EightBit;

    double normalize(double value) const;
};

class Components
{
public:
    Components() = default;
    Components(Type type, std::vector<Component> components):
        _type(type), _components(std::move(components)) {}

    static Components const &get(Type type, bool alpha = false);

    const std::vector<Component>& getAll() const { return _components; }

    std::vector<Component>::const_iterator begin() const { return std::begin(_components); }
    std::vector<Component>::const_iterator end() const { return std::end(_components); }
    Component const &operator[](const unsigned int index) const { return _components[index]; }

    Type getType() const { return _type; }
    unsigned size() const { return _components.size(); }

    void add(std::string id, std::string name, std::string tip, Unit unit = Unit::EightBit);
    void setType(Type type) { _type = type; }

private:
    Type _type = Type::NONE;
    std::vector<Component> _components;
};

} // namespace Inkscape::Colors::Space

#endif // SEEN_COLORS_COMPONENTS_H
