// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Join lists of elements, while respecting internationalization.
 *
 * Authors:
 * Copyright (C) 2026 Michael Terry
 *
 * Released under GNU GPL v2+, read the file 'COPYING' for more information.
 */

#include <boost/algorithm/string/join.hpp>
#include <glibmm/i18n.h>

#include "join.h"

namespace Inkscape {
namespace Util {

/**
 * Join a set of items with a language-appropriate separator.
 * In English, this would be a comma, but some languages use other separators (like "、" in CJK).
 *
 * - An empty set will return an empty string.
 * - A set with one element will return just that element.
 * - The list will be joined in sort-order.
 * - This method does NOT add a joiner word like "and".
 *
 * Example call for English locale:
 *  set("apple", "grape", "banana") => "apple, banana, grape"
 *
 * @param items strings to join
 */
Glib::ustring join_with_separator(std::set<Glib::ustring> const &items)
{
    return boost::algorithm::join(items, C_("list separator", ", "));
}

} // namespace Util
} // namespace Inkscape

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
