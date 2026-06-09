#include "binding_macros.h"
#include <QLayout>
#include <QHBoxLayout>
#include <QVBoxLayout>
#include <QSplitter>



LUA_BIND_WIDGET_CREATOR(lua_create_hbox_layout, QHBoxLayout)
LUA_BIND_WIDGET_CREATOR(lua_create_vbox_layout, QVBoxLayout)

int lua_create_splitter(lua_State* L) {
    const char* direction = lua_tostring(L, 1);
    Qt::Orientation orientation = (direction && strcmp(direction, "vertical") == 0) ? Qt::Vertical : Qt::Horizontal;
    QSplitter* splitter = new QSplitter(orientation);
    lua_push_widget(L, splitter);
    return 1;
}

int lua_set_layout(lua_State* L) {
    // QLayout and QWidget both inherit QObject (single inheritance), so the
    // void* returned by lua_to_widget can be reinterpreted as QObject* without
    // offset adjustment. qobject_cast then uses Qt's metaobject system to
    // verify the actual runtime type — guards against a QWidget userdata
    // being passed where a QLayout is expected (which previously corrupted
    // setLayout via an unchecked static_cast).
    QWidget* widget = widget_cast<QWidget>(lua_to_widget(L, 1));
    QLayout* layout = widget_cast<QLayout>(lua_to_widget(L, 2));

    if (widget && layout) {
        widget->setLayout(layout);
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_add_widget_to_layout(lua_State* L) {
    void* container_ptr = lua_to_widget(L, 1);
    QWidget* widget = get_widget<QWidget>(L, 2);

    if (!container_ptr || !widget) {
        lua_pushboolean(L, 0);
        return 1;
    }

    // Try QSplitter
    if (QSplitter* splitter = widget_cast<QSplitter>(container_ptr)) {
        splitter->addWidget(widget);
        lua_pushboolean(L, 1);
        return 1;
    }

    // Try QLayout
    if (QLayout* layout = widget_cast<QLayout>(container_ptr)) {
         Qt::Alignment alignment = Qt::Alignment();
        if (lua_gettop(L) >= 3 && lua_isstring(L, 3)) {
            // TODO: Use the optimized lookup here later
            const char* align_str = lua_tostring(L, 3);
            if (strcmp(align_str, "AlignVCenter") == 0) alignment = Qt::AlignVCenter;
            else if (strcmp(align_str, "AlignTop") == 0) alignment = Qt::AlignTop;
            else if (strcmp(align_str, "AlignBottom") == 0) alignment = Qt::AlignBottom;
            else if (strcmp(align_str, "AlignBaseline") == 0) alignment = Qt::AlignBaseline;
        }

        if (QBoxLayout* box = qobject_cast<QBoxLayout*>(layout)) {
            box->addWidget(widget, 0, alignment);
        } else {
            layout->addWidget(widget);
        }
        lua_pushboolean(L, 1);
        return 1;
    }
    
    lua_pushboolean(L, 0);
    return 1;
}

int lua_insert_widget_in_layout(lua_State* L) {
    void* container_ptr = lua_to_widget(L, 1);
    QWidget* widget = get_widget<QWidget>(L, 2);
    int index = luaL_checkinteger(L, 3);
    if (!container_ptr || !widget) return luaL_error(L, "insert_widget: layout and widget required");

    QBoxLayout* box = widget_cast<QBoxLayout>(container_ptr);
    if (!box) return luaL_error(L, "insert_widget: container must be a QBoxLayout");
    box->insertWidget(index, widget);
    lua_pushboolean(L, 1);
    return 1;
}

int lua_add_stretch_to_layout(lua_State* L) {
    void* container_ptr = lua_to_widget(L, 1);
    int stretch = lua_tointeger(L, 2);
    
    if (QBoxLayout* box = widget_cast<QBoxLayout>(container_ptr)) {
        box->addStretch(stretch);
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_set_splitter_sizes(lua_State* L) {
    QSplitter* splitter = get_widget<QSplitter>(L, 1);
    if (splitter && lua_istable(L, 2)) {
        QList<int> sizes;
        int len = lua_objlen(L, 2);
        for (int i = 1; i <= len; i++) {
            lua_rawgeti(L, 2, i);
            if (lua_isnumber(L, -1)) {
                sizes.append(lua_tointeger(L, -1));
            }
            lua_pop(L, 1);
        }
        splitter->setSizes(sizes);
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_set_layout_margins(lua_State* L) {
    void* userdata = lua_to_widget(L, 1);
    if (!userdata) {
        lua_pushboolean(L, 0);
        return 1;
    }

    int left = luaL_checkinteger(L, 2);
    int top = luaL_checkinteger(L, 3);
    int right = luaL_checkinteger(L, 4);
    int bottom = luaL_checkinteger(L, 5);

    // Try as QWidget first
    if (QWidget* w = widget_cast<QWidget>(userdata)) {
        if (QLayout* layout = w->layout()) {
            layout->setContentsMargins(left, top, right, bottom);
            lua_pushboolean(L, 1);
            return 1;
        }
    }

    // Try as QLayout directly
    if (QLayout* l = widget_cast<QLayout>(userdata)) {
         l->setContentsMargins(left, top, right, bottom);
         lua_pushboolean(L, 1);
         return 1;
    }

    // Caller passed a non-null userdata that is neither a QWidget nor a
    // QLayout — that's a binding misuse, not a lifecycle silent-no-op
    // (the destroyed-widget path returned at line ~131 already). Raise
    // so the call site shows up instead of silently swallowing.
    return luaL_error(L,
        "set_contents_margins: userdata is neither QWidget nor QLayout");
}

int lua_set_layout_spacing(lua_State* L) {
    void* userdata = lua_to_widget(L, 1);
    if (!userdata) {
        lua_pushboolean(L, 0);
        return 1;
    }

    int spacing = luaL_checkinteger(L, 2);

    // Try as QWidget first
    if (QWidget* w = widget_cast<QWidget>(userdata)) {
        if (QLayout* layout = w->layout()) {
            layout->setSpacing(spacing);
            lua_pushboolean(L, 1);
            return 1;
        }
    }

    // Try as QLayout directly
    if (QLayout* l = widget_cast<QLayout>(userdata)) {
         l->setSpacing(spacing);
         lua_pushboolean(L, 1);
         return 1;
    }

    // See set_contents_margins above — non-null wrong-type is misuse.
    return luaL_error(L,
        "set_layout_spacing: userdata is neither QWidget nor QLayout");
}

int lua_get_splitter_sizes(lua_State* L) {
    QSplitter* splitter = get_widget<QSplitter>(L, 1);
    if (splitter) {
        QList<int> sizes = splitter->sizes();
        lua_newtable(L);
        for (int i = 0; i < sizes.size(); ++i) {
            lua_pushinteger(L, sizes[i]);
            lua_rawseti(L, -2, i + 1);
        }
        return 1;
    }
    lua_pushnil(L);
    return 1;
}

// Add spacing to a box layout
int lua_add_spacing_to_layout(lua_State* L) {
    void* container_ptr = lua_to_widget(L, 1);
    int spacing = luaL_checkinteger(L, 2);

    if (QBoxLayout* box = widget_cast<QBoxLayout>(container_ptr)) {
        box->addSpacing(spacing);
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

// Add nested layout to a box layout
int lua_add_layout_to_layout(lua_State* L) {
    void* parent_ptr = lua_to_widget(L, 1);
    void* child_ptr = lua_to_widget(L, 2);

    if (!parent_ptr || !child_ptr) {
        lua_pushboolean(L, 0);
        return 1;
    }

    QBoxLayout* parent_box = widget_cast<QBoxLayout>(parent_ptr);
    QLayout* child_layout = widget_cast<QLayout>(child_ptr);

    if (parent_box && child_layout) {
        parent_box->addLayout(child_layout);
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

// Set layout on a widget (for group boxes, etc.)
// Same defense-in-depth as lua_set_layout (pass 11): qobject_cast both sides
// so a swapped widget/layout userdata or a stale destroyed QObject is caught
// at the metaobject layer instead of corrupting setLayout via a bad pointer.
int lua_set_widget_layout(lua_State* L) {
    QWidget* widget = widget_cast<QWidget>(lua_to_widget(L, 1));
    QLayout* layout = widget_cast<QLayout>(lua_to_widget(L, 2));

    if (widget && layout) {
        widget->setLayout(layout);
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}