#include "binding_macros.h"
#include <QPushButton>
#include <QCheckBox>
#include <QComboBox>
#include <QDialogButtonBox>
#include <QSlider>
#include <QGroupBox>
#include <QTextEdit>
#include <QLineEdit>
#include <QProgressBar>
#include <QScrollBar>
#include <QApplication>

// CONTROL.PROCESS_EVENTS() — drain Qt event queue (also drains GCD main queue on macOS).
// Also forces pending repaints so widget state changes (disable, text) are visible
// even when called from within a signal handler.
// Essential for integration tests: PlaybackController dispatches frame delivery
// and callbacks via dispatch_async(dispatch_get_main_queue()), which requires
// the main run loop to be pumped.
static int lua_process_events(lua_State*) {
    // sendPostedEvents first to flush deferred layout/paint events,
    // then processEvents to drain the full queue including repaints.
    // Without sendPostedEvents, widget changes (setText, setEnabled)
    // made inside a signal handler aren't visible until the handler returns.
    QApplication::sendPostedEvents();
    QApplication::processEvents();
    return 0;
}




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

int lua_get_scroll_area_v_scroll(lua_State* L) {
    QScrollArea* sa = get_widget<QScrollArea>(L, 1);
    if (sa && sa->verticalScrollBar()) {
        lua_pushinteger(L, sa->verticalScrollBar()->value());
    } else {
        lua_pushinteger(L, 0);
    }
    return 1;
}

int lua_set_scroll_area_v_scroll(lua_State* L) {
    QScrollArea* sa = get_widget<QScrollArea>(L, 1);
    int value = luaL_checkinteger(L, 2);
    if (sa && sa->verticalScrollBar()) {
        sa->verticalScrollBar()->setValue(value);
    }
    return 0;
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

// Group Box
LUA_BIND_WIDGET_CREATOR_WITH_TEXT(lua_create_group_box, QGroupBox)

// Text Edit (multiline)
int lua_create_text_edit(lua_State* L) {
    const char* text = lua_tostring(L, 1);
    QTextEdit* te = new QTextEdit();
    if (text) te->setPlainText(QString::fromUtf8(text));
    lua_push_widget(L, te);
    return 1;
}

int lua_set_text_edit_read_only(lua_State* L) {
    QTextEdit* te = get_widget<QTextEdit>(L, 1);
    bool ro = lua_toboolean(L, 2);
    if (te) te->setReadOnly(ro);
    return 0;
}

// CONTROL.SCROLL_TEXT_EDIT_TO_END(text_edit)
int lua_scroll_text_edit_to_end(lua_State* L) {
    QTextEdit* te = get_widget<QTextEdit>(L, 1);
    if (te) {
        te->moveCursor(QTextCursor::End);
        te->ensureCursorVisible();
    }
    return 0;
}

// CONTROL.SET_BUTTON_AUTO_DEFAULT(button, bool)
int lua_set_button_auto_default(lua_State* L) {
    QPushButton* btn = get_widget<QPushButton>(L, 1);
    bool ad = lua_toboolean(L, 2);
    if (btn) {
        btn->setAutoDefault(ad);
        btn->setDefault(ad);
    }
    return 0;
}

int lua_set_line_edit_read_only(lua_State* L) {
    QLineEdit* le = get_widget<QLineEdit>(L, 1);
    bool ro = lua_toboolean(L, 2);
    if (le) le->setReadOnly(ro);
    return 0;
}

// Progress Bar
int lua_create_progress_bar(lua_State* L) {
    QProgressBar* pb = new QProgressBar();
    pb->setRange(0, 100);
    pb->setValue(0);
    lua_push_widget(L, pb);
    return 1;
}

int lua_set_progress_bar_value(lua_State* L) {
    QProgressBar* pb = get_widget<QProgressBar>(L, 1);
    int val = luaL_checkinteger(L, 2);
    if (pb) pb->setValue(val);
    return 0;
}

int lua_set_progress_bar_range(lua_State* L) {
    QProgressBar* pb = get_widget<QProgressBar>(L, 1);
    int min = luaL_checkinteger(L, 2);
    int max = luaL_checkinteger(L, 3);
    if (pb) pb->setRange(min, max);
    return 0;
}

// Generic setEnabled for any widget
int lua_set_enabled(lua_State* L) {
    QWidget* w = static_cast<QWidget*>(lua_to_widget(L, 1));
    bool enabled = lua_toboolean(L, 2);
    if (w) w->setEnabled(enabled);
    return 0;
}

// Combobox index
int lua_set_combobox_current_index(lua_State* L) {
    QComboBox* cb = get_widget<QComboBox>(L, 1);
    int idx = luaL_checkinteger(L, 2);
    if (cb) cb->setCurrentIndex(idx);
    return 0;
}

int lua_get_combobox_current_index(lua_State* L) {
    QComboBox* cb = get_widget<QComboBox>(L, 1);
    if (cb) {
        lua_pushinteger(L, cb->currentIndex());
    } else {
        lua_pushnil(L);
    }
    return 1;
}

// Connect QComboBox::currentIndexChanged to a Lua handler
// Args: combobox, handler_name (global function)
int lua_set_combobox_change_handler(lua_State* L) {
    QComboBox* cb = get_widget<QComboBox>(L, 1);
    const char* handler_name = luaL_checkstring(L, 2);
    if (!cb || !handler_name) {
        return luaL_error(L, "qt_set_combobox_change_handler: combobox and handler required");
    }

    std::string handler_str(handler_name);
    QObject::connect(cb, QOverload<int>::of(&QComboBox::currentIndexChanged),
        [L, handler_str](int) {
            lua_getglobal(L, handler_str.c_str());
            if (lua_isfunction(L, -1)) {
                if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
                    jve_handle_lua_callback_error(L, "combobox.current_index_changed");
                }
            } else {
                jve_discard_non_function_handler(L, handler_str.c_str(),
                    "combobox.current_index_changed");
            }
        });
    return 0;
}

