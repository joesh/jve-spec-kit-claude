#include "binding_macros.h"
#include <QAbstractButton>
#include <QCoreApplication>
#include <QContextMenuEvent>
#include <QLineEdit>
#include <QKeyEvent>
#include <QMouseEvent>
#include <QScrollArea>
#include <QScrollBar>
#include <QSplitter>
#include <QSplitterHandle>
#include <QTimer>
#include <QApplication> // For QApplication::focusWidget()
#include <QMetaObject> // For metaObject()->className()

// Helper to determine if a widget accepts text input
static bool widget_accepts_text_input(QWidget* widget)
{
    if (!widget) return false;
    // Check common text input widgets
    if (widget->inherits("QLineEdit") ||
        widget->inherits("QTextEdit") ||
        widget->inherits("QPlainTextEdit") ||
        widget->inherits("QSpinBox") ||
        widget->inherits("QDoubleSpinBox") ||
        widget->inherits("QAbstractSpinBox") ||
        widget->inherits("QComboBox")) { // QComboBox can be editable
        return true;
    }
    // Traverse up focus proxy chain (limited depth to prevent infinite loops)
    QWidget* current = widget;
    int guard = 0;
    while (current && guard < 8) {
        QWidget* proxy = current->focusProxy();
        if (proxy && proxy != current) {
            current = proxy;
            if (current->inherits("QLineEdit") || current->inherits("QTextEdit") ||
                current->inherits("QPlainTextEdit") || current->inherits("QSpinBox") ||
                current->inherits("QDoubleSpinBox") || current->inherits("QAbstractSpinBox") ||
                current->inherits("QComboBox")) {
                return true;
            }
        } else {
            break;
        }
        ++guard;
    }
    return false;
}

// Global key event filter class
class GlobalKeyFilter : public QObject
{
public:
    GlobalKeyFilter(lua_State* L_ptr, const std::string& handler)
        : QObject(), lua_state(L_ptr), handler_name(handler) {}

protected:
    bool eventFilter(QObject* obj, QEvent* event) override {
        if (event->type() == QEvent::KeyPress && lua_state) {
            QKeyEvent* keyEvent = static_cast<QKeyEvent*>(event);

            lua_getglobal(lua_state, handler_name.c_str());
            if (lua_isfunction(lua_state, -1)) {
                lua_newtable(lua_state);

                lua_pushstring(lua_state, "key");
                lua_pushinteger(lua_state, keyEvent->key());
                lua_settable(lua_state, -3);

                lua_pushstring(lua_state, "text");
                lua_pushstring(lua_state, keyEvent->text().toUtf8().constData());
                lua_settable(lua_state, -3);

                lua_pushstring(lua_state, "modifiers");
                lua_pushinteger(lua_state, (int)keyEvent->modifiers());
                lua_settable(lua_state, -3);

                QWidget* focus_widget = QApplication::focusWidget();
                if (focus_widget) {
                    lua_pushstring(lua_state, "focus_widget");
                    lua_push_widget(lua_state, focus_widget);
                    lua_settable(lua_state, -3);

                    lua_pushstring(lua_state, "focus_widget_class");
                    lua_pushstring(lua_state, focus_widget->metaObject()->className());
                    lua_settable(lua_state, -3);

                    lua_pushstring(lua_state, "focus_widget_object_name");
                    QByteArray name_bytes = focus_widget->objectName().toUtf8();
                    lua_pushstring(lua_state, name_bytes.constData());
                    lua_settable(lua_state, -3);

                    lua_pushstring(lua_state, "focus_widget_is_text_input");
                    lua_pushboolean(lua_state, widget_accepts_text_input(focus_widget));
                    lua_settable(lua_state, -3);
                } else {
                    lua_pushstring(lua_state, "focus_widget_is_text_input");
                    lua_pushboolean(lua_state, 0);
                    lua_settable(lua_state, -3);
                }

                if (lua_pcall(lua_state, 1, 1, 0) == LUA_OK) {
                    bool handled = lua_toboolean(lua_state, -1);
                    lua_pop(lua_state, 1);
                    if (handled) {
                        return true;  // Event consumed
                    }
                } else {
                    qWarning() << "Error in global key handler:" << lua_tostring(lua_state, -1);
                    lua_pop(lua_state, 1);
                }
            } else {
                lua_pop(lua_state, 1);
            }
        }
        return QObject::eventFilter(obj, event);
    }

private:
    lua_State* lua_state;
    std::string handler_name;
};

