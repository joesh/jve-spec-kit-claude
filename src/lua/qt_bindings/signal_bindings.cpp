#include "binding_macros.h"
#include "../../jve_log.h"
#include "../../assert_handler.h"
#include <QAbstractButton>
#include <QByteArray>
#include <QCoreApplication>
#include <QContextMenuEvent>
#include <QDrag>
#include <QDragEnterEvent>
#include <QDragMoveEvent>
#include <QDropEvent>
#include <QLineEdit>
#include <QKeyEvent>
#include <QMimeData>
#include <QMouseEvent>
#include <QScrollArea>
#include <QScrollBar>
#include <QSplitter>
#include <QSplitterHandle>
#include <QTimer>
#include <QApplication> // For QApplication::focusWidget()
#include <QComboBox>    // For PanelFocusTrap Return on combo
#include <QKeySequence> // For QKeySequence::StandardKey text-editing classification
#include <QMap>         // For g_panel_traps
#include <QMetaObject>  // For metaObject()->className()
#include <QPushButton>  // For PanelFocusTrap (qobject_cast)

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

// Classify a key event as "text-editing" per Qt's canonical standard-key table.
// A text widget that has focus must be allowed to consume these keys; they
// must NEVER dispatch as application shortcuts. Examples: bare letters (typing),
// Shift+letter (typing capitals), arrow keys (caret movement), Shift+arrow
// (selection extension), Cmd+A (SelectAll), Cmd+C/V/X/Z/Shift+Cmd+Z (macOS
// clipboard+undo), Delete/Backspace/word-delete variants.
//
// Non-text-editing keys — Cmd+S (Save), Cmd+F (Find), F-keys, bare extended
// keys like Escape — fall through to application shortcut dispatch.
static bool is_text_editing_key(QKeyEvent* keyEvent)
{
    if (!keyEvent) return false;

    const int key = keyEvent->key();
    const Qt::KeyboardModifiers mods = keyEvent->modifiers();

    // Pure modifier keypresses never count.
    if (key == Qt::Key_Control || key == Qt::Key_Shift ||
        key == Qt::Key_Alt     || key == Qt::Key_Meta) {
        return false;
    }

    // Bare typing: any printable key (Space through the pre-extended range)
    // with no Ctrl/Cmd/Alt modifier. Shift alone counts as bare (capital
    // letters, shifted punctuation).
    const Qt::KeyboardModifiers nonShiftMods =
        mods & (Qt::ControlModifier | Qt::MetaModifier | Qt::AltModifier);
    if (nonShiftMods == Qt::NoModifier && key >= 0x20 && key < 0x01000000) {
        return true;
    }

    // Qt's canonical text-editing StandardKey bindings. matches() is
    // platform-correct (e.g. Cmd on macOS, Ctrl on others) and handles the
    // Shift-extension variants for caret-selection moves.
    static const QKeySequence::StandardKey editingKeys[] = {
        // Caret navigation
        QKeySequence::MoveToNextChar,
        QKeySequence::MoveToPreviousChar,
        QKeySequence::MoveToNextWord,
        QKeySequence::MoveToPreviousWord,
        QKeySequence::MoveToNextLine,
        QKeySequence::MoveToPreviousLine,
        QKeySequence::MoveToNextPage,
        QKeySequence::MoveToPreviousPage,
        QKeySequence::MoveToStartOfLine,
        QKeySequence::MoveToEndOfLine,
        QKeySequence::MoveToStartOfBlock,
        QKeySequence::MoveToEndOfBlock,
        QKeySequence::MoveToStartOfDocument,
        QKeySequence::MoveToEndOfDocument,
        // Selection-extension (Shift + navigation)
        QKeySequence::SelectNextChar,
        QKeySequence::SelectPreviousChar,
        QKeySequence::SelectNextWord,
        QKeySequence::SelectPreviousWord,
        QKeySequence::SelectNextLine,
        QKeySequence::SelectPreviousLine,
        QKeySequence::SelectNextPage,
        QKeySequence::SelectPreviousPage,
        QKeySequence::SelectStartOfLine,
        QKeySequence::SelectEndOfLine,
        QKeySequence::SelectStartOfBlock,
        QKeySequence::SelectEndOfBlock,
        QKeySequence::SelectStartOfDocument,
        QKeySequence::SelectEndOfDocument,
        QKeySequence::SelectAll,
        // Clipboard / history
        QKeySequence::Copy,
        QKeySequence::Cut,
        QKeySequence::Paste,
        QKeySequence::Undo,
        QKeySequence::Redo,
        // Deletion
        QKeySequence::Delete,
        QKeySequence::Backspace,
        QKeySequence::DeleteStartOfWord,
        QKeySequence::DeleteEndOfWord,
        QKeySequence::DeleteCompleteLine,
        // Line insertion (rich-text widgets)
        QKeySequence::InsertParagraphSeparator,
        QKeySequence::InsertLineSeparator,
    };
    for (QKeySequence::StandardKey sk : editingKeys) {
        if (keyEvent->matches(sk)) return true;
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
        // Modal-dialog isolation: when a modal widget owns focus, it must own
        // ALL key events. Skip the global filter entirely so Qt delivers the
        // event to the focused widget normally and our Lua dispatcher's
        // floating-window pass-through (which redirects to the focused panel)
        // doesn't fire. Without this, Delete/J/K/L/etc. leak into the timeline
        // while a modal dialog like the keyboard customization dialog is open.
        if (event->type() == QEvent::KeyPress
                || event->type() == QEvent::KeyRelease
                || event->type() == QEvent::ShortcutOverride) {
            QWidget* modal = QApplication::activeModalWidget();
            QWidget* focusW = QApplication::focusWidget();
            if (modal && focusW
                    && (focusW == modal || modal->isAncestorOf(focusW))) {
                return false;  // Qt delivers natively to the modal widget
            }
        }

        // ShortcutOverride: only claim residual keys that the Lua handler
        // still manages (arrow repeat, context gathering, escape cascade).
        // All other keys pass through to Qt's QShortcut resolution.
        if (event->type() == QEvent::ShortcutOverride) {
            QKeyEvent* keyEvent = static_cast<QKeyEvent*>(event);
            int k = keyEvent->key();
            auto mods = keyEvent->modifiers() & (Qt::ControlModifier | Qt::AltModifier | Qt::MetaModifier);

            // Always-residual keys (any modifier combo): arrows, Escape
            // Tab NOT claimed — Qt's native focusNextPrevChild handles Tab cycling.
            // Return NOT claimed — Qt's native default button / button click handles it.
            // F9/F10 NOT claimed — handled via TOML keymap / QShortcut.
            if (k == Qt::Key_Left || k == Qt::Key_Right ||
                k == Qt::Key_Escape) {
                event->accept();
                return true;
            }
            // Residual without Cmd/Ctrl/Alt: Comma, Period, E.
            // Shift+Comma/Period = 5-frame nudge (still residual).
            // Cmd+Comma, Cmd+E etc. → let QShortcut resolve.
            if (mods == Qt::NoModifier &&
                (k == Qt::Key_Comma || k == Qt::Key_Period || k == Qt::Key_E)) {
                event->accept();
                return true;
            }
            // Text-input priority: when focus is on a text-editing widget and
            // the key is a canonical text-editing key (typing, caret nav,
            // selection, clipboard, undo/redo, delete), claim ShortcutOverride
            // so QShortcut dispatch aborts. The widget's keyPressEvent will
            // consume the key normally. One rule for main-window and floating-
            // window text input — replaces the former 5-key residual whitelist.
            QWidget* focusWidget = QApplication::focusWidget();
            if (widget_accepts_text_input(focusWidget) &&
                is_text_editing_key(keyEvent)) {
                event->accept();
                return true;
            }

            // When focus is outside the main window (e.g. floating tool panels
            // like History), QShortcuts scoped to panel containers won't match.
            // Claim all keys here so they route through the Lua handler, which
            // falls back to TOML registry lookup (globals-only via FLOATING_CONTEXT).
            QWidget* mainWin = SimpleLuaEngine::s_lastCreatedMainWindow;
            if (focusWidget && mainWin
                && focusWidget != mainWin
                && !mainWin->isAncestorOf(focusWidget)) {
                event->accept();
                return true;
            }

            // Let Qt resolve QShortcuts for everything else
            return false;
        }
        if (event->type() == QEvent::KeyPress && lua_state) {
            QKeyEvent* keyEvent = static_cast<QKeyEvent*>(event);

            int k = keyEvent->key();

            // Skip standalone modifier keys — they don't map to commands
            if (k == Qt::Key_Control || k == Qt::Key_Shift ||
                k == Qt::Key_Alt || k == Qt::Key_Meta) {
                return QObject::eventFilter(obj, event);
            }

            // Return/Enter: let Qt handle natively (default button / widget keyPressEvent).
            if (k == Qt::Key_Return || k == Qt::Key_Enter) {
                return QObject::eventFilter(obj, event);
            }

            // Tab/Backtab: forwarded to Lua unconditionally. Qt's native
            // focusNextPrevChild can't be reached from QShortcut dispatch, so
            // the Lua handler is the only place Tab can become a remappable
            // command (e.g. ToggleTimecodeFocus @timeline). Lua decides per
            // context: floating-window display-only redirects to the focused
            // main-window panel; floating text input (find_dialog) returns
            // false to let Qt cycle the dialog's own fields; main window
            // dispatches via the TOML registry, falling back to false (Qt
            // native cycling) when nothing is bound.

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

                lua_pushstring(lua_state, "is_auto_repeat");
                lua_pushboolean(lua_state, keyEvent->isAutoRepeat());
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

                // Qt-canonical classification of the key as a text-editing
                // operation (typing, caret nav, selection, clipboard, delete,
                // undo/redo). Lua's text-input guard uses this to decide
                // whether to defer to the focused widget.
                lua_pushstring(lua_state, "is_text_editing_key");
                lua_pushboolean(lua_state, is_text_editing_key(keyEvent));
                lua_settable(lua_state, -3);

                // Tell Lua whether focus is outside the main window.
                // When true, QShortcuts can't resolve — Lua must fall back
                // to TOML registry lookup.
                QWidget* mainWin = SimpleLuaEngine::s_lastCreatedMainWindow;
                bool outside = focus_widget && mainWin
                    && focus_widget != mainWin
                    && !mainWin->isAncestorOf(focus_widget);
                lua_pushstring(lua_state, "focus_outside_main_window");
                lua_pushboolean(lua_state, outside);
                lua_settable(lua_state, -3);

                if (lua_pcall(lua_state, 1, 1, 0) == LUA_OK) {
                    bool handled = lua_toboolean(lua_state, -1);
                    lua_pop(lua_state, 1);
                    if (handled) {
                        return true;  // Event consumed
                    }
                } else {
                    jve_handle_lua_callback_error(lua_state, "signal.global_key_press");
                }
            } else {
                jve_discard_non_function_handler(lua_state, handler_name.c_str(),
                    "signal.global_key_press");
            }
        }
        // Handle key release for K held state (JKL shuttle)
        else if (event->type() == QEvent::KeyRelease && lua_state) {
            QKeyEvent* keyEvent = static_cast<QKeyEvent*>(event);

            lua_getglobal(lua_state, "global_key_release_handler");
            if (lua_isfunction(lua_state, -1)) {
                lua_newtable(lua_state);

                lua_pushstring(lua_state, "key");
                lua_pushinteger(lua_state, keyEvent->key());
                lua_settable(lua_state, -3);

                lua_pushstring(lua_state, "is_auto_repeat");
                lua_pushboolean(lua_state, keyEvent->isAutoRepeat());
                lua_settable(lua_state, -3);

                if (lua_pcall(lua_state, 1, 1, 0) != LUA_OK) {
                    jve_handle_lua_callback_error(lua_state, "signal.global_key_release");
                } else {
                    lua_pop(lua_state, 1);  // Pop return value
                }
            } else {
                jve_discard_non_function_handler(lua_state, "global_key_release_handler",
                    "signal.global_key_release");
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
                    jve_handle_lua_callback_error(lua_state, "signal.focus_change");
                }
            } else {
                jve_discard_non_function_handler(lua_state, handler_name.c_str(),
                    "signal.focus_change");
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

                    if (lua_pcall(lua_state, 2, 0, 0) != LUA_OK) {
                        jve_handle_lua_callback_error(lua_state, "signal.panel_click");
                    }
                } else {
                    jve_discard_non_function_handler(lua_state, handler_name.c_str(),
                        "signal.panel_click");
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

// Drag event filter: detects left-button drag gestures on a widget.
// Fires the Lua handler as handler(event_type, global_x, global_y, modifiers)
// where event_type is "start", "move", or "end" and modifiers is an integer
// (Qt::KeyboardModifiers bitmask: Alt=0x08000000, Shift=0x02000000, Ctrl=0x04000000).
// "start" fires once when the drag threshold is exceeded.
// "move" fires on every subsequent mouse-move while dragging.
// "end" fires on mouse-release (only if a drag was active).
// Click (press+release without crossing threshold) fires nothing.
static constexpr int DRAG_THRESHOLD_PX = 5;

class DragMouseEventFilter : public QObject {
public:
    DragMouseEventFilter(const std::string& handler, lua_State* L_ptr, QObject* parent = nullptr)
        : QObject(parent), handler_name(handler), lua_state(L_ptr),
          dragging(false), press_x(0), press_y(0) {}

protected:
    bool eventFilter(QObject* obj, QEvent* event) override {
        if (event->type() == QEvent::MouseButtonPress) {
            QMouseEvent* me = static_cast<QMouseEvent*>(event);
            if (me->button() == Qt::LeftButton) {
                dragging = false;
                QPoint gp = me->globalPosition().toPoint();
                press_x = gp.x();
                press_y = gp.y();
                return false;
            }
        } else if (event->type() == QEvent::MouseMove) {
            QMouseEvent* me = static_cast<QMouseEvent*>(event);
            if (me->buttons() & Qt::LeftButton) {
                QPoint gp = me->globalPosition().toPoint();
                int dx = gp.x() - press_x;
                int dy = gp.y() - press_y;
                bool crossed = (dx*dx + dy*dy) >= (DRAG_THRESHOLD_PX * DRAG_THRESHOLD_PX);
                const char* ev_type = dragging ? "move" : (crossed ? "start" : nullptr);
                if (crossed) dragging = true;
                if (ev_type) {
                    fire(ev_type, gp.x(), gp.y(), static_cast<int>(me->modifiers()));
                }
                return false;
            }
        } else if (event->type() == QEvent::MouseButtonRelease) {
            QMouseEvent* me = static_cast<QMouseEvent*>(event);
            if (me->button() == Qt::LeftButton && dragging) {
                dragging = false;
                QPoint gp = me->globalPosition().toPoint();
                fire("end", gp.x(), gp.y(), static_cast<int>(me->modifiers()));
                return false;
            }
            dragging = false;
        }
        return QObject::eventFilter(obj, event);
    }

private:
    void fire(const char* ev_type, int gx, int gy, int mods) {
        lua_getglobal(lua_state, handler_name.c_str());
        if (!lua_isfunction(lua_state, -1)) {
            jve_discard_non_function_handler(lua_state, handler_name.c_str(), "signal.drag");
            return;
        }
        lua_pushstring(lua_state, ev_type);
        lua_pushinteger(lua_state, gx);
        lua_pushinteger(lua_state, gy);
        lua_pushinteger(lua_state, mods);
        if (lua_pcall(lua_state, 4, 0, 0) != LUA_OK) {
            jve_handle_lua_callback_error(lua_state, "signal.drag");
        }
    }

    std::string handler_name;
    lua_State* lua_state;
    bool dragging;
    int press_x, press_y;
};

// Event filter class to maintain bottom-anchored scrolling.
// Suspended during programmatic scroll restoration (sequence tab switch)
// to prevent async singleShot callbacks from clobbering the restored position.
class BottomAnchorFilter : public QObject
{
public:
    BottomAnchorFilter(QScrollArea* sa) : QObject(sa), scrollArea(sa), distanceFromBottom(0), suspended(false) {}

    void setSuspended(bool s) { suspended = s; }
    bool isSuspended() const { return suspended; }

protected:
    bool eventFilter(QObject* obj, QEvent* event) override
    {
        if (suspended || !scrollArea || !scrollArea->widget()) {
            return QObject::eventFilter(obj, event);
        }
        QScrollBar* vbar = scrollArea->verticalScrollBar();
        if (vbar) {
            if (event->type() == QEvent::Resize) {
                int oldMax = vbar->maximum();
                int oldValue = vbar->value();
                distanceFromBottom = oldMax - oldValue;

                QTimer::singleShot(0, [this, vbar]() {
                    if (suspended) return;
                    int newMax = vbar->maximum();
                    int newValue = newMax - distanceFromBottom;
                    vbar->setValue(qMax(0, newValue));
                });
            } else if (event->type() == QEvent::Wheel || event->type() == QEvent::MouseButtonPress) {
                QTimer::singleShot(0, [this, vbar]() {
                    if (suspended) return;
                    distanceFromBottom = vbar->maximum() - vbar->value();
                });
            }
        }
        return QObject::eventFilter(obj, event);
    }

private:
    QScrollArea* scrollArea;
    int distanceFromBottom;
    bool suspended;
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
                jve_handle_lua_callback_error(L, "signal.button_clicked");
            }
        } else {
            jve_discard_non_function_handler(L, handler_str.c_str(), "signal.button_clicked");
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

// Install a drag event filter on a widget.
// Lua: qt_set_widget_drag_handler(widget, handler_name)
// handler fires as: handler(event_type, global_x, global_y, modifiers)
int lua_set_widget_drag_handler(lua_State* L) {
    QWidget* widget = static_cast<QWidget*>(lua_to_widget(L, 1));
    const char* handler_name = lua_tostring(L, 2);
    if (!widget || !handler_name) {
        return luaL_error(L, "qt_set_widget_drag_handler: widget and handler_name required");
    }
    widget->setMouseTracking(true);
    DragMouseEventFilter* filter = new DragMouseEventFilter(handler_name, L, widget);
    widget->installEventFilter(filter);
    return 0;
}

// ============================================================================
// Row-level patch routing drag-and-drop (FR-010, FR-010a).
// Real Qt drag-and-drop (QDrag/QDropEvent), unlike the synthetic
// DragMouseEventFilter above. Drop targets can be ANY QWidget (a track
// header, a timeline-strip widget, etc.) — Qt handles cross-widget
// dispatch, cursor feedback, and event routing.
// ============================================================================

// Drag source: starts a QDrag with a mime payload provided by a Lua callback
// when the user drags past DRAG_THRESHOLD_PX. The payload is an opaque string
// (JSON in practice); Qt's mime system just carries bytes.
class DragSourceFilter : public QObject {
public:
    DragSourceFilter(const std::string& mime, const std::string& provider,
                     lua_State* L_ptr, QWidget* parent)
        : QObject(parent), source_widget(parent),
          mime_type(QString::fromStdString(mime)),
          payload_provider(provider), lua_state(L_ptr),
          press_x(0), press_y(0), pressed(false), dragging(false) {}

protected:
    bool eventFilter(QObject* obj, QEvent* event) override {
        // Re-entrancy guard: QDrag::exec runs a nested event loop and may
        // surface stray events through this filter during the drag. Ignore
        // them until exec returns.
        if (dragging) return QObject::eventFilter(obj, event);
        if (event->type() == QEvent::MouseButtonPress) {
            auto* me = static_cast<QMouseEvent*>(event);
            if (me->button() == Qt::LeftButton) {
                QPoint gp = me->globalPosition().toPoint();
                press_x = gp.x();
                press_y = gp.y();
                pressed = true;
            }
        } else if (event->type() == QEvent::MouseMove) {
            if (!pressed) return QObject::eventFilter(obj, event);
            auto* me = static_cast<QMouseEvent*>(event);
            if (!(me->buttons() & Qt::LeftButton)) {
                pressed = false;
                return QObject::eventFilter(obj, event);
            }
            QPoint gp = me->globalPosition().toPoint();
            int dx = gp.x() - press_x;
            int dy = gp.y() - press_y;
            if (dx*dx + dy*dy < DRAG_THRESHOLD_PX * DRAG_THRESHOLD_PX) {
                return QObject::eventFilter(obj, event);
            }
            pressed = false;
            startDrag();
            return true;
        } else if (event->type() == QEvent::MouseButtonRelease) {
            pressed = false;
        }
        return QObject::eventFilter(obj, event);
    }

private:
    void startDrag() {
        lua_getglobal(lua_state, payload_provider.c_str());
        if (!lua_isfunction(lua_state, -1)) {
            jve_discard_non_function_handler(lua_state,
                payload_provider.c_str(), "signal.drag_source");
            return;
        }
        if (lua_pcall(lua_state, 0, 1, 0) != LUA_OK) {
            jve_handle_lua_callback_error(lua_state, "signal.drag_source");
            return;
        }
        JVE_ASSERT(lua_isstring(lua_state, -1),
            "drag source payload provider must return a string");
        size_t len = 0;
        const char* str = lua_tolstring(lua_state, -1, &len);
        QByteArray payload(str, static_cast<int>(len));
        lua_pop(lua_state, 1);

        QMimeData* mime = new QMimeData;
        mime->setData(mime_type, payload);
        QDrag* drag = new QDrag(source_widget);
        drag->setMimeData(mime);
        dragging = true;
        drag->exec(Qt::CopyAction);
        dragging = false;
    }

    QWidget* source_widget;
    QString mime_type;
    std::string payload_provider;
    lua_State* lua_state;
    int press_x, press_y;
    bool pressed;
    bool dragging;
};

// Drop target: accepts drags whose mime payload matches `mime_type` and fires
// the Lua handler with (local_x, local_y, payload_string) on drop. Caller
// must install this on a widget that should receive drops (header, strip).
class DropTargetFilter : public QObject {
public:
    DropTargetFilter(const std::string& mime, const std::string& handler,
                     lua_State* L_ptr, QWidget* parent)
        : QObject(parent), mime_type(QString::fromStdString(mime)),
          handler_name(handler), lua_state(L_ptr) {}

    // Public so test code (qt_synthetic_drop) can invoke the same code
    // path the Qt event system would, bypassing QApplication::notify which
    // in Qt 6 short-circuits synthetic QDropEvent dispatch outside an
    // active QDrag operation. Production drops still flow through Qt's
    // notify pipeline (driven by QDrag::exec); this entry point exists
    // solely for in-process testing.
    bool eventFilter(QObject* obj, QEvent* event) override {
        const QEvent::Type t = event->type();
        if (t == QEvent::DragEnter) {
            auto* de = static_cast<QDragEnterEvent*>(event);
            if (de->mimeData()->hasFormat(mime_type)) {
                de->acceptProposedAction();
                return true;
            }
        } else if (t == QEvent::DragMove) {
            auto* de = static_cast<QDragMoveEvent*>(event);
            if (de->mimeData()->hasFormat(mime_type)) {
                de->acceptProposedAction();
                return true;
            }
        } else if (t == QEvent::Drop) {
            auto* de = static_cast<QDropEvent*>(event);
            if (de->mimeData()->hasFormat(mime_type)) {
                QByteArray payload = de->mimeData()->data(mime_type);
                QPoint pos = de->position().toPoint();
                fireDrop(pos.x(), pos.y(), payload);
                de->acceptProposedAction();
                return true;
            }
        }
        return QObject::eventFilter(obj, event);
    }

private:
    void fireDrop(int x, int y, const QByteArray& payload) {
        lua_getglobal(lua_state, handler_name.c_str());
        if (!lua_isfunction(lua_state, -1)) {
            jve_discard_non_function_handler(lua_state, handler_name.c_str(),
                "signal.drop_target");
            return;
        }
        lua_pushinteger(lua_state, x);
        lua_pushinteger(lua_state, y);
        lua_pushlstring(lua_state, payload.constData(), payload.size());
        if (lua_pcall(lua_state, 3, 0, 0) != LUA_OK) {
            jve_handle_lua_callback_error(lua_state, "signal.drop_target");
        }
    }

    QString mime_type;
    std::string handler_name;
    lua_State* lua_state;
};

// Install a drag-source event filter on a widget.
// Lua: qt_install_drag_source(widget, mime_type, payload_provider_handler_name)
// The provider handler is called as: handler() → returns payload string.
int lua_install_drag_source(lua_State* L) {
    QWidget* widget = static_cast<QWidget*>(lua_to_widget(L, 1));
    const char* mime = luaL_checkstring(L, 2);
    const char* provider = luaL_checkstring(L, 3);
    if (!widget) {
        return luaL_error(L, "qt_install_drag_source: widget required");
    }
    DragSourceFilter* filter = new DragSourceFilter(mime, provider, L, widget);
    widget->installEventFilter(filter);
    return 0;
}

// Install a drop-target event filter on a widget.
// Lua: qt_install_drop_target(widget, mime_type, handler_name)
// The handler is called as: handler(local_x, local_y, payload_string).
// Calls setAcceptDrops(true) on the widget so Qt routes drag events to it.
int lua_install_drop_target(lua_State* L) {
    QWidget* widget = static_cast<QWidget*>(lua_to_widget(L, 1));
    const char* mime = luaL_checkstring(L, 2);
    const char* handler = luaL_checkstring(L, 3);
    if (!widget) {
        return luaL_error(L, "qt_install_drop_target: widget required");
    }
    widget->setAcceptDrops(true);
    DropTargetFilter* filter = new DropTargetFilter(mime, handler, L, widget);
    widget->installEventFilter(filter);
    return 0;
}

// Test-only: invoke the installed DropTargetFilter directly with a
// freshly-constructed QDropEvent. Bypasses QApplication::notify, whose
// Qt 6 implementation short-circuits synthetic QDropEvent dispatch when
// no QDrag operation is active in the system event queue. Production
// drops still flow through Qt's notify pipeline, driven by QDrag::exec
// during a real user gesture — see DragSourceFilter::startDrag.
//
// This test entry point exercises the filter's mime parse + Lua dispatch
// code (the only production-relevant logic in the drop bridge) without
// depending on the OS event loop or real mouse input. It does NOT test
// Qt's own routing — that's Qt's responsibility, covered by manual UI
// verification of the real drag-drop gesture.
//
// Asserts on no installed filter so the test fails loudly rather than
// silently no-op'ing.
// Lua: qt_synthetic_drop(widget, mime_type, payload_str, local_x, local_y)
int lua_synthetic_drop(lua_State* L) {
    QWidget* widget = static_cast<QWidget*>(lua_to_widget(L, 1));
    const char* mime = luaL_checkstring(L, 2);
    size_t plen = 0;
    const char* pstr = luaL_checklstring(L, 3, &plen);
    int x = static_cast<int>(luaL_checkinteger(L, 4));
    int y = static_cast<int>(luaL_checkinteger(L, 5));
    if (!widget) {
        return luaL_error(L, "qt_synthetic_drop: widget required");
    }
    // The filter is parented to the widget at install time, so it lives
    // among the widget's direct children. Iterate via QObject::children()
    // (Qt's children() returns a const QObjectList& with no Q_OBJECT
    // requirement, unlike findChildren). dynamic_cast routes to QObject's
    // RTTI which works for any subclass with virtual methods.
    QMimeData mime_data;
    mime_data.setData(QString::fromUtf8(mime),
        QByteArray(pstr, static_cast<int>(plen)));
    QPointF pos(x, y);
    QDropEvent drop(pos, Qt::CopyAction, &mime_data, Qt::NoButton,
        Qt::NoModifier, QEvent::Drop);
    int invoked = 0;
    for (QObject* child : widget->children()) {
        DropTargetFilter* f = dynamic_cast<DropTargetFilter*>(child);
        if (f) {
            f->eventFilter(widget, &drop);
            ++invoked;
        }
    }
    if (invoked == 0) {
        return luaL_error(L,
            "qt_synthetic_drop: no DropTargetFilter installed on widget — "
            "call qt_install_drop_target first");
    }
    return 0;
}

// Return the QWidget at global screen position, or nil.
// Lua: qt_widget_at_global(x, y) → widget|nil
int lua_widget_at_global(lua_State* L) {
    int x = static_cast<int>(luaL_checkinteger(L, 1));
    int y = static_cast<int>(luaL_checkinteger(L, 2));
    QWidget* w = QApplication::widgetAt(x, y);
    lua_push_widget(L, w);
    return 1;
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

            {
    
                if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
                    jve_handle_lua_callback_error(L, "signal.context_menu");
                }
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
                jve_handle_lua_callback_error(L, "signal.line_edit_text_changed");
            }
        } else {
            jve_discard_non_function_handler(L, handler_str.c_str(), "signal.line_edit_text_changed");
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
                jve_handle_lua_callback_error(L, "signal.line_edit_editing_finished");
            }
        } else {
            jve_discard_non_function_handler(L, handler_str.c_str(), "signal.line_edit_editing_finished");
        }
    });
    return 0;
}

int lua_set_line_edit_return_pressed_handler(lua_State* L) {
    QLineEdit* le = get_widget<QLineEdit>(L, 1);
    const char* handler_name = luaL_checkstring(L, 2);
    if (!le || !handler_name) return 0;

    std::string handler_str(handler_name);
    QObject::connect(le, &QLineEdit::returnPressed, [L, handler_str]() {
        lua_getglobal(L, handler_str.c_str());
        if (lua_isfunction(L, -1)) {
            if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
                jve_handle_lua_callback_error(L, "signal.line_edit_return_pressed");
            }
        } else {
            jve_discard_non_function_handler(L, handler_str.c_str(), "signal.line_edit_return_pressed");
        }
    });
    return 0;
}

// ============================================================================
// Panel focus trap: Tab wraps within a panel, Return activates focused button.
// Installed on a panel's container widget via qt_install_panel_focus_trap().
// ============================================================================
class PanelFocusTrap : public QObject {
public:
    explicit PanelFocusTrap(QWidget* panel) : QObject(panel), m_panel(panel) {
        panel->installEventFilter(this);
    }

    void setDefaultButton(QAbstractButton* btn) { m_defaultButton = btn; }

protected:
    bool eventFilter(QObject* /*obj*/, QEvent* event) override {
        if (event->type() != QEvent::KeyPress) return false;

        auto* ke = static_cast<QKeyEvent*>(event);
        int key = ke->key();

        // Return/Enter: activate focused control or default button
        if (key == Qt::Key_Return || key == Qt::Key_Enter) {
            QWidget* focused = QApplication::focusWidget();
            // Focused button: activate it directly
            if (auto* btn = qobject_cast<QAbstractButton*>(focused)) {
                btn->animateClick();
                return true;
            }
            // QComboBox: show popup
            if (auto* combo = qobject_cast<QComboBox*>(focused)) {
                combo->showPopup();
                return true;
            }
            // QLineEdit or anything else: activate default button
            if (m_defaultButton && m_defaultButton->isVisible() && m_defaultButton->isEnabled()) {
                m_defaultButton->animateClick();
                return true;
            }
            return false;
        }

        // Tab/Shift+Tab: wrap focus within this panel
        if (key == Qt::Key_Tab || key == Qt::Key_Backtab) {
            bool forward = (key == Qt::Key_Tab);
            QList<QWidget*> focusable;
            for (auto* child : m_panel->findChildren<QWidget*>()) {
                if ((child->focusPolicy() & Qt::TabFocus) && child->isVisible() && child->isEnabled()) {
                    focusable.append(child);
                }
            }
            if (focusable.isEmpty()) return false;

            QWidget* current = QApplication::focusWidget();
            int idx = focusable.indexOf(current);
            // Use TabFocusReason so Qt shows focus highlights (ring/outline)
            if (idx < 0) { focusable.first()->setFocus(Qt::TabFocusReason); return true; }

            int next = forward ? (idx + 1) % focusable.size()
                               : (idx - 1 + focusable.size()) % focusable.size();
            focusable[next]->setFocus(forward ? Qt::TabFocusReason : Qt::BacktabFocusReason);
            return true;
        }

        return false;
    }

private:
    QWidget* m_panel;
    QAbstractButton* m_defaultButton = nullptr;
};

// Install panel focus trap on a container widget.
// Args: container_widget, [optional] default_button
// Returns the trap as light userdata so set_panel_default_button can find it.
static QMap<QWidget*, PanelFocusTrap*> g_panel_traps;

int lua_install_panel_focus_trap(lua_State* L) {
    QWidget* widget = get_widget<QWidget>(L, 1);
    if (widget) {
        auto* trap = new PanelFocusTrap(widget);
        g_panel_traps[widget] = trap;
        // Optional 2nd arg: default button
        if (lua_gettop(L) >= 2) {
            QWidget* btn_widget = get_widget<QWidget>(L, 2);
            if (auto* btn = qobject_cast<QAbstractButton*>(btn_widget)) {
                trap->setDefaultButton(btn);
            }
        }
    }
    return 0;
}

// Set/change the default button for a panel's focus trap.
// Args: container_widget, button_widget
int lua_set_panel_default_button(lua_State* L) {
    QWidget* widget = get_widget<QWidget>(L, 1);
    QWidget* btn_widget = get_widget<QWidget>(L, 2);
    if (widget && btn_widget) {
        auto it = g_panel_traps.find(widget);
        if (it != g_panel_traps.end()) {
            if (auto* btn = qobject_cast<QAbstractButton*>(btn_widget)) {
                it.value()->setDefaultButton(btn);
            }
        }
    }
    return 0;
}

// Cycle focus within a panel's focusable children (Tab wrapping).
// Args: container_widget, bool forward
int lua_cycle_panel_focus(lua_State* L) {
    QWidget* panel = get_widget<QWidget>(L, 1);
    bool forward = lua_toboolean(L, 2);
    if (!panel) return 0;

    QList<QWidget*> focusable;
    for (auto* child : panel->findChildren<QWidget*>()) {
        if ((child->focusPolicy() & Qt::TabFocus) && child->isVisible() && child->isEnabled()) {
            focusable.append(child);
        }
    }
    if (focusable.isEmpty()) return 0;

    QWidget* current = QApplication::focusWidget();
    int idx = focusable.indexOf(current);
    if (idx < 0) { focusable.first()->setFocus(Qt::TabFocusReason); return 0; }

    int next = forward ? (idx + 1) % focusable.size()
                       : (idx - 1 + focusable.size()) % focusable.size();
    focusable[next]->setFocus(forward ? Qt::TabFocusReason : Qt::BacktabFocusReason);
    return 0;
}

// Panel focus filter: installed on QApplication, catches MouseButtonPress,
// walks up widget parent chain to find a registered panel container, calls
// Lua handler with the panel widget. One filter for all panels.
class PanelFocusFilter : public QObject
{
public:
    PanelFocusFilter(lua_State* L_ptr, const std::string& handler)
        : QObject(QCoreApplication::instance()), lua_state(L_ptr), handler_name(handler) {}

