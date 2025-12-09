#include "binding_macros.h"
#include <QMenu>
#include <QMenuBar>
#include <QAction>
#include <QKeySequence>

// Menu System Bindings

// Get menu bar from main window
int lua_get_menu_bar(lua_State* L) {
    QMainWindow* main_window = get_widget<QMainWindow>(L, 1);
    if (!main_window) {
        return luaL_error(L, "GET_MENU_BAR: widget is not a QMainWindow");
    }
    QMenuBar* menu_bar = main_window->menuBar();
    lua_push_widget(L, menu_bar);
    return 1;
}

// Create menu (can be attached to menu bar or parent menu)
int lua_create_menu(lua_State* L) {
    QWidget* parent = static_cast<QWidget*>(lua_to_widget(L, 1));
    const char* title = luaL_checkstring(L, 2);

    QMenu* menu = nullptr;
    if (QMenuBar* menu_bar = qobject_cast<QMenuBar*>(parent)) {
        menu = new QMenu(QString::fromUtf8(title), menu_bar);
    } else if (QMenu* parent_menu = qobject_cast<QMenu*>(parent)) {
        menu = new QMenu(QString::fromUtf8(title), parent_menu);
    } else if (parent) { // Generic QWidget parent
        menu = new QMenu(QString::fromUtf8(title), parent);
    } else {
        return luaL_error(L, "CREATE_MENU: parent must be QMenuBar, QMenu, or QWidget");
    }

    lua_push_widget(L, menu);
    return 1;
}

// Add menu to menu bar
int lua_add_menu_to_bar(lua_State* L) {
    QMenuBar* menu_bar = get_widget<QMenuBar>(L, 1);
    QMenu* menu = get_widget<QMenu>(L, 2);
    if (!menu_bar) return luaL_error(L, "ADD_MENU_TO_BAR: first argument must be QMenuBar");
    if (!menu) return luaL_error(L, "ADD_MENU_TO_BAR: second argument must be QMenu");
    menu_bar->addMenu(menu);
    return 0;
}

// Add submenu to menu
int lua_add_submenu(lua_State* L) {
    QMenu* parent_menu = get_widget<QMenu>(L, 1);
    QMenu* submenu = get_widget<QMenu>(L, 2);
    if (!parent_menu) return luaL_error(L, "ADD_SUBMENU: first argument must be QMenu");
    if (!submenu) return luaL_error(L, "ADD_SUBMENU: second argument must be QMenu");
    parent_menu->addMenu(submenu);
    return 0;
}

// Create menu action
int lua_create_menu_action(lua_State* L) {
    QMenu* menu = get_widget<QMenu>(L, 1);
    const char* text = luaL_checkstring(L, 2);
    const char* shortcut = luaL_optstring(L, 3, "");
    bool checkable = lua_toboolean(L, 4);

    if (!menu) return luaL_error(L, "CREATE_MENU_ACTION: first argument must be QMenu");

    QAction* action = new QAction(QString::fromUtf8(text), menu);
    if (shortcut && strlen(shortcut) > 0) {
        action->setShortcut(QKeySequence(QString::fromUtf8(shortcut)));
    }
    if (checkable) {
        action->setCheckable(true);
    }
    menu->addAction(action);
    lua_push_widget(L, action);
    return 1;
}

// Connect menu action to callback
int lua_connect_menu_action(lua_State* L) {
    QAction* action = get_widget<QAction>(L, 1);
    if (!lua_isfunction(L, 2)) return luaL_error(L, "CONNECT_MENU_ACTION: second argument must be a function");
    if (!action) return luaL_error(L, "CONNECT_MENU_ACTION: first argument must be QAction");

    // Store callback in registry
    lua_pushvalue(L, 2);
    int callback_ref = luaL_ref(L, LUA_REGISTRYINDEX);

    // Connect action to callback
    QObject::connect(action, &QAction::triggered, [L, callback_ref]() {
        lua_rawgeti(L, LUA_REGISTRYINDEX, callback_ref);
        if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
            const char* error = lua_tostring(L, -1);
            qDebug() << "Error in menu action callback:" << error;
            lua_pop(L, 1);
        }
    });
    return 0;
}

// Add separator to menu
int lua_add_menu_separator(lua_State* L) {
    QMenu* menu = get_widget<QMenu>(L, 1);
    if (!menu) return luaL_error(L, "ADD_MENU_SEPARATOR: argument must be QMenu");
    menu->addSeparator();
    return 0;
}

int lua_show_menu_popup(lua_State* L) {
    QMenu* menu = get_widget<QMenu>(L, 1);
    int global_x = luaL_checkint(L, 2);
    int global_y = luaL_checkint(L, 3);
    if (!menu) return luaL_error(L, "SHOW_POPUP: argument must be QMenu");

    QAction* triggered = menu->exec(QPoint(global_x, global_y));
    lua_pushboolean(L, triggered != nullptr);
    return 1;
}

// Set action enabled state
int lua_set_action_enabled(lua_State* L) {
    QAction* action = get_widget<QAction>(L, 1);
    bool enabled = lua_toboolean(L, 2);
    if (!action) return luaL_error(L, "SET_ACTION_ENABLED: argument must be QAction");
    action->setEnabled(enabled);
    return 0;
}

// Set action checked state
int lua_set_action_checked(lua_State* L) {
    QAction* action = get_widget<QAction>(L, 1);
    bool checked = lua_toboolean(L, 2);
    if (!action) return luaL_error(L, "SET_ACTION_CHECKED: argument must be QAction");
    action->setChecked(checked);
    return 0;
}