// Focus event filter for tracking widget focus changes
class FocusEventFilter : public QObject
{
public:
    FocusEventFilter(lua_State* L_ptr, const std::string& handler, QWidget* widget)
        : QObject(widget), lua_state(L_ptr), handler_name(handler), tracked_widget(widget) {}

protected:
    bool eventFilter(QObject* obj, QEvent* event) override {
        if ((event->type() == QEvent::FocusIn || event->type() == QEvent::FocusOut) && lua_state) {
            bool focus_in = (event->type() == QEvent::FocusIn);

            lua_getglobal(lua_state, handler_name.c_str());
            if (lua_isfunction(lua_state, -1)) {
                lua_newtable(lua_state);

                lua_pushstring(lua_state, "focus_in");
                lua_pushboolean(lua_state, focus_in);
                lua_settable(lua_state, -3);

                lua_pushstring(lua_state, "widget");
                lua_push_widget(lua_state, tracked_widget);
                lua_settable(lua_state, -3);

                if (lua_pcall(lua_state, 1, 0, 0) != LUA_OK) {
                    qWarning() << "Error in focus event handler:" << lua_tostring(lua_state, -1);
                    lua_pop(lua_state, 1); // Fix: Changed from lua_pop(L_ptr, 1) to lua_pop(lua_state, 1)
                }
            } else {
                lua_pop(lua_state, 1);
            }
        }
        return QObject::eventFilter(obj, event);
    }

private:
    lua_State* lua_state;
    std::string handler_name;
    QWidget* tracked_widget;
};

// Event filter class for widget clicks
class ClickEventFilter : public QObject {
public:
    ClickEventFilter(const std::string& handler, lua_State* L_ptr, QObject* parent = nullptr)
        : QObject(parent), handler_name(handler), lua_state(L_ptr) {}

protected:
    bool eventFilter(QObject* obj, QEvent* event) override {
        if (event->type() == QEvent::MouseButtonPress || event->type() == QEvent::MouseButtonRelease) {
            QMouseEvent* mouseEvent = static_cast<QMouseEvent*>(event);
            if (mouseEvent->button() == Qt::LeftButton) {
                lua_getglobal(lua_state, handler_name.c_str());
                if (lua_isfunction(lua_state, -1)) {
                    if (event->type() == QEvent::MouseButtonPress) {
                        lua_pushstring(lua_state, "press");
                    } else {
                        lua_pushstring(lua_state, "release");
                    }
                    lua_pushinteger(lua_state, mouseEvent->pos().y());

                    int result = lua_pcall(lua_state, 2, 0, 0);
                    if (result != 0) {
                        qWarning() << "Error calling Lua click handler:" << lua_tostring(lua_state, -1);
                        lua_pop(lua_state, 1);
                    }
                } else {
                    qWarning() << "Lua click handler not found:" << handler_name.c_str();
                    lua_pop(lua_state, 1);
                }
                return false; // Let the event propagate for other handlers (e.g., splitter)
            }
        }
        return QObject::eventFilter(obj, event);
    }

private:
    std::string handler_name;
    lua_State* lua_state;
};

// Event filter class to maintain bottom-anchored scrolling
class BottomAnchorFilter : public QObject
{
public:
    BottomAnchorFilter(QScrollArea* sa) : QObject(sa), scrollArea(sa), distanceFromBottom(0) {}

protected:
    bool eventFilter(QObject* obj, QEvent* event) override
    {
        if (scrollArea && scrollArea->widget()) {
            QScrollBar* vbar = scrollArea->verticalScrollBar();
            if (vbar) {
                if (event->type() == QEvent::Resize) {
                    int oldMax = vbar->maximum();
                    int oldValue = vbar->value();
                    distanceFromBottom = oldMax - oldValue;

                    QTimer::singleShot(0, [this, vbar]() {
                        int newMax = vbar->maximum();
                        int newValue = newMax - distanceFromBottom;
                        vbar->setValue(qMax(0, newValue));
                    });
                } else if (event->type() == QEvent::Wheel || event->type() == QEvent::MouseButtonPress) {
                    QTimer::singleShot(0, [this, vbar]() {
                        distanceFromBottom = vbar->maximum() - vbar->value();
                    });
                }
            }
        }
        return QObject::eventFilter(obj, event);
    }

private:
    QScrollArea* scrollArea;
    int distanceFromBottom;
};

// ============================================================================
// Signal Binding Functions
// ============================================================================

int lua_set_button_click_handler(lua_State* L) {
    QAbstractButton* button = get_widget<QAbstractButton>(L, 1);
    const char* handler_name = lua_tostring(L, 2);
    if (!button || !handler_name) return 0;

    std::string handler_str(handler_name);
    QObject::connect(button, &QAbstractButton::clicked, [L, handler_str]() {
        lua_getglobal(L, handler_str.c_str());
        if (lua_isfunction(L, -1)) {
            if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
                qWarning() << "Error calling Lua click handler:" << lua_tostring(L, -1);
                lua_pop(L, 1);
            }
        } else {
            lua_pop(L, 1);
        }
    });
    return 0;
}

int lua_set_widget_click_handler(lua_State* L) {
    QWidget* widget = static_cast<QWidget*>(lua_to_widget(L, 1));
    const char* handler_name = lua_tostring(L, 2);
    if (!widget || !handler_name) return 0;

    std::string handler_str(handler_name);
    ClickEventFilter* filter = new ClickEventFilter(handler_str, L, widget);
    widget->installEventFilter(filter);
    return 0;
}

int lua_set_context_menu_handler(lua_State* L) {
    QWidget* widget = static_cast<QWidget*>(lua_to_widget(L, 1));
    const char* handler_name = lua_tostring(L, 2);
    if (!widget || !handler_name) return 0;

    widget->setContextMenuPolicy(Qt::CustomContextMenu);
    std::string handler_str(handler_name);

    QObject::connect(widget, &QWidget::customContextMenuRequested,
        [widget, L, handler_str](const QPoint& pos) {
            lua_getglobal(L, handler_str.c_str());
            if (!lua_isfunction(L, -1)) { lua_pop(L, 1); return; }

            lua_newtable(L);
            lua_pushstring(L, "x"); lua_pushinteger(L, pos.x()); lua_settable(L, -3);
            lua_pushstring(L, "y"); lua_pushinteger(L, pos.y()); lua_settable(L, -3);
            QPoint global_pos = widget->mapToGlobal(pos);
            lua_pushstring(L, "global_x"); lua_pushinteger(L, global_pos.x()); lua_settable(L, -3);
            lua_pushstring(L, "global_y"); lua_pushinteger(L, global_pos.y()); lua_settable(L, -3);

            if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
                qWarning() << "Error calling Lua context menu handler:" << lua_tostring(L, -1);
                lua_pop(L, 1);
            }
        });
    return 0;
}

int lua_set_line_edit_text_changed_handler(lua_State* L) {
    QLineEdit* le = get_widget<QLineEdit>(L, 1);
    const char* handler_name = luaL_checkstring(L, 2);
    if (!le || !handler_name) return 0;

    std::string handler_str(handler_name);
    QObject::connect(le, &QLineEdit::textChanged, [L, handler_str](const QString& /*text*/) {
        lua_getglobal(L, handler_str.c_str());
        if (lua_isfunction(L, -1)) {
            if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
                qWarning() << "Error calling" << QString::fromStdString(handler_str) << ":" << lua_tostring(L, -1);
                lua_pop(L, 1);
            }
        } else {
            lua_pop(L, 1);
        }
    });
    return 0;
}

int lua_set_line_edit_editing_finished_handler(lua_State* L) {
    QLineEdit* le = get_widget<QLineEdit>(L, 1);
    const char* handler_name = luaL_checkstring(L, 2);
    if (!le || !handler_name) return 0;

    std::string handler_str(handler_name);
    QObject::connect(le, &QLineEdit::editingFinished, [L, handler_str]() {
        lua_getglobal(L, handler_str.c_str());
        if (lua_isfunction(L, -1)) {
            if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
                qWarning() << "Error calling" << QString::fromStdString(handler_str) << ":" << lua_tostring(L, -1);
                lua_pop(L, 1);
            }
        } else {
            lua_pop(L, 1);
        }
    });
    return 0;
}

// Global key handler
int lua_set_global_key_handler(lua_State* L) {
    QWidget* widget = static_cast<QWidget*>(lua_to_widget(L, 1)); // Passed but not used for filter installation
    const char* handler_name = luaL_checkstring(L, 2);
    if (!widget || !handler_name) return 0;

    GlobalKeyFilter* filter = new GlobalKeyFilter(L, handler_name);
    QCoreApplication::instance()->installEventFilter(filter);
    return 0;
}

// Focus handler
int lua_set_focus_handler(lua_State* L) {
    QWidget* widget = static_cast<QWidget*>(lua_to_widget(L, 1));
    const char* handler_name = luaL_checkstring(L, 2);
    if (!widget || !handler_name) return 0;

    std::string handler(handler_name);
    FocusEventFilter* filter = new FocusEventFilter(L, handler, widget);
    widget->installEventFilter(filter);
    widget->setFocusPolicy(Qt::StrongFocus); // Ensure widget can receive focus
    return 0;
}

