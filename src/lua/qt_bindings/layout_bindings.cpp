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
    QWidget* widget = static_cast<QWidget*>(lua_to_widget(L, 1));
    QLayout* layout = static_cast<QLayout*>(lua_to_widget(L, 2)); // Cast via QWidget* first is unsafe if layouts aren't widgets in our system
    // Note: In Qt, QLayout is NOT a QWidget. Our Lua system treats everything as "widget" userdata.
    // We need to check if the userdata is actually a QLayout.
    
    // Correct cast:
    // The lua_to_widget returns a void*. We need to know if it's a QLayout.
    // For now, assume the userdata system holds QLayout* pointers correctly.
    
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
    QWidget* widget = static_cast<QWidget*>(lua_to_widget(L, 2));
    
    if (!container_ptr || !widget) {
        lua_pushboolean(L, 0);
        return 1;
    }
    
    // Try QSplitter
    if (QSplitter* splitter = qobject_cast<QSplitter*>(static_cast<QWidget*>(container_ptr))) {
        splitter->addWidget(widget);
        lua_pushboolean(L, 1);
        return 1;
    }
    
    // Try QLayout
    if (QLayout* layout = qobject_cast<QLayout*>(static_cast<QObject*>(static_cast<QWidget*>(container_ptr)))) {
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

int lua_add_stretch_to_layout(lua_State* L) {
    void* container_ptr = lua_to_widget(L, 1);
    int stretch = lua_tointeger(L, 2);
    
    if (QBoxLayout* box = qobject_cast<QBoxLayout*>(static_cast<QObject*>(static_cast<QWidget*>(container_ptr)))) {
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
    if (QWidget* w = qobject_cast<QWidget*>(static_cast<QObject*>(userdata))) {
        if (QLayout* layout = w->layout()) {
            layout->setContentsMargins(left, top, right, bottom);
            lua_pushboolean(L, 1);
            return 1;
        }
    }

    // Try as QLayout directly
    if (QLayout* l = qobject_cast<QLayout*>(static_cast<QObject*>(userdata))) {
         l->setContentsMargins(left, top, right, bottom);
         lua_pushboolean(L, 1);
         return 1;
    }

    // Neither QWidget nor QLayout
    lua_pushboolean(L, 0);
    return 1;
}

int lua_set_layout_spacing(lua_State* L) {
    void* userdata = lua_to_widget(L, 1);
    if (!userdata) {
        lua_pushboolean(L, 0);
        return 1;
    }

    int spacing = luaL_checkinteger(L, 2);

    // Try as QWidget first
    if (QWidget* w = qobject_cast<QWidget*>(static_cast<QObject*>(userdata))) {
        if (QLayout* layout = w->layout()) {
            layout->setSpacing(spacing);
            lua_pushboolean(L, 1);
            return 1;
        }
    }

    // Try as QLayout directly
    if (QLayout* l = qobject_cast<QLayout*>(static_cast<QObject*>(userdata))) {
         l->setSpacing(spacing);
         lua_pushboolean(L, 1);
         return 1;
    }

    // Neither QWidget nor QLayout
    lua_pushboolean(L, 0);
    return 1;
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

    if (QBoxLayout* box = qobject_cast<QBoxLayout*>(static_cast<QObject*>(static_cast<QWidget*>(container_ptr)))) {
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

    QBoxLayout* parent_box = qobject_cast<QBoxLayout*>(static_cast<QObject*>(static_cast<QWidget*>(parent_ptr)));
    QLayout* child_layout = qobject_cast<QLayout*>(static_cast<QObject*>(static_cast<QWidget*>(child_ptr)));

    if (parent_box && child_layout) {
        parent_box->addLayout(child_layout);
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

// Set layout on a widget (for group boxes, etc.)
int lua_set_widget_layout(lua_State* L) {
    QWidget* widget = static_cast<QWidget*>(lua_to_widget(L, 1));
    QLayout* layout = qobject_cast<QLayout*>(static_cast<QObject*>(static_cast<QWidget*>(lua_to_widget(L, 2))));

    if (widget && layout) {
        widget->setLayout(layout);
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}