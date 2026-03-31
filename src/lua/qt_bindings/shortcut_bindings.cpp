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
// FocusContainmentWidget — overrides focusNextPrevChild() to trap Tab within
// a panel's children. This is the Qt-standard mechanism for panel-scoped
// focus cycling. Using TabFocusReason ensures native focus highlights appear.
// ============================================================================
class FocusContainmentWidget : public StyledWidget {
public:
    using StyledWidget::StyledWidget;

    void setDefaultButton(QAbstractButton* btn) { m_defaultButton = btn; }
    QAbstractButton* defaultButton() const { return m_defaultButton; }

protected:
    bool focusNextPrevChild(bool next) override {
        // Collect top-level focusable children only — skip internal sub-widgets
        // of compound controls (QTreeWidget viewport, scrollbar handles, etc.)
        QList<QWidget*> focusable;
        for (auto* child : findChildren<QWidget*>()) {
            if (!(child->focusPolicy() & Qt::TabFocus)
                || !child->isVisible() || !child->isEnabled()) {
                continue;
            }
            // Skip if a focusable ancestor (other than this container) exists —
            // that means child is an internal widget of a compound control.
            bool is_internal = false;
            for (QWidget* p = child->parentWidget(); p && p != this; p = p->parentWidget()) {
                if (p->focusPolicy() & Qt::TabFocus) {
                    is_internal = true;
                    break;
                }
            }
            if (!is_internal) {
                focusable.append(child);
            }
        }
        if (focusable.isEmpty()) return false;

        QWidget* current = QApplication::focusWidget();
        int idx = focusable.indexOf(current);
        // If current focus is inside a compound widget (e.g., tree viewport),
        // resolve to the top-level focusable parent in our list.
        if (idx < 0 && current) {
            for (QWidget* p = current->parentWidget(); p && p != this; p = p->parentWidget()) {
                idx = focusable.indexOf(p);
                if (idx >= 0) break;
            }
        }
        if (idx < 0) {
            focusable.first()->setFocus(Qt::TabFocusReason);
            return true;
        }

        int target = next ? (idx + 1) % focusable.size()
                          : (idx - 1 + focusable.size()) % focusable.size();
        QWidget* targetWidget = focusable[target];
        targetWidget->setFocus(next ? Qt::TabFocusReason
                                    : Qt::BacktabFocusReason);

        // If focusing a tree with no current item, select the first item
        // so the focus ring is visible on an item row.
        if (auto* tree = qobject_cast<QTreeWidget*>(targetWidget)) {
            if (!tree->currentItem() && tree->topLevelItemCount() > 0) {
                tree->setCurrentItem(tree->topLevelItem(0));
            }
        }
        return true;  // Handled — Tab stays within this panel
    }

private:
    QAbstractButton* m_defaultButton = nullptr;
};

// ============================================================================
// Create a FocusContainmentWidget — use as panel container for Tab wrapping.
// Args: (none)
// Returns: widget userdata
// ============================================================================
int lua_create_focus_container(lua_State* L) {
    auto* widget = new FocusContainmentWidget();
    lua_push_widget(L, widget);
    return 1;
}

// ============================================================================
// Set a default button on a FocusContainmentWidget.
// The default button is activated via QLineEdit::returnPressed connections
// (set up in Lua) — not via QShortcut which fires too early.
// Args: container_widget, button_widget
// ============================================================================
int lua_set_container_default_button(lua_State* L) {
    auto* container = dynamic_cast<FocusContainmentWidget*>(
        get_widget<QWidget>(L, 1));
    auto* button = get_widget<QAbstractButton>(L, 2);
    if (!container) {
        return luaL_error(L, "qt_set_container_default_button: "
                             "container must be a FocusContainmentWidget");
    }
    if (!button) {
        return luaL_error(L, "qt_set_container_default_button: "
                             "button required");
    }

    container->setDefaultButton(button);
    // Default button activation is handled by connecting QLineEdit::returnPressed
    // to the action in Lua (qt_set_line_edit_return_pressed_handler).
    // No QShortcut — QShortcut fires before widgets process Return, wrong priority.
    return 0;
}

