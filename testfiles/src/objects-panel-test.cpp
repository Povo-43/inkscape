// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Regression tests for the Layers and Objects panel.
 *
 * Released under GNU GPL v2+, read the file 'COPYING' for more information.
 */

#include <cstdlib>
#include <gtest/gtest.h>
#include <gtk/gtk.h>
#include <gtkmm/treestore.h>

namespace Inkscape::UI::Dialog {
bool objects_panel_use_native_tree_reordering(bool over_name_column);
}

namespace {

class TestColumns final : public Gtk::TreeModel::ColumnRecord
{
public:
    TestColumns() { add(label); }

    Gtk::TreeModelColumn<Glib::ustring> label;
};

struct GtkSelectionDataFields
{
    // GTK 3 does not expose a constructor for selection data with a specific
    // target; this mirrors GtkSelectionData's private layout for this child
    // process so we can exercise GTK_TREE_MODEL_ROW serialization directly.
    GdkAtom selection = GDK_NONE;
    GdkAtom target = GDK_NONE;
    GdkAtom type = GDK_NONE;
    gint format = 0;
    guchar *data = nullptr;
    gint length = -1;
    GdkDisplay *display = nullptr;
};

void request_native_tree_model_row_data_for_deep_path()
{
    TestColumns columns;
    auto store = Gtk::TreeStore::create(columns);

    auto root = *store->append();
    root[columns.label] = "root";
    auto child = *store->append(root.children());
    child[columns.label] = "child";
    auto grandchild = *store->append(child.children());
    grandchild[columns.label] = "grandchild";

    auto path = store->get_path(grandchild);
    if (path.to_string() != "0:0:0") {
        std::_Exit(2);
    }

    GtkSelectionDataFields selection_data;
    selection_data.target = gdk_atom_intern_static_string("GTK_TREE_MODEL_ROW");

    auto *gtk_selection_data = reinterpret_cast<GtkSelectionData *>(&selection_data);
    if (!gtk_tree_drag_source_drag_data_get(GTK_TREE_DRAG_SOURCE(store->gobj()), path.gobj(), gtk_selection_data)) {
        std::_Exit(3);
    }

    g_free(selection_data.data);
}

} // namespace

TEST(ObjectsPanelTest, DoesNotRequestNativeTreeModelRowDataForDeepRows)
{
    ASSERT_EXIT(
        {
            if (Inkscape::UI::Dialog::objects_panel_use_native_tree_reordering(true)) {
                request_native_tree_model_row_data_for_deep_path();
                std::_Exit(4);
            }
            std::_Exit(0);
        },
        ::testing::ExitedWithCode(0), "");
}
