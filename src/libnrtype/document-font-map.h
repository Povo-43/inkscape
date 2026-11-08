// SPDX-License-Identifier: GPL-2.0-or-later
/** @file
 * Per-document @font-face map. Owns a PangoFontMap that sees system fonts
 * plus this document's TTF/OTF faces (data: and local file src). Faces are
 * not registered on the process-global FontFactory.
 */
#ifndef LIBNRTYPE_DOCUMENT_FONT_MAP_H
#define LIBNRTYPE_DOCUMENT_FONT_MAP_H

#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

#include <glibmm/ustring.h>
#include <pango/pango-font.h>
#include <pango/pango-fontmap.h>

struct _CRDeclaration;
typedef struct _CRDeclaration CRDeclaration;

class FontInstance;
class SPDocument;

namespace Inkscape {

class DocumentFontMap
{
public:
    enum class Backend
    {
        PangoAddFile,
        FcConfig,
        Unavailable
    };

    enum class SrcKind
    {
        DataUri,
        RelativeFile,
        LocalFile, ///< file:// URL
        Skipped
    };

    struct Face
    {
        Glib::ustring family;
        SrcKind src_kind = SrcKind::Skipped;
        Glib::ustring src;
        std::string cache_path;
        Glib::ustring pango_family; ///< name table inside the font file, not the CSS name
        bool loaded = false;
    };

    explicit DocumentFontMap(SPDocument *document);
    ~DocumentFontMap();

    DocumentFontMap(DocumentFontMap const &) = delete;
    DocumentFontMap &operator=(DocumentFontMap const &) = delete;

    void add_font_face_rule(CRDeclaration const *decls);

    bool has_faces() const { return !_faces.empty(); }
    std::vector<Face> const &faces() const { return _faces; }

    bool has_css_family(Glib::ustring const &name) const;
    Glib::ustring canonical_css_family(Glib::ustring const &name) const;

    /// Rewrite CSS @font-face family names in a Pango description to the file's real family.
    bool rewrite_description(PangoFontDescription *descr) const;

    PangoFontMap *map();
    PangoContext *context();

    std::shared_ptr<FontInstance> face(PangoFontDescription *descr, bool canFail = true);

    Backend backend() const { return _backend; }

private:
    void ensure_map();
    void choose_backend();
    bool add_file(std::string const &path, GError **err);
    bool add_via_pango(std::string const &path, GError **err);
    bool add_via_fc(std::string const &path, GError **err);
    bool decode_and_add(Face &face);
    void verify_css_family_resolves(Face &face);
    bool ensure_cache_dir();
    std::string write_cache_file(std::string const &bytes, std::string const &ext);
    static bool env_forces_fallback(char const **why);
    static bool pref_forces_fallback();

    SPDocument *_document = nullptr;
    unsigned _serial = 0;
    std::vector<Face> _faces;
    PangoFontMap *_map = nullptr;
    PangoContext *_ctx = nullptr;
    void *_private_config = nullptr; // FcConfig*, only if set on the map
    Backend _backend = Backend::Unavailable;
    bool _backend_chosen = false;
    bool _fallback_forced = false;
    char const *_force_reason = nullptr;
    std::string _cache_dir;
    std::unordered_map<std::string, std::shared_ptr<FontInstance>> _loaded;
};

} // namespace Inkscape

#endif // LIBNRTYPE_DOCUMENT_FONT_MAP_H