// Splitter moved handler
int lua_set_splitter_moved_handler(lua_State* L) {
    QSplitter* splitter = get_widget<QSplitter>(L, 1);
    const char* handler_name = lua_tostring(L, 2);
    if (!splitter || !handler_name) return 0;

    std::string handler_str = std::string(handler_name);
    QObject::connect(splitter, &QSplitter::splitterMoved, [L, handler_str](int pos, int index) {
        lua_getglobal(L, handler_str.c_str());
        if (lua_isfunction(L, -1)) {
            lua_pushinteger(L, pos);
            lua_pushinteger(L, index);
            if (lua_pcall(L, 2, 0, 0) != 0) {
                qWarning() << "Error calling Lua splitter moved handler:" << lua_tostring(L, -1);
                lua_pop(L, 1);
            }
        } else {
            qWarning() << "Lua splitter moved handler not found:" << handler_str.c_str();
            lua_pop(L, 1);
        }
    });
    return 0;
}

// Timer functions
int lua_create_single_shot_timer(lua_State* L) {
    int interval_ms = luaL_checkint(L, 1);
    if (!lua_isfunction(L, 2)) {
        return luaL_error(L, "qt_create_single_shot_timer: second argument must be a function");
    }

    lua_pushvalue(L, 2);
    int callback_ref = luaL_ref(L, LUA_REGISTRYINDEX);

    QTimer* timer = new QTimer();
    timer->setSingleShot(true);

    QObject::connect(timer, &QTimer::timeout, [L, callback_ref, timer]() {
        lua_rawgeti(L, LUA_REGISTRYINDEX, callback_ref);
        if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
            qDebug() << "Error in timer callback:" << lua_tostring(L, -1);
            lua_pop(L, 1);
        }
        luaL_unref(L, LUA_REGISTRYINDEX, callback_ref);
        timer->deleteLater();
    });
    timer->start(interval_ms);
    lua_push_widget(L, timer);
    return 1;
}

// Scroll Area handlers
int lua_set_scroll_area_scroll_handler(lua_State* L) {
    QScrollArea* sa = get_widget<QScrollArea>(L, 1);
    const char* handler_name = luaL_checkstring(L, 2);
    if (!sa || !handler_name) return 0;

    std::string handler_str(handler_name);
    QScrollBar* vScrollBar = sa->verticalScrollBar();
    if (vScrollBar) {
        QObject::connect(vScrollBar, &QScrollBar::valueChanged, [L, handler_str](int value) {
            lua_getglobal(L, handler_str.c_str());
            if (lua_isfunction(L, -1)) {
                lua_pushinteger(L, value);
                if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
                    qWarning() << "Error calling" << QString::fromStdString(handler_str) << ":" << lua_tostring(L, -1);
                    lua_pop(L, 1);
                }
            } else {
                lua_pop(L, 1);
            }
        });
    }
    return 0;
}

int lua_set_scroll_area_anchor_bottom(lua_State* L) {
    QScrollArea* sa = get_widget<QScrollArea>(L, 1);
    bool enable = lua_toboolean(L, 2);
    if (!sa) return 0;

    if (enable) {
        BottomAnchorFilter* filter = new BottomAnchorFilter(sa);
        sa->viewport()->installEventFilter(filter);
        QScrollBar* vbar = sa->verticalScrollBar();
        if (vbar) {
            vbar->setValue(vbar->maximum());
        }
    }
    return 0;
}

// Event filter for window geometry changes (resize and move)
class GeometryChangeFilter : public QObject
{
public:
    GeometryChangeFilter(lua_State* L_ptr, const std::string& handler, QWidget* widget)
        : QObject(widget), lua_state(L_ptr), handler_name(handler) {}

protected:
    bool eventFilter(QObject* obj, QEvent* event) override {
        if ((event->type() == QEvent::Resize || event->type() == QEvent::Move) && lua_state) {
            lua_getglobal(lua_state, handler_name.c_str());
            if (lua_isfunction(lua_state, -1)) {
                if (lua_pcall(lua_state, 0, 0, 0) != LUA_OK) {
                    qWarning() << "Error in geometry change handler:" << lua_tostring(lua_state, -1);
                    lua_pop(lua_state, 1);
                }
            } else {
                lua_pop(lua_state, 1);
            }
        }
        return QObject::eventFilter(obj, event);
    }

private:
    lua_State* lua_state;
    std::string handler_name;
};

// Window geometry change handler - fires on resize or move
int lua_set_geometry_change_handler(lua_State* L) {
    QWidget* widget = static_cast<QWidget*>(lua_to_widget(L, 1));
    const char* handler_name = luaL_checkstring(L, 2);
    if (!widget || !handler_name) return 0;

    std::string handler(handler_name);
    GeometryChangeFilter* filter = new GeometryChangeFilter(L, handler, widget);
    widget->installEventFilter(filter);
    return 0;
}