    void add_panel_widget(QWidget* w, const std::string& panel_id) {
        if (w) {
            panel_widgets.push_back(w);
            panel_ids.push_back(panel_id);
        }
    }

protected:
    bool eventFilter(QObject* obj, QEvent* event) override {
        if (event->type() != QEvent::MouseButtonPress || !lua_state)
            return QObject::eventFilter(obj, event);

        QWidget* clicked = qobject_cast<QWidget*>(obj);
        if (!clicked) return QObject::eventFilter(obj, event);

        // Walk up parent chain to find a registered panel container
        QWidget* w = clicked;
        while (w) {
            for (size_t i = 0; i < panel_widgets.size(); ++i) {
                if (w == panel_widgets[i]) {
                    lua_getglobal(lua_state, handler_name.c_str());
                    if (lua_isfunction(lua_state, -1)) {
                        lua_pushstring(lua_state, panel_ids[i].c_str());
                        if (lua_pcall(lua_state, 1, 0, 0) != LUA_OK) {
                            jve_handle_lua_callback_error(lua_state, "signal.panel_focus_trap_click");
                        }
                    } else {
                        jve_discard_non_function_handler(lua_state, handler_name.c_str(),
                            "signal.panel_focus_trap_click");
                    }
                    return QObject::eventFilter(obj, event);
                }
            }
            w = w->parentWidget();
        }
        return QObject::eventFilter(obj, event);
    }

private:
    lua_State* lua_state;
    std::string handler_name;
    std::vector<QWidget*> panel_widgets;
    std::vector<std::string> panel_ids;
};

