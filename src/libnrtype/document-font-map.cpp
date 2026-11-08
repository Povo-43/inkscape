// SPDX-License-Identifier: GPL-2.0-or-later
#include "libnrtype/document-font-map.h"
#include "libnrtype/document-font-prefs.h"

#include <cctype>
#include <cstdint>
#include <cstring>

#include <glib.h>
#include <glib/gstdio.h>
#include <glibmm/fileutils.h>
#include <glibmm/miscutils.h>
#include <pango/pango-fontmap.h>
#include <pango/pangofc-fontmap.h>
#include <pango/pangoft2.h>

#ifndef PANGO_ENABLE_ENGINE
#define PANGO_ENABLE_ENGINE
#endif

#include <fontconfig/fontconfig.h>
#include <fontconfig/fcfreetype.h>

#include "3rdparty/libcroco/src/cr-declaration.h"
#include "3rdparty/libcroco/src/cr-string.h"
#include "3rdparty/libcroco/src/cr-term.h"

#include "document.h"
#include "io/resource.h"
#include "io/sys.h"
#include "libnrtype/font-factory.h"
#include "libnrtype/font-instance.h"
#include "preferences.h"

namespace {

std::string first_family_token(char const *family)
{
    if (!family) {
        return {};
    }
    std::string s = family;
    auto comma = s.find(',');
    if (comma != std::string::npos) {
        s.resize(comma);
    }
    auto b = s.find_first_not_of(" \t\"'");
    auto e = s.find_last_not_of(" \t\"'");
    if (b == std::string::npos) {
        return {};
    }
    return s.substr(b, e - b + 1);
}

std::string casefold_c(char const *s)
{
    if (!s) {
        return {};
    }
    gchar *cf = g_utf8_casefold(s, -1);
    std::string out = cf ? cf : "";
    g_free(cf);
    return out;
}

bool families_equal(char const *a, char const *b)
{
    return casefold_c(a) == casefold_c(b);
}

std::string query_file_family(std::string const &path)
{
    int count = 0;
    FcPattern *pat = FcFreeTypeQuery(reinterpret_cast<FcChar8 const *>(path.c_str()), 0, nullptr, &count);
    if (!pat) {
        return {};
    }
    FcChar8 *fam = nullptr;
    std::string out;
    if (FcPatternGetString(pat, FC_FAMILY, 0, &fam) == FcResultMatch && fam) {
        out = reinterpret_cast<char *>(fam);
    }
    FcPatternDestroy(pat);
    return out;
}

void replace_fc_family(FcPattern *pat, char const *family)
{
    while (FcPatternRemove(pat, FC_FAMILY, 0)) {
    }
    FcPatternAddString(pat, FC_FAMILY, reinterpret_cast<FcChar8 const *>(family));
}

bool pattern_asks_for_face(FcPattern *pattern, Inkscape::DocumentFontMap::Face const &face)
{
    for (int i = 0;; ++i) {
        FcChar8 *fam = nullptr;
        if (FcPatternGetString(pattern, FC_FAMILY, i, &fam) != FcResultMatch || !fam) {
            break;
        }
        char const *ask = reinterpret_cast<char const *>(fam);
        if (families_equal(face.family.c_str(), ask) ||
            (!face.pango_family.empty() && families_equal(face.pango_family.c_str(), ask))) {
            return true;
        }
    }
    return false;
}

void factory_substitute(FcPattern *pattern, gpointer data)
{
    auto *self = static_cast<Inkscape::DocumentFontMap *>(data);
    if (self) {
        for (auto const &face : self->faces()) {
            if (face.loaded && pattern_asks_for_face(pattern, face)) {
                char const *use_fam =
                    !face.pango_family.empty() ? face.pango_family.c_str() : face.family.c_str();
                replace_fc_family(pattern, use_fam);
                break;
            }
        }
    }
    FcPatternAddBool(pattern, "FC_OUTLINE", FcTrue);
}

char const *backend_name(Inkscape::DocumentFontMap::Backend b)
{
    switch (b) {
        case Inkscape::DocumentFontMap::Backend::PangoAddFile:
            return "PangoAddFile";
        case Inkscape::DocumentFontMap::Backend::FcConfig:
            return "FcConfig";
        default:
            return "Unavailable";
    }
}

bool parse_boolish(char const *e)
{
    if (!e || !e[0]) {
        return false;
    }
    return g_ascii_strcasecmp(e, "0") != 0 && g_ascii_strcasecmp(e, "false") != 0 &&
           g_ascii_strcasecmp(e, "no") != 0 && g_ascii_strcasecmp(e, "off") != 0;
}

std::string term_string(CRTerm const *term)
{
    if (!term) {
        return {};
    }
    if (term->content.str && term->content.str->stryng && term->content.str->stryng->str) {
        return term->content.str->stryng->str;
    }
    if (guchar *s = cr_term_to_string(const_cast<CRTerm *>(term))) {
        std::string out(reinterpret_cast<char *>(s));
        g_free(s);
        return out;
    }
    return {};
}

std::string strip_quotes(std::string s)
{
    if (s.size() >= 2 && ((s.front() == '"' && s.back() == '"') || (s.front() == '\'' && s.back() == '\''))) {
        return s.substr(1, s.size() - 2);
    }
    return s;
}

std::string ext_for_hint(std::string const &hint)
{
    auto lower = hint;
    for (auto &c : lower) {
        c = static_cast<char>(g_ascii_tolower(c));
    }
    if (lower.find("otf") != std::string::npos || lower.find("opentype") != std::string::npos) {
        return ".otf";
    }
    return ".ttf";
}

bool looks_like_sfnt_file(std::string const &path)
{
    auto lower = path;
    for (auto &c : lower) {
        c = static_cast<char>(g_ascii_tolower(c));
    }
    auto has = [&](char const *s) {
        auto n = std::strlen(s);
        return lower.size() >= n && lower.compare(lower.size() - n, std::string::npos, s) == 0;
    };
    return has(".ttf") || has(".otf");
}

bool is_sfnt_magic(uint8_t const *p, size_t n)
{
    if (n < 4) {
        return false;
    }
    return (p[0] == 0 && p[1] == 1 && p[2] == 0 && p[3] == 0) || std::memcmp(p, "OTTO", 4) == 0 ||
           std::memcmp(p, "true", 4) == 0 || std::memcmp(p, "typ1", 4) == 0;
}

bool is_woff_magic(uint8_t const *p, size_t n)
{
    return n >= 4 && (std::memcmp(p, "wOFF", 4) == 0 || std::memcmp(p, "wOF2", 4) == 0);
}

bool is_remote_url(char const *src)
{
    if (!src || !src[0]) {
        return false;
    }
    if (g_ascii_strncasecmp(src, "http://", 7) == 0 || g_ascii_strncasecmp(src, "https://", 8) == 0) {
        return true;
    }
    return src[0] == '/' && src[1] == '/' && src[2] && src[2] != '/';
}

} // namespace

namespace Inkscape {

bool DocumentFontMap::env_forces_fallback(char const **why)
{
    char const *e = g_getenv("INKSCAPE_DOCUMENT_FONT_FALLBACK");
    if (parse_boolish(e)) {
        if (why) {
            *why = "env INKSCAPE_DOCUMENT_FONT_FALLBACK";
        }
        return true;
    }
    return false;
}

bool DocumentFontMap::pref_forces_fallback()
{
    return Preferences::get()->getBool("/options/font/force_document_font_fallback", false);
}

DocumentFontMap::DocumentFontMap(SPDocument *document)
    : _document(document)
{
    static unsigned next_serial = 1;
    _serial = next_serial++;
    char const *docname = document && document->getDocumentName() ? document->getDocumentName() : "(unnamed)";
    DFM_MSG("DocumentFontMap: created map for '%s' serial=%u", docname, _serial);
}

DocumentFontMap::~DocumentFontMap()
{
    DFM_MSG("DocumentFontMap: destroyed (%zu faces) serial=%u", _faces.size(), _serial);
    _loaded.clear();
    if (_ctx) {
        g_object_unref(_ctx);
        _ctx = nullptr;
    }
    if (_map) {
        g_object_unref(_map);
        _map = nullptr;
    }
    _private_config = nullptr;
    for (auto const &face : _faces) {
        if (face.cache_path.empty() || _cache_dir.empty()) {
            continue;
        }
        if (face.cache_path.rfind(_cache_dir, 0) == 0) {
            g_unlink(face.cache_path.c_str());
        }
    }
    if (!_cache_dir.empty()) {
        g_rmdir(_cache_dir.c_str());
    }
}

void DocumentFontMap::ensure_map()
{
    if (_map) {
        return;
    }
    _map = pango_ft2_font_map_new();
    pango_ft2_font_map_set_resolution(PANGO_FT2_FONT_MAP(_map), 72, 72);
#if PANGO_VERSION_CHECK(1, 48, 0)
    pango_fc_font_map_set_default_substitute(PANGO_FC_FONT_MAP(_map), factory_substitute, this, nullptr);
#else
    pango_ft2_font_map_set_default_substitute(PANGO_FT2_FONT_MAP(_map), factory_substitute, this, nullptr);
#endif
    _ctx = pango_font_map_create_context(_map);
    pango_context_set_language(_ctx, pango_language_from_string("und"));

    // Private FcConfig so add_font_file does not publish faces on the process map.
    if (PANGO_IS_FC_FONT_MAP(_map)) {
        auto *cfg = FcInitLoadConfigAndFonts();
        pango_fc_font_map_set_config(PANGO_FC_FONT_MAP(_map), cfg);
        FcConfigDestroy(cfg);
        _private_config = pango_fc_font_map_get_config(PANGO_FC_FONT_MAP(_map));
        DFM_MSG("DocumentFontMap: attached private FcConfig");
    }

    choose_backend();
}

void DocumentFontMap::choose_backend()
{
    if (_backend_chosen) {
        return;
    }
    _backend_chosen = true;

    char const *env_why = nullptr;
    _fallback_forced = env_forces_fallback(&env_why);
    if (!_fallback_forced && pref_forces_fallback()) {
        _fallback_forced = true;
        _force_reason = "pref /options/font/force_document_font_fallback";
    } else if (_fallback_forced) {
        _force_reason = env_why;
    }

    bool const have_pango =
#if PANGO_VERSION_CHECK(1, 56, 0)
        true;
#else
        false;
#endif
    bool const have_fc = PANGO_IS_FC_FONT_MAP(_map);

    if (_fallback_forced) {
        DFM_MSG("DocumentFontMap: fallback FORCED (%s)", _force_reason ? _force_reason : "unknown");
        if (have_fc) {
            _backend = Backend::FcConfig;
        } else {
            g_warning("DocumentFontMap: fallback FORCED but Fontconfig backend is unavailable");
            _backend = have_pango ? Backend::PangoAddFile : Backend::Unavailable;
        }
    } else if (have_pango) {
        _backend = Backend::PangoAddFile;
    } else if (have_fc) {
        _backend = Backend::FcConfig;
    } else {
        _backend = Backend::Unavailable;
    }

    DFM_MSG("DocumentFontMap: using backend %s (pango %s)", backend_name(_backend), pango_version_string());
}

bool DocumentFontMap::add_via_pango(std::string const &path, GError **err)
{
#if PANGO_VERSION_CHECK(1, 56, 0)
    return pango_font_map_add_font_file(_map, path.c_str(), err);
#else
    if (err) {
        g_set_error(err, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED,
                    "pango_font_map_add_font_file requires Pango 1.56");
    }
    return false;
#endif
}

bool DocumentFontMap::add_via_fc(std::string const &path, GError **err)
{
    if (!PANGO_IS_FC_FONT_MAP(_map)) {
        if (err) {
            g_set_error(err, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED,
                        "Need a Fontconfig Pango map for FcConfig fallback");
        }
        return false;
    }
    ensure_map();
    auto *cfg = static_cast<FcConfig *>(_private_config);
    if (!cfg) {
        if (err) {
            g_set_error(err, G_IO_ERROR, G_IO_ERROR_FAILED, "No private FcConfig on document map");
        }
        return false;
    }
    gchar *file = g_filename_from_utf8(path.c_str(), -1, nullptr, nullptr, nullptr);
    if (!file) {
        if (err) {
            g_set_error(err, G_IO_ERROR, G_IO_ERROR_INVALID_FILENAME, "Cannot convert path to filesystem encoding");
        }
        return false;
    }
    FcBool res = FcConfigAppFontAddFile(cfg, reinterpret_cast<FcChar8 const *>(file));
    g_free(file);
    if (res != FcTrue) {
        if (err) {
            g_set_error(err, G_IO_ERROR, G_IO_ERROR_FAILED, "FcConfigAppFontAddFile failed");
        }
        return false;
    }
    pango_fc_font_map_config_changed(PANGO_FC_FONT_MAP(_map));
    return true;
}

bool DocumentFontMap::add_file(std::string const &path, GError **err)
{
    ensure_map();
    switch (_backend) {
        case Backend::PangoAddFile:
            return add_via_pango(path, err);
        case Backend::FcConfig:
            return add_via_fc(path, err);
        default:
            if (err) {
                g_set_error(err, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED, "No document-font backend available");
            }
            return false;
    }
}

bool DocumentFontMap::ensure_cache_dir()
{
    if (!_cache_dir.empty()) {
        return true;
    }
    gchar *dir = g_dir_make_tmp("inkscape-dfm-XXXXXX", nullptr);
    if (!dir) {
        g_warning("DocumentFontMap: cannot create temp dir for font cache");
        return false;
    }
    _cache_dir = dir;
    g_free(dir);
    DFM_MSG("DocumentFontMap: cache dir '%s'", _cache_dir.c_str());
    return true;
}

std::string DocumentFontMap::write_cache_file(std::string const &bytes, std::string const &ext)
{
    if (!ensure_cache_dir()) {
        return {};
    }
    auto path = Glib::build_filename(_cache_dir, Glib::ustring::compose("face-%1%2", _faces.size(), ext));
    GError *error = nullptr;
    if (!g_file_set_contents(path.c_str(), bytes.data(), static_cast<gssize>(bytes.size()), &error)) {
        g_warning("DocumentFontMap: failed to write cache '%s': %s", path.c_str(),
                  error ? error->message : "unknown");
        g_clear_error(&error);
        return {};
    }
    return path;
}

bool DocumentFontMap::decode_and_add(Face &face)
{
    if (face.src_kind == SrcKind::Skipped) {
        return false;
    }
    if (face.src_kind == SrcKind::DataUri) {
        auto const &src = face.src.raw();
        auto comma = src.find(',');
        if (comma == std::string::npos) {
            g_warning("DocumentFontMap: data: URI missing comma for family='%s'", face.family.c_str());
            return false;
        }
        auto header = src.substr(0, comma);
        auto payload = src.substr(comma + 1);
        bool is_b64 = header.find(";base64") != std::string::npos;
        std::string bytes;
        if (is_b64) {
            gsize len = 0;
            guchar *raw = g_base64_decode(payload.c_str(), &len);
            if (!raw || !len) {
                g_warning("DocumentFontMap: base64 decode failed for family='%s'", face.family.c_str());
                g_free(raw);
                return false;
            }
            bytes.assign(reinterpret_cast<char *>(raw), len);
            g_free(raw);
        } else {
            gchar *unesc = g_uri_unescape_string(payload.c_str(), nullptr);
            if (!unesc) {
                return false;
            }
            bytes = unesc;
            g_free(unesc);
        }
        auto const *p = reinterpret_cast<uint8_t const *>(bytes.data());
        if (is_woff_magic(p, bytes.size())) {
            g_warning("DocumentFontMap: WOFF/WOFF2 not supported for family='%s'", face.family.c_str());
            return false;
        }
        if (!is_sfnt_magic(p, bytes.size())) {
            g_warning("DocumentFontMap: not a TTF/OTF for family='%s'", face.family.c_str());
            return false;
        }
        face.cache_path = write_cache_file(bytes, ext_for_hint(header));
    } else if (face.src_kind == SrcKind::RelativeFile) {
        if (_document) {
            if (char const *fn = _document->getDocumentFilename()) {
                face.cache_path = IO::Resource::get_filename(fn, face.src.raw());
            }
            if (face.cache_path.empty()) {
                if (char const *base = _document->getDocumentBase()) {
                    face.cache_path = IO::Resource::get_filename(base, face.src.raw());
                }
            }
        }
        if (face.cache_path.empty()) {
            g_warning("DocumentFontMap: no document path to resolve relative src '%s'", face.src.c_str());
            return false;
        }
    } else if (face.src_kind == SrcKind::LocalFile) {
        GError *uri_err = nullptr;
        gchar *path = g_filename_from_uri(face.src.c_str(), nullptr, &uri_err);
        if (!path) {
            g_warning("DocumentFontMap: bad file:// src '%s': %s", face.src.c_str(),
                      uri_err ? uri_err->message : "unknown");
            g_clear_error(&uri_err);
            return false;
        }
        face.cache_path = path;
        g_free(path);
    }

    if (face.cache_path.empty() || !Inkscape::IO::file_test(face.cache_path.c_str(), G_FILE_TEST_IS_REGULAR)) {
        g_warning("DocumentFontMap: no font file for family='%s' src='%s'", face.family.c_str(),
                  face.src.c_str());
        return false;
    }

    if (face.src_kind != SrcKind::DataUri) {
        gchar *raw = nullptr;
        gsize len = 0;
        GError *rderr = nullptr;
        if (g_file_get_contents(face.cache_path.c_str(), &raw, &len, &rderr)) {
            auto const *p = reinterpret_cast<uint8_t const *>(raw);
            bool woff = is_woff_magic(p, len);
            bool sfnt = is_sfnt_magic(p, len);
            g_free(raw);
            if (woff) {
                g_warning("DocumentFontMap: WOFF/WOFF2 not supported for family='%s'", face.family.c_str());
                return false;
            }
            if (!sfnt) {
                g_warning("DocumentFontMap: not a TTF/OTF for family='%s'", face.family.c_str());
                return false;
            }
        } else {
            g_clear_error(&rderr);
        }
    }

    GError *err = nullptr;
    bool ok = add_file(face.cache_path, &err);
    DFM_MSG("DocumentFontMap: add_file family='%s' cache='%s' via %s: %s", face.family.c_str(),
            face.cache_path.c_str(), backend_name(_backend), ok ? "ok" : "FAILED");
    if (!ok) {
        g_warning("DocumentFontMap: add_file failed: %s", err ? err->message : "unknown");
        g_clear_error(&err);
    }
    face.loaded = ok;
    if (ok) {
        face.pango_family = query_file_family(face.cache_path);
        DFM_MSG("DocumentFontMap: CSS family '%s' maps to Pango family '%s'", face.family.c_str(),
                face.pango_family.empty() ? "(unknown)" : face.pango_family.c_str());
    }
    return ok;
}

void DocumentFontMap::verify_css_family_resolves(Face &face)
{
    if (!face.loaded || face.family.empty()) {
        return;
    }
    ensure_map();
    if (!_map || !_ctx) {
        return;
    }
    PangoFontDescription *desc = pango_font_description_new();
    pango_font_description_set_family(desc, face.family.c_str());
    pango_font_description_set_size(desc, 12 * PANGO_SCALE);
    rewrite_description(desc);
    PangoFont *font = pango_font_map_load_font(_map, _ctx, desc);
    Glib::ustring got;
    if (font) {
        PangoFontDescription *got_desc = pango_font_describe(font);
        if (auto const *fam = pango_font_description_get_family(got_desc)) {
            got = fam;
        }
        pango_font_description_free(got_desc);
        g_object_unref(font);
    }
    pango_font_description_free(desc);

    bool const hit = !got.empty() &&
                     (families_equal(got.c_str(), face.family.c_str()) ||
                      (!face.pango_family.empty() && families_equal(got.c_str(), face.pango_family.c_str())));
    DFM_MSG("DocumentFontMap: probe CSS family '%s' got '%s'%s", face.family.c_str(),
            got.empty() ? "(none)" : got.c_str(), hit ? "" : " (NOT this face)");
    if (!hit) {
        g_warning("DocumentFontMap: CSS family '%s' resolved to '%s' instead of this face",
                  face.family.c_str(), got.empty() ? "(none)" : got.c_str());
        face.loaded = false;
    }
}

Glib::ustring DocumentFontMap::canonical_css_family(Glib::ustring const &name) const
{
    auto token = first_family_token(name.c_str());
    if (token.empty()) {
        return {};
    }
    for (auto const &face : _faces) {
        if (face.loaded && families_equal(face.family.c_str(), token.c_str())) {
            return face.family;
        }
    }
    return {};
}

bool DocumentFontMap::has_css_family(Glib::ustring const &name) const
{
    return !canonical_css_family(name).empty();
}

bool DocumentFontMap::rewrite_description(PangoFontDescription *descr) const
{
    if (!descr) {
        return false;
    }
    char const *fam = pango_font_description_get_family(descr);
    if (!fam) {
        return false;
    }
    auto token = first_family_token(fam);
    for (auto const &face : _faces) {
        if (!face.loaded || face.pango_family.empty()) {
            continue;
        }
        if (!families_equal(face.family.c_str(), token.c_str())) {
            continue;
        }
        std::string rest;
        char const *comma = strchr(fam, ',');
        if (comma) {
            rest = comma;
        }
        std::string rewritten = face.pango_family.raw() + rest;
        pango_font_description_set_family(descr, rewritten.c_str());
        DFM_MSG("DocumentFontMap: rewrite family '%s' -> '%s'", fam, rewritten.c_str());
        return true;
    }
    return false;
}

void DocumentFontMap::add_font_face_rule(CRDeclaration const *decls)
{
    ensure_map();

    Face face;
    std::vector<std::string> srcs;

    for (auto const *cur = decls; cur; cur = cur->next) {
        if (!cur->property || !cur->property->stryng || !cur->property->stryng->str) {
            continue;
        }
        char const *prop = cur->property->stryng->str;
        if (g_ascii_strcasecmp(prop, "font-family") == 0) {
            face.family = strip_quotes(term_string(cur->value));
        } else if (g_ascii_strcasecmp(prop, "src") == 0) {
            for (CRTerm const *t = cur->value; t; t = t->next) {
                if (t->type == TERM_URI) {
                    srcs.push_back(term_string(t));
                } else if (t->type == TERM_FUNCTION) {
                    auto name = term_string(t);
                    if (g_ascii_strcasecmp(name.c_str(), "local") == 0) {
                        continue;
                    }
                    if (g_ascii_strcasecmp(name.c_str(), "url") == 0 && t->ext_content.func_param) {
                        srcs.push_back(strip_quotes(term_string(t->ext_content.func_param)));
                    }
                } else if (t->type == TERM_STRING) {
                    srcs.push_back(strip_quotes(term_string(t)));
                }
            }
            if (srcs.empty()) {
                auto raw = term_string(cur->value);
                if (raw.find("url(") != std::string::npos) {
                    auto a = raw.find('(');
                    auto b = raw.rfind(')');
                    if (a != std::string::npos && b != std::string::npos && b > a) {
                        srcs.push_back(strip_quotes(raw.substr(a + 1, b - a - 1)));
                    }
                } else if (!raw.empty()) {
                    srcs.push_back(strip_quotes(raw));
                }
            }
        }
    }

    DFM_MSG("DocumentFontMap: @font-face family='%s' src-candidates=%zu",
            face.family.empty() ? "?" : face.family.c_str(), srcs.size());

    bool added = false;
    for (auto const &src : srcs) {
        Face one = face;
        one.src = src;
        if (g_ascii_strncasecmp(src.c_str(), "data:", 5) == 0) {
            one.src_kind = SrcKind::DataUri;
        } else if (is_remote_url(src.c_str())) {
            DFM_MSG("DocumentFontMap: skip remote src '%s' for family='%s'", src.c_str(), face.family.c_str());
            continue;
        } else if (g_ascii_strncasecmp(src.c_str(), "file:", 5) == 0) {
            one.src_kind = SrcKind::LocalFile;
        } else if (looks_like_sfnt_file(src) || src.find("://") == std::string::npos) {
            one.src_kind = SrcKind::RelativeFile;
        } else {
            DFM_MSG("DocumentFontMap: skip src '%s' for family='%s'", src.c_str(), face.family.c_str());
            continue;
        }
        if (decode_and_add(one)) {
            _faces.push_back(std::move(one));
            added = true;
            verify_css_family_resolves(_faces.back());
            break;
        }
    }
    if (!added) {
        g_warning("DocumentFontMap: no resolvable TTF/OTF src for family='%s'",
                  face.family.empty() ? "?" : face.family.c_str());
    }
}

PangoFontMap *DocumentFontMap::map()
{
    ensure_map();
    return _map;
}

PangoContext *DocumentFontMap::context()
{
    ensure_map();
    return _ctx;
}

std::shared_ptr<FontInstance> DocumentFontMap::face(PangoFontDescription *descr, bool canFail)
{
    ensure_map();
    pango_font_description_set_size(descr, FontFactory::fontSize * PANGO_SCALE);
    rewrite_description(descr);
    char const *family = pango_font_description_get_family(descr);
    DFM_MSG("DocumentFontMap: Face() via document map family='%s'", family ? family : "(null)");

    char *key = pango_font_description_to_string(descr);
    std::string skey = key ? key : "";
    g_free(key);
    if (auto it = _loaded.find(skey); it != _loaded.end()) {
        return it->second;
    }

    try {
        auto descr_copy = pango_font_description_copy(descr);
        PangoFont *pfont = pango_font_map_load_font(_map, _ctx, descr);
        auto inst = std::make_shared<FontInstance>(pfont, descr_copy);
        _loaded.emplace(skey, inst);
        return inst;
    } catch (FontInstance::CtorException const &) {
        if (canFail) {
            pango_font_description_set_family(descr, "sans-serif");
            return face(descr, false);
        }
        throw;
    }
}

} // namespace Inkscape
