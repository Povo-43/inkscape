// SPDX-License-Identifier: GPL-2.0-or-later
/** @file
 * Runtime flags for document @font-face loading.
 *
 *   INKSCAPE_DOCUMENT_WEBFONTS        0/1  load @font-face (engine). Default on.
 *   INKSCAPE_DOCUMENT_WEBFONTS_DEBUG  0/1  DocumentFontMap g_message tracing. Default off.
 *
 * Env var, if set, wins over the preference of the same name.
 */
#ifndef LIBNRTYPE_DOCUMENT_FONT_PREFS_H
#define LIBNRTYPE_DOCUMENT_FONT_PREFS_H

#include <glib.h>

namespace Inkscape::DocumentFontPrefs {

bool enabled();
bool debug();

} // namespace Inkscape::DocumentFontPrefs

#define DFM_MSG(...) \
    G_STMT_START { \
        if (Inkscape::DocumentFontPrefs::debug()) { \
            g_message(__VA_ARGS__); \
        } \
    } G_STMT_END

#endif // LIBNRTYPE_DOCUMENT_FONT_PREFS_H
