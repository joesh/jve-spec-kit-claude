// shortcut_bindings.cpp — QShortcut bindings for Lua
//
// Creates QShortcut objects with Qt context (Window or WidgetWithChildren),
// connects activated() signal to Lua callbacks.

#include "binding_macros.h"
#include <QShortcut>
#include <QKeySequence>
#include <QKeySequenceEdit>
#include <QKeyCombination>
#include <QKeyEvent>
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
                jve_handle_lua_callback_error(L, "shortcut.activated");
            }
        } else {
            jve_discard_non_function_handler(L, handler_str.c_str(), "shortcut.activated");
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
        // deleteLater: an activated() handler may still be on the call
        // stack when Lua decides to drop the shortcut (e.g. handler
        // unbinds itself). Raw delete would yank the object out from
        // under Qt's event dispatch and corrupt iteration.
        shortcut->deleteLater();
    }
    return 0;
}

// ============================================================================
// QKeySequenceEdit — Qt's purpose-built widget for capturing a key chord.
// Used by the keyboard customization dialog to capture user-typed shortcuts
// instead of fighting QShortcut with a global key handler.
//
// PermissiveKeySequenceEdit overrides keyPressEvent because vanilla
// QKeySequenceEdit silently drops plain printable keys without modifiers
// (e.g. ',' '.' 'A' on their own) — but NLE shortcuts are routinely
// single-key (J/K/L, comma/period for trim, etc.). We accept any non-
// modifier key as a valid sequence.
//
// Returns key + modifiers as two ints (QKeyCombination decomposed) so the
// Lua side can run them through registry.format_shortcut() — that yields
// the same canonical strings the TOML keymap uses.
// ============================================================================
class PermissiveKeySequenceEdit : public QKeySequenceEdit {
public:
    using QKeySequenceEdit::QKeySequenceEdit;
protected:
    void keyPressEvent(QKeyEvent* e) override {
        int key = e->key();
        // Ignore pure modifier-key presses (we want the key they modify)
        if (key == 0
            || key == Qt::Key_Control || key == Qt::Key_Shift
            || key == Qt::Key_Alt || key == Qt::Key_Meta
            || key == Qt::Key_AltGr || key == Qt::Key_CapsLock
            || key == Qt::Key_NumLock || key == Qt::Key_ScrollLock) {
            return;
        }
        // Keep only the four chord-modifiers; Qt sometimes sets KeypadModifier
        // and GroupSwitchModifier which would mismatch TOML bindings.
        Qt::KeyboardModifiers mods = e->modifiers() & (
            Qt::ShiftModifier | Qt::ControlModifier
            | Qt::AltModifier | Qt::MetaModifier);
        QKeyCombination combo(mods, static_cast<Qt::Key>(key));
        setKeySequence(QKeySequence(combo));  // fires keySequenceChanged
        e->accept();
    }
};

int lua_create_key_sequence_edit(lua_State* L) {
    auto* edit = new PermissiveKeySequenceEdit();
    // Capture only the first combo — we don't support multi-stroke chords
    // (Premiere-style shortcuts are single combos).
    edit->setMaximumSequenceLength(1);
    lua_push_widget(L, edit);
    return 1;
}

// Returns: key_int, modifiers_int   (or nothing if the sequence is empty)
int lua_key_sequence_edit_get(lua_State* L) {
    QKeySequenceEdit* edit = get_widget<QKeySequenceEdit>(L, 1);
    if (!edit) {
        return luaL_error(L, "qt_key_sequence_edit_get: widget required");
    }
    QKeySequence seq = edit->keySequence();
    if (seq.isEmpty()) {
        return 0;
    }
    QKeyCombination combo = seq[0];
    lua_pushinteger(L, static_cast<lua_Integer>(combo.key()));
    lua_pushinteger(L, static_cast<lua_Integer>(combo.keyboardModifiers()));
    return 2;
}

int lua_key_sequence_edit_clear(lua_State* L) {
    QKeySequenceEdit* edit = get_widget<QKeySequenceEdit>(L, 1);
    if (edit) {
        edit->clear();
    }
    return 0;
}

// Set the captured sequence programmatically (used to seed the editor with
// the command's existing shortcut so the user can edit-not-retype).
int lua_key_sequence_edit_set(lua_State* L) {
    QKeySequenceEdit* edit = get_widget<QKeySequenceEdit>(L, 1);
    int key = static_cast<int>(luaL_checkinteger(L, 2));
    int mods = static_cast<int>(luaL_checkinteger(L, 3));
    if (!edit) {
        return luaL_error(L, "qt_key_sequence_edit_set: widget required");
    }
    QKeyCombination combo = QKeyCombination::fromCombined(key | mods);
    edit->setKeySequence(QKeySequence(combo));
    return 0;
}

