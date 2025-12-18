#pragma once

#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
#include <QDebug>
#include <QWidget>
#include "../../qt_bindings.h"

#include <QScrollArea>
// Helper to get widget from Lua stack with type checking
template<typename T>
T* get_widget(lua_State* L, int index = 1) {
    void* widget_ptr = lua_to_widget(L, index);
    if (!widget_ptr) return nullptr;
    return qobject_cast<T*>(static_cast<QObject*>(static_cast<QWidget*>(widget_ptr)));
}

class LuaScrollArea : public QScrollArea {
public:
    void setViewportMargins(int left, int top, int right, int bottom) {
        QAbstractScrollArea::setViewportMargins(left, top, right, bottom);
    }
};

// Macro for standard widget creator functions
#define LUA_BIND_WIDGET_CREATOR(FunctionName, WidgetType) \
    int FunctionName(lua_State* L) { \
        WidgetType* w = new WidgetType(); \
        lua_push_widget(L, w); \
        return 1; \
    }

// Macro for widget creator with text (e.g., QLabel, QPushButton)
#define LUA_BIND_WIDGET_CREATOR_WITH_TEXT(FunctionName, WidgetType) \
    int FunctionName(lua_State* L) { \
        const char* text = lua_tostring(L, 1); \
        WidgetType* w = new WidgetType(text ? QString::fromUtf8(text) : QString()); \
        lua_push_widget(L, w); \
        return 1; \
    }

// Macro for string setters
#define LUA_BIND_SETTER_STRING(FunctionName, WidgetType, SetterMethod) \
    int FunctionName(lua_State* L) { \
        WidgetType* w = get_widget<WidgetType>(L, 1); \
        const char* val = lua_tostring(L, 2); \
        if (w && val) { \
            w->SetterMethod(QString::fromUtf8(val)); \
        } \
        return 0; \
    }

// Macro for boolean setters
#define LUA_BIND_SETTER_BOOL(FunctionName, WidgetType, SetterMethod) \
    int FunctionName(lua_State* L) { \
        WidgetType* w = get_widget<WidgetType>(L, 1); \
        if (w) { \
            w->SetterMethod(lua_toboolean(L, 2)); \
        } \
        return 0; \
    }

// Macro for integer setters
#define LUA_BIND_SETTER_INT(FunctionName, WidgetType, SetterMethod) \
    int FunctionName(lua_State* L) { \
        WidgetType* w = get_widget<WidgetType>(L, 1); \
        if (w) { \
            w->SetterMethod(luaL_checkinteger(L, 2)); \
        } \
        return 0; \
    }

// Macro for getters (string)
#define LUA_BIND_GETTER_STRING(FunctionName, WidgetType, GetterMethod) \
    int FunctionName(lua_State* L) { \
        WidgetType* w = get_widget<WidgetType>(L, 1); \
        if (w) { \
            lua_pushstring(L, w->GetterMethod().toUtf8().constData()); \
            return 1; \
        } \
        lua_pushnil(L); \
        return 1; \
    }

// Macro for boolean getters
#define LUA_BIND_GETTER_BOOL(FunctionName, WidgetType, GetterMethod) \
    int FunctionName(lua_State* L) { \
        WidgetType* w = get_widget<WidgetType>(L, 1); \
        if (w) { \
            lua_pushboolean(L, w->GetterMethod()); \
            return 1; \
        } \
        lua_pushnil(L); \
        return 1; \
    }

// Macro for integer getters
#define LUA_BIND_GETTER_INT(FunctionName, WidgetType, GetterMethod) \
    int FunctionName(lua_State* L) { \
        WidgetType* w = get_widget<WidgetType>(L, 1); \
        if (w) { \
            lua_pushinteger(L, w->GetterMethod()); \
            return 1; \
        } \
        lua_pushnil(L); \
        return 1; \
    }