// ============================================================================
// QDialogButtonBox bindings
// ============================================================================

// CONTROL.CREATE_BUTTON_BOX() → button_box widget
int lua_create_button_box(lua_State* L) {
    auto* bb = new QDialogButtonBox();
    lua_push_widget(L, bb);
    return 1;
}

// Map Lua role string to QDialogButtonBox::ButtonRole
static QDialogButtonBox::ButtonRole role_from_string(const char* role) {
    if (!role) return QDialogButtonBox::ActionRole;
    if (strcmp(role, "accept") == 0) return QDialogButtonBox::AcceptRole;
    if (strcmp(role, "reject") == 0) return QDialogButtonBox::RejectRole;
    if (strcmp(role, "apply") == 0)  return QDialogButtonBox::ApplyRole;
    if (strcmp(role, "reset") == 0)  return QDialogButtonBox::ResetRole;
    if (strcmp(role, "help") == 0)   return QDialogButtonBox::HelpRole;
    return QDialogButtonBox::ActionRole;
}

// CONTROL.BUTTON_BOX_ADD(button_box, text, role) → button widget
// role: "accept", "reject", "apply", "reset", "help", "action" (default)
// Accept-role button automatically becomes the default button.
// Reject-role button has autoDefault disabled.
int lua_button_box_add(lua_State* L) {
    auto* bb = get_widget<QDialogButtonBox>(L, 1);
    const char* text = luaL_checkstring(L, 2);
    const char* role_str = lua_isstring(L, 3) ? lua_tostring(L, 3) : "action";

    if (!bb) return luaL_error(L, "BUTTON_BOX_ADD: first argument must be QDialogButtonBox");

    auto role = role_from_string(role_str);
    QPushButton* btn = new QPushButton(QString::fromUtf8(text));

    // Accept role: make it the default button
    if (role == QDialogButtonBox::AcceptRole) {
        btn->setDefault(true);
        btn->setAutoDefault(true);
    } else {
        // All non-accept buttons: prevent stealing default on focus
        btn->setAutoDefault(false);
        btn->setDefault(false);
    }

    bb->addButton(btn, role);
    lua_push_widget(L, btn);
    return 1;
}

// CONTROL.BUTTON_BOX_SET_HANDLER(button_box, signal, global_name)
// signal: "accepted", "rejected"
int lua_button_box_set_handler(lua_State* L) {
    auto* bb = get_widget<QDialogButtonBox>(L, 1);
    const char* signal = luaL_checkstring(L, 2);
    const char* handler_name = luaL_checkstring(L, 3);

    if (!bb) return luaL_error(L, "BUTTON_BOX_SET_HANDLER: first argument must be QDialogButtonBox");

    lua_State* gL = L;  // capture for lambda

    if (strcmp(signal, "accepted") == 0) {
        QObject::connect(bb, &QDialogButtonBox::accepted, bb, [gL, handler_name]() {
            lua_getglobal(gL, handler_name);
            if (lua_isfunction(gL, -1)) {
                if (lua_pcall(gL, 0, 0, 0) != 0) {
                    jve_handle_lua_callback_error(gL, "button_box.accepted");
                }
            } else {
                jve_discard_non_function_handler(gL, handler_name, "button_box.accepted");
            }
        });
    } else if (strcmp(signal, "rejected") == 0) {
        QObject::connect(bb, &QDialogButtonBox::rejected, bb, [gL, handler_name]() {
            lua_getglobal(gL, handler_name);
            if (lua_isfunction(gL, -1)) {
                if (lua_pcall(gL, 0, 0, 0) != 0) {
                    jve_handle_lua_callback_error(gL, "button_box.rejected");
                }
            } else {
                jve_discard_non_function_handler(gL, handler_name, "button_box.rejected");
            }
        });
    } else {
        return luaL_error(L, "BUTTON_BOX_SET_HANDLER: unknown signal '%s' (use 'accepted' or 'rejected')", signal);
    }

    return 0;
}
