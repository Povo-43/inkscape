// SPDX-License-Identifier: GPL-2.0-or-later
/**
 * Isolated libnrtype unit-test stand-ins for DocumentFontMap / prefs / SPDocument.
 * Linked only into libnrtype_unit_lib, not inkscape_base.
 */

#include "libnrtype/document-font-map.h"
#include "libnrtype/document-font-prefs.h"
#include "libnrtype/font-instance.h"

#include "document.h"

#include <stdexcept>

namespace Inkscape {

std::shared_ptr<FontInstance> DocumentFontMap::face(PangoFontDescription * /*descr*/, bool /*canFail*/)
{
    throw std::logic_error("DocumentFontMap::face is not available in libnrtype unit tests");
}

} // namespace Inkscape

namespace Inkscape::DocumentFontPrefs {

bool enabled()
{
    return false;
}

} // namespace Inkscape::DocumentFontPrefs

Inkscape::DocumentFontMap &SPDocument::getDocumentFontMap()
{
    throw std::logic_error("SPDocument::getDocumentFontMap is not available in libnrtype unit tests");
}

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