// Connect the editingFinished signal (fires when user releases keys / focus leaves)
int lua_key_sequence_edit_on_changed(lua_State* L) {
    QKeySequenceEdit* edit = get_widget<QKeySequenceEdit>(L, 1);
    const char* handler_name = luaL_checkstring(L, 2);
    if (!edit || !handler_name) {
        return luaL_error(L, "qt_key_sequence_edit_on_changed: widget and handler required");
    }
    std::string handler_str(handler_name);
    QObject::connect(edit, &QKeySequenceEdit::keySequenceChanged,
        [L, handler_str](const QKeySequence&) {
            lua_getglobal(L, handler_str.c_str());
            if (lua_isfunction(L, -1)) {
                if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
                    jve_handle_lua_callback_error(L, "key_sequence_edit.changed");
                }
            } else {
                jve_discard_non_function_handler(L, handler_str.c_str(),
                    "key_sequence_edit.changed");
            }
        });
    return 0;
}

// ============================================================================
// KeyStateWatcher — installs an event filter on a target widget that fires
// the Lua handler for every KeyPress/KeyRelease on that widget's window.
// Handler signature: (event_type_string, key_int, modifiers_int)
//   event_type = "press" | "release"
//   key        = Qt::Key code of the key that changed state
//   modifiers  = POST-event modifier mask (correct even for modifier keys,
//                because Qt reports pre-event modifiers — we flip the bit)
//
// Used by the keyboard customization dialog so the picture can:
//   - reflect physically-held modifiers (Shift/Cmd/Opt/Ctrl)
//   - highlight the tile matching the physically-pressed key
// ============================================================================
class KeyStateWatcher : public QObject {
public:
    KeyStateWatcher(lua_State* L_ptr, const std::string& handler, QObject* parent = nullptr)
        : QObject(parent), lua_state(L_ptr), handler_name(handler) {}

protected:
    bool eventFilter(QObject* obj, QEvent* event) override {
        QEvent::Type t = event->type();
        if (t != QEvent::KeyPress && t != QEvent::KeyRelease) {
            return QObject::eventFilter(obj, event);
        }
        QKeyEvent* ke = static_cast<QKeyEvent*>(event);
        // Ignore OS auto-repeat — a held-down key otherwise fires dozens of
        // press events per second, which would flash the tile and thrash any
        // filter driven by it. Releases don't auto-repeat.
        if (ke->isAutoRepeat()) {
            return QObject::eventFilter(obj, event);
        }
        int k = ke->key();

        int mods = static_cast<int>(ke->modifiers() & (
            Qt::ShiftModifier | Qt::ControlModifier
            | Qt::AltModifier | Qt::MetaModifier));
        // For modifier-key events, Qt reports PRE-event modifiers — flip the
        // bit being pressed/released so callers see the post-event mask.
        int mod_bit = 0;
        if (k == Qt::Key_Shift)        mod_bit = Qt::ShiftModifier;
        else if (k == Qt::Key_Control) mod_bit = Qt::ControlModifier;
        else if (k == Qt::Key_Alt)     mod_bit = Qt::AltModifier;
        else if (k == Qt::Key_Meta)    mod_bit = Qt::MetaModifier;
        if (mod_bit) {
            if (t == QEvent::KeyPress) mods |= mod_bit;
            else                       mods &= ~mod_bit;
        }

        lua_getglobal(lua_state, handler_name.c_str());
        if (lua_isfunction(lua_state, -1)) {
            lua_pushstring(lua_state, t == QEvent::KeyPress ? "press" : "release");
            lua_pushinteger(lua_state, k);
            lua_pushinteger(lua_state, mods);
            if (lua_pcall(lua_state, 3, 0, 0) != LUA_OK) {
                jve_handle_lua_callback_error(lua_state, "key_state_watcher");
            }
        } else {
            jve_discard_non_function_handler(lua_state, handler_name.c_str(),
                "key_state_watcher");
        }
        return QObject::eventFilter(obj, event);
    }

private:
    lua_State* lua_state;
    std::string handler_name;
};

int lua_install_key_state_watcher(lua_State* L) {
    QWidget* target = get_widget<QWidget>(L, 1);
    const char* handler_name = luaL_checkstring(L, 2);
    if (!target) {
        return luaL_error(L, "qt_install_key_state_watcher: widget required");
    }
    auto* watcher = new KeyStateWatcher(L, std::string(handler_name), target);
    target->installEventFilter(watcher);
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

