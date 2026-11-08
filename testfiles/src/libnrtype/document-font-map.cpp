// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Tests for per-document TTF/OTF @font-face loading (data: and local file src).
 *
 * Copyright (C) 2026 Authors
 *
 * Released under GNU GPL v2+, read the file 'COPYING' for more information.
 */

#include <gtest/gtest.h>

#include <glib.h>
#include <glibmm/miscutils.h>
#include <string>
#include <string_view>

#include "document.h"
#include "inkscape.h"
#include "libnrtype/document-font-map.h"
#include "libnrtype/font-factory.h"
#include "libnrtype/font-instance.h"

using namespace std::literals;

namespace {

std::string fonts_dir()
{
    return Glib::build_filename(INKSCAPE_TESTS_DIR, "rendering_tests", "fonts");
}

std::string read_file(std::string const &path)
{
    gchar *raw = nullptr;
    gsize len = 0;
    EXPECT_TRUE(g_file_get_contents(path.c_str(), &raw, &len, nullptr)) << path;
    std::string out(raw ? raw : "", len);
    g_free(raw);
    return out;
}

std::string base64_file(std::string const &path)
{
    auto bytes = read_file(path);
    gchar *b64 = g_base64_encode(reinterpret_cast<guchar const *>(bytes.data()), bytes.size());
    std::string out = b64 ? b64 : "";
    g_free(b64);
    return out;
}

std::string data_uri_for(std::string const &ttf_path)
{
    return "data:font/ttf;base64," + base64_file(ttf_path);
}

std::string svg_with_face(std::string const &css_family, std::string const &src)
{
    return "<svg xmlns='http://www.w3.org/2000/svg'>\n"
           "<style>@font-face { font-family: '" +
           css_family + "'; src: url('" + src + "'); }</style>\n"
           "<text style=\"font-family: '" + css_family + "'\">A</text>\n"
           "</svg>";
}

std::unique_ptr<SPDocument> load_svg(std::string const &svg, std::string const &filename = "")
{
    auto doc = SPDocument::createNewDocFromMem(std::string_view(svg), filename);
    EXPECT_TRUE(doc);
    return doc;
}

char const *asked_family(FontInstance const &inst)
{
    return pango_font_description_get_family(inst.get_descr());
}

std::string loaded_family(FontInstance const &inst)
{
    PangoFontDescription *got = pango_font_describe(inst.get_font());
    char const *fam = pango_font_description_get_family(got);
    std::string out = fam ? fam : "";
    pango_font_description_free(got);
    return out;
}

std::shared_ptr<FontInstance> face_for(SPDocument *doc, char const *family)
{
    PangoFontDescription *descr = pango_font_description_new();
    pango_font_description_set_family(descr, family);
    auto inst = FontFactory::get().Face(descr, true, doc);
    pango_font_description_free(descr);
    return inst;
}

bool process_map_has(char const *family)
{
    for (auto const &name : FontFactory::get().GetAllFontNames()) {
        if (g_ascii_strcasecmp(name.c_str(), family) == 0) {
            return true;
        }
    }
    return false;
}

class DocumentFontMapTest : public ::testing::Test
{
protected:
    static void SetUpTestSuite()
    {
        Inkscape::Application::create(false);
    }
};

TEST_F(DocumentFontMapTest, DataUriTtfUsesFileFamilyNotCssName)
{
    auto comic = Glib::build_filename(fonts_dir(), "ComicSpice.ttf");
    auto doc = load_svg(svg_with_face("DocFaceA", data_uri_for(comic)));
    ASSERT_TRUE(doc);

    auto *dfm = doc->peekDocumentFontMap();
    ASSERT_TRUE(dfm);
    EXPECT_TRUE(dfm->has_css_family("DocFaceA"));

    auto inst = face_for(doc.get(), "DocFaceA");
    ASSERT_TRUE(inst);
    EXPECT_STREQ(asked_family(*inst), "ComicSpice");
    EXPECT_EQ(loaded_family(*inst), "ComicSpice");

    EXPECT_FALSE(process_map_has("DocFaceA"));
}

TEST_F(DocumentFontMapTest, RelativeFileSrc)
{
    auto neucha = Glib::build_filename(fonts_dir(), "Neucha.ttf");
    ASSERT_TRUE(g_file_test(neucha.c_str(), G_FILE_TEST_IS_REGULAR));

    auto filename = Glib::build_filename(fonts_dir(), "dfm-relative.svg");
    auto doc = load_svg(svg_with_face("DocFaceFile", "Neucha.ttf"), filename);
    ASSERT_TRUE(doc);

    auto *dfm = doc->peekDocumentFontMap();
    ASSERT_TRUE(dfm);
    EXPECT_TRUE(dfm->has_css_family("DocFaceFile"));

    auto inst = face_for(doc.get(), "DocFaceFile");
    ASSERT_TRUE(inst);
    EXPECT_STREQ(asked_family(*inst), "Neucha");
    EXPECT_EQ(loaded_family(*inst), "Neucha");

    EXPECT_FALSE(process_map_has("DocFaceFile"));
}

TEST_F(DocumentFontMapTest, TwoDocumentsSameCssFamilyStayIsolated)
{
    auto comic = Glib::build_filename(fonts_dir(), "ComicSpice.ttf");
    auto neucha = Glib::build_filename(fonts_dir(), "Neucha.ttf");

    auto doc_a = load_svg(svg_with_face("SharedFace", data_uri_for(comic)));
    auto doc_b = load_svg(svg_with_face("SharedFace", data_uri_for(neucha)));
    ASSERT_TRUE(doc_a);
    ASSERT_TRUE(doc_b);

    auto inst_a = face_for(doc_a.get(), "SharedFace");
    auto inst_b = face_for(doc_b.get(), "SharedFace");
    ASSERT_TRUE(inst_a);
    ASSERT_TRUE(inst_b);

    EXPECT_EQ(loaded_family(*inst_a), "ComicSpice");
    EXPECT_EQ(loaded_family(*inst_b), "Neucha");
    EXPECT_NE(loaded_family(*inst_a), loaded_family(*inst_b));

    EXPECT_FALSE(process_map_has("SharedFace"));
}

TEST_F(DocumentFontMapTest, FaceWithoutDocumentDoesNotSeeCssFamily)
{
    auto comic = Glib::build_filename(fonts_dir(), "ComicSpice.ttf");
    auto doc = load_svg(svg_with_face("DocFaceOnly", data_uri_for(comic)));
    ASSERT_TRUE(doc);
    ASSERT_TRUE(doc->peekDocumentFontMap());
    EXPECT_TRUE(doc->peekDocumentFontMap()->has_css_family("DocFaceOnly"));

    auto inst = face_for(nullptr, "DocFaceOnly");
    ASSERT_TRUE(inst);
    EXPECT_NE(loaded_family(*inst), "DocFaceOnly");
    EXPECT_FALSE(process_map_has("DocFaceOnly"));
}

TEST_F(DocumentFontMapTest, RemoteSrcIsSkipped)
{
    auto doc = load_svg(svg_with_face("RemoteFace", "https://example.invalid/font.ttf"));
    ASSERT_TRUE(doc);
    auto *dfm = doc->peekDocumentFontMap();
    if (dfm) {
        EXPECT_FALSE(dfm->has_css_family("RemoteFace"));
    }
}

} // namespace

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
