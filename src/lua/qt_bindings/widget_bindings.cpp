#include "binding_macros.h"
#include <QMainWindow>
#include <QLabel>
#include <QLineEdit>
#include <QScrollArea>


LUA_BIND_WIDGET_CREATOR(lua_create_main_window, QMainWindow)
LUA_BIND_WIDGET_CREATOR(lua_create_widget, QWidget)
LUA_BIND_WIDGET_CREATOR_WITH_TEXT(lua_create_label, QLabel)

int lua_create_scroll_area(lua_State* L) {
    LuaScrollArea* sa = new LuaScrollArea();
    sa->setWidgetResizable(true);
    lua_push_widget(L, sa);
    return 1;
}

int lua_create_line_edit(lua_State* L) {
    const char* ph = lua_tostring(L, 1);
    QLineEdit* le = new QLineEdit();
    if (ph) le->setPlaceholderText(QString::fromUtf8(ph));
    lua_push_widget(L, le);
    return 1;
}

// Generic Setters
LUA_BIND_SETTER_STRING(lua_set_text, QLabel, setText) // Only works for QLabel... need to handle others manually or specialize
LUA_BIND_SETTER_STRING(lua_set_placeholder_text, QLineEdit, setPlaceholderText)
// LUA_BIND_SETTER_STRING(lua_set_object_name, QObject, setObjectName) -- Implemented in misc_bindings.cpp to avoid QWidget cast
LUA_BIND_SETTER_STRING(lua_set_window_title, QWidget, setWindowTitle)
LUA_BIND_SETTER_STRING(lua_set_style_sheet, QWidget, setStyleSheet)
LUA_BIND_SETTER_BOOL(lua_set_visible, QWidget, setVisible)

int lua_set_text_generic(lua_State* L) {
    QWidget* w = static_cast<QWidget*>(lua_to_widget(L, 1));
    const char* txt = lua_tostring(L, 2);
    if (!w || !txt) return 0;
    QString qtxt = QString::fromUtf8(txt);
    
    if (QLabel* l = qobject_cast<QLabel*>(w)) l->setText(qtxt);
    else if (QLineEdit* le = qobject_cast<QLineEdit*>(w)) le->setText(qtxt);
    // Add other types here
    
    lua_pushboolean(L, 1);
    return 1;
}

int lua_get_text_generic(lua_State* L) {
    QWidget* w = static_cast<QWidget*>(lua_to_widget(L, 1));
    if (!w) { lua_pushnil(L); return 1; }
    
    if (QLabel* l = qobject_cast<QLabel*>(w)) lua_pushstring(L, l->text().toUtf8().constData());
    else if (QLineEdit* le = qobject_cast<QLineEdit*>(w)) lua_pushstring(L, le->text().toUtf8().constData());
    else lua_pushnil(L);
    
    return 1;
}

int lua_set_central_widget(lua_State* L) {
    QMainWindow* mw = get_widget<QMainWindow>(L, 1);
    QWidget* w = static_cast<QWidget*>(lua_to_widget(L, 2));
    if (mw && w) {
        mw->setCentralWidget(w);
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_show_widget(lua_State* L) {
    if (QWidget* w = static_cast<QWidget*>(lua_to_widget(L, 1))) {
        w->show();
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

// Size and Geometry
int lua_set_size(lua_State* L) {
    QWidget* w = static_cast<QWidget*>(lua_to_widget(L, 1));
    int width = luaL_checkinteger(L, 2);
    int height = luaL_checkinteger(L, 3);
    if (w) {
        w->resize(width, height);
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_get_widget_size(lua_State* L) {
    QWidget* w = static_cast<QWidget*>(lua_to_widget(L, 1));
    if (w) {
        lua_pushinteger(L, w->width());
        lua_pushinteger(L, w->height());
        return 2;
    }
    return 0;
}

int lua_set_minimum_width(lua_State* L) {
    QWidget* w = static_cast<QWidget*>(lua_to_widget(L, 1));
    int val = luaL_checkinteger(L, 2);
    if (w) w->setMinimumWidth(val);
    return 0;
}

int lua_set_maximum_width(lua_State* L) {
    QWidget* w = static_cast<QWidget*>(lua_to_widget(L, 1));
    int val = luaL_checkinteger(L, 2);
    if (w) w->setMaximumWidth(val);
    return 0;
}

int lua_set_minimum_height(lua_State* L) {
    QWidget* w = static_cast<QWidget*>(lua_to_widget(L, 1));
    int val = luaL_checkinteger(L, 2);
    if (w) w->setMinimumHeight(val);
    return 0;
}

int lua_set_maximum_height(lua_State* L) {
    QWidget* w = static_cast<QWidget*>(lua_to_widget(L, 1));
    int val = luaL_checkinteger(L, 2);
    if (w) w->setMaximumHeight(val);
    return 0;
}

int lua_set_geometry(lua_State* L) {
    QWidget* w = static_cast<QWidget*>(lua_to_widget(L, 1));
    int x = luaL_checkinteger(L, 2);
    int y = luaL_checkinteger(L, 3);
    int width = luaL_checkinteger(L, 4);
    int height = luaL_checkinteger(L, 5);
    if (w) w->setGeometry(x, y, width, height);
    return 0;
}

int lua_get_geometry(lua_State* L) {
    QWidget* w = static_cast<QWidget*>(lua_to_widget(L, 1));
    if (w) {
        QRect g = w->geometry();
        lua_pushinteger(L, g.x());
        lua_pushinteger(L, g.y());
        lua_pushinteger(L, g.width());
        lua_pushinteger(L, g.height());
        return 4;
    }
    return 0;
}

// Misc Setters
int lua_raise_widget(lua_State* L) {
    QWidget* w = static_cast<QWidget*>(lua_to_widget(L, 1));
    if (w) w->raise();
    return 0;
}

int lua_activate_window(lua_State* L) {
    QWidget* w = static_cast<QWidget*>(lua_to_widget(L, 1));
    if (w) w->activateWindow();
    return 0;
}