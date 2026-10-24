// SPDX-License-Identifier: GPL-2.0-or-later
/** @file
 * Style interactions with libnrtype
 *//*
 * Copyright (C) 2018-2026 Authors
 * Released under GNU GPL v2+, read the file 'COPYING' for more information.
 */

#include "style-text.h"
#include "libnrtype/font-instance.h"
#include "libnrtype/font-utils.h"

// User must free return value.
// Used below to find font for finding font metrics.
// Used in Layout-TNG-Input to find font.
// Used in FontLister.
PangoFontDescription *ink_font_description_from_style(SPStyle const *style)
{
    PangoFontDescription *descr = pango_font_description_new();

    pango_font_description_set_family(descr, style->font_family.value());

    // This duplicates Layout::EnumConversionItem... perhaps we can share code?
    switch (style->font_style.computed) {
        case SP_CSS_FONT_STYLE_ITALIC:
            pango_font_description_set_style(descr, PANGO_STYLE_ITALIC);
            break;

        case SP_CSS_FONT_STYLE_OBLIQUE:
            pango_font_description_set_style(descr, PANGO_STYLE_OBLIQUE);
            break;

        case SP_CSS_FONT_STYLE_NORMAL:
        default:
            pango_font_description_set_style(descr, PANGO_STYLE_NORMAL);
            break;
    }

    // CSS now allows any value between 1 and 1000, including 1000.
    auto weight = style->font_weight.computed;
    if (weight > 0 && weight <= 1000) {
        pango_font_description_set_weight(descr, static_cast<PangoWeight>(style->font_weight.computed));
    } else {
        // SP_CSS_FONT_WEIGHT_LIGHTER, SP_CSS_FONT_WEIGHT_BOLDER (shouldn't be in computed).
        g_warning("FaceFromStyle: Unrecognized font_weight.computed value");
        pango_font_description_set_weight(descr, PANGO_WEIGHT_NORMAL);
    }

    switch (style->font_stretch.computed) {
        case SP_CSS_FONT_STRETCH_ULTRA_CONDENSED:
            pango_font_description_set_stretch(descr, PANGO_STRETCH_ULTRA_CONDENSED);
            break;

        case SP_CSS_FONT_STRETCH_EXTRA_CONDENSED:
            pango_font_description_set_stretch(descr, PANGO_STRETCH_EXTRA_CONDENSED);
            break;

        case SP_CSS_FONT_STRETCH_CONDENSED:
            pango_font_description_set_stretch(descr, PANGO_STRETCH_CONDENSED);
            break;

        case SP_CSS_FONT_STRETCH_SEMI_CONDENSED:
            pango_font_description_set_stretch(descr, PANGO_STRETCH_SEMI_CONDENSED);
            break;

        case SP_CSS_FONT_STRETCH_NORMAL:
            pango_font_description_set_stretch(descr, PANGO_STRETCH_NORMAL);
            break;

        case SP_CSS_FONT_STRETCH_SEMI_EXPANDED:
            pango_font_description_set_stretch(descr, PANGO_STRETCH_SEMI_EXPANDED);
            break;

        case SP_CSS_FONT_STRETCH_EXPANDED:
            pango_font_description_set_stretch(descr, PANGO_STRETCH_EXPANDED);
            break;

        case SP_CSS_FONT_STRETCH_EXTRA_EXPANDED:
            pango_font_description_set_stretch(descr, PANGO_STRETCH_EXTRA_EXPANDED);
            break;

        case SP_CSS_FONT_STRETCH_ULTRA_EXPANDED:
            pango_font_description_set_stretch(descr, PANGO_STRETCH_ULTRA_EXPANDED);

        case SP_CSS_FONT_STRETCH_WIDER:
        case SP_CSS_FONT_STRETCH_NARROWER:
        default:
            g_warning("FaceFromStyle: Unrecognized font_stretch.computed value");
            pango_font_description_set_stretch(descr, PANGO_STRETCH_NORMAL);
            break;
    }

    switch (style->font_variant.computed) {
        case SP_CSS_FONT_VARIANT_SMALL_CAPS:
            pango_font_description_set_variant(descr, PANGO_VARIANT_SMALL_CAPS);
            break;

        case SP_CSS_FONT_VARIANT_NORMAL:
        default:
            pango_font_description_set_variant(descr, PANGO_VARIANT_NORMAL);
            break;
    }

    // Check if not empty as Pango will add @ to string even if empty (bug in Pango?).
    if (!style->font_variation_settings.axes.empty()) {
        pango_font_description_set_variations(descr, style->font_variation_settings.toString().c_str());
    }

    // Set "opsz" variable font axis, if present in font.
    // Pango commit ca7ff79717305f5667759810c1e6f6d429617c52 sets "opsz" to point size,
    // in the function pango_fc_font_create_hb_font().
    auto font = FontFactory::get().Face(descr);
    auto axes = font->get_opentype_varaxes();
    for (auto axis : axes) {
        if (axis.tag == "opsz") {
            // The font face has the "opsz" axis.
            auto variations = pango_font_description_get_variations(descr);
            auto variations_map = Inkscape::parse_variations(variations);
            if (style->font_optical_sizing.computed == SP_CSS_FONT_OPTICAL_SIZING_NONE) {
                // Always use default value from font.
                variations_map["opsz"] = std::to_string(axis.def);
            } else {
                // Auto: use "opsz" from font-variation-settings if present or from transformed font-size.
                if (!variations_map.count("opsz")) {
                    // Not already set, set to scaled font size.
                    variations_map["opsz"] = std::to_string(style->font_size.opsz);
                }
            }
            auto variations_out = Inkscape::variations_to_string(variations_map);
            pango_font_description_set_variations(descr, variations_out.c_str());
            break;
        }
    }

    pango_font_description_set_size(descr, style->font_size * PANGO_SCALE);

    return descr;
}

// Only used by SPText, SPFlowText, and Layout::Calculator to find the "strut" using FontMetrics.
std::shared_ptr<FontInstance> ink_font_from_style(SPStyle const *style)
{
    auto temp_descr = ink_font_description_from_style(style);
    auto font = FontFactory::get().Face(temp_descr);
    pango_font_description_free(temp_descr);
    return font;
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
// vim: filetype=cpp:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:fileencoding=utf-8 :