static PanelFocusFilter* g_panel_focus_filter = nullptr;

// Install global panel focus filter: qt_install_panel_focus_filter(handler_name)
// Call once at startup. handler_name receives the panel widget on click.
int lua_install_panel_focus_filter(lua_State* L) {
    const char* handler_name = luaL_checkstring(L, 1);
    if (!handler_name) return 0;

    g_panel_focus_filter = new PanelFocusFilter(L, handler_name);
    QCoreApplication::instance()->installEventFilter(g_panel_focus_filter);
    return 0;
}

// Register a panel widget with the global focus filter: qt_register_panel_focus_widget(widget, panel_id)
int lua_register_panel_focus_widget(lua_State* L) {
    QWidget* widget = static_cast<QWidget*>(lua_to_widget(L, 1));
    const char* panel_id = luaL_checkstring(L, 2);
    if (!widget || !panel_id || !g_panel_focus_filter) return 0;
    g_panel_focus_filter->add_panel_widget(widget, panel_id);
    return 0;
}

// Returns true iff the widget with Qt keyboard focus is outside the main
// window's subtree (e.g., a floating tool window). Same predicate used by
// the global key dispatcher — exposed to Lua for the click-to-focus logic
// that must distinguish within-main-window clicks from cross-window clicks.
int lua_focus_outside_main_window(lua_State* L) {
    QWidget* focus_widget = QApplication::focusWidget();
    QWidget* mainWin = SimpleLuaEngine::s_lastCreatedMainWindow;
    bool outside = focus_widget && mainWin
        && focus_widget != mainWin
        && !mainWin->isAncestorOf(focus_widget);
    lua_pushboolean(L, outside);
    return 1;
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

            if (lua_pcall(L, 2, 0, 0) != LUA_OK) {
                jve_handle_lua_callback_error(L, "signal.splitter_moved");
            }
        } else {
            jve_discard_non_function_handler(L, handler_str.c_str(), "signal.splitter_moved");
        }
    });
    return 0;
}

