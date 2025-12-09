#include "binding_macros.h"
#include <QPushButton>
#include <QCheckBox>
#include <QComboBox>
#include <QSlider>




int lua_set_scroll_area_widget(lua_State* L) {
    QScrollArea* sa = get_widget<QScrollArea>(L, 1);
    QWidget* w = static_cast<QWidget*>(lua_to_widget(L, 2));
    if (sa && w) {
        sa->setWidget(w);
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

LUA_BIND_WIDGET_CREATOR_WITH_TEXT(lua_create_button, QPushButton)
LUA_BIND_WIDGET_CREATOR_WITH_TEXT(lua_create_checkbox, QCheckBox)
LUA_BIND_WIDGET_CREATOR(lua_create_combobox, QComboBox)

int lua_create_slider(lua_State* L) {
    const char* orient = lua_tostring(L, 1);
    Qt::Orientation o = (orient && strcmp(orient, "vertical") == 0) ? Qt::Vertical : Qt::Horizontal;
    QSlider* s = new QSlider(o);
    lua_push_widget(L, s);
    return 1;
}

LUA_BIND_SETTER_BOOL(lua_set_checked, QAbstractButton, setChecked)
LUA_BIND_GETTER_BOOL(lua_get_checked, QAbstractButton, isChecked)

int lua_add_combobox_item(lua_State* L) {
    QComboBox* cb = get_widget<QComboBox>(L, 1);
    const char* text = lua_tostring(L, 2);
    if (cb && text) {
        cb->addItem(QString::fromUtf8(text));
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_set_combobox_current_text(lua_State* L) {
    QComboBox* cb = get_widget<QComboBox>(L, 1);
    const char* text = lua_tostring(L, 2);
    if (cb && text) {
        cb->setCurrentText(QString::fromUtf8(text));
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_get_combobox_current_text(lua_State* L) {
    QComboBox* cb = get_widget<QComboBox>(L, 1);
    if (cb) {
        lua_pushstring(L, cb->currentText().toUtf8().constData());
    } else {
        lua_pushnil(L);
    }
    return 1;
}

int lua_set_scroll_area_viewport_margins(lua_State* L) {
    LuaScrollArea* sa = static_cast<LuaScrollArea*>(static_cast<QWidget*>(lua_to_widget(L, 1)));
    int left = luaL_checkinteger(L, 2);
    int top = luaL_checkinteger(L, 3);
    int right = luaL_checkinteger(L, 4);
    int bottom = luaL_checkinteger(L, 5);
    
    if (sa) {
        sa->setViewportMargins(left, top, right, bottom);
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_set_slider_range(lua_State* L) {
    QSlider* s = get_widget<QSlider>(L, 1);
    int min = lua_tointeger(L, 2);
    int max = lua_tointeger(L, 3);
    if (s) {
        s->setRange(min, max);
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

LUA_BIND_SETTER_INT(lua_set_slider_value, QSlider, setValue)
LUA_BIND_GETTER_INT(lua_get_slider_value, QSlider, value)
