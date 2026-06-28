#include "qt_bindings_bug_reporter.h"
#include "../jve_log.h"
#include "../jve_lua_callback.h"
#include "../qt_bindings.h"
#include "gesture_logger.h"
#include <QWidget>
#include <QPixmap>
#include <QPainter>
#include <QPointer>
#include <QColor>
#include <QPoint>
#include <QRect>
#include <QTimer>
#include <QApplication>
#include <QMouseEvent>
#include <QKeyEvent>
#include <QWheelEvent>
#include <QThread>
#include <QElapsedTimer>
#include <QList>

namespace bug_reporter {

// Global gesture logger instance
static GestureLogger* g_gestureLogger = nullptr;

// Feature 027 FR-019: widgets that must be visually redacted in every
// screenshot before the pixmap reaches the in-memory ring. UI code
// (e.g. project_browser.lua) marks its tree as sensitive at setup
// time; lua_grab_window walks this list post-grab and fills each
// visible widget's rect with solid grey. QPointer auto-nils when the
// underlying QWidget is destroyed, so stale entries don't crash.
static QList<QPointer<QWidget>> s_redact_widgets;

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
            jve_handle_lua_callback_error(L, "bug_reporter.gesture");
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
    // Feature 027 T010b: target the JVE main window by objectName so a
    // transient dialog focused at F12 time can't poison the capture.
    // The main window's objectName is set in src/lua/ui/layout.lua just
    // after WIDGET.CREATE_MAIN_WINDOW (T010a). If no widget matches,
    // fail loud — per Constitution VI we do NOT silently fall back to
    // whatever activeWindow happens to be.
    QWidget* mainWidget = nullptr;
    for (QWidget* w : qApp->topLevelWidgets()) {
        if (w && w->objectName() == QStringLiteral("JVEMainWindow")) {
            mainWidget = w;
            break;
        }
    }
    if (!mainWidget) {
        return luaL_error(L,
            "bug_reporter grab_window: no top-level widget has objectName 'JVEMainWindow' — "
            "is layout.lua's qt_set_object_name call wired (T010a)?");
    }

    QPixmap pixmap = mainWidget->grab();

    // FR-019: scrub registered sensitive widget regions out of the
    // pixmap before it can be stored in the ring. Path strings shown
    // by project_browser are the canonical leak; UI code marks the
    // widget via qt_bug_reporter_redact_widget at setup. QPointer
    // guards against widgets destroyed between mark and grab.
    if (!s_redact_widgets.isEmpty()) {
        QPainter painter(&pixmap);
        const QColor mask(96, 96, 96);
        for (const QPointer<QWidget>& wp : s_redact_widgets) {
            QWidget* w = wp.data();
            if (!w || !w->isVisible()) continue;
            QPoint topLeft = w->mapTo(mainWidget, QPoint(0, 0));
            QRect r(topLeft, w->size());
            painter.fillRect(r, mask);
        }
        painter.end();
    }

    // Create QPixmap userdata
    QPixmap** userData = (QPixmap**)lua_newuserdata(L, sizeof(QPixmap*));
    *userData = new QPixmap(pixmap);

    luaL_getmetatable(L, "QPixmap");
    lua_setmetatable(L, -2);

    return 1;
}

/**
 * qt_bug_reporter_redact_widget(widget)
 * Marks `widget` as visually sensitive — its rect will be filled with
 * solid grey on every subsequent grab_window pixmap. Idempotent for
 * the same QWidget*; the entry self-clears when the widget is destroyed
 * (QPointer). FR-019.
 */
static int lua_bug_reporter_redact_widget(lua_State* L) {
    void* ptr = lua_to_widget(L, 1);
    if (!ptr) {
        return luaL_error(L,
            "qt_bug_reporter_redact_widget: widget arg required");
    }
    QWidget* w = static_cast<QWidget*>(ptr);
    for (const QPointer<QWidget>& existing : s_redact_widgets) {
        if (existing.data() == w) return 0;
    }
    s_redact_widgets.append(QPointer<QWidget>(w));
    return 0;
}

/**
 * qpixmap_width(pixmap) / qpixmap_height(pixmap) — accessors used by
 * the bug-reporter main-window capture test (T004). Trivial wrappers
 * over QPixmap::width()/height().
 */
static int lua_qpixmap_width(lua_State* L) {
    QPixmap** userData = (QPixmap**)luaL_checkudata(L, 1, "QPixmap");
    lua_pushinteger(L, (*userData)->width());
    return 1;
}
static int lua_qpixmap_height(lua_State* L) {
    QPixmap** userData = (QPixmap**)luaL_checkudata(L, 1, "QPixmap");
    lua_pushinteger(L, (*userData)->height());
    return 1;
}

