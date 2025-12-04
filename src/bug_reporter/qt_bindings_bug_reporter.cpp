#include "qt_bindings_bug_reporter.h"
#include "gesture_logger.h"
#include <QWidget>
#include <QPixmap>
#include <QTimer>
#include <QApplication>

namespace bug_reporter {

// Global gesture logger instance
static GestureLogger* g_gestureLogger = nullptr;

//============================================================================
// Gesture Logger Bindings
//============================================================================

/**
 * lua_install_gesture_logger(callback_function)
 * Installs global event filter and sets Lua callback.
 */
static int lua_install_gesture_logger(lua_State* L) {
    // Argument: callback function
    luaL_checktype(L, 1, LUA_TFUNCTION);

    // Create gesture logger if needed
    if (!g_gestureLogger) {
        g_gestureLogger = new GestureLogger(qApp);
    }

    // Store callback in registry
    lua_pushvalue(L, 1);  // Copy callback to top
    int callbackRef = luaL_ref(L, LUA_REGISTRYINDEX);

    // Set C++ callback that calls Lua function
    g_gestureLogger->setCallback([L, callbackRef](const GestureEvent& gesture) {
        // Push callback function
        lua_rawgeti(L, LUA_REGISTRYINDEX, callbackRef);

        // Create gesture table
        lua_newtable(L);

        lua_pushstring(L, gesture.type.toStdString().c_str());
        lua_setfield(L, -2, "type");

        lua_pushinteger(L, gesture.screen_x);
        lua_setfield(L, -2, "screen_x");

        lua_pushinteger(L, gesture.screen_y);
        lua_setfield(L, -2, "screen_y");

        lua_pushinteger(L, gesture.window_x);
        lua_setfield(L, -2, "window_x");

        lua_pushinteger(L, gesture.window_y);
        lua_setfield(L, -2, "window_y");

        if (!gesture.button.isEmpty()) {
            lua_pushstring(L, gesture.button.toStdString().c_str());
            lua_setfield(L, -2, "button");
        }

        if (!gesture.key.isEmpty()) {
            lua_pushstring(L, gesture.key.toStdString().c_str());
            lua_setfield(L, -2, "key");
        }

        // Modifiers array
        lua_newtable(L);
        for (int i = 0; i < gesture.modifiers.size(); ++i) {
            lua_pushstring(L, gesture.modifiers[i].toStdString().c_str());
            lua_rawseti(L, -2, i + 1);
        }
        lua_setfield(L, -2, "modifiers");

        if (gesture.delta != 0) {
            lua_pushinteger(L, gesture.delta);
            lua_setfield(L, -2, "delta");
        }

        // Call Lua callback with gesture table
        if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
            const char* error = lua_tostring(L, -1);
            qWarning() << "Gesture callback error:" << error;
            lua_pop(L, 1);
        }
    });

    // Install event filter
    g_gestureLogger->install();

    return 0;
}

/**
 * lua_set_gesture_logger_enabled(enabled)
 * Enable or disable gesture capture.
 */
static int lua_set_gesture_logger_enabled(lua_State* L) {
    bool enabled = lua_toboolean(L, 1);

    if (g_gestureLogger) {
        g_gestureLogger->setEnabled(enabled);
    }

    return 0;
}

//============================================================================
// Screenshot Capture Bindings
//============================================================================

/**
 * lua_grab_window(widget) -> QPixmap userdata
 * Captures screenshot of widget.
 */
static int lua_grab_window(lua_State* L) {
    // For now, grab the main application widget
    QWidget* mainWidget = qApp->activeWindow();
    if (!mainWidget) {
        // Try to get any top-level widget
        QWidgetList topLevel = qApp->topLevelWidgets();
        if (!topLevel.isEmpty()) {
            mainWidget = topLevel.first();
        }
    }

    if (!mainWidget) {
        lua_pushnil(L);
        lua_pushstring(L, "No window available to capture");
        return 2;
    }

    // Grab the window
    QPixmap pixmap = mainWidget->grab();

    // Create QPixmap userdata
    QPixmap** userData = (QPixmap**)lua_newuserdata(L, sizeof(QPixmap*));
    *userData = new QPixmap(pixmap);

    // Set metatable (we'll define this below)
    luaL_getmetatable(L, "QPixmap");
    lua_setmetatable(L, -2);

    return 1;
}

/**
 * QPixmap:save(path) -> boolean
 * Saves pixmap to file.
 */
static int qpixmap_save(lua_State* L) {
    QPixmap** userData = (QPixmap**)luaL_checkudata(L, 1, "QPixmap");
    const char* path = luaL_checkstring(L, 2);

    bool success = (*userData)->save(QString::fromUtf8(path));
    lua_pushboolean(L, success);

    return 1;
}

/**
 * QPixmap:__gc() - Cleanup
 */
static int qpixmap_gc(lua_State* L) {
    QPixmap** userData = (QPixmap**)luaL_checkudata(L, 1, "QPixmap");
    delete *userData;
    *userData = nullptr;
    return 0;
}

//============================================================================
// Timer Bindings
//============================================================================

/**
 * lua_create_timer(interval_ms, repeat_mode, callback) -> timer userdata
 * Creates a QTimer that calls Lua callback.
 */
static int lua_create_timer(lua_State* L) {
    int interval_ms = luaL_checkinteger(L, 1);
    bool repeat_mode = lua_toboolean(L, 2);
    luaL_checktype(L, 3, LUA_TFUNCTION);

    // Store callback in registry
    lua_pushvalue(L, 3);
    int callbackRef = luaL_ref(L, LUA_REGISTRYINDEX);

    // Create timer
    QTimer* timer = new QTimer();
    timer->setInterval(interval_ms);
    timer->setSingleShot(!repeat_mode);

    // Connect to Lua callback
    QObject::connect(timer, &QTimer::timeout, [L, callbackRef]() {
        lua_rawgeti(L, LUA_REGISTRYINDEX, callbackRef);
        if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
            const char* error = lua_tostring(L, -1);
            qWarning() << "Timer callback error:" << error;
            lua_pop(L, 1);
        }
    });

    // Create timer userdata
    QTimer** userData = (QTimer**)lua_newuserdata(L, sizeof(QTimer*));
    *userData = timer;

    // Set metatable
    luaL_getmetatable(L, "QTimer");
    lua_setmetatable(L, -2);

    return 1;
}

/**
 * QTimer:start()
 */
static int qtimer_start(lua_State* L) {
    QTimer** userData = (QTimer**)luaL_checkudata(L, 1, "QTimer");
    (*userData)->start();
    return 0;
}

/**
 * QTimer:stop()
 */
static int qtimer_stop(lua_State* L) {
    QTimer** userData = (QTimer**)luaL_checkudata(L, 1, "QTimer");
    (*userData)->stop();
    return 0;
}

/**
 * QTimer:__gc() - Cleanup
 */
static int qtimer_gc(lua_State* L) {
    QTimer** userData = (QTimer**)luaL_checkudata(L, 1, "QTimer");
    (*userData)->stop();
    delete *userData;
    *userData = nullptr;
    return 0;
}

//============================================================================
// Registration
//============================================================================

void registerBugReporterBindings(lua_State* L) {
    // Register gesture logger functions
    lua_register(L, "install_gesture_logger", lua_install_gesture_logger);
    lua_register(L, "set_gesture_logger_enabled", lua_set_gesture_logger_enabled);

    // Register screenshot functions
    lua_register(L, "grab_window", lua_grab_window);

    // Register timer functions
    lua_register(L, "create_timer", lua_create_timer);

    // Create QPixmap metatable
    luaL_newmetatable(L, "QPixmap");
    lua_pushstring(L, "__index");
    lua_newtable(L);
    lua_pushcfunction(L, qpixmap_save);
    lua_setfield(L, -2, "save");
    lua_settable(L, -3);
    lua_pushcfunction(L, qpixmap_gc);
    lua_setfield(L, -2, "__gc");
    lua_pop(L, 1);

    // Create QTimer metatable
    luaL_newmetatable(L, "QTimer");
    lua_pushstring(L, "__index");
    lua_newtable(L);
    lua_pushcfunction(L, qtimer_start);
    lua_setfield(L, -2, "start");
    lua_pushcfunction(L, qtimer_stop);
    lua_setfield(L, -2, "stop");
    lua_settable(L, -3);
    lua_pushcfunction(L, qtimer_gc);
    lua_setfield(L, -2, "__gc");
    lua_pop(L, 1);
}

} // namespace bug_reporter