// Scroll area vertical scroll changed handler
int lua_set_scroll_area_v_scroll_handler(lua_State* L) {
    QScrollArea* sa = get_widget<QScrollArea>(L, 1);
    const char* handler_name = lua_tostring(L, 2);
    if (!sa || !handler_name) return 0;

    QScrollBar* sb = sa->verticalScrollBar();
    if (!sb) return 0;

    std::string handler_str = std::string(handler_name);
    QObject::connect(sb, &QScrollBar::valueChanged, [L, handler_str](int value) {
        lua_getglobal(L, handler_str.c_str());
        if (lua_isfunction(L, -1)) {
            lua_pushinteger(L, value);
            if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
                jve_handle_lua_callback_error(L, "signal.scroll_area_vscroll");
            }
        } else {
            jve_discard_non_function_handler(L, handler_str.c_str(), "signal.scroll_area_vscroll");
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
            jve_handle_lua_callback_error(L, "signal.single_shot_timer");
        }
        // Single-shot: always release the callback ref and schedule the timer
        // for deletion. Drain does not unwind, so this runs on both success
        // and error paths.
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
                    jve_handle_lua_callback_error(L, "signal.scroll_area_scroll_v");
                }
            } else {
                jve_discard_non_function_handler(L, handler_str.c_str(), "signal.scroll_area_scroll_v");
            }
        });
    }
    return 0;
}

