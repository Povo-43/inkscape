// SPDX-License-Identifier: GPL-2.0-or-later

#include "icon-combobox.h"

#include <gtkmm/binlayout.h>
#include <gtkmm/box.h>
#include <gtkmm/image.h>
#include <gtkmm/label.h>
#include <gtkmm/picture.h>
#include <gtkmm/separator.h>
#include <gtkmm/togglebutton.h>
#include "ui/util.h"

namespace Inkscape::UI::Widget {

IconComboBox::IconComboBox(Glib::RefPtr<Gio::ListStore<ListItem>> store, bool use_icons, HeaderType header) {
    construct(store, use_icons, header);
}

IconComboBox::IconComboBox(bool use_icons, HeaderType header) {
    construct({}, use_icons, header);
}

IconComboBox::IconComboBox(BaseObjectType* cobject, const Glib::RefPtr<Gtk::Builder>&, Glib::RefPtr<Gio::ListStore<ListItem>> store, bool use_icons, HeaderType header): Gtk::DropDown(cobject) {
    construct(store, use_icons, header);
}

void IconComboBox::construct(Glib::RefPtr<Gio::ListStore<ListItem>> store, bool use_icons, HeaderType header) {
    _factory = Gtk::SignalListItemFactory::create();

    auto set_up_image = [=](Gtk::Box& box, Geom::Point size, bool center) {
        if (use_icons) {
            auto icon = Gtk::make_managed<Gtk::Image>();
            icon->set_icon_size(Gtk::IconSize::NORMAL);
            if (center) {
                icon->set_halign(Gtk::Align::CENTER);
                icon->set_hexpand();
            }

            box.append(*icon);
        }
        else {
            auto image = Gtk::make_managed<Gtk::Picture>();
            image->set_layout_manager(Gtk::BinLayout::create());
            image->set_size_request(size.x(), size.y());
            image->set_can_shrink(true);
            image->set_content_fit(Gtk::ContentFit::CONTAIN);
            image->set_valign(Gtk::Align::CENTER);
            if (center) {
                image->set_halign(Gtk::Align::CENTER);
                image->set_hexpand();
            }

            box.append(*image);
        }
    };

    auto setup_separator = [](const Glib::RefPtr<Gtk::ListItem>& list_item)
    {
        if (list_item->get_selectable()) {
            list_item->set_selectable(false);
            list_item->set_activatable(false);
            list_item->set_focusable(false);
            auto rule = Gtk::make_managed<Gtk::Separator>();
            rule->add_css_class("item-separator");
            list_item->unset_child();
            list_item->set_child(*rule);
        }
    };

    _factory->signal_setup().connect([this, set_up_image](const Glib::RefPtr<Gtk::ListItem>& list_item) {

        auto box = Gtk::make_managed<Gtk::Box>();
        box->add_css_class("item-box");
        box->set_orientation(Gtk::Orientation::HORIZONTAL);
        box->set_spacing(5);

        auto label = Gtk::make_managed<Gtk::Label>();
        label->set_hexpand();
        label->set_xalign(0);
        label->set_valign(Gtk::Align::CENTER);
        if (_label_max_chars) {
            label->set_max_width_chars(_label_max_chars);
            label->set_ellipsize(Pango::EllipsizeMode::END);
        }

        set_up_image(*box, get_image_size(), false);
        box->append(*label);

        list_item->set_child(*box);
    });

    _factory->signal_bind().connect([=](const Glib::RefPtr<Gtk::ListItem>& list_item) {
        auto item = std::dynamic_pointer_cast<ListItem>(list_item->get_item());
        auto& box = dynamic_cast<Gtk::Box&>(*list_item->get_child());
        auto first = box.get_first_child();
        if (!first) throw std::runtime_error("Missing widget in IconComboBox factory binding");

        // At bind time because item data is not available at setup time
        if (item->is_separator) {
            setup_separator(list_item);
            return;
        }

        auto& label = dynamic_cast<Gtk::Label&>(*first->get_next_sibling());
        if (use_icons) {
            dynamic_cast<Gtk::Image&>(*first).set_from_icon_name(item->icon);
        } else {
            auto& picture = dynamic_cast<Gtk::Picture&>(*first);
            picture.set_paintable(item->image);
            picture.set_visible(!!item->image);
        }
        label.set_label(item->label);
    });

    set_list_factory(_factory);

    if (header == ImageOnly) {
        // show only icon in closed combobox
        _compact_factory = Gtk::SignalListItemFactory::create();

        _compact_factory->signal_setup().connect([this, set_up_image](const Glib::RefPtr<Gtk::ListItem>& list_item) {
            auto box = Gtk::make_managed<Gtk::Box>();
            box->add_css_class("item-box");
            box->set_orientation(Gtk::Orientation::HORIZONTAL);
            set_up_image(*box, get_image_size(), true);
            list_item->set_child(*box);
        });

        _compact_factory->signal_bind().connect([=](const Glib::RefPtr<Gtk::ListItem>& list_item) {
            auto item = std::dynamic_pointer_cast<ListItem>(list_item->get_item());

            // At bind time because item data is not available at setup time
            if (item->is_separator) {
                setup_separator(list_item);
                return;
            }

            auto& box = dynamic_cast<Gtk::Box&>(*list_item->get_child());
            auto first = box.get_first_child();

            if (use_icons) {
                dynamic_cast<Gtk::Image&>(*first).set_from_icon_name(item->icon);
            }
            else {
                dynamic_cast<Gtk::Picture&>(*first).set_paintable(item->image);
            }
        });

        set_factory(_compact_factory);
    }
    else if (header == LabelOnly) {
        // show only label in closed combobox
        _compact_factory = Gtk::SignalListItemFactory::create();

        _compact_factory->signal_setup().connect([this](const Glib::RefPtr<Gtk::ListItem>& list_item) {
            auto label = Gtk::make_managed<Gtk::Label>();
            label->set_hexpand();
            label->set_xalign(0.5);
            label->set_valign(Gtk::Align::FILL);
            if (_label_max_chars) {
                label->set_max_width_chars(_label_max_chars);
                label->set_ellipsize(Pango::EllipsizeMode::END);
            }
            list_item->set_child(*label);
        });

        _compact_factory->signal_bind().connect([=](const Glib::RefPtr<Gtk::ListItem>& list_item) {
            auto item = std::dynamic_pointer_cast<ListItem>(list_item->get_item());

            // At bind time because item data is not available at setup time
            if (item->is_separator) {
                setup_separator(list_item);
                return;
            }

            auto& label = dynamic_cast<Gtk::Label&>(*list_item->get_child());
            label.set_label(item->short_name.empty() ? item->label : item->short_name);
        });

        set_factory(_compact_factory);
    }
    else {
        set_factory(_factory);
    }

    _store = store ? store : Gio::ListStore<ListItem>::create();
    _filter = Gtk::BoolFilter::create({});
    _filtered_model = Gtk::FilterListModel::create(_store, _filter);
    _selection_model = Gtk::SingleSelection::create(_filtered_model);
    set_model(_selection_model);
    refilter();

    property_selected_item().signal_changed().connect([this]() {
        auto item = current_item();
        _signal_current_changed.emit(item ? item->id : -1);
    });
}

IconComboBox::~IconComboBox() = default;

bool IconComboBox::is_item_visible(const Glib::RefPtr<Glib::ObjectBase>& item) const {
    auto li = std::dynamic_pointer_cast<ListItem>(item);
    if (!li) return false;

    return li->is_visible;
}

void IconComboBox::refilter() {
    // When a new expression is set in the BoolFilter, it emits signal_changed(),
    // and the FilterListModel re-evaluates the filter.
    auto expression = Gtk::ClosureExpression<bool>::create([this](auto& item){ return is_item_visible(item); });
    // filter results
    _filter->set_expression(expression);
}

void IconComboBox::add_row(Glib::ustring const &icon_name, Glib::ustring const &label, int const id)
{
    _store->append(ListItem::create(id, label, {}, icon_name, Glib::RefPtr<Gdk::Texture>() ));
}

void IconComboBox::add_row(const Glib::ustring& icon_name, const Glib::ustring& full_name, const Glib::ustring& short_name, int id) {
    _store->append(ListItem::create(id, full_name, short_name, icon_name, Glib::RefPtr<Gdk::Texture>() ));
}

void IconComboBox::add_row(Cairo::RefPtr<Cairo::Surface> image, const Glib::ustring& label, int id) {
    auto tex = to_texture(image);
    _store->append(ListItem::create(id, label, {}, {}, tex));
}

void IconComboBox::add_separator()
{
    _store->append(ListItem::create_separator());
}

void IconComboBox::clear()
{
    _store->remove_all();
}

void IconComboBox::set_active_by_id(int const id)
{
    auto [item, pos] = find_by_id(id, true);
    if (item) {
        property_selected().set_value(pos);
    }
};

sigc::signal<void (int)>& IconComboBox::signal_changed() {
    return _signal_current_changed;
}

std::shared_ptr<IconComboBox::ListItem> IconComboBox::current_item() {
    auto obj = get_selected_item();
    auto item = std::dynamic_pointer_cast<ListItem>(obj);
    return item;
}

std::pair<std::shared_ptr<IconComboBox::ListItem>, int> IconComboBox::find_by_id(int id, bool visible_only) {
    auto n = visible_only ? _selection_model->get_n_items() : _store->get_n_items();
    for (decltype(n) i = 0; i < n; ++i) {
        auto obj = visible_only ? _selection_model->get_object(i) : _store->get_object(i);
        auto item = std::dynamic_pointer_cast<ListItem>(obj);
        if (item && item->id == id) {
            return std::make_pair(item, i);
        }
    }
    return std::make_pair(nullptr, -1);
}

void IconComboBox::set_row_visible(int const id, bool const visible, bool refilter_items)
{
    auto [item, _] = find_by_id(id, false);
    if (item) {
        if (item->is_visible != visible) {
            item->is_visible = visible;
            if (refilter_items) {
                refilter();
            }
        }
    }
}

int IconComboBox::get_active_row_id() const
{
    if (auto item = const_cast<IconComboBox*>(this)->current_item()) {
        return item->id;
    }
    return -1;
}

void IconComboBox::set_has_frame(bool frame) {
    if (auto btn = dynamic_cast<Gtk::ToggleButton*>(get_first_child())) {
        btn->set_has_frame(frame);
    }
}

} // namespace Inkscape::UI::Widget

/*
  Local Variables:
  mode:c++
  c-file-style:"stroustrup"
  c-file-offsets:((innamespace . 0)(inline-open . 0)(case-label . +))
  indent-tabs-mode:nil
  fill-column:99
  End:
*/
// vim:filetype=cpp:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:fileencoding=utf-8:textwidth=99:
