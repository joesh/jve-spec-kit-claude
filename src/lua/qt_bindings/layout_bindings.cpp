#include "binding_macros.h"
#include <QLayout>
#include <QHBoxLayout>
#include <QVBoxLayout>
#include <QSplitter>



LUA_BIND_WIDGET_CREATOR(lua_create_hbox_layout, QHBoxLayout)
LUA_BIND_WIDGET_CREATOR(lua_create_vbox_layout, QVBoxLayout)

int lua_create_splitter(lua_State* L) {
    // Direction is required and closed-set: silently defaulting an unknown
    // string to Horizontal hid caller typos as "the splitter is sideways".
    const char* direction = luaL_checkstring(L, 1);
    Qt::Orientation orientation;
    if (strcmp(direction, "vertical") == 0) {
        orientation = Qt::Vertical;
    } else if (strcmp(direction, "horizontal") == 0) {
        orientation = Qt::Horizontal;
    } else {
        return luaL_error(L,
            "create_splitter: direction must be 'vertical' or 'horizontal', got '%s'", direction);
    }
    QSplitter* splitter = new QSplitter(orientation);
    lua_push_widget(L, splitter);
    return 1;
}

// Set a layout on a widget. Registered under both SET_ON_WIDGET and
// SET_WIDGET_LAYOUT (group boxes etc.) — one implementation, one contract.
//
// Error policy matches set_splitter_sizes / set_contents_margins: a null
// userdata (QPointer auto-nulled during teardown) is a silent no-op; a
// non-null arg of the wrong type is binding misuse and raises.
//
// QLayout and QWidget both inherit QObject (single inheritance), so the void*
// from lua_to_widget reinterprets as QObject* without offset adjustment;
// qobject_cast (via widget_cast) then verifies the runtime type, guarding
// against a swapped widget/layout pair corrupting setLayout.
int lua_set_layout(lua_State* L) {
    void* widget_ptr = lua_to_widget(L, 1);
    void* layout_ptr = lua_to_widget(L, 2);
    if (!widget_ptr || !layout_ptr) {
        lua_pushboolean(L, 0);
        return 1;
    }

    QWidget* widget = widget_cast<QWidget>(widget_ptr);
    QLayout* layout = widget_cast<QLayout>(layout_ptr);
    if (!widget || !layout) {
        return luaL_error(L,
            "set_layout: arg 1 must be a QWidget and arg 2 a QLayout");
    }

    widget->setLayout(layout);
    lua_pushboolean(L, 1);
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

    // Non-null container that is neither a QSplitter nor a QLayout is binding
    // misuse, not teardown (the null path returned above) — raise instead of
    // silently dropping the widget on the floor.
    return luaL_error(L,
        "add_widget_to_layout: container is neither a QSplitter nor a QLayout");
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
    // Stretch factor is optional; Qt's QBoxLayout::addStretch defaults to 0.
    int stretch = luaL_optinteger(L, 2, 0);

    if (!container_ptr) {
        lua_pushboolean(L, 0);
        return 1;
    }
    QBoxLayout* box = widget_cast<QBoxLayout>(container_ptr);
    if (!box) {
        return luaL_error(L, "add_stretch_to_layout: container is not a QBoxLayout");
    }
    box->addStretch(stretch);
    lua_pushboolean(L, 1);
    return 1;
}

int lua_set_splitter_sizes(lua_State* L) {
    // Same error policy as set_contents_margins/set_layout_spacing: null
    // userdata (QPointer auto-nulled during teardown) is a silent no-op;
    // a non-null wrong-type arg is binding misuse and raises.
    void* userdata = lua_to_widget(L, 1);
    if (!userdata) {
        lua_pushboolean(L, 0);
        return 1;
    }
    QSplitter* splitter = widget_cast<QSplitter>(userdata);
    if (!splitter) {
        return luaL_error(L, "set_splitter_sizes: arg 1 is not a QSplitter");
    }
    luaL_checktype(L, 2, LUA_TTABLE);

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
    // Null userdata (destroyed/teardown) returns nil — panel_manager's
    // snapshot query intentionally treats nil as "not bootstrapped". A
    // non-null wrong-type arg is binding misuse and raises.
    void* userdata = lua_to_widget(L, 1);
    if (!userdata) {
        lua_pushnil(L);
        return 1;
    }
    QSplitter* splitter = widget_cast<QSplitter>(userdata);
    if (!splitter) {
        return luaL_error(L, "get_splitter_sizes: arg 1 is not a QSplitter");
    }
    QList<int> sizes = splitter->sizes();
    lua_newtable(L);
    for (int i = 0; i < sizes.size(); ++i) {
        lua_pushinteger(L, sizes[i]);
        lua_rawseti(L, -2, i + 1);
    }
    return 1;
}

// Add spacing to a box layout
int lua_add_spacing_to_layout(lua_State* L) {
    void* container_ptr = lua_to_widget(L, 1);
    int spacing = luaL_checkinteger(L, 2);

    if (!container_ptr) {
        lua_pushboolean(L, 0);
        return 1;
    }
    QBoxLayout* box = widget_cast<QBoxLayout>(container_ptr);
    if (!box) {
        return luaL_error(L, "add_spacing_to_layout: container is not a QBoxLayout");
    }
    box->addSpacing(spacing);
    lua_pushboolean(L, 1);
    return 1;
}

// Add nested layout to a box layout
int lua_add_layout_to_layout(lua_State* L) {
    void* parent_ptr = lua_to_widget(L, 1);
    void* child_ptr = lua_to_widget(L, 2);

    // Null userdata (QPointer auto-nulled during teardown) is a silent no-op.
    if (!parent_ptr || !child_ptr) {
        lua_pushboolean(L, 0);
        return 1;
    }

    QBoxLayout* parent_box = widget_cast<QBoxLayout>(parent_ptr);
    QLayout* child_layout = widget_cast<QLayout>(child_ptr);
    if (!parent_box || !child_layout) {
        return luaL_error(L,
            "add_layout_to_layout: parent must be a QBoxLayout and child a QLayout");
    }

    parent_box->addLayout(child_layout);
    lua_pushboolean(L, 1);
    return 1;
}

// (lua_set_widget_layout removed — it was a byte-for-byte duplicate of
// lua_set_layout. SET_WIDGET_LAYOUT now registers the same function.)