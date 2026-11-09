// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Authors:
 *   Martin Owens <doctormo@geek-2.com>
 *
 * Copyright (C) 2023 Authors
 *
 * Released under GNU GPL v2+, read the file 'COPYING' for more information.
 */

#ifndef SEEN_COLORS_SPACES_NAMED_H
#define SEEN_COLORS_SPACES_NAMED_H

#include "rgb.h"

namespace Inkscape::Colors::Space {

/**
 * A named color is still a purely RGB color, it's just formatted so it
 * can be written back out as a named color faithfully.
 */
class NamedColor : public RGB
{
public:
    NamedColor(): RGB(Type::CSSNAME, "CSSNAME", "Named", "named") {}
    ~NamedColor() override = default;

    Type getComponentType() const override { return Type::RGB; }

    static std::string getNameFor(unsigned int rgba);

    class NameParser : public Colors::Parser
    {
    public:
        NameParser()
            : Colors::Parser("", Type::CSSNAME)
        {}
        bool parse(std::istringstream &input, std::vector<double> &output) const override;
    };
private:
    std::string _to_string(std::vector<double> const &values, bool opacity = true) const override;
};

} // namespace Inkscape::Colors::Space

#endif // SEEN_COLORS_SPACES_NAMED_H