/**
 * QPixmap:byte_count() -> integer
 * Conservative upper bound on the in-RAM cost of this pixmap, computed
 * from the underlying QImage's sizeInBytes(). Used by capture_manager
 * to bound the screenshot ring by total bytes rather than count; a
 * 4K-monitor pixmap is ~33 MB at 32bpp, so the prior 300-entry cap
 * meant up to 10 GB of RSS — pass 1+2 audit's #6 HIGH finding.
 */
static int lua_qpixmap_byte_count(lua_State* L) {
    QPixmap** userData = (QPixmap**)luaL_checkudata(L, 1, "QPixmap");
    QPixmap* pm = *userData;
    if (!pm || pm->isNull()) {
        lua_pushinteger(L, 0);
        return 1;
    }
    // toImage() copies; sizeInBytes is on the QImage. width*height*depth/8
    // is the same number without the copy.
    qint64 bytes = static_cast<qint64>(pm->width())
                 * static_cast<qint64>(pm->height())
                 * static_cast<qint64>(pm->depth() > 0 ? pm->depth() : 32)
                 / 8;
    lua_pushinteger(L, bytes);
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

    // Parent to qApp so QApplication shutdown reaps the timer cleanly
    // if Lua never GC's the userdata. Without a parent, a long-lived
    // Lua-side reference (e.g. global) keeps the QTimer alive past
    // QApplication teardown, then the eventual GC `delete` runs after
    // the QObject machinery is gone — dangling-timeout on shutdown.
    QTimer* timer = new QTimer(qApp);
    timer->setInterval(interval_ms);
    timer->setSingleShot(!repeat_mode);

    // Connect to Lua callback. Single-shot timers must release the registry
    // ref after firing; repeating timers hold the ref for their lifetime
    // (released when the Lua GC finalizes the QTimer userdata).
    bool single_shot = !repeat_mode;
    QObject::connect(timer, &QTimer::timeout, [L, callbackRef, single_shot, timer]() {
        lua_rawgeti(L, LUA_REGISTRYINDEX, callbackRef);
        if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
            jve_handle_lua_callback_error(L, "bug_reporter.timer");
        }
        if (single_shot) {
            luaL_unref(L, LUA_REGISTRYINDEX, callbackRef);
            timer->deleteLater();
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
    if (*userData) {
        (*userData)->stop();
        // deleteLater (not direct delete) so any in-flight timeout
        // event Qt has already posted gets flushed against the still-
        // live object before the destructor runs. Direct delete here
        // would crash on the queued timeout (use-after-free).
        (*userData)->deleteLater();
        *userData = nullptr;
    }
    return 0;
}

//============================================================================
// Event Posting Bindings (for test replay)
//============================================================================

/**
 * Helper: Convert Lua modifier table to Qt::KeyboardModifiers
 */
static Qt::KeyboardModifiers parseModifiers(lua_State* L, int index) {
    Qt::KeyboardModifiers modifiers = Qt::NoModifier;

    lua_pushnil(L);
    while (lua_next(L, index) != 0) {
        if (lua_isstring(L, -1)) {
            QString mod = QString::fromUtf8(lua_tostring(L, -1));
            if (mod == "shift") modifiers |= Qt::ShiftModifier;
            else if (mod == "ctrl") modifiers |= Qt::ControlModifier;
            else if (mod == "alt") modifiers |= Qt::AltModifier;
            else if (mod == "meta") modifiers |= Qt::MetaModifier;
        }
        lua_pop(L, 1);
    }

    return modifiers;
}

/**
 * Helper: Convert button string to Qt::MouseButton
 */
static Qt::MouseButton parseMouseButton(const QString& button) {
    if (button == "left") return Qt::LeftButton;
    if (button == "right") return Qt::RightButton;
    if (button == "middle") return Qt::MiddleButton;
    return Qt::NoButton;
}

/**
 * Helper: Convert key string to Qt::Key
 */
static int parseKey(const QString& keyStr) {
    // Simple mapping - extend as needed
    if (keyStr == "Return" || keyStr == "Enter") return Qt::Key_Return;
    if (keyStr == "Escape") return Qt::Key_Escape;
    if (keyStr == "Tab") return Qt::Key_Tab;
    if (keyStr == "Backspace") return Qt::Key_Backspace;
    if (keyStr == "Delete") return Qt::Key_Delete;
    if (keyStr == "Left") return Qt::Key_Left;
    if (keyStr == "Right") return Qt::Key_Right;
    if (keyStr == "Up") return Qt::Key_Up;
    if (keyStr == "Down") return Qt::Key_Down;
    if (keyStr == "Space") return Qt::Key_Space;

    // Single character keys
    if (keyStr.length() == 1) {
        return keyStr[0].unicode();
    }

    return Qt::Key_unknown;
}

/**
 * lua_post_mouse_event(event_type, x, y, button, modifiers)
 * Posts a mouse event to the application.
 */
static int lua_post_mouse_event(lua_State* L) {
    const char* eventTypeStr = luaL_checkstring(L, 1);
    int x = luaL_checkinteger(L, 2);
    int y = luaL_checkinteger(L, 3);
    const char* buttonStr = luaL_optstring(L, 4, "left");

    QEvent::Type eventType;
    QString typeStr = QString::fromUtf8(eventTypeStr);
    if (typeStr == "MouseButtonPress") eventType = QEvent::MouseButtonPress;
    else if (typeStr == "MouseButtonRelease") eventType = QEvent::MouseButtonRelease;
    else if (typeStr == "MouseMove") eventType = QEvent::MouseMove;
    else {
        lua_pushboolean(L, false);
        lua_pushstring(L, "Unknown mouse event type");
        return 2;
    }

    Qt::MouseButton button = parseMouseButton(QString::fromUtf8(buttonStr));
    Qt::KeyboardModifiers modifiers = Qt::NoModifier;
    if (lua_istable(L, 5)) {
        modifiers = parseModifiers(L, 5);
    }

    // Get the widget at the given position
    QWidget* widget = qApp->widgetAt(QPoint(x, y));
    if (!widget) {
        // Try active window
        widget = qApp->activeWindow();
    }

    if (!widget) {
        lua_pushboolean(L, false);
        lua_pushstring(L, "No target widget found");
        return 2;
    }

    // Convert to widget-local coordinates
    QPoint globalPos(x, y);
    QPoint localPos = widget->mapFromGlobal(globalPos);

    // Create and post event. QMouseEvent's 5th arg `buttons` is the bitmask
    // of all currently-held buttons (for chording / drag-with-second-button
    // scenarios); the 4th `button` is just the one that triggered this event.
    // Synthetic events posted from the bug-reporter test harness drive a
    // single button at a time, so `buttons = button` is the correct bitmask
    // for those flows. If we ever post multi-button events, take a bitmask
    // here instead of mirroring `button`.
    Qt::MouseButtons buttons = QFlags<Qt::MouseButton>(button);
    QMouseEvent* event = new QMouseEvent(
        eventType,
        localPos,
        globalPos,
        button,
        buttons,
        modifiers
    );

    QApplication::postEvent(widget, event);
    lua_pushboolean(L, true);
    return 1;
}

/**
 * lua_post_key_event(event_type, key, text, modifiers)
 * Posts a keyboard event to the application.
 */
static int lua_post_key_event(lua_State* L) {
    const char* eventTypeStr = luaL_checkstring(L, 1);
    const char* keyStr = luaL_checkstring(L, 2);
    const char* text = luaL_optstring(L, 3, "");

    QEvent::Type eventType;
    QString typeStr = QString::fromUtf8(eventTypeStr);
    if (typeStr == "KeyPress") eventType = QEvent::KeyPress;
    else if (typeStr == "KeyRelease") eventType = QEvent::KeyRelease;
    else {
        lua_pushboolean(L, false);
        lua_pushstring(L, "Unknown key event type");
        return 2;
    }

    int key = parseKey(QString::fromUtf8(keyStr));
    Qt::KeyboardModifiers modifiers = Qt::NoModifier;
    if (lua_istable(L, 4)) {
        modifiers = parseModifiers(L, 4);
    }

    // Get focused widget
    QWidget* widget = qApp->focusWidget();
    if (!widget) {
        widget = qApp->activeWindow();
    }

    if (!widget) {
        lua_pushboolean(L, false);
        lua_pushstring(L, "No target widget found");
        return 2;
    }

    // Create and post event
    QKeyEvent* event = new QKeyEvent(
        eventType,
        key,
        modifiers,
        QString::fromUtf8(text)
    );

    QApplication::postEvent(widget, event);
    lua_pushboolean(L, true);
    return 1;
}

/**
 * lua_sleep_ms(milliseconds)
 * Sleep for specified milliseconds (for replay timing).
 */
static int lua_sleep_ms(lua_State* L) {
    int ms = luaL_checkinteger(L, 1);
    QThread::msleep(ms);
    return 0;
}

/**
 * lua_process_events()
 * Process pending Qt events (useful during replay).
 */
static int lua_process_events(lua_State* /*L*/) {
    QApplication::processEvents();
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
    lua_register(L, "qt_bug_reporter_redact_widget", lua_bug_reporter_redact_widget);
    // QPixmap dimension + byte-count accessors — feature 027 T010b
    // (byte_count added for capture_manager byte-bound ring, post-rewrite)
    lua_register(L, "qpixmap_width", lua_qpixmap_width);
    lua_register(L, "qpixmap_height", lua_qpixmap_height);
    lua_register(L, "qpixmap_byte_count", lua_qpixmap_byte_count);

    // Register timer functions
    lua_register(L, "create_timer", lua_create_timer);

    // Register event posting functions (for test replay)
    lua_register(L, "post_mouse_event", lua_post_mouse_event);
    lua_register(L, "post_key_event", lua_post_key_event);
    lua_register(L, "sleep_ms", lua_sleep_ms);
    lua_register(L, "process_events", lua_process_events);

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