int lua_set_scroll_area_h_scroll_handler(lua_State* L) {
    QScrollArea* sa = get_widget<QScrollArea>(L, 1);
    const char* handler_name = luaL_checkstring(L, 2);
    if (!sa || !handler_name) return 0;

    std::string handler_str(handler_name);
    QScrollBar* hScrollBar = sa->horizontalScrollBar();
    if (hScrollBar) {
        QObject::connect(hScrollBar, &QScrollBar::valueChanged, [L, handler_str](int value) {
            lua_getglobal(L, handler_str.c_str());
            if (lua_isfunction(L, -1)) {
                lua_pushinteger(L, value);
    
                if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
                    jve_handle_lua_callback_error(L, "signal.scroll_area_scroll_h");
                }
            } else {
                jve_discard_non_function_handler(L, handler_str.c_str(), "signal.scroll_area_scroll_h");
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

int lua_suspend_scroll_area_anchor(lua_State* L) {
    QScrollArea* sa = get_widget<QScrollArea>(L, 1);
    bool suspend = lua_toboolean(L, 2);
    if (!sa || !sa->viewport()) return 0;

    // Find the BottomAnchorFilter installed on this scroll area's viewport
    for (QObject* child : sa->viewport()->children()) {
        BottomAnchorFilter* filter = dynamic_cast<BottomAnchorFilter*>(child);
        if (filter) {
            filter->setSuspended(suspend);
            break;
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
                    jve_handle_lua_callback_error(lua_state, "signal.geometry_change");
                }
            } else {
                jve_discard_non_function_handler(lua_state, handler_name.c_str(),
                    "signal.geometry_change");
            }
        }
        return QObject::eventFilter(obj, event);
    }

private:
    lua_State* lua_state;
    std::string handler_name;
};

// Window close handler - fires on QEvent::Close (X button, Cmd+W, etc.)
class CloseEventFilter : public QObject
{
public:
    CloseEventFilter(lua_State* L_ptr, const std::string& handler, QWidget* widget)
        : QObject(widget), lua_state(L_ptr), handler_name(handler) {}

protected:
    bool eventFilter(QObject* obj, QEvent* event) override {
        if (event->type() == QEvent::Close && lua_state) {
            lua_getglobal(lua_state, handler_name.c_str());
            if (lua_isfunction(lua_state, -1)) {
                if (lua_pcall(lua_state, 0, 0, 0) != LUA_OK) {
                    jve_handle_lua_callback_error(lua_state, "signal.close_event");
                }
            } else {
                jve_discard_non_function_handler(lua_state, handler_name.c_str(),
                    "signal.close_event");
            }
        }
        return QObject::eventFilter(obj, event);
    }

private:
    lua_State* lua_state;
    std::string handler_name;
};

int lua_set_close_handler(lua_State* L) {
    QWidget* widget = static_cast<QWidget*>(lua_to_widget(L, 1));
    const char* handler_name = luaL_checkstring(L, 2);
    if (!widget || !handler_name) return 0;

    CloseEventFilter* filter = new CloseEventFilter(L, handler_name, widget);
    widget->installEventFilter(filter);
    return 0;
}

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
