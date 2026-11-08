// SPDX-License-Identifier: GPL-2.0-or-later

#include "document-font-prefs.h"

#include <cstring>
#include <glib.h>

#include "preferences.h"

namespace {

bool env_override(char const *name, bool *out)
{
    char const *e = g_getenv(name);
    if (!e || !*e) {
        return false;
    }
    *out = !(g_ascii_strcasecmp(e, "0") == 0 || g_ascii_strcasecmp(e, "false") == 0 ||
             g_ascii_strcasecmp(e, "off") == 0 || g_ascii_strcasecmp(e, "no") == 0);
    return true;
}

bool pref_or_env(char const *env, char const *pref, bool default_value)
{
    bool v = default_value;
    if (env_override(env, &v)) {
        return v;
    }
    return Inkscape::Preferences::get()->getBool(pref, default_value);
}

} // namespace

namespace Inkscape::DocumentFontPrefs {

bool enabled()
{
    return pref_or_env("INKSCAPE_DOCUMENT_WEBFONTS", "/options/font/document_webfonts", true);
}

bool debug()
{
    return pref_or_env("INKSCAPE_DOCUMENT_WEBFONTS_DEBUG", "/options/font/document_webfonts_debug", false);
}

} // namespace Inkscape::DocumentFontPrefs
