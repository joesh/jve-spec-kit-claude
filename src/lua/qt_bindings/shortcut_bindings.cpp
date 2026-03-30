// shortcut_bindings.cpp — QShortcut bindings for Lua
//
// Creates QShortcut objects with Qt context (Window or WidgetWithChildren),
// connects activated() signal to Lua callbacks.

#include "binding_macros.h"
#include <QShortcut>
#include <QKeySequence>
#include <QApplication>
#include <cstring>

// ============================================================================
// Create a QShortcut
// Args: parent_widget, key_sequence_string, context_string ("window"|"widget_children")
// Returns: shortcut as widget userdata
// ============================================================================
int lua_create_shortcut(lua_State* L) {
    QWidget* parent = get_widget<QWidget>(L, 1);
    const char* key_seq = luaL_checkstring(L, 2);
    const char* context_str = luaL_optstring(L, 3, "window");

    if (!parent) {
        return luaL_error(L, "qt_create_shortcut: parent widget required");
    }

    Qt::ShortcutContext context = Qt::WindowShortcut;
    if (strcmp(context_str, "widget_children") == 0) {
        context = Qt::WidgetWithChildrenShortcut;
    } else if (strcmp(context_str, "widget") == 0) {
        context = Qt::WidgetShortcut;
    }

    auto* shortcut = new QShortcut(QKeySequence(QString::fromUtf8(key_seq)), parent, nullptr, nullptr, context);

    lua_push_widget(L, shortcut);
    return 1;
}

// ============================================================================
// Connect QShortcut::activated to a Lua handler
// Args: shortcut, handler_name (global function name)
// ============================================================================
int lua_connect_shortcut(lua_State* L) {
    QShortcut* shortcut = get_widget<QShortcut>(L, 1);
    const char* handler_name = luaL_checkstring(L, 2);

    if (!shortcut || !handler_name) {
        return luaL_error(L, "qt_connect_shortcut: shortcut and handler_name required");
    }

    std::string handler_str(handler_name);
    QObject::connect(shortcut, &QShortcut::activated, [L, handler_str]() {
        lua_getglobal(L, handler_str.c_str());
        if (lua_isfunction(L, -1)) {
            if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
                const char* err = lua_tostring(L, -1);
                fprintf(stderr, "QShortcut handler '%s' error: %s\n", handler_str.c_str(), err ? err : "unknown");
                lua_pop(L, 1);
            }
        } else {
            lua_pop(L, 1);
        }
    });

    return 0;
}

// ============================================================================
// Enable/disable a QShortcut
// Args: shortcut, bool enabled
// ============================================================================
int lua_set_shortcut_enabled(lua_State* L) {
    QShortcut* shortcut = get_widget<QShortcut>(L, 1);
    bool enabled = lua_toboolean(L, 2);

    if (shortcut) {
        shortcut->setEnabled(enabled);
    }
    return 0;
}

// ============================================================================
// Delete a QShortcut
// Args: shortcut
// ============================================================================
int lua_delete_shortcut(lua_State* L) {
    QShortcut* shortcut = get_widget<QShortcut>(L, 1);
    if (shortcut) {
        delete shortcut;
    }
    return 0;
}

// ============================================================================
// Set focus containment on a widget — Tab wraps within its children
// Uses focusNextPrevChild logic via event filter
// Args: container_widget
// ============================================================================
class FocusContainment : public QObject {
public:
    explicit FocusContainment(QWidget* panel) : QObject(panel), m_panel(panel) {}

    bool handleTab(bool forward) {
        QList<QWidget*> focusable;
        for (auto* child : m_panel->findChildren<QWidget*>()) {
            if ((child->focusPolicy() & Qt::TabFocus) && child->isVisible() && child->isEnabled()) {
                focusable.append(child);
            }
        }
        if (focusable.isEmpty()) return false;

        QWidget* current = QApplication::focusWidget();
        int idx = focusable.indexOf(current);
        if (idx < 0) { focusable.first()->setFocus(); return true; }

        int next = forward ? (idx + 1) % focusable.size()
                           : (idx - 1 + focusable.size()) % focusable.size();
        focusable[next]->setFocus();
        return true;
    }

private:
    QWidget* m_panel;
};

static QMap<QWidget*, FocusContainment*> g_focus_containments;

int lua_set_focus_containment(lua_State* L) {
    QWidget* widget = get_widget<QWidget>(L, 1);
    if (!widget) return 0;

    if (!g_focus_containments.contains(widget)) {
        g_focus_containments[widget] = new FocusContainment(widget);
    }
    return 0;
}

// Called from Lua keyboard dispatch for Tab within a contained panel
int lua_cycle_contained_focus(lua_State* L) {
    QWidget* widget = get_widget<QWidget>(L, 1);
    bool forward = lua_toboolean(L, 2);
    if (!widget) return 0;

    auto it = g_focus_containments.find(widget);
    if (it != g_focus_containments.end()) {
        it.value()->handleTab(forward);
    }
    return 0;
}
