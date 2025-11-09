#include "qt_bindings.h"
#include "simple_lua_engine.h"
#include <QWidget>
#include <QApplication>
#include <QMainWindow>
#include <QLabel>
#include <QLineEdit>
#include <QCheckBox>
#include <QComboBox>
#include <QSlider>
#include <QTreeWidget>
#include <QTreeWidgetItem>
#include <QAbstractItemView>
#include <QItemSelectionModel>
#include <QDropEvent>
#include <QMimeData>
#include <QHBoxLayout>
#include <QVBoxLayout>
#include <QSplitter>
#include <QScrollArea>
#include <QScrollBar>
#include <QPushButton>
#include <QMessageBox>
#include <QRubberBand>
#include <QSizePolicy>
#include <QEvent>
#include <QMouseEvent>
#include <QKeyEvent>
#include <QSet>
#include <QMap>
#include <QTimer>
#include <QDebug>
#include <QStyle>
#include <QIcon>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QJsonValue>
#include <QVariant>
#include <QByteArray>
#include <QMenuBar>
#include <QMenu>
#include <QAction>
#include <QFileDialog>
#include <QString>
#include <QAbstractItemDelegate>
#include <QModelIndex>
#include <string>

#ifdef Q_OS_MAC
#include <objc/objc-runtime.h>
static id qt_nsstring_from_utf8(const char* utf8)
{
    if (!utf8) {
        return nil;
    }
    Class NSStringClass = objc_getClass("NSString");
    SEL stringWithUTF8StringSel = sel_getUid("stringWithUTF8String:");
    return ((id (*)(Class, SEL, const char*))objc_msgSend)(NSStringClass, stringWithUTF8StringSel, utf8);
}
#endif

// Include existing UI components
#include "ui/timeline/scriptable_timeline.h"  // Performance-critical timeline rendering

// Widget userdata metatable name
static const char* WIDGET_METATABLE = "JVE.Widget";

// Forward declarations
int lua_create_scriptable_timeline(lua_State* L);
int lua_set_line_edit_text_changed_handler(lua_State* L);
int lua_set_line_edit_editing_finished_handler(lua_State* L);
int lua_update_widget(lua_State* L);
int lua_get_widget_size(lua_State* L);
int lua_get_geometry(lua_State* L);
int lua_set_minimum_width(lua_State* L);
int lua_set_maximum_width(lua_State* L);
int lua_set_minimum_height(lua_State* L);
int lua_set_maximum_height(lua_State* L);
int lua_get_splitter_sizes(lua_State* L);
int lua_set_splitter_moved_handler(lua_State* L);
int lua_set_scroll_area_widget_resizable(lua_State* L);
int lua_set_scroll_area_h_scrollbar_policy(lua_State* L);
int lua_set_scroll_area_v_scrollbar_policy(lua_State* L);
int lua_hide_splitter_handle(lua_State* L);
int lua_set_splitter_stretch_factor(lua_State* L);
int lua_get_splitter_handle(lua_State* L);
int lua_create_rubber_band(lua_State* L);
int lua_set_rubber_band_geometry(lua_State* L);
int lua_grab_mouse(lua_State* L);
int lua_release_mouse(lua_State* L);
int lua_map_point_from(lua_State* L);
int lua_map_rect_from(lua_State* L);
int lua_map_to_global(lua_State* L);
int lua_map_from_global(lua_State* L);
int lua_set_widget_stylesheet(lua_State* L);
int lua_set_window_appearance(lua_State* L);
int lua_create_single_shot_timer(lua_State* L);
int lua_set_scroll_area_alignment(lua_State* L);
int lua_set_scroll_area_anchor_bottom(lua_State* L);
int lua_set_focus_policy(lua_State* L);
int lua_set_focus(lua_State* L);
int lua_set_global_key_handler(lua_State* L);
int lua_set_focus_handler(lua_State* L);
int lua_set_widget_cursor(lua_State* L);
int lua_set_tree_selection_mode(lua_State* L);
int lua_set_tree_item_editable(lua_State* L);
int lua_edit_tree_item(lua_State* L);
int lua_is_tree_item_expanded(lua_State* L);
int lua_set_tree_item_text(lua_State* L);
int lua_set_tree_item_changed_handler(lua_State* L);
int lua_set_tree_close_editor_handler(lua_State* L);
int lua_set_tree_drag_drop_mode(lua_State* L);
int lua_set_tree_drop_handler(lua_State* L);
int lua_set_tree_key_handler(lua_State* L);

// Helper function to convert Lua table to QJsonValue
static QJsonValue luaTableToJsonValue(lua_State* L, int index);
static lua_Integer makeTreeItemId(QTreeWidgetItem* item);

class LuaTreeWidget : public QTreeWidget {
public:
    explicit LuaTreeWidget(lua_State* state)
        : QTreeWidget(nullptr)
        , lua_state(state)
    {
        setRootIsDecorated(true);
    }

    void setDragDropEnabled(bool enabled) {
        setDragEnabled(enabled);
        setAcceptDrops(enabled);
        if (viewport()) {
            viewport()->setAcceptDrops(enabled);
        }
        setDropIndicatorShown(enabled);
    }

    void setDropHandler(const std::string& handler) {
        drop_handler = handler;
    }

    void setKeyHandler(const std::string& handler) {
        key_handler = handler;
    }

protected:
    void dropEvent(QDropEvent* event) override {
        bool handled = invokeDropHandler(event);
        if (handled) {
            event->setDropAction(Qt::MoveAction);
            event->accept();
            return;
        }
        QTreeWidget::dropEvent(event);
    }

    void keyPressEvent(QKeyEvent* event) override {
        if (invokeKeyHandler(event)) {
            event->accept();
            return;
        }
        QTreeWidget::keyPressEvent(event);
    }

private:
    bool invokeDropHandler(QDropEvent* event) {
        if (drop_handler.empty() || !lua_state) {
            return false;
        }

        lua_getglobal(lua_state, drop_handler.c_str());
        if (!lua_isfunction(lua_state, -1)) {
            lua_pop(lua_state, 1);
            return false;
        }

#if QT_VERSION >= QT_VERSION_CHECK(6, 0, 0)
        QPoint dropPos = event->position().toPoint();
#else
        QPoint dropPos = event->pos();
#endif
        QTreeWidgetItem* targetItem = itemAt(dropPos);

        lua_newtable(lua_state);

        lua_pushstring(lua_state, "target_id");
        if (targetItem) {
            lua_pushinteger(lua_state, makeTreeItemId(targetItem));
        } else {
            lua_pushnil(lua_state);
        }
        lua_settable(lua_state, -3);

        QString positionStr = "viewport";
        switch (dropIndicatorPosition()) {
            case QAbstractItemView::AboveItem:
                positionStr = "above";
                break;
            case QAbstractItemView::BelowItem:
                positionStr = "below";
                break;
            case QAbstractItemView::OnItem:
                positionStr = "into";
                break;
            case QAbstractItemView::OnViewport:
                positionStr = "viewport";
                break;
            default:
                positionStr = "viewport";
                break;
        }
        lua_pushstring(lua_state, "position");
        lua_pushstring(lua_state, positionStr.toUtf8().constData());
        lua_settable(lua_state, -3);

        QList<QTreeWidgetItem*> selected = selectedItems();
        lua_pushstring(lua_state, "sources");
        lua_newtable(lua_state);
        for (int i = 0; i < selected.size(); ++i) {
            lua_pushinteger(lua_state, makeTreeItemId(selected.at(i)));
            lua_rawseti(lua_state, -2, i + 1);
        }
        lua_settable(lua_state, -3);

        lua_pushstring(lua_state, "modifiers");
        lua_pushinteger(lua_state, static_cast<int>(event->modifiers()));
        lua_settable(lua_state, -3);

        if (lua_pcall(lua_state, 1, 1, 0) != LUA_OK) {
            qWarning() << "Error calling Lua tree drop handler:" << lua_tostring(lua_state, -1);
            lua_pop(lua_state, 1);
            return false;
        }

        bool handled = lua_toboolean(lua_state, -1);
        lua_pop(lua_state, 1);
        return handled;
    }

    bool invokeKeyHandler(QKeyEvent* event) {
        if (key_handler.empty() || !lua_state) {
            return false;
        }

        lua_getglobal(lua_state, key_handler.c_str());
        if (!lua_isfunction(lua_state, -1)) {
            lua_pop(lua_state, 1);
            return false;
        }

        lua_newtable(lua_state);
        lua_pushstring(lua_state, "key");
        lua_pushinteger(lua_state, event->key());
        lua_settable(lua_state, -3);

        lua_pushstring(lua_state, "modifiers");
        lua_pushinteger(lua_state, static_cast<int>(event->modifiers()));
        lua_settable(lua_state, -3);

        lua_pushstring(lua_state, "text");
        lua_pushstring(lua_state, event->text().toUtf8().constData());
        lua_settable(lua_state, -3);

        if (lua_pcall(lua_state, 1, 1, 0) != LUA_OK) {
            qWarning() << "Error calling Lua tree key handler:" << lua_tostring(lua_state, -1);
            lua_pop(lua_state, 1);
            return false;
        }

        bool handled = lua_toboolean(lua_state, -1);
        lua_pop(lua_state, 1);
        return handled;
    }

    lua_State* lua_state = nullptr;
    std::string drop_handler;
    std::string key_handler;
};

static QJsonValue luaValueToJsonValue(lua_State* L, int index) {
    int type = lua_type(L, index);

    switch (type) {
        case LUA_TNIL:
            return QJsonValue(QJsonValue::Null);
        case LUA_TBOOLEAN:
            return QJsonValue(lua_toboolean(L, index) != 0);
        case LUA_TNUMBER:
            return QJsonValue(lua_tonumber(L, index));
        case LUA_TSTRING:
            return QJsonValue(QString::fromUtf8(lua_tostring(L, index)));
        case LUA_TTABLE:
            return luaTableToJsonValue(L, index);
        default:
            return QJsonValue(QJsonValue::Null);
    }
}

static QJsonValue luaTableToJsonValue(lua_State* L, int index) {
    // Normalize index to absolute
    if (index < 0) {
        index = lua_gettop(L) + index + 1;
    }

    // Check if it's an array (sequential integer keys starting from 1)
    bool isArray = true;
    lua_pushnil(L);
    while (lua_next(L, index) != 0) {
        if (lua_type(L, -2) != LUA_TNUMBER) {
            isArray = false;
            lua_pop(L, 2);
            break;
        }
        lua_pop(L, 1);
    }

    if (isArray) {
        QJsonArray array;
        int len = lua_objlen(L, index);  // LuaJIT uses lua_objlen instead of lua_rawlen
        for (int i = 1; i <= len; i++) {
            lua_rawgeti(L, index, i);
            array.append(luaValueToJsonValue(L, -1));
            lua_pop(L, 1);
        }
        return array;
    } else {
        QJsonObject obj;
        lua_pushnil(L);
        while (lua_next(L, index) != 0) {
            const char* key = lua_tostring(L, -2);
            if (key) {
                obj[QString::fromUtf8(key)] = luaValueToJsonValue(L, -1);
            }
            lua_pop(L, 1);
        }
        return obj;
    }
}

// Helper function to push QJsonValue to Lua stack
static void pushJsonValueToLua(lua_State* L, const QJsonValue& value) {
    switch (value.type()) {
        case QJsonValue::Null:
        case QJsonValue::Undefined:
            lua_pushnil(L);
            break;
        case QJsonValue::Bool:
            lua_pushboolean(L, value.toBool());
            break;
        case QJsonValue::Double:
            lua_pushnumber(L, value.toDouble());
            break;
        case QJsonValue::String:
            lua_pushstring(L, value.toString().toUtf8().constData());
            break;
        case QJsonValue::Array: {
            QJsonArray arr = value.toArray();
            lua_newtable(L);
            for (int i = 0; i < arr.size(); i++) {
                pushJsonValueToLua(L, arr[i]);
                lua_rawseti(L, -2, i + 1);
            }
            break;
        }
        case QJsonValue::Object: {
            QJsonObject obj = value.toObject();
            lua_newtable(L);
            for (auto it = obj.constBegin(); it != obj.constEnd(); ++it) {
                lua_pushstring(L, it.key().toUtf8().constData());
                pushJsonValueToLua(L, it.value());
                lua_settable(L, -3);
            }
            break;
        }
    }
}

// json.encode(table) -> string
int lua_json_encode(lua_State* L) {
    if (lua_gettop(L) < 1) {
        return luaL_error(L, "json_encode requires 1 argument (table)");
    }

    if (!lua_istable(L, 1)) {
        return luaL_error(L, "json_encode argument must be a table");
    }

    QJsonValue jsonValue = luaTableToJsonValue(L, 1);
    QJsonDocument doc;

    if (jsonValue.isArray()) {
        doc.setArray(jsonValue.toArray());
    } else if (jsonValue.isObject()) {
        doc.setObject(jsonValue.toObject());
    } else {
        return luaL_error(L, "json_encode: table must convert to object or array");
    }

    QByteArray json = doc.toJson(QJsonDocument::Compact);
    lua_pushlstring(L, json.constData(), json.size());
    return 1;
}

// json.decode(string) -> table
int lua_json_decode(lua_State* L) {
    if (lua_gettop(L) < 1) {
        return luaL_error(L, "json_decode requires 1 argument (string)");
    }

    if (!lua_isstring(L, 1)) {
        return luaL_error(L, "json_decode argument must be a string");
    }

    size_t len;
    const char* jsonStr = lua_tolstring(L, 1, &len);
    QByteArray jsonData(jsonStr, len);

    QJsonParseError error;
    QJsonDocument doc = QJsonDocument::fromJson(jsonData, &error);

    if (error.error != QJsonParseError::NoError) {
        return luaL_error(L, "json_decode: parse error at offset %d: %s",
                         error.offset, error.errorString().toUtf8().constData());
    }

    if (doc.isArray()) {
        pushJsonValueToLua(L, doc.array());
    } else if (doc.isObject()) {
        pushJsonValueToLua(L, doc.object());
    } else {
        lua_pushnil(L);
    }

    return 1;
}

// Scroll position functions
int lua_get_scroll_position(lua_State* L) {
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);

    if (!widget) {
        qWarning() << "Invalid widget in lua_get_scroll_position";
        return 0;
    }

    QScrollArea* scrollArea = qobject_cast<QScrollArea*>(widget);
    if (!scrollArea) {
        qWarning() << "Widget is not a QScrollArea in lua_get_scroll_position";
        return 0;
    }

    int position = scrollArea->verticalScrollBar()->value();
    lua_pushinteger(L, position);
    return 1;
}

int lua_set_scroll_position(lua_State* L) {
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    int position = luaL_checkinteger(L, 2);

    if (!widget) {
        qWarning() << "Invalid widget in lua_set_scroll_position";
        return 0;
    }

    QScrollArea* scrollArea = qobject_cast<QScrollArea*>(widget);
    if (!scrollArea) {
        qWarning() << "Widget is not a QScrollArea in lua_set_scroll_position";
        return 0;
    }

    scrollArea->verticalScrollBar()->setValue(position);
    return 0;
}

int lua_set_scroll_area_scroll_handler(lua_State* L) {
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    const char* handler_name = luaL_checkstring(L, 2);

    if (!widget) {
        qWarning() << "Invalid widget in lua_set_scroll_area_scroll_handler";
        return 0;
    }

    QScrollArea* scrollArea = qobject_cast<QScrollArea*>(widget);
    if (!scrollArea) {
        qWarning() << "Widget is not a QScrollArea in lua_set_scroll_area_scroll_handler";
        return 0;
    }

    std::string handler_str(handler_name);
    QScrollBar* vScrollBar = scrollArea->verticalScrollBar();

    if (vScrollBar) {
        QObject::connect(vScrollBar, &QScrollBar::valueChanged, [L, handler_str](int value) {
            lua_getglobal(L, handler_str.c_str());
            if (lua_isfunction(L, -1)) {
                lua_pushinteger(L, value);
                if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
                    qWarning() << "Error calling" << QString::fromStdString(handler_str)
                              << ":" << lua_tostring(L, -1);
                    lua_pop(L, 1);
                }
            } else {
                lua_pop(L, 1);
            }
        });
    }

    return 0;
}

// ============================================================================
// Menu System Bindings
// ============================================================================

// Get menu bar from main window
int lua_get_menu_bar(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    QMainWindow* main_window = qobject_cast<QMainWindow*>(widget);

    if (!main_window) {
        return luaL_error(L, "GET_MENU_BAR: widget is not a QMainWindow");
    }

    QMenuBar* menu_bar = main_window->menuBar();
    lua_push_widget(L, menu_bar);
    return 1;
}

// Create menu (can be attached to menu bar or parent menu)
int lua_create_menu(lua_State* L)
{
    QWidget* parent = (QWidget*)lua_to_widget(L, 1);
    const char* title = luaL_checkstring(L, 2);

    QMenu* menu = nullptr;

    // Check if parent is QMenuBar, QMenu, or generic QWidget
    QMenuBar* menu_bar = qobject_cast<QMenuBar*>(parent);
    QMenu* parent_menu = qobject_cast<QMenu*>(parent);
    QWidget* widget_parent = qobject_cast<QWidget*>(parent);

    if (menu_bar) {
        menu = new QMenu(QString::fromUtf8(title), menu_bar);
    } else if (parent_menu) {
        menu = new QMenu(QString::fromUtf8(title), parent_menu);
    } else if (widget_parent) {
        menu = new QMenu(QString::fromUtf8(title), widget_parent);
    } else {
        return luaL_error(L, "CREATE_MENU: parent must be QMenuBar, QMenu, or QWidget");
    }

    lua_push_widget(L, menu);
    return 1;
}

// Add menu to menu bar
int lua_add_menu_to_bar(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    QWidget* menu_widget = (QWidget*)lua_to_widget(L, 2);

    QMenuBar* menu_bar = qobject_cast<QMenuBar*>(widget);
    QMenu* menu = qobject_cast<QMenu*>(menu_widget);

    if (!menu_bar) {
        return luaL_error(L, "ADD_MENU_TO_BAR: first argument must be QMenuBar");
    }

    if (!menu) {
        return luaL_error(L, "ADD_MENU_TO_BAR: second argument must be QMenu");
    }

    menu_bar->addMenu(menu);
    return 0;
}

// Add submenu to menu
int lua_add_submenu(lua_State* L)
{
    QWidget* parent_widget = (QWidget*)lua_to_widget(L, 1);
    QWidget* submenu_widget = (QWidget*)lua_to_widget(L, 2);

    QMenu* parent_menu = qobject_cast<QMenu*>(parent_widget);
    QMenu* submenu = qobject_cast<QMenu*>(submenu_widget);

    if (!parent_menu) {
        return luaL_error(L, "ADD_SUBMENU: first argument must be QMenu");
    }

    if (!submenu) {
        return luaL_error(L, "ADD_SUBMENU: second argument must be QMenu");
    }

    parent_menu->addMenu(submenu);
    return 0;
}

// Create menu action
int lua_create_menu_action(lua_State* L)
{
    QWidget* menu_widget = (QWidget*)lua_to_widget(L, 1);
    const char* text = luaL_checkstring(L, 2);
    const char* shortcut = luaL_optstring(L, 3, "");
    bool checkable = lua_toboolean(L, 4);

    QMenu* menu = qobject_cast<QMenu*>(menu_widget);

    if (!menu) {
        return luaL_error(L, "CREATE_MENU_ACTION: first argument must be QMenu");
    }

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
int lua_connect_menu_action(lua_State* L)
{
    QObject* obj = (QObject*)lua_to_widget(L, 1);

    if (!lua_isfunction(L, 2)) {
        return luaL_error(L, "CONNECT_MENU_ACTION: second argument must be a function");
    }

    QAction* action = qobject_cast<QAction*>(obj);

    if (!action) {
        return luaL_error(L, "CONNECT_MENU_ACTION: first argument must be QAction");
    }

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
int lua_add_menu_separator(lua_State* L)
{
    QWidget* menu_widget = (QWidget*)lua_to_widget(L, 1);

    QMenu* menu = qobject_cast<QMenu*>(menu_widget);

    if (!menu) {
        return luaL_error(L, "ADD_MENU_SEPARATOR: argument must be QMenu");
    }

    menu->addSeparator();
    return 0;
}

int lua_show_menu_popup(lua_State* L)
{
    QWidget* menu_widget = (QWidget*)lua_to_widget(L, 1);
    int global_x = luaL_checkint(L, 2);
    int global_y = luaL_checkint(L, 3);

    QMenu* menu = qobject_cast<QMenu*>(menu_widget);
    if (!menu) {
        return luaL_error(L, "SHOW_POPUP: argument must be QMenu");
    }

    QAction* triggered = menu->exec(QPoint(global_x, global_y));
    lua_pushboolean(L, triggered != nullptr);
    return 1;
}

// Set action enabled state
int lua_set_action_enabled(lua_State* L)
{
    QObject* obj = (QObject*)lua_to_widget(L, 1);
    bool enabled = lua_toboolean(L, 2);

    QAction* action = qobject_cast<QAction*>(obj);

    if (!action) {
        return luaL_error(L, "SET_ACTION_ENABLED: argument must be QAction");
    }

    action->setEnabled(enabled);
    return 0;
}

// Set action checked state
int lua_set_action_checked(lua_State* L)
{
    QObject* obj = (QObject*)lua_to_widget(L, 1);
    bool checked = lua_toboolean(L, 2);

    QAction* action = qobject_cast<QAction*>(obj);

    if (!action) {
        return luaL_error(L, "SET_ACTION_CHECKED: argument must be QAction");
    }

    action->setChecked(checked);
    return 0;
}

// ============================================================================
// File Dialog Bindings
// ============================================================================

// Show file open dialog
// Returns: selected file path (string) or nil if cancelled
int lua_file_dialog_open(lua_State* L)
{
    QWidget* parent = nullptr;
    const char* title = "Open File";
    const char* filter = "All Files (*)";
    const char* dir = "";

    // Optional arguments
    if (lua_gettop(L) >= 1 && !lua_isnil(L, 1)) {
        parent = (QWidget*)lua_to_widget(L, 1);
    }
    if (lua_gettop(L) >= 2 && lua_isstring(L, 2)) {
        title = lua_tostring(L, 2);
    }
    if (lua_gettop(L) >= 3 && lua_isstring(L, 3)) {
        filter = lua_tostring(L, 3);
    }
    if (lua_gettop(L) >= 4 && lua_isstring(L, 4)) {
        dir = lua_tostring(L, 4);
    }

    QString filename = QFileDialog::getOpenFileName(
        parent,
        QString::fromUtf8(title),
        QString::fromUtf8(dir),
        QString::fromUtf8(filter)
    );

    if (filename.isEmpty()) {
        lua_pushnil(L);
    } else {
        lua_pushstring(L, filename.toUtf8().constData());
    }

    return 1;
}

// Show multiple file open dialog
// Returns: array of selected file paths or nil if cancelled
int lua_file_dialog_open_multiple(lua_State* L)
{
    QWidget* parent = nullptr;
    const char* title = "Open Files";
    const char* filter = "All Files (*)";
    const char* dir = "";

    // Optional arguments
    if (lua_gettop(L) >= 1 && !lua_isnil(L, 1)) {
        parent = (QWidget*)lua_to_widget(L, 1);
    }
    if (lua_gettop(L) >= 2 && lua_isstring(L, 2)) {
        title = lua_tostring(L, 2);
    }
    if (lua_gettop(L) >= 3 && lua_isstring(L, 3)) {
        filter = lua_tostring(L, 3);
    }
    if (lua_gettop(L) >= 4 && lua_isstring(L, 4)) {
        dir = lua_tostring(L, 4);
    }

    QStringList filenames = QFileDialog::getOpenFileNames(
        parent,
        QString::fromUtf8(title),
        QString::fromUtf8(dir),
        QString::fromUtf8(filter)
    );

    if (filenames.isEmpty()) {
        lua_pushnil(L);
    } else {
        lua_newtable(L);
        for (int i = 0; i < filenames.size(); ++i) {
            lua_pushstring(L, filenames[i].toUtf8().constData());
            lua_rawseti(L, -2, i + 1);
        }
    }

    return 1;
}

// Show a confirmation dialog with optional customisation
// Accepts either:
//   - table with fields:
//       parent (widget), title, message, informative_text, detail_text,
//       confirm_text, cancel_text, icon ("information","warning","critical","question"),
//       default_button ("confirm"|"cancel")
//   - positional arguments (message [, confirm_text [, cancel_text]])
// Returns: boolean accepted, string result ("confirm"|"cancel")
int lua_show_confirm_dialog(lua_State* L)
{
    QWidget* parent = nullptr;
    QString title = QStringLiteral("Confirm");
    QString message = QStringLiteral("Are you sure?");
    QString informativeText;
    QString detailText;
    QString confirmText = QStringLiteral("OK");
    QString cancelText = QStringLiteral("Cancel");
    QString defaultButton = QStringLiteral("confirm");
    QMessageBox::Icon icon = QMessageBox::Question;

    int argCount = lua_gettop(L);

    if (argCount >= 1) {
        if (lua_istable(L, 1)) {
            lua_getfield(L, 1, "parent");
            if (lua_isuserdata(L, -1)) {
                parent = static_cast<QWidget*>(lua_to_widget(L, -1));
            }
            lua_pop(L, 1);

            lua_getfield(L, 1, "title");
            if (lua_isstring(L, -1)) {
                title = QString::fromUtf8(lua_tostring(L, -1));
            }
            lua_pop(L, 1);

            lua_getfield(L, 1, "message");
            if (lua_isstring(L, -1)) {
                message = QString::fromUtf8(lua_tostring(L, -1));
            }
            lua_pop(L, 1);

            lua_getfield(L, 1, "informative_text");
            if (lua_isstring(L, -1)) {
                informativeText = QString::fromUtf8(lua_tostring(L, -1));
            }
            lua_pop(L, 1);

            lua_getfield(L, 1, "detail_text");
            if (lua_isstring(L, -1)) {
                detailText = QString::fromUtf8(lua_tostring(L, -1));
            }
            lua_pop(L, 1);

            lua_getfield(L, 1, "confirm_text");
            if (lua_isstring(L, -1)) {
                confirmText = QString::fromUtf8(lua_tostring(L, -1));
            }
            lua_pop(L, 1);

            lua_getfield(L, 1, "cancel_text");
            if (lua_isstring(L, -1)) {
                cancelText = QString::fromUtf8(lua_tostring(L, -1));
            }
            lua_pop(L, 1);

            lua_getfield(L, 1, "default_button");
            if (lua_isstring(L, -1)) {
                defaultButton = QString::fromUtf8(lua_tostring(L, -1)).toLower();
            }
            lua_pop(L, 1);

            lua_getfield(L, 1, "icon");
            if (lua_isstring(L, -1)) {
                QString iconName = QString::fromUtf8(lua_tostring(L, -1)).toLower();
                if (iconName == "information" || iconName == "info") {
                    icon = QMessageBox::Information;
                } else if (iconName == "warning") {
                    icon = QMessageBox::Warning;
                } else if (iconName == "critical" || iconName == "error") {
                    icon = QMessageBox::Critical;
                } else if (iconName == "question") {
                    icon = QMessageBox::Question;
                }
            }
            lua_pop(L, 1);
        } else if (lua_isstring(L, 1)) {
            message = QString::fromUtf8(lua_tostring(L, 1));
            if (argCount >= 2 && lua_isstring(L, 2)) {
                confirmText = QString::fromUtf8(lua_tostring(L, 2));
            }
            if (argCount >= 3 && lua_isstring(L, 3)) {
                cancelText = QString::fromUtf8(lua_tostring(L, 3));
            }
        }
    }

    QMessageBox msgBox(icon, title, message, QMessageBox::NoButton, parent);
    msgBox.setWindowModality(Qt::WindowModal);
    if (!informativeText.isEmpty()) {
        msgBox.setInformativeText(informativeText);
    }
    if (!detailText.isEmpty()) {
        msgBox.setDetailedText(detailText);
    }

    QAbstractButton* confirmButton = msgBox.addButton(confirmText, QMessageBox::AcceptRole);
    QAbstractButton* cancelButton = msgBox.addButton(cancelText, QMessageBox::RejectRole);

    if (defaultButton == "cancel") {
        msgBox.setDefaultButton(qobject_cast<QPushButton*>(cancelButton));
    } else {
        msgBox.setDefaultButton(qobject_cast<QPushButton*>(confirmButton));
    }

    msgBox.exec();
    QAbstractButton* clicked = msgBox.clickedButton();
    bool accepted = (clicked == confirmButton);

    lua_pushboolean(L, accepted ? 1 : 0);
    lua_pushstring(L, accepted ? "confirm" : "cancel");
    return 2;
}

// Show directory selection dialog
// Returns: selected directory path (string) or nil if cancelled
int lua_file_dialog_directory(lua_State* L)
{
    QWidget* parent = nullptr;
    const char* title = "Select Directory";
    const char* dir = "";

    // Optional arguments
    if (lua_gettop(L) >= 1 && !lua_isnil(L, 1)) {
        parent = (QWidget*)lua_to_widget(L, 1);
    }
    if (lua_gettop(L) >= 2 && lua_isstring(L, 2)) {
        title = lua_tostring(L, 2);
    }
    if (lua_gettop(L) >= 3 && lua_isstring(L, 3)) {
        dir = lua_tostring(L, 3);
    }

    QString dirname = QFileDialog::getExistingDirectory(
        parent,
        QString::fromUtf8(title),
        QString::fromUtf8(dir)
    );

    if (dirname.isEmpty()) {
        lua_pushnil(L);
    } else {
        lua_pushstring(L, dirname.toUtf8().constData());
    }

    return 1;
}

void registerQtBindings(lua_State* L)
{
    // // qDebug() << "Registering Qt bindings with Lua";
    
    // Create widget metatable
    luaL_newmetatable(L, WIDGET_METATABLE);
    lua_pop(L, 1);
    
    // Create qt_constants table
    lua_newtable(L);
    
    // Create WIDGET subtable
    lua_newtable(L);
    lua_pushcfunction(L, lua_create_main_window);
    lua_setfield(L, -2, "CREATE_MAIN_WINDOW");
    lua_pushcfunction(L, lua_create_widget);
    lua_setfield(L, -2, "CREATE");
    lua_pushcfunction(L, lua_create_scroll_area);
    lua_setfield(L, -2, "CREATE_SCROLL_AREA");
    lua_pushcfunction(L, lua_create_label);
    lua_setfield(L, -2, "CREATE_LABEL");
    lua_pushcfunction(L, lua_create_line_edit);
    lua_setfield(L, -2, "CREATE_LINE_EDIT");
    lua_pushcfunction(L, lua_create_button);
    lua_setfield(L, -2, "CREATE_BUTTON");
    lua_pushcfunction(L, lua_create_checkbox);
    lua_setfield(L, -2, "CREATE_CHECKBOX");
    lua_pushcfunction(L, lua_create_combobox);
    lua_setfield(L, -2, "CREATE_COMBOBOX");
    lua_pushcfunction(L, lua_create_slider);
    lua_setfield(L, -2, "CREATE_SLIDER");
    lua_pushcfunction(L, lua_create_tree_widget);
    lua_setfield(L, -2, "CREATE_TREE");
    lua_pushcfunction(L, lua_create_scriptable_timeline);
    lua_setfield(L, -2, "CREATE_TIMELINE");
    lua_pushcfunction(L, lua_create_inspector_panel);
    lua_setfield(L, -2, "CREATE_INSPECTOR");
    lua_pushcfunction(L, lua_create_rubber_band);
    lua_setfield(L, -2, "CREATE_RUBBER_BAND");
    lua_pushcfunction(L, lua_set_rubber_band_geometry);
    lua_setfield(L, -2, "SET_RUBBER_BAND_GEOMETRY");
    lua_pushcfunction(L, lua_grab_mouse);
    lua_setfield(L, -2, "GRAB_MOUSE");
    lua_pushcfunction(L, lua_release_mouse);
    lua_setfield(L, -2, "RELEASE_MOUSE");
    lua_pushcfunction(L, lua_map_point_from);
    lua_setfield(L, -2, "MAP_POINT_FROM");
    lua_pushcfunction(L, lua_map_rect_from);
    lua_setfield(L, -2, "MAP_RECT_FROM");
    lua_pushcfunction(L, lua_map_to_global);
    lua_setfield(L, -2, "MAP_TO_GLOBAL");
    lua_pushcfunction(L, lua_map_from_global);
    lua_setfield(L, -2, "MAP_FROM_GLOBAL");
    lua_pushcfunction(L, lua_set_parent);
    lua_setfield(L, -2, "SET_PARENT");
    lua_setfield(L, -2, "WIDGET");
    
    // Create LAYOUT subtable
    lua_newtable(L);
    lua_pushcfunction(L, lua_create_hbox_layout);
    lua_setfield(L, -2, "CREATE_HBOX");
    lua_pushcfunction(L, lua_create_vbox_layout);
    lua_setfield(L, -2, "CREATE_VBOX");
    lua_pushcfunction(L, lua_create_splitter);
    lua_setfield(L, -2, "CREATE_SPLITTER");
    lua_pushcfunction(L, lua_set_layout);
    lua_setfield(L, -2, "SET_ON_WIDGET");
    lua_pushcfunction(L, lua_add_widget_to_layout);
    lua_setfield(L, -2, "ADD_WIDGET");
    lua_pushcfunction(L, lua_add_stretch_to_layout);
    lua_setfield(L, -2, "ADD_STRETCH");
    lua_pushcfunction(L, lua_set_central_widget);
    lua_setfield(L, -2, "SET_CENTRAL_WIDGET");
    lua_pushcfunction(L, lua_set_splitter_sizes);
    lua_setfield(L, -2, "SET_SPLITTER_SIZES");
    lua_pushcfunction(L, lua_get_splitter_sizes);
    lua_setfield(L, -2, "GET_SPLITTER_SIZES");
    lua_pushcfunction(L, lua_set_splitter_stretch_factor);
    lua_setfield(L, -2, "SET_SPLITTER_STRETCH_FACTOR");
    lua_setfield(L, -2, "LAYOUT");
    
    // Create PROPERTIES subtable
    lua_newtable(L);
    lua_pushcfunction(L, lua_set_text);
    lua_setfield(L, -2, "SET_TEXT");
    lua_pushcfunction(L, lua_get_text);
    lua_setfield(L, -2, "GET_TEXT");
    lua_pushcfunction(L, lua_set_checked);
    lua_setfield(L, -2, "SET_CHECKED");
    lua_pushcfunction(L, lua_get_checked);
    lua_setfield(L, -2, "GET_CHECKED");
    lua_pushcfunction(L, lua_add_combobox_item);
    lua_setfield(L, -2, "ADD_COMBOBOX_ITEM");
    lua_pushcfunction(L, lua_set_combobox_current_text);
    lua_setfield(L, -2, "SET_COMBOBOX_CURRENT_TEXT");
    lua_pushcfunction(L, lua_get_combobox_current_text);
    lua_setfield(L, -2, "GET_COMBOBOX_CURRENT_TEXT");
    lua_pushcfunction(L, lua_set_slider_range);
    lua_setfield(L, -2, "SET_SLIDER_RANGE");
    lua_pushcfunction(L, lua_set_slider_value);
    lua_setfield(L, -2, "SET_SLIDER_VALUE");
    lua_pushcfunction(L, lua_get_slider_value);
    lua_setfield(L, -2, "GET_SLIDER_VALUE");
    lua_pushcfunction(L, lua_set_placeholder_text);
    lua_setfield(L, -2, "SET_PLACEHOLDER_TEXT");
    lua_pushcfunction(L, lua_set_window_title);
    lua_setfield(L, -2, "SET_TITLE");
    lua_pushcfunction(L, lua_set_size);
    lua_setfield(L, -2, "SET_SIZE");
    lua_pushcfunction(L, lua_get_widget_size);
    lua_setfield(L, -2, "GET_SIZE");
    lua_pushcfunction(L, lua_set_minimum_width);
    lua_setfield(L, -2, "SET_MIN_WIDTH");
    lua_pushcfunction(L, lua_set_maximum_width);
    lua_setfield(L, -2, "SET_MAX_WIDTH");
    lua_pushcfunction(L, lua_set_minimum_height);
    lua_setfield(L, -2, "SET_MIN_HEIGHT");
    lua_pushcfunction(L, lua_set_maximum_height);
    lua_setfield(L, -2, "SET_MAX_HEIGHT");
    lua_pushcfunction(L, lua_set_geometry);
    lua_setfield(L, -2, "SET_GEOMETRY");
    lua_pushcfunction(L, lua_get_geometry);
    lua_setfield(L, -2, "GET_GEOMETRY");
    lua_pushcfunction(L, lua_set_style_sheet);
    lua_setfield(L, -2, "SET_STYLE");
    lua_pushcfunction(L, lua_set_window_appearance);
    lua_setfield(L, -2, "SET_WINDOW_APPEARANCE");
    lua_setfield(L, -2, "PROPERTIES");
    
    // Create DISPLAY subtable
    lua_newtable(L);
    lua_pushcfunction(L, lua_show_widget);
    lua_setfield(L, -2, "SHOW");
    lua_pushcfunction(L, lua_set_visible);
    lua_setfield(L, -2, "SET_VISIBLE");
    lua_pushcfunction(L, lua_raise_widget);
    lua_setfield(L, -2, "RAISE");
    lua_pushcfunction(L, lua_activate_window);
    lua_setfield(L, -2, "ACTIVATE");
    lua_setfield(L, -2, "DISPLAY");
    
    // Create CONTROL subtable
    lua_newtable(L);
    lua_pushcfunction(L, lua_set_scroll_area_widget);
    lua_setfield(L, -2, "SET_SCROLL_AREA_WIDGET");
    lua_pushcfunction(L, lua_set_scroll_area_viewport_margins);
    lua_setfield(L, -2, "SET_SCROLL_AREA_VIEWPORT_MARGINS");
    lua_pushcfunction(L, lua_set_scroll_area_widget_resizable);
    lua_setfield(L, -2, "SET_SCROLL_AREA_WIDGET_RESIZABLE");
    lua_pushcfunction(L, lua_set_scroll_area_h_scrollbar_policy);
    lua_setfield(L, -2, "SET_SCROLL_AREA_H_SCROLLBAR_POLICY");
    lua_pushcfunction(L, lua_set_scroll_area_v_scrollbar_policy);
    lua_setfield(L, -2, "SET_SCROLL_AREA_V_SCROLLBAR_POLICY");
    lua_pushcfunction(L, lua_set_layout_spacing);
    lua_setfield(L, -2, "SET_LAYOUT_SPACING");
    lua_pushcfunction(L, lua_set_layout_margins);
    lua_setfield(L, -2, "SET_LAYOUT_MARGINS");
    lua_pushcfunction(L, lua_set_widget_size_policy);
    lua_setfield(L, -2, "SET_WIDGET_SIZE_POLICY");
    lua_pushcfunction(L, lua_set_button_click_handler);
    lua_setfield(L, -2, "SET_BUTTON_CLICK_HANDLER");
    lua_pushcfunction(L, lua_set_widget_click_handler);
    lua_setfield(L, -2, "SET_WIDGET_CLICK_HANDLER");
    lua_pushcfunction(L, lua_set_context_menu_handler);
    lua_setfield(L, -2, "SET_CONTEXT_MENU_HANDLER");
    lua_pushcfunction(L, lua_set_tree_headers);
    lua_setfield(L, -2, "SET_TREE_HEADERS");
    lua_pushcfunction(L, lua_set_tree_column_width);
    lua_setfield(L, -2, "SET_TREE_COLUMN_WIDTH");
    lua_pushcfunction(L, lua_set_tree_indentation);
    lua_setfield(L, -2, "SET_TREE_INDENTATION");
    lua_pushcfunction(L, lua_set_tree_expands_on_double_click);
    lua_setfield(L, -2, "SET_TREE_EXPANDS_ON_DOUBLE_CLICK");
    lua_pushcfunction(L, lua_add_tree_item);
    lua_setfield(L, -2, "ADD_TREE_ITEM");
    lua_pushcfunction(L, lua_add_tree_child_item);
    lua_setfield(L, -2, "ADD_TREE_CHILD_ITEM");
    lua_pushcfunction(L, lua_get_tree_selected_index);
    lua_setfield(L, -2, "GET_TREE_SELECTED_INDEX");
    lua_pushcfunction(L, lua_clear_tree);
    lua_setfield(L, -2, "CLEAR_TREE");
    lua_pushcfunction(L, lua_set_tree_item_expanded);
    lua_setfield(L, -2, "SET_TREE_ITEM_EXPANDED");
    lua_pushcfunction(L, lua_is_tree_item_expanded);
    lua_setfield(L, -2, "IS_TREE_ITEM_EXPANDED");
    lua_pushcfunction(L, lua_set_tree_item_data);
    lua_setfield(L, -2, "SET_TREE_ITEM_DATA");
    lua_pushcfunction(L, lua_get_tree_item_data);
    lua_setfield(L, -2, "GET_TREE_ITEM_DATA");
    lua_pushcfunction(L, lua_set_tree_item_text);
    lua_setfield(L, -2, "SET_TREE_ITEM_TEXT");
    lua_pushcfunction(L, lua_set_tree_item_editable);
    lua_setfield(L, -2, "SET_TREE_ITEM_EDITABLE");
    lua_pushcfunction(L, lua_edit_tree_item);
    lua_setfield(L, -2, "EDIT_TREE_ITEM");
    lua_pushcfunction(L, lua_set_tree_selection_changed_handler);
    lua_setfield(L, -2, "SET_TREE_SELECTION_HANDLER");
    lua_pushcfunction(L, lua_set_tree_item_changed_handler);
    lua_setfield(L, -2, "SET_TREE_ITEM_CHANGED_HANDLER");
    lua_pushcfunction(L, lua_set_tree_close_editor_handler);
    lua_setfield(L, -2, "SET_TREE_CLOSE_EDITOR_HANDLER");
    lua_pushcfunction(L, lua_set_tree_selection_mode);
    lua_setfield(L, -2, "SET_TREE_SELECTION_MODE");
    lua_pushcfunction(L, lua_set_tree_drag_drop_mode);
    lua_setfield(L, -2, "SET_TREE_DRAG_DROP_MODE");
    lua_pushcfunction(L, lua_set_tree_drop_handler);
    lua_setfield(L, -2, "SET_TREE_DROP_HANDLER");
    lua_pushcfunction(L, lua_set_tree_key_handler);
    lua_setfield(L, -2, "SET_TREE_KEY_HANDLER");
    lua_pushcfunction(L, lua_set_tree_item_icon);
    lua_setfield(L, -2, "SET_TREE_ITEM_ICON");
lua_pushcfunction(L, lua_set_tree_item_double_click_handler);
lua_setfield(L, -2, "SET_TREE_DOUBLE_CLICK_HANDLER");
    lua_pushcfunction(L, lua_set_tree_current_item);
    lua_setfield(L, -2, "SET_TREE_CURRENT_ITEM");
    lua_pushcfunction(L, lua_get_tree_item_at);
    lua_setfield(L, -2, "GET_TREE_ITEM_AT");
    lua_setfield(L, -2, "CONTROL");
    
    // Register signal handler functions globally for qt_signals module
    lua_pushcfunction(L, lua_set_button_click_handler);
    lua_setglobal(L, "qt_set_button_click_handler");
    lua_pushcfunction(L, lua_set_widget_click_handler);
    lua_setglobal(L, "qt_set_widget_click_handler");
    lua_pushcfunction(L, lua_set_context_menu_handler);
    lua_setglobal(L, "qt_set_context_menu_handler");
    lua_pushcfunction(L, lua_set_line_edit_text_changed_handler);
    lua_setglobal(L, "qt_set_line_edit_text_changed_handler");
    lua_pushcfunction(L, lua_set_line_edit_editing_finished_handler);
    lua_setglobal(L, "qt_set_line_edit_editing_finished_handler");
    lua_pushcfunction(L, lua_set_tree_selection_changed_handler);
    lua_setglobal(L, "qt_set_tree_selection_handler");
    lua_pushcfunction(L, lua_set_tree_selection_mode);
    lua_setglobal(L, "qt_set_tree_selection_mode");
    lua_pushcfunction(L, lua_set_tree_drag_drop_mode);
    lua_setglobal(L, "qt_set_tree_drag_drop_mode");
    lua_pushcfunction(L, lua_set_tree_drop_handler);
    lua_setglobal(L, "qt_set_tree_drop_handler");
    lua_pushcfunction(L, lua_set_tree_key_handler);
    lua_setglobal(L, "qt_set_tree_key_handler");
    lua_pushcfunction(L, lua_is_tree_item_expanded);
    lua_setglobal(L, "qt_is_tree_item_expanded");
    lua_pushcfunction(L, lua_set_tree_item_icon);
    lua_setglobal(L, "qt_set_tree_item_icon");
    lua_pushcfunction(L, lua_set_tree_item_double_click_handler);
    lua_setglobal(L, "qt_set_tree_item_double_click_handler");
    lua_pushcfunction(L, lua_set_tree_expands_on_double_click);
    lua_setglobal(L, "qt_set_tree_expands_on_double_click");
    lua_pushcfunction(L, lua_get_tree_item_at);
    lua_setglobal(L, "qt_get_tree_item_at");
    lua_pushcfunction(L, lua_hide_splitter_handle);
    lua_setglobal(L, "qt_hide_splitter_handle");
    lua_pushcfunction(L, lua_set_splitter_moved_handler);
    lua_setglobal(L, "qt_set_splitter_moved_handler");
    lua_pushcfunction(L, lua_get_splitter_handle);
    lua_setglobal(L, "qt_get_splitter_handle");
    lua_pushcfunction(L, lua_update_widget);
    lua_setglobal(L, "qt_update_widget");

    // Register scroll functions globally
    lua_pushcfunction(L, lua_get_scroll_position);
    lua_setglobal(L, "qt_get_scroll_position");
    lua_pushcfunction(L, lua_set_scroll_position);
    lua_setglobal(L, "qt_set_scroll_position");
    lua_pushcfunction(L, lua_set_scroll_area_scroll_handler);
    lua_setglobal(L, "qt_set_scroll_area_scroll_handler");

    // Register JSON functions globally
    lua_pushcfunction(L, lua_json_encode);
    lua_setglobal(L, "qt_json_encode");
    lua_pushcfunction(L, lua_json_decode);
    lua_setglobal(L, "qt_json_decode");

    // Register new missing functions globally for lazy_function access
    lua_pushcfunction(L, lua_set_layout_stretch_factor);
    lua_setglobal(L, "qt_set_layout_stretch_factor");
    lua_pushcfunction(L, lua_set_widget_alignment);
    lua_setglobal(L, "qt_set_widget_alignment");
    lua_pushcfunction(L, qt_set_layout_alignment);
    lua_setglobal(L, "qt_set_layout_alignment");
    lua_pushcfunction(L, lua_set_parent);
    lua_setglobal(L, "qt_set_parent");
    lua_pushcfunction(L, lua_set_widget_attribute);
    lua_setglobal(L, "qt_set_widget_attribute");
    lua_pushcfunction(L, lua_set_object_name);
    lua_setglobal(L, "qt_set_object_name");
    lua_pushcfunction(L, lua_set_widget_stylesheet);
    lua_setglobal(L, "qt_set_widget_stylesheet");
    lua_pushcfunction(L, lua_set_widget_cursor);
    lua_setglobal(L, "qt_set_widget_cursor");
    lua_pushcfunction(L, lua_set_window_appearance);
    lua_setglobal(L, "qt_set_window_appearance");
    lua_pushcfunction(L, lua_create_single_shot_timer);
    lua_setglobal(L, "qt_create_single_shot_timer");
    lua_pushcfunction(L, lua_set_scroll_area_alignment);
    lua_setglobal(L, "qt_set_scroll_area_alignment");
    lua_pushcfunction(L, lua_set_scroll_area_anchor_bottom);
    lua_setglobal(L, "qt_set_scroll_area_anchor_bottom");
    lua_pushcfunction(L, lua_set_focus_policy);
    lua_setglobal(L, "qt_set_focus_policy");
    lua_pushcfunction(L, lua_set_focus);
    lua_setglobal(L, "qt_set_focus");
    lua_pushcfunction(L, lua_set_global_key_handler);
    lua_setglobal(L, "qt_set_global_key_handler");
    lua_pushcfunction(L, lua_set_focus_handler);
    lua_setglobal(L, "qt_set_focus_handler");
    lua_pushcfunction(L, lua_show_confirm_dialog);
    lua_setglobal(L, "qt_show_confirm_dialog");
    lua_pushcfunction(L, lua_show_menu_popup);
    lua_setglobal(L, "qt_show_menu_popup");

    // Create MENU subtable
    lua_newtable(L);
    lua_pushcfunction(L, lua_get_menu_bar);
    lua_setfield(L, -2, "GET_MENU_BAR");
    lua_pushcfunction(L, lua_create_menu);
    lua_setfield(L, -2, "CREATE_MENU");
    lua_pushcfunction(L, lua_add_menu_to_bar);
    lua_setfield(L, -2, "ADD_MENU_TO_BAR");
    lua_pushcfunction(L, lua_add_submenu);
    lua_setfield(L, -2, "ADD_SUBMENU");
    lua_pushcfunction(L, lua_create_menu_action);
    lua_setfield(L, -2, "CREATE_MENU_ACTION");
    lua_pushcfunction(L, lua_connect_menu_action);
    lua_setfield(L, -2, "CONNECT_MENU_ACTION");
    lua_pushcfunction(L, lua_add_menu_separator);
    lua_setfield(L, -2, "ADD_MENU_SEPARATOR");
    lua_pushcfunction(L, lua_set_action_enabled);
    lua_setfield(L, -2, "SET_ACTION_ENABLED");
    lua_pushcfunction(L, lua_set_action_checked);
    lua_setfield(L, -2, "SET_ACTION_CHECKED");
    lua_pushcfunction(L, lua_show_menu_popup);
    lua_setfield(L, -2, "SHOW_POPUP");
    lua_setfield(L, -2, "MENU");

    // Create DIALOG subtable
    lua_newtable(L);
    lua_pushcfunction(L, lua_show_confirm_dialog);
    lua_setfield(L, -2, "SHOW_CONFIRM");
    lua_setfield(L, -2, "DIALOG");

    // Create FILE_DIALOG subtable
    lua_newtable(L);
    lua_pushcfunction(L, lua_file_dialog_open);
    lua_setfield(L, -2, "OPEN_FILE");
    lua_pushcfunction(L, lua_file_dialog_open_multiple);
    lua_setfield(L, -2, "OPEN_FILES");
    lua_pushcfunction(L, lua_file_dialog_directory);
    lua_setfield(L, -2, "OPEN_DIRECTORY");
    lua_setfield(L, -2, "FILE_DIALOG");

    // Set the qt_constants global
    lua_setglobal(L, "qt_constants");
    
    // // qDebug() << "Qt bindings registered successfully";
}

void* lua_to_widget(lua_State* L, int index)
{
    if (!lua_isuserdata(L, index)) {
        luaL_error(L, "Expected widget userdata at index %d", index);
        return nullptr;
    }
    
    void** widget_ptr = (void**)luaL_checkudata(L, index, WIDGET_METATABLE);
    return *widget_ptr;
}

void lua_push_widget(lua_State* L, void* widget)
{
    if (!widget) {
        lua_pushnil(L);
        return;
    }
    
    void** widget_ptr = (void**)lua_newuserdata(L, sizeof(void*));
    *widget_ptr = widget;
    luaL_getmetatable(L, WIDGET_METATABLE);
    lua_setmetatable(L, -2);
}

// Widget creation functions
int lua_create_main_window(lua_State* L)
{
    // // qDebug() << "Creating main window from Lua";
    QMainWindow* window = new QMainWindow();
    
    // Store reference to prevent destruction
    SimpleLuaEngine::s_lastCreatedMainWindow = window;
    
    lua_push_widget(L, window);
    return 1;
}

int lua_create_widget(lua_State* L)
{
    // // qDebug() << "Creating widget from Lua";
    QWidget* widget = new QWidget();
    lua_push_widget(L, widget);
    return 1;
}

int lua_create_scroll_area(lua_State* L)
{
    // // qDebug() << "Creating scroll area from Lua";
    QScrollArea* scrollArea = new QScrollArea();
    scrollArea->setWidgetResizable(true);
    lua_push_widget(L, scrollArea);
    return 1;
}

int lua_create_label(lua_State* L)
{
    const char* text = lua_tostring(L, 1);
    // // qDebug() << "Creating label from Lua with text:" << (text ? text : "");
    
    QLabel* label = new QLabel(text ? QString::fromUtf8(text) : QString());
    lua_push_widget(L, label);
    return 1;
}

int lua_create_line_edit(lua_State* L)
{
    const char* placeholder = lua_tostring(L, 1);
    // // qDebug() << "Creating line edit from Lua with placeholder:" << (placeholder ? placeholder : "");
    
    QLineEdit* lineEdit = new QLineEdit();
    if (placeholder) {
        lineEdit->setPlaceholderText(QString::fromUtf8(placeholder));
    }
    lua_push_widget(L, lineEdit);
    return 1;
}

int lua_create_button(lua_State* L)
{
    const char* text = lua_tostring(L, 1);
    // // qDebug() << "Creating button from Lua with text:" << (text ? text : "");

    QPushButton* button = new QPushButton();
    if (text) {
        button->setText(QString::fromUtf8(text));
    }
    lua_push_widget(L, button);
    return 1;
}

int lua_create_checkbox(lua_State* L)
{
    const char* text = lua_tostring(L, 1);
    // // qDebug() << "Creating checkbox from Lua with text:" << (text ? text : "");

    QCheckBox* checkbox = new QCheckBox();
    if (text) {
        checkbox->setText(QString::fromUtf8(text));
    }
    lua_push_widget(L, checkbox);
    return 1;
}

int lua_create_combobox(lua_State* L)
{
    // // qDebug() << "Creating combobox from Lua";

    QComboBox* combobox = new QComboBox();
    lua_push_widget(L, combobox);
    return 1;
}

int lua_create_slider(lua_State* L)
{
    const char* orientation = lua_tostring(L, 1);
    // // qDebug() << "Creating slider from Lua with orientation:" << (orientation ? orientation : "horizontal");

    Qt::Orientation orient = Qt::Horizontal;
    if (orientation && strcmp(orientation, "vertical") == 0) {
        orient = Qt::Vertical;
    }

    QSlider* slider = new QSlider(orient);
    lua_push_widget(L, slider);
    return 1;
}

int lua_create_tree_widget(lua_State* L)
{
    // // qDebug() << "Creating tree widget from Lua";
    LuaTreeWidget* tree = new LuaTreeWidget(L);
    lua_push_widget(L, tree);
    return 1;
}

int lua_create_scriptable_timeline(lua_State* L)
{
    // // qDebug() << "Creating scriptable timeline from Lua";
    JVE::ScriptableTimeline* timeline = new JVE::ScriptableTimeline("timeline_widget");

    // Set size policy to expand and fill available space
    timeline->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);
    timeline->setMinimumHeight(30);  // Small minimum height for flexible track sizing

    // Don't call renderTestTimeline() - Lua will handle all rendering
    lua_push_widget(L, timeline);
    return 1;
}

int lua_create_inspector_panel(lua_State* L)
{
    // // qDebug() << "Creating Lua inspector container from Lua";
    // Create a simple widget container - the Lua system will add its own scroll area
    QWidget* inspector_container = new QWidget();
    inspector_container->setObjectName("LuaInspectorContainer");
    
    // Set up basic styling for the inspector container
    inspector_container->setStyleSheet(
        "QWidget#LuaInspectorContainer { "
        "    background: #2b2b2b; "
        "    border: 1px solid #444; "
        "}"
    );
    
    lua_push_widget(L, inspector_container);
    return 1;
}

// QRubberBand functions
int lua_create_rubber_band(lua_State* L)
{
    QWidget* parent = (QWidget*)lua_to_widget(L, 1);
    if (!parent) {
        return luaL_error(L, "qt_create_rubber_band: parent widget required");
    }

    QRubberBand* band = new QRubberBand(QRubberBand::Rectangle, parent);
    band->hide();  // Start hidden
    lua_push_widget(L, band);
    return 1;
}

int lua_set_rubber_band_geometry(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    if (!widget) {
        return luaL_error(L, "qt_set_rubber_band_geometry: widget required");
    }

    int x = luaL_checkint(L, 2);
    int y = luaL_checkint(L, 3);
    int width = luaL_checkint(L, 4);
    int height = luaL_checkint(L, 5);

    widget->setGeometry(x, y, width, height);
    return 0;
}

int lua_grab_mouse(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    if (!widget) {
        return luaL_error(L, "qt_grab_mouse: widget required");
    }

    widget->grabMouse();
    return 0;
}

int lua_release_mouse(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    if (!widget) {
        return luaL_error(L, "qt_release_mouse: widget required");
    }

    widget->releaseMouse();
    return 0;
}

// Coordinate mapping functions
int lua_map_point_from(lua_State* L)
{
    QWidget* target_widget = (QWidget*)lua_to_widget(L, 1);
    QWidget* source_widget = (QWidget*)lua_to_widget(L, 2);
    int x = luaL_checkint(L, 3);
    int y = luaL_checkint(L, 4);

    if (!target_widget || !source_widget) {
        return luaL_error(L, "qt_map_point_from: both widgets required");
    }

    QPoint point(x, y);
    QPoint mapped = target_widget->mapFrom(source_widget, point);

    lua_pushinteger(L, mapped.x());
    lua_pushinteger(L, mapped.y());
    return 2;
}

int lua_map_rect_from(lua_State* L)
{
    QWidget* target_widget = (QWidget*)lua_to_widget(L, 1);
    QWidget* source_widget = (QWidget*)lua_to_widget(L, 2);
    int x = luaL_checkint(L, 3);
    int y = luaL_checkint(L, 4);
    int width = luaL_checkint(L, 5);
    int height = luaL_checkint(L, 6);

    if (!target_widget || !source_widget) {
        return luaL_error(L, "qt_map_rect_from: both widgets required");
    }

    // Map top-left and bottom-right corners
    QPoint top_left(x, y);
    QPoint bottom_right(x + width, y + height);

    QPoint mapped_tl = target_widget->mapFrom(source_widget, top_left);
    QPoint mapped_br = target_widget->mapFrom(source_widget, bottom_right);

    // Calculate mapped rect
    int mapped_x = mapped_tl.x();
    int mapped_y = mapped_tl.y();
    int mapped_width = mapped_br.x() - mapped_tl.x();
    int mapped_height = mapped_br.y() - mapped_tl.y();

    lua_pushinteger(L, mapped_x);
    lua_pushinteger(L, mapped_y);
    lua_pushinteger(L, mapped_width);
    lua_pushinteger(L, mapped_height);
    return 4;
}

// Widget styling
int lua_set_widget_stylesheet(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    const char* stylesheet = luaL_checkstring(L, 2);

    if (!widget) {
        return luaL_error(L, "qt_set_widget_stylesheet: widget required");
    }

    widget->setStyleSheet(QString::fromUtf8(stylesheet));
    return 0;
}

// Set widget cursor
// Parameters: widget, cursor_type (string: "arrow", "hand", "size_horz", "size_vert", "cross")
int lua_set_widget_cursor(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    const char* cursor_type = luaL_checkstring(L, 2);

    if (!widget) {
        return luaL_error(L, "qt_set_widget_cursor: widget required");
    }

    Qt::CursorShape shape = Qt::ArrowCursor;  // Default

    if (strcmp(cursor_type, "arrow") == 0) {
        shape = Qt::ArrowCursor;
    } else if (strcmp(cursor_type, "hand") == 0) {
        shape = Qt::PointingHandCursor;
    } else if (strcmp(cursor_type, "size_horz") == 0) {
        shape = Qt::SizeHorCursor;
    } else if (strcmp(cursor_type, "size_vert") == 0) {
        shape = Qt::SizeVerCursor;
    } else if (strcmp(cursor_type, "split_h") == 0) {
        shape = Qt::SplitHCursor;  // Horizontal splitter cursor (for edit points)
    } else if (strcmp(cursor_type, "split_v") == 0) {
        shape = Qt::SplitVCursor;
    } else if (strcmp(cursor_type, "cross") == 0) {
        shape = Qt::CrossCursor;
    } else if (strcmp(cursor_type, "ibeam") == 0) {
        shape = Qt::IBeamCursor;
    } else if (strcmp(cursor_type, "size_all") == 0) {
        shape = Qt::SizeAllCursor;
    } else {
        return luaL_error(L, "qt_set_widget_cursor: unknown cursor type '%s'", cursor_type);
    }

    widget->setCursor(QCursor(shape));
    return 0;
}

// Global coordinate mapping functions
int lua_map_to_global(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    int x = luaL_checkint(L, 2);
    int y = luaL_checkint(L, 3);

    if (!widget) {
        return luaL_error(L, "qt_map_to_global: widget required");
    }

    QPoint local(x, y);
    QPoint global = widget->mapToGlobal(local);

    lua_pushinteger(L, global.x());
    lua_pushinteger(L, global.y());
    return 2;
}

int lua_map_from_global(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    int x = luaL_checkint(L, 2);
    int y = luaL_checkint(L, 3);

    if (!widget) {
        return luaL_error(L, "qt_map_from_global: widget required");
    }

    QPoint global(x, y);
    QPoint local = widget->mapFromGlobal(global);

    lua_pushinteger(L, local.x());
    lua_pushinteger(L, local.y());
    return 2;
}

// Layout functions
int lua_create_hbox_layout(lua_State* L)
{
    // // qDebug() << "Creating HBox layout from Lua";
    QHBoxLayout* layout = new QHBoxLayout();
    lua_push_widget(L, layout);
    return 1;
}

int lua_create_vbox_layout(lua_State* L)
{
    // // qDebug() << "Creating VBox layout from Lua";
    QVBoxLayout* layout = new QVBoxLayout();
    lua_push_widget(L, layout);
    return 1;
}

int lua_create_splitter(lua_State* L)
{
    const char* direction = lua_tostring(L, 1);
    // // qDebug() << "Creating splitter from Lua with direction:" << (direction ? direction : "horizontal");
    
    Qt::Orientation orientation = Qt::Horizontal;
    if (direction && strcmp(direction, "vertical") == 0) {
        orientation = Qt::Vertical;
    }
    
    QSplitter* splitter = new QSplitter(orientation);
    lua_push_widget(L, splitter);
    return 1;
}

int lua_set_layout(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    QLayout* layout = (QLayout*)lua_to_widget(L, 2);
    
    if (widget && layout) {
        // qDebug() << "Setting layout on widget from Lua";
        widget->setLayout(layout);
        lua_pushboolean(L, 1);
    } else {
        qWarning() << "Invalid widget or layout in set_layout";
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_add_widget_to_layout(lua_State* L)
{
    void* first = lua_to_widget(L, 1);
    QWidget* widget = (QWidget*)lua_to_widget(L, 2);
    
    if (!first || !widget) {
        qWarning() << "Invalid parameters in add_widget_to_layout";
        lua_pushboolean(L, 0);
        return 1;
    }
    
    // Try as QSplitter first
    if (QSplitter* splitter = qobject_cast<QSplitter*>((QWidget*)first)) {
        // qDebug() << "Adding widget to splitter from Lua";
        splitter->addWidget(widget);
        lua_pushboolean(L, 1);
        return 1;
    }
    
    // Try as QLayout
    if (QLayout* layout = qobject_cast<QLayout*>((QObject*)first)) {
        // Check for optional alignment parameter
        Qt::Alignment alignment = Qt::Alignment();
        if (lua_gettop(L) >= 3 && lua_isstring(L, 3)) {
            const char* alignment_str = lua_tostring(L, 3);
            if (strcmp(alignment_str, "AlignVCenter") == 0) {
                alignment = Qt::AlignVCenter;
            } else if (strcmp(alignment_str, "AlignTop") == 0) {
                alignment = Qt::AlignTop;
            } else if (strcmp(alignment_str, "AlignBottom") == 0) {
                alignment = Qt::AlignBottom;
            } else if (strcmp(alignment_str, "AlignBaseline") == 0) {
                alignment = Qt::AlignBaseline;
            }
        }

        // For QBoxLayout, use addWidget with alignment
        if (QBoxLayout* boxLayout = qobject_cast<QBoxLayout*>(layout)) {
            // qDebug() << "Adding widget to box layout from Lua with alignment";
            boxLayout->addWidget(widget, 0, alignment);
        } else {
            // qDebug() << "Adding widget to layout from Lua";
            layout->addWidget(widget);
        }
        lua_pushboolean(L, 1);
        return 1;
    }
    
    qWarning() << "First parameter is neither QSplitter nor QLayout in add_widget_to_layout";
    lua_pushboolean(L, 0);
    return 1;
}

int lua_add_stretch_to_layout(lua_State* L)
{
    void* layout_ptr = lua_to_widget(L, 1);
    int stretch = lua_tointeger(L, 2);

    if (!layout_ptr) {
        qWarning() << "Invalid layout in add_stretch_to_layout";
        lua_pushboolean(L, 0);
        return 1;
    }

    // Try as QBoxLayout
    if (QBoxLayout* boxLayout = qobject_cast<QBoxLayout*>((QObject*)layout_ptr)) {
        // qDebug() << "Adding stretch to layout from Lua:" << stretch;
        boxLayout->addStretch(stretch);
        lua_pushboolean(L, 1);
        return 1;
    }

    qWarning() << "Layout is not a QBoxLayout in add_stretch_to_layout";
    lua_pushboolean(L, 0);
    return 1;
}

int lua_set_central_widget(lua_State* L)
{
    QMainWindow* window = (QMainWindow*)lua_to_widget(L, 1);
    QWidget* widget = (QWidget*)lua_to_widget(L, 2);

    if (window && widget) {
        // qDebug() << "Setting central widget from Lua";
        window->setCentralWidget(widget);
        lua_pushboolean(L, 1);
    } else {
        qWarning() << "Invalid window or widget in set_central_widget";
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_set_splitter_sizes(lua_State* L)
{
    QSplitter* splitter = (QSplitter*)lua_to_widget(L, 1);

    if (!splitter) {
        qWarning() << "Invalid splitter in set_splitter_sizes";
        lua_pushboolean(L, 0);
        return 1;
    }

    if (!lua_istable(L, 2)) {
        qWarning() << "Expected table for splitter sizes";
        lua_pushboolean(L, 0);
        return 1;
    }

    QList<int> sizes;
    int len = lua_objlen(L, 2);
    for (int i = 1; i <= len; i++) {
        lua_rawgeti(L, 2, i);
        if (lua_isnumber(L, -1)) {
            sizes.append(lua_tointeger(L, -1));
        }
        lua_pop(L, 1);
    }

    // // qDebug() << "Setting splitter sizes from Lua:" << sizes;
    splitter->setSizes(sizes);
    lua_pushboolean(L, 1);
    return 1;
}

int lua_get_splitter_sizes(lua_State* L)
{
    QSplitter* splitter = (QSplitter*)lua_to_widget(L, 1);

    if (!splitter) {
        qWarning() << "Invalid splitter in get_splitter_sizes";
        lua_pushnil(L);
        return 1;
    }

    QList<int> sizes = splitter->sizes();

    // Create Lua table
    lua_newtable(L);
    for (int i = 0; i < sizes.size(); i++) {
        lua_pushinteger(L, sizes[i]);
        lua_rawseti(L, -2, i + 1);  // Lua uses 1-based indexing
    }

    return 1;
}

int lua_set_splitter_stretch_factor(lua_State* L)
{
    QSplitter* splitter = (QSplitter*)lua_to_widget(L, 1);
    int index = lua_tointeger(L, 2);
    int stretch = lua_tointeger(L, 3);

    if (!splitter) {
        qWarning() << "Invalid splitter in set_splitter_stretch_factor";
        lua_pushboolean(L, 0);
        return 1;
    }

    // Set the stretch factor for the widget at the given index
    splitter->setStretchFactor(index, stretch);
    lua_pushboolean(L, 1);
    return 1;
}

int lua_get_splitter_handle(lua_State* L)
{
    QSplitter* splitter = (QSplitter*)lua_to_widget(L, 1);
    int index = lua_tointeger(L, 2);

    if (!splitter) {
        qWarning() << "Invalid splitter in get_splitter_handle";
        lua_pushnil(L);
        return 1;
    }

    // qDebug() << "get_splitter_handle: splitter=" << splitter << "index=" << index << "count=" << splitter->count();

    // Get the handle widget at the given index
    QSplitterHandle* handle = splitter->handle(index);
    // qDebug() << "  -> handle(" << index << ") returned:" << handle;

    if (handle) {
        lua_push_widget(L, handle);
    } else {
        qWarning() << "  -> WARNING: handle is null!";
        lua_pushnil(L);
    }
    return 1;
}

// Property functions
int lua_set_text(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    const char* text = lua_tostring(L, 2);

    if (widget && text) {
        if (QLabel* label = qobject_cast<QLabel*>(widget)) {
            label->setText(QString::fromUtf8(text));
        } else if (QLineEdit* lineEdit = qobject_cast<QLineEdit*>(widget)) {
            lineEdit->setText(QString::fromUtf8(text));
        }

        lua_pushboolean(L, 1);
    } else {
        qWarning() << "Invalid widget or text in set_text";
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_set_checked(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    bool checked = lua_toboolean(L, 2);

    if (widget) {
        // qDebug() << "Setting checked state from Lua:" << checked;

        if (QCheckBox* checkbox = qobject_cast<QCheckBox*>(widget)) {
            checkbox->setChecked(checked);
            lua_pushboolean(L, 1);
        } else {
            qWarning() << "Widget is not a QCheckBox in set_checked";
            lua_pushboolean(L, 0);
        }
    } else {
        qWarning() << "Invalid widget in set_checked";
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_add_combobox_item(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    const char* text = luaL_checkstring(L, 2);

    if (widget && text) {
        if (QComboBox* combobox = qobject_cast<QComboBox*>(widget)) {
            combobox->addItem(QString::fromUtf8(text));
            lua_pushboolean(L, 1);
        } else {
            qWarning() << "Widget is not a QComboBox in add_combobox_item";
            lua_pushboolean(L, 0);
        }
    } else {
        qWarning() << "Invalid widget or text in add_combobox_item";
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_set_combobox_current_text(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    const char* text = luaL_checkstring(L, 2);

    if (widget && text) {
        if (QComboBox* combobox = qobject_cast<QComboBox*>(widget)) {
            combobox->setCurrentText(QString::fromUtf8(text));
            lua_pushboolean(L, 1);
        } else {
            qWarning() << "Widget is not a QComboBox in set_combobox_current_text";
            lua_pushboolean(L, 0);
        }
    } else {
        qWarning() << "Invalid widget or text in set_combobox_current_text";
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_set_slider_range(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    int min = lua_tointeger(L, 2);
    int max = lua_tointeger(L, 3);

    if (widget) {
        if (QSlider* slider = qobject_cast<QSlider*>(widget)) {
            slider->setRange(min, max);
            lua_pushboolean(L, 1);
        } else {
            qWarning() << "Widget is not a QSlider in set_slider_range";
            lua_pushboolean(L, 0);
        }
    } else {
        qWarning() << "Invalid widget in set_slider_range";
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_set_slider_value(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    int value = lua_tointeger(L, 2);

    if (widget) {
        if (QSlider* slider = qobject_cast<QSlider*>(widget)) {
            slider->setValue(value);
            lua_pushboolean(L, 1);
        } else {
            qWarning() << "Widget is not a QSlider in set_slider_value";
            lua_pushboolean(L, 0);
        }
    } else {
        qWarning() << "Invalid widget in set_slider_value";
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_get_text(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);

    if (widget) {
        QString text;

        if (QLabel* label = qobject_cast<QLabel*>(widget)) {
            text = label->text();
        } else if (QLineEdit* lineEdit = qobject_cast<QLineEdit*>(widget)) {
            text = lineEdit->text();
        } else {
            qWarning() << "Invalid widget type in get_text";
            lua_pushnil(L);
            return 1;
        }

        lua_pushstring(L, text.toUtf8().constData());
    } else {
        qWarning() << "Invalid widget in get_text";
        lua_pushnil(L);
    }
    return 1;
}

int lua_get_checked(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);

    if (widget) {
        if (QCheckBox* checkbox = qobject_cast<QCheckBox*>(widget)) {
            lua_pushboolean(L, checkbox->isChecked());
        } else {
            qWarning() << "Invalid widget type in get_checked (expected QCheckBox)";
            lua_pushnil(L);
            return 1;
        }
    } else {
        qWarning() << "Invalid widget in get_checked";
        lua_pushnil(L);
    }
    return 1;
}

int lua_get_slider_value(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);

    if (widget) {
        if (QSlider* slider = qobject_cast<QSlider*>(widget)) {
            lua_pushinteger(L, slider->value());
        } else {
            qWarning() << "Invalid widget type in get_slider_value (expected QSlider)";
            lua_pushnil(L);
            return 1;
        }
    } else {
        qWarning() << "Invalid widget in get_slider_value";
        lua_pushnil(L);
    }
    return 1;
}

int lua_get_combobox_current_text(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);

    if (widget) {
        if (QComboBox* combobox = qobject_cast<QComboBox*>(widget)) {
            QString text = combobox->currentText();
            lua_pushstring(L, text.toUtf8().constData());
        } else {
            qWarning() << "Invalid widget type in get_combobox_current_text (expected QComboBox)";
            lua_pushnil(L);
            return 1;
        }
    } else {
        qWarning() << "Invalid widget in get_combobox_current_text";
        lua_pushnil(L);
    }
    return 1;
}

int lua_set_placeholder_text(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    const char* text = lua_tostring(L, 2);

    if (widget && text) {
        if (QLineEdit* lineEdit = qobject_cast<QLineEdit*>(widget)) {
            lineEdit->setPlaceholderText(QString::fromUtf8(text));
        }
        
        lua_pushboolean(L, 1);
    } else {
        qWarning() << "Invalid widget or text in set_placeholder_text";
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_set_window_title(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    const char* title = lua_tostring(L, 2);
    
    if (widget && title) {
        // qDebug() << "Setting window title from Lua:" << title;
        widget->setWindowTitle(QString::fromUtf8(title));
        lua_pushboolean(L, 1);
    } else {
        qWarning() << "Invalid widget or title in set_window_title";
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_set_size(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    int width = lua_tointeger(L, 2);
    int height = lua_tointeger(L, 3);

    if (widget && width > 0 && height > 0) {
        // qDebug() << "Setting size from Lua:" << width << "x" << height;
        widget->resize(width, height);
        lua_pushboolean(L, 1);
    } else {
        qWarning() << "Invalid widget or size in set_size";
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_get_widget_size(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);

    if (widget) {
        lua_pushinteger(L, widget->width());
        lua_pushinteger(L, widget->height());
        return 2;
    } else {
        lua_pushinteger(L, 0);
        lua_pushinteger(L, 0);
        return 2;
    }
}

int lua_get_geometry(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);

    if (widget) {
        QRect geom = widget->geometry();
        lua_pushinteger(L, geom.x());
        lua_pushinteger(L, geom.y());
        lua_pushinteger(L, geom.width());
        lua_pushinteger(L, geom.height());
        return 4;
    } else {
        lua_pushinteger(L, 0);
        lua_pushinteger(L, 0);
        lua_pushinteger(L, 0);
        lua_pushinteger(L, 0);
        return 4;
    }
}

int lua_set_minimum_width(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    int width = lua_tointeger(L, 2);

    if (widget) {
        widget->setMinimumWidth(width);
        lua_pushboolean(L, 1);
    } else {
        qWarning() << "Invalid widget in set_minimum_width";
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_set_maximum_width(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    int width = lua_tointeger(L, 2);

    if (widget) {
        widget->setMaximumWidth(width);
        lua_pushboolean(L, 1);
    } else {
        qWarning() << "Invalid widget in set_maximum_width";
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_set_minimum_height(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    int height = lua_tointeger(L, 2);

    if (widget) {
        widget->setMinimumHeight(height);
        lua_pushboolean(L, 1);
    } else {
        qWarning() << "Invalid widget in set_minimum_height";
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_set_maximum_height(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    int height = lua_tointeger(L, 2);

    if (widget) {
        widget->setMaximumHeight(height);
        lua_pushboolean(L, 1);
    } else {
        qWarning() << "Invalid widget in set_maximum_height";
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_set_geometry(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    int x = lua_tointeger(L, 2);
    int y = lua_tointeger(L, 3);
    int width = lua_tointeger(L, 4);
    int height = lua_tointeger(L, 5);

    if (widget) {
        widget->setGeometry(x, y, width, height);
        lua_pushboolean(L, 1);
    } else {
        qWarning() << "Invalid widget in set_geometry";
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_set_style_sheet(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    const char* style = lua_tostring(L, 2);
    
    if (widget && style) {
        // qDebug() << "Setting style sheet from Lua:" << style;
        widget->setStyleSheet(QString::fromUtf8(style));
        lua_pushboolean(L, 1);
    } else {
        qWarning() << "Invalid widget or style in set_style_sheet";
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_set_window_appearance(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    const char* appearance_name = luaL_optstring(L, 2, "NSAppearanceNameDarkAqua");

    if (!widget) {
        qWarning() << "Invalid widget in set_window_appearance";
        lua_pushboolean(L, 0);
        return 1;
    }

#ifdef Q_OS_MAC
    if (!widget->windowHandle()) {
        widget->createWinId();
    }
    id nsWindow = nil;
    id cocoaView = (id)widget->winId();
    if (cocoaView) {
        nsWindow = ((id (*)(id, SEL))objc_msgSend)(cocoaView, sel_getUid("window"));
    }
    if (nsWindow) {
        id appearanceString = qt_nsstring_from_utf8(appearance_name);
        if (!appearanceString) {
            appearanceString = qt_nsstring_from_utf8("NSAppearanceNameDarkAqua");
        }
        Class NSAppearanceClass = objc_getClass("NSAppearance");
        SEL appearanceNamedSel = sel_getUid("appearanceNamed:");
        id nsAppearance = nil;
        if (NSAppearanceClass && appearanceString) {
            nsAppearance = ((id (*)(Class, SEL, id))objc_msgSend)(NSAppearanceClass, appearanceNamedSel, appearanceString);
        }
        if (nsAppearance) {
            SEL setAppearanceSel = sel_getUid("setAppearance:");
            ((void (*)(id, SEL, id))objc_msgSend)(nsWindow, setAppearanceSel, nsAppearance);
            lua_pushboolean(L, 1);
            return 1;
        }
    }
#else
    Q_UNUSED(appearance_name);
#endif

    lua_pushboolean(L, 0);
    return 1;
}

// Display functions
int lua_show_widget(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    
    if (widget) {
        // qDebug() << "Showing widget from Lua";
        widget->show();
        lua_pushboolean(L, 1);
    } else {
        qWarning() << "Invalid widget in show_widget";
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_set_visible(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    bool visible = lua_toboolean(L, 2);
    
    if (widget) {
        // qDebug() << "Setting widget visibility from Lua:" << visible;
        widget->setVisible(visible);
        lua_pushboolean(L, 1);
    } else {
        qWarning() << "Invalid widget in set_visible";
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_raise_widget(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    
    if (widget) {
        // qDebug() << "Raising widget from Lua";
        widget->raise();
        lua_pushboolean(L, 1);
    } else {
        qWarning() << "Invalid widget in raise_widget";
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_activate_window(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    
    if (widget) {
        // qDebug() << "Activating window from Lua";
        widget->activateWindow();
        lua_pushboolean(L, 1);
    } else {
        qWarning() << "Invalid widget in activate_window";
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_set_scroll_area_widget(lua_State* L)
{
    QWidget* scrollArea = (QWidget*)lua_to_widget(L, 1);
    QWidget* contentWidget = (QWidget*)lua_to_widget(L, 2);

    if (scrollArea && contentWidget) {
        QScrollArea* sa = qobject_cast<QScrollArea*>(scrollArea);
        if (sa) {
            // qDebug() << "Setting scroll area widget from Lua";
            sa->setWidget(contentWidget);
            lua_pushboolean(L, 1);
        } else {
            qWarning() << "First argument is not a QScrollArea";
            lua_pushboolean(L, 0);
        }
    } else {
        qWarning() << "Invalid widget arguments in set_scroll_area_widget";
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_set_scroll_area_viewport_margins(lua_State* L)
{
    QWidget* scrollArea = (QWidget*)lua_to_widget(L, 1);
    int left = lua_tointeger(L, 2);
    int top = lua_tointeger(L, 3);
    int right = lua_tointeger(L, 4);
    int bottom = lua_tointeger(L, 5);

    if (scrollArea) {
        QScrollArea* sa = qobject_cast<QScrollArea*>(scrollArea);
        if (sa) {
            // qDebug() << "Setting scroll area content margins from Lua:" << left << top << right << bottom;
            // setViewportMargins is protected, so we set margins on the content widget's layout instead
            QWidget* widget = sa->widget();
            if (widget && widget->layout()) {
                widget->layout()->setContentsMargins(left, top, right, bottom);
                lua_pushboolean(L, 1);
            } else {
                qWarning() << "Scroll area has no widget or widget has no layout";
                lua_pushboolean(L, 0);
            }
        } else {
            qWarning() << "First argument is not a QScrollArea";
            lua_pushboolean(L, 0);
        }
    } else {
        qWarning() << "Invalid widget argument in set_scroll_area_viewport_margins";
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_set_scroll_area_widget_resizable(lua_State* L)
{
    QWidget* scrollArea = (QWidget*)lua_to_widget(L, 1);
    bool resizable = lua_toboolean(L, 2);

    if (scrollArea) {
        QScrollArea* sa = qobject_cast<QScrollArea*>(scrollArea);
        if (sa) {
            sa->setWidgetResizable(resizable);
            lua_pushboolean(L, 1);
        } else {
            qWarning() << "First argument is not a QScrollArea";
            lua_pushboolean(L, 0);
        }
    } else {
        qWarning() << "Invalid widget argument in set_scroll_area_widget_resizable";
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_set_scroll_area_h_scrollbar_policy(lua_State* L)
{
    QWidget* scrollArea = (QWidget*)lua_to_widget(L, 1);
    const char* policy = luaL_checkstring(L, 2);

    if (scrollArea) {
        QScrollArea* sa = qobject_cast<QScrollArea*>(scrollArea);
        if (sa) {
            if (strcmp(policy, "AlwaysOff") == 0) {
                sa->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
            } else if (strcmp(policy, "AlwaysOn") == 0) {
                sa->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOn);
            } else if (strcmp(policy, "AsNeeded") == 0) {
                sa->setHorizontalScrollBarPolicy(Qt::ScrollBarAsNeeded);
            }
            lua_pushboolean(L, 1);
        } else {
            qWarning() << "First argument is not a QScrollArea";
            lua_pushboolean(L, 0);
        }
    } else {
        qWarning() << "Invalid widget argument in set_scroll_area_h_scrollbar_policy";
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_set_scroll_area_v_scrollbar_policy(lua_State* L)
{
    QWidget* scrollArea = (QWidget*)lua_to_widget(L, 1);
    const char* policy = luaL_checkstring(L, 2);

    if (scrollArea) {
        QScrollArea* sa = qobject_cast<QScrollArea*>(scrollArea);
        if (sa) {
            if (strcmp(policy, "AlwaysOff") == 0) {
                sa->setVerticalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
            } else if (strcmp(policy, "AlwaysOn") == 0) {
                sa->setVerticalScrollBarPolicy(Qt::ScrollBarAlwaysOn);
            } else if (strcmp(policy, "AsNeeded") == 0) {
                sa->setVerticalScrollBarPolicy(Qt::ScrollBarAsNeeded);
            }
            lua_pushboolean(L, 1);
        } else {
            qWarning() << "First argument is not a QScrollArea";
            lua_pushboolean(L, 0);
        }
    } else {
        qWarning() << "Invalid widget argument in set_scroll_area_v_scrollbar_policy";
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_set_scroll_area_alignment(lua_State* L)
{
    QWidget* scrollArea = (QWidget*)lua_to_widget(L, 1);
    const char* alignment_str = luaL_checkstring(L, 2);

    if (scrollArea) {
        QScrollArea* sa = qobject_cast<QScrollArea*>(scrollArea);
        if (sa) {
            Qt::Alignment alignment = Qt::AlignLeft | Qt::AlignTop;  // Default
            if (strcmp(alignment_str, "AlignBottom") == 0) {
                alignment = Qt::AlignLeft | Qt::AlignBottom;
            } else if (strcmp(alignment_str, "AlignTop") == 0) {
                alignment = Qt::AlignLeft | Qt::AlignTop;
            } else if (strcmp(alignment_str, "AlignVCenter") == 0) {
                alignment = Qt::AlignLeft | Qt::AlignVCenter;
            }
            sa->setAlignment(alignment);
            lua_pushboolean(L, 1);
        } else {
            qWarning() << "First argument is not a QScrollArea";
            lua_pushboolean(L, 0);
        }
    } else {
        qWarning() << "Invalid widget argument in set_scroll_area_alignment";
        lua_pushboolean(L, 0);
    }
    return 1;
}

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
                    // Before resize completes, calculate distance from bottom
                    int oldMax = vbar->maximum();
                    int oldValue = vbar->value();
                    distanceFromBottom = oldMax - oldValue;

                    // After resize, restore distance from bottom
                    QTimer::singleShot(0, [this, vbar]() {
                        int newMax = vbar->maximum();
                        int newValue = newMax - distanceFromBottom;
                        vbar->setValue(qMax(0, newValue));
                    });
                } else if (event->type() == QEvent::Wheel || event->type() == QEvent::MouseButtonPress) {
                    // User is scrolling - update our tracking
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

int lua_set_scroll_area_anchor_bottom(lua_State* L)
{
    QWidget* scrollArea = (QWidget*)lua_to_widget(L, 1);
    bool enable = lua_toboolean(L, 2);

    if (scrollArea) {
        QScrollArea* sa = qobject_cast<QScrollArea*>(scrollArea);
        if (sa) {
            if (enable) {
                BottomAnchorFilter* filter = new BottomAnchorFilter(sa);
                sa->viewport()->installEventFilter(filter);
                // Set initial scroll position to bottom
                QScrollBar* vbar = sa->verticalScrollBar();
                if (vbar) {
                    vbar->setValue(vbar->maximum());
                }
            }
            lua_pushboolean(L, 1);
        } else {
            qWarning() << "First argument is not a QScrollArea";
            lua_pushboolean(L, 0);
        }
    } else {
        qWarning() << "Invalid widget argument in set_scroll_area_anchor_bottom";
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_set_focus_policy(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    const char* policy = luaL_checkstring(L, 2);

    if (widget) {
        Qt::FocusPolicy fp = Qt::NoFocus;
        if (strcmp(policy, "StrongFocus") == 0) {
            fp = Qt::StrongFocus;
        } else if (strcmp(policy, "ClickFocus") == 0) {
            fp = Qt::ClickFocus;
        } else if (strcmp(policy, "TabFocus") == 0) {
            fp = Qt::TabFocus;
        } else if (strcmp(policy, "WheelFocus") == 0) {
            fp = Qt::WheelFocus;
        } else if (strcmp(policy, "NoFocus") == 0) {
            fp = Qt::NoFocus;
        }
        widget->setFocusPolicy(fp);
        lua_pushboolean(L, 1);
    } else {
        qWarning() << "Invalid widget argument in set_focus_policy";
        lua_pushboolean(L, 0);
    }
    return 1;
}

// Set keyboard focus to a widget
int lua_set_focus(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);

    if (widget) {
        widget->setFocus(Qt::OtherFocusReason);
        lua_pushboolean(L, 1);
    } else {
        qWarning() << "Invalid widget argument in set_focus";
        lua_pushboolean(L, 0);
    }
    return 1;
}

// Global key event filter class
static bool widget_accepts_text_input(QWidget* widget)
{
    if (!widget) {
        return false;
    }

    QWidget* current = widget;
    int guard = 0;
    while (current && guard < 8) {
        if (current->inherits("QLineEdit") ||
            current->inherits("QTextEdit") ||
            current->inherits("QPlainTextEdit") ||
            current->inherits("QSpinBox") ||
            current->inherits("QDoubleSpinBox") ||
            current->inherits("QAbstractSpinBox") ||
            current->inherits("QComboBox")) {
            return true;
        }

        QWidget* proxy = current->focusProxy();
        if (proxy && proxy != current) {
            current = proxy;
        } else {
            current = current->parentWidget();
        }
        ++guard;
    }

    return false;
}

class GlobalKeyFilter : public QObject
{
public:
    GlobalKeyFilter(lua_State* L, const std::string& handler)
        : QObject(), lua_state(L), handler_name(handler) {}

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
    FocusEventFilter(lua_State* L, const std::string& handler, QWidget* widget)
        : QObject(widget), lua_state(L), handler_name(handler), tracked_widget(widget) {}

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
    QWidget* tracked_widget;
};

int lua_set_global_key_handler(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);  // Still passed but not used for filter installation
    const char* handler_name = luaL_checkstring(L, 2);

    if (widget) {
        GlobalKeyFilter* filter = new GlobalKeyFilter(L, handler_name);
        // Install filter on QApplication to intercept ALL key events globally
        // This ensures shortcuts work regardless of which widget has focus
        QCoreApplication::instance()->installEventFilter(filter);
        lua_pushboolean(L, 1);
    } else {
        qWarning() << "Invalid widget argument in set_global_key_handler";
        lua_pushboolean(L, 0);
    }
    return 1;
}

// Install focus event filter on a widget
// Args: widget, handler_name (Lua function name in global scope)
// Handler receives: {focus_in: bool, widget: userdata}
int lua_set_focus_handler(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    const char* handler_name = luaL_checkstring(L, 2);

    if (widget) {
        std::string handler(handler_name);
        FocusEventFilter* filter = new FocusEventFilter(L, handler, widget);
        widget->installEventFilter(filter);

        // Make sure widget can receive focus
        widget->setFocusPolicy(Qt::StrongFocus);

        lua_pushboolean(L, 1);
    } else {
        qWarning() << "Invalid widget argument in set_focus_handler";
        lua_pushboolean(L, 0);
    }
    return 1;
}

// Hide a splitter handle at a specific index
int lua_hide_splitter_handle(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    int index = luaL_checkinteger(L, 2);

    if (!widget) {
        qWarning() << "Invalid widget in hide_splitter_handle";
        lua_pushboolean(L, 0);
        return 1;
    }

    QSplitter* splitter = qobject_cast<QSplitter*>(widget);
    if (!splitter) {
        qWarning() << "Widget is not a QSplitter";
        lua_pushboolean(L, 0);
        return 1;
    }

    QSplitterHandle* handle = splitter->handle(index);
    if (handle) {
        handle->setEnabled(false);
        handle->setVisible(false);
        lua_pushboolean(L, 1);
    } else {
        qWarning() << "Splitter handle at index" << index << "not found";
        lua_pushboolean(L, 0);
    }
    return 1;
}

// Splitter moved signal handler
int lua_set_splitter_moved_handler(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    const char* handler_name = lua_tostring(L, 2);

    if (!widget || !handler_name) {
        qWarning() << "Invalid arguments in set_splitter_moved_handler";
        lua_pushboolean(L, 0);
        return 1;
    }

    QSplitter* splitter = qobject_cast<QSplitter*>(widget);
    if (!splitter) {
        qWarning() << "Widget is not a QSplitter";
        lua_pushboolean(L, 0);
        return 1;
    }

    std::string handler_str = std::string(handler_name);

    // Connect Qt splitterMoved signal to Lua function call
    QObject::connect(splitter, &QSplitter::splitterMoved, [L, handler_str](int pos, int index) {
        // Call the Lua handler function with position and index
        lua_getglobal(L, handler_str.c_str());
        if (lua_isfunction(L, -1)) {
            lua_pushinteger(L, pos);
            lua_pushinteger(L, index);
            int result = lua_pcall(L, 2, 0, 0);
            if (result != 0) {
                qWarning() << "Error calling Lua splitter moved handler:" << lua_tostring(L, -1);
                lua_pop(L, 1);
            }
        } else {
            qWarning() << "Lua splitter moved handler not found:" << handler_str.c_str();
            lua_pop(L, 1);
        }
    });

    lua_pushboolean(L, 1);
    return 1;
}

int lua_set_tree_close_editor_handler(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    const char* handler_name = luaL_checkstring(L, 2);

    if (!widget) {
        qWarning() << "Invalid tree widget in set_tree_close_editor_handler";
        lua_pushboolean(L, 0);
        return 1;
    }

    QTreeWidget* tree = qobject_cast<QTreeWidget*>(widget);
    if (!tree) {
        qWarning() << "Widget is not a QTreeWidget in set_tree_close_editor_handler";
        lua_pushboolean(L, 0);
        return 1;
    }

    std::string handler(handler_name);
    QAbstractItemDelegate* delegate = tree->itemDelegate();
    if (!delegate) {
        qWarning() << "Tree widget has no item delegate in set_tree_close_editor_handler";
        lua_pushboolean(L, 0);
        return 1;
    }

    QObject::connect(delegate, &QAbstractItemDelegate::closeEditor,
        tree, [tree, L, handler](QWidget*, QAbstractItemDelegate::EndEditHint hint) {
            lua_getglobal(L, handler.c_str());
            if (!lua_isfunction(L, -1)) {
                lua_pop(L, 1);
                return;
            }

            lua_newtable(L);

            QTreeWidgetItem* item = tree->currentItem();
            if (!item) {
                QModelIndex idx = tree->currentIndex();
                if (idx.isValid()) {
                    item = tree->itemFromIndex(idx);
                }
            }
            if (!item) {
                QList<QTreeWidgetItem*> selected = tree->selectedItems();
                if (!selected.isEmpty()) {
                    item = selected.first();
                }
            }

            if (item) {
                lua_pushstring(L, "item_id");
                lua_pushinteger(L, makeTreeItemId(item));
                lua_settable(L, -3);

                lua_pushstring(L, "text");
                QByteArray bytes = item->text(0).toUtf8();
                lua_pushlstring(L, bytes.constData(), bytes.size());
                lua_settable(L, -3);
            }

            lua_pushstring(L, "hint");
            lua_pushinteger(L, static_cast<int>(hint));
            lua_settable(L, -3);

            bool accepted = hint != QAbstractItemDelegate::RevertModelCache;
            lua_pushstring(L, "accepted");
            lua_pushboolean(L, accepted);
            lua_settable(L, -3);

            if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
                qWarning() << "Error calling Lua tree close editor handler:" << lua_tostring(L, -1);
                lua_pop(L, 1);
            }
        });

    lua_pushboolean(L, 1);
    return 1;
}

// Signal handling functions
int lua_set_button_click_handler(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    const char* handler_name = lua_tostring(L, 2);
    
    if (!widget || !handler_name) {
        qWarning() << "Invalid arguments in set_button_click_handler";
        lua_pushboolean(L, 0);
        return 1;
    }
    
    QAbstractButton* button = qobject_cast<QAbstractButton*>(widget);
    if (!button) {
        qWarning() << "Widget is not a QAbstractButton";
        lua_pushboolean(L, 0);
        return 1;
    }
    
    std::string handler_str = std::string(handler_name);
    
    // Connect Qt clicked signal to Lua function call
    QObject::connect(button, &QAbstractButton::clicked, [L, handler_str]() {
        // Call the Lua handler function
        lua_getglobal(L, handler_str.c_str());
        if (lua_isfunction(L, -1)) {
            int result = lua_pcall(L, 0, 0, 0);
            if (result != 0) {
                qWarning() << "Error calling Lua click handler:" << lua_tostring(L, -1);
                lua_pop(L, 1);
            }
        } else {
            qWarning() << "Lua click handler not found:" << handler_str.c_str();
            lua_pop(L, 1);
        }
    });
    
    // // qDebug() << "Button click handler connected for:" << handler_name;
    lua_pushboolean(L, 1);
    return 1;
}

// Event filter class for widget clicks
class ClickEventFilter : public QObject {
public:
    ClickEventFilter(const std::string& handler, lua_State* L, QObject* parent = nullptr)
        : QObject(parent), handler_name(handler), lua_state(L) {}

protected:
    bool eventFilter(QObject* obj, QEvent* event) override {
        // Log first 20 events for each filter to debug handle 0
        static QMap<QString, int> event_counts;
        QString key = QString::fromStdString(handler_name);
        if (!event_counts.contains(key)) event_counts[key] = 0;

        // if (event_counts[key] < 20) {
        //     qDebug() << "ClickEventFilter[" << key << "]: event" << event->type() << "obj=" << obj << "count=" << event_counts[key]++;
        // }

        if (event->type() == QEvent::MouseButtonPress || event->type() == QEvent::MouseButtonRelease) {
            QMouseEvent* mouseEvent = static_cast<QMouseEvent*>(event);
            if (mouseEvent->button() == Qt::LeftButton) {
                // qDebug() << "ClickEventFilter[" << key << "]: Mouse" << (event->type() == QEvent::MouseButtonPress ? "PRESS" : "RELEASE") << "at y=" << mouseEvent->pos().y();

                // Call the Lua handler function with event type and position
                lua_getglobal(lua_state, handler_name.c_str());
                if (lua_isfunction(lua_state, -1)) {
                    // Push event type ("press" or "release")
                    if (event->type() == QEvent::MouseButtonPress) {
                        lua_pushstring(lua_state, "press");
                    } else {
                        lua_pushstring(lua_state, "release");
                    }
                    // Push Y position
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
                // Don't return true - let the event propagate so splitter can handle the drag
                return false;
            }
        }
        return QObject::eventFilter(obj, event);
    }

private:
    std::string handler_name;
    lua_State* lua_state;
};

int lua_set_widget_click_handler(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    const char* handler_name = lua_tostring(L, 2);

    if (!widget || !handler_name) {
        qWarning() << "Invalid arguments in set_widget_click_handler";
        lua_pushboolean(L, 0);
        return 1;
    }

    std::string handler_str = std::string(handler_name);

    // Create and install event filter
    // qDebug() << "qt_set_widget_click_handler: widget=" << widget << "handler=" << QString::fromStdString(handler_str);
    // qDebug() << "  -> geometry=" << widget->geometry() << "visible=" << widget->isVisible() << "enabled=" << widget->isEnabled();
    ClickEventFilter* filter = new ClickEventFilter(handler_str, L, widget);
    widget->installEventFilter(filter);
    // qDebug() << "  -> Event filter installed on widget" << widget;

    lua_pushboolean(L, 1);
    return 1;
}

int lua_set_context_menu_handler(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    const char* handler_name = lua_tostring(L, 2);

    if (!widget || !handler_name) {
        qWarning() << "Invalid arguments in set_context_menu_handler";
        lua_pushboolean(L, 0);
        return 1;
    }

    widget->setContextMenuPolicy(Qt::CustomContextMenu);
    std::string handler_str(handler_name);

    QObject::connect(widget, &QWidget::customContextMenuRequested,
        [widget, L, handler_str](const QPoint& pos) {
            lua_getglobal(L, handler_str.c_str());
            if (!lua_isfunction(L, -1)) {
                lua_pop(L, 1);
                return;
            }

            lua_newtable(L);
            lua_pushstring(L, "x");
            lua_pushinteger(L, pos.x());
            lua_settable(L, -3);
            lua_pushstring(L, "y");
            lua_pushinteger(L, pos.y());
            lua_settable(L, -3);

            QPoint global_pos = widget->mapToGlobal(pos);
            lua_pushstring(L, "global_x");
            lua_pushinteger(L, global_pos.x());
            lua_settable(L, -3);
            lua_pushstring(L, "global_y");
            lua_pushinteger(L, global_pos.y());
            lua_settable(L, -3);

            if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
                qWarning() << "Error calling Lua context menu handler:" << lua_tostring(L, -1);
                lua_pop(L, 1);
            }
        });

    lua_pushboolean(L, 1);
    return 1;
}

// Layout styling functions
int lua_set_layout_spacing(lua_State* L)
{
    QLayout* layout = (QLayout*)lua_to_widget(L, 1);
    int spacing = lua_tointeger(L, 2);
    
    if (layout) {
        // qDebug() << "Setting layout spacing from Lua:" << spacing;
        layout->setSpacing(spacing);
        lua_pushboolean(L, 1);
    } else {
        qWarning() << "Invalid layout in set_layout_spacing";
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_set_layout_margins(lua_State* L)
{
    QLayout* layout = (QLayout*)lua_to_widget(L, 1);

    if (!layout) {
        qWarning() << "Invalid layout in set_layout_margins";
        lua_pushboolean(L, 0);
        return 1;
    }

    int num_args = lua_gettop(L);

    if (num_args == 2) {
        // Uniform margins (all sides equal)
        int margins = lua_tointeger(L, 2);
        // qDebug() << "Setting layout margins from Lua:" << margins;
        layout->setContentsMargins(margins, margins, margins, margins);
    } else if (num_args == 5) {
        // Asymmetric margins (left, top, right, bottom)
        int left = lua_tointeger(L, 2);
        int top = lua_tointeger(L, 3);
        int right = lua_tointeger(L, 4);
        int bottom = lua_tointeger(L, 5);
        // qDebug() << "Setting layout margins from Lua (LTRB):" << left << top << right << bottom;
        layout->setContentsMargins(left, top, right, bottom);
    } else {
        qWarning() << "Invalid number of arguments in set_layout_margins (expected 2 or 5, got" << num_args << ")";
        lua_pushboolean(L, 0);
        return 1;
    }

    lua_pushboolean(L, 1);
    return 1;
}

int qt_set_layout_alignment(lua_State* L)
{
    QLayout* layout = (QLayout*)lua_to_widget(L, 1);
    const char* alignment_str = lua_tostring(L, 2);

    if (layout && alignment_str) {
        // qDebug() << "Setting layout alignment from Lua:" << alignment_str;

        Qt::Alignment alignment;
        if (strcmp(alignment_str, "AlignTop") == 0) {
            alignment = Qt::AlignTop;
        } else if (strcmp(alignment_str, "AlignBottom") == 0) {
            alignment = Qt::AlignBottom;
        } else if (strcmp(alignment_str, "AlignLeft") == 0) {
            alignment = Qt::AlignLeft;
        } else if (strcmp(alignment_str, "AlignRight") == 0) {
            alignment = Qt::AlignRight;
        } else if (strcmp(alignment_str, "AlignCenter") == 0) {
            alignment = Qt::AlignCenter;
        } else if (strcmp(alignment_str, "AlignVCenter") == 0) {
            alignment = Qt::AlignVCenter;
        } else {
            qWarning() << "Invalid alignment:" << alignment_str;
            lua_pushboolean(L, 0);
            return 1;
        }

        layout->setAlignment(alignment);
        lua_pushboolean(L, 1);
    } else {
        qWarning() << "Invalid layout or alignment in qt_set_layout_alignment";
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_set_widget_size_policy(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    const char* horizontal = lua_tostring(L, 2);
    const char* vertical = lua_tostring(L, 3);

    if (widget && horizontal && vertical) {
        QSizePolicy::Policy hPolicy = QSizePolicy::Preferred;
        QSizePolicy::Policy vPolicy = QSizePolicy::Preferred;

        // Convert string to size policy (case-insensitive)
        if (strcasecmp(horizontal, "expanding") == 0) hPolicy = QSizePolicy::Expanding;
        else if (strcasecmp(horizontal, "fixed") == 0) hPolicy = QSizePolicy::Fixed;
        else if (strcasecmp(horizontal, "minimum") == 0) hPolicy = QSizePolicy::Minimum;
        else if (strcasecmp(horizontal, "maximum") == 0) hPolicy = QSizePolicy::Maximum;
        else if (strcasecmp(horizontal, "ignored") == 0) hPolicy = QSizePolicy::Ignored;

        if (strcasecmp(vertical, "expanding") == 0) vPolicy = QSizePolicy::Expanding;
        else if (strcasecmp(vertical, "fixed") == 0) vPolicy = QSizePolicy::Fixed;
        else if (strcasecmp(vertical, "minimum") == 0) vPolicy = QSizePolicy::Minimum;
        else if (strcasecmp(vertical, "maximum") == 0) vPolicy = QSizePolicy::Maximum;
        else if (strcasecmp(vertical, "ignored") == 0) vPolicy = QSizePolicy::Ignored;

        // qDebug() << "Setting size policy:" << horizontal << "->" << hPolicy << "," << vertical << "->" << vPolicy << "on widget" << widget;
        widget->setSizePolicy(hPolicy, vPolicy);
        lua_pushboolean(L, 1);
    } else {
        qWarning() << "Invalid widget or size policy arguments";
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_set_layout_stretch_factor(lua_State* L)
{
    QLayout* layout = (QLayout*)lua_to_widget(L, 1);
    QWidget* widget = (QWidget*)lua_to_widget(L, 2);
    int stretch = lua_tointeger(L, 3);
    
    if (layout && widget) {
        // qDebug() << "Setting layout stretch factor from Lua:" << stretch;

        // Try casting to different layout types
        if (QHBoxLayout* hbox = qobject_cast<QHBoxLayout*>(layout)) {
            hbox->setStretchFactor(widget, stretch);
            lua_pushboolean(L, 1);
        } else if (QVBoxLayout* vbox = qobject_cast<QVBoxLayout*>(layout)) {
            vbox->setStretchFactor(widget, stretch);
            lua_pushboolean(L, 1);
        } else {
            qWarning() << "Unsupported layout type for stretch factor";
            lua_pushboolean(L, 0);
        }
    } else {
        qWarning() << "Invalid layout or widget in set_layout_stretch_factor";
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_set_widget_alignment(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    const char* alignment = lua_tostring(L, 2);

    if (widget && alignment) {
        // qDebug() << "Setting widget alignment from Lua:" << alignment;

        Qt::Alignment align = Qt::AlignLeft;
        if (strcmp(alignment, "AlignRight") == 0) {
            align = Qt::AlignRight;
        } else if (strcmp(alignment, "AlignCenter") == 0) {
            align = Qt::AlignCenter;
        } else if (strcmp(alignment, "AlignLeft") == 0) {
            align = Qt::AlignLeft;
        }

        // Try to set alignment based on widget type
        if (QLabel* label = qobject_cast<QLabel*>(widget)) {
            label->setAlignment(align);
            lua_pushboolean(L, 1);
        } else {
            qWarning() << "Widget type doesn't support alignment:" << widget->metaObject()->className();
            lua_pushboolean(L, 0);
        }
    } else {
        qWarning() << "Invalid widget or alignment in set_widget_alignment";
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_set_parent(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    QWidget* parent = (QWidget*)lua_to_widget(L, 2);

    if (widget && parent) {
        widget->setParent(parent);
        lua_pushboolean(L, 1);
    } else {
        qWarning() << "Invalid widget or parent in set_parent";
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_set_widget_attribute(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    if (!widget) {
        qWarning() << "Invalid widget in set_widget_attribute";
        lua_pushboolean(L, 0);
        return 1;
    }

    const char* attr_name = luaL_checkstring(L, 2);
    bool value = lua_toboolean(L, 3);

    // Map attribute name to Qt::WidgetAttribute enum
    Qt::WidgetAttribute attr;
    if (strcmp(attr_name, "WA_TransparentForMouseEvents") == 0) {
        attr = Qt::WA_TransparentForMouseEvents;
    } else if (strcmp(attr_name, "WA_Hover") == 0) {
        attr = Qt::WA_Hover;
    } else if (strcmp(attr_name, "WA_StyledBackground") == 0) {
        attr = Qt::WA_StyledBackground;
    } else {
        qWarning() << "Unknown widget attribute:" << attr_name;
        lua_pushboolean(L, 0);
        return 1;
    }

    widget->setAttribute(attr, value);
    lua_pushboolean(L, 1);
    return 1;
}

int lua_set_object_name(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    const char* name = lua_tostring(L, 2);

    if (!widget || !name) {
        qWarning() << "Invalid arguments in set_object_name";
        lua_pushboolean(L, 0);
        return 1;
    }

    widget->setObjectName(QString::fromUtf8(name));
    lua_pushboolean(L, 1);
    return 1;
}

// Tree widget functions
int lua_set_tree_headers(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);

    if (!widget) {
        qWarning() << "Invalid tree widget in set_tree_headers";
        lua_pushboolean(L, 0);
        return 1;
    }

    QTreeWidget* tree = qobject_cast<QTreeWidget*>(widget);
    if (!tree) {
        qWarning() << "Widget is not a QTreeWidget in set_tree_headers";
        lua_pushboolean(L, 0);
        return 1;
    }

    if (!lua_istable(L, 2)) {
        qWarning() << "Expected table for tree headers";
        lua_pushboolean(L, 0);
        return 1;
    }

    QStringList headers;
    int len = lua_objlen(L, 2);
    for (int i = 1; i <= len; i++) {
        lua_rawgeti(L, 2, i);
        if (lua_isstring(L, -1)) {
            headers.append(QString::fromUtf8(lua_tostring(L, -1)));
        }
        lua_pop(L, 1);
    }

    // // qDebug() << "Setting tree headers from Lua:" << headers;
    tree->setColumnCount(headers.size());
    tree->setHeaderLabels(headers);
    lua_pushboolean(L, 1);
    return 1;
}

int lua_set_tree_column_width(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    int column = lua_tointeger(L, 2);
    int width = lua_tointeger(L, 3);

    if (!widget) {
        qWarning() << "Invalid tree widget in set_tree_column_width";
        lua_pushboolean(L, 0);
        return 1;
    }

    QTreeWidget* tree = qobject_cast<QTreeWidget*>(widget);
    if (!tree) {
        qWarning() << "Widget is not a QTreeWidget in set_tree_column_width";
        lua_pushboolean(L, 0);
        return 1;
    }

    // // qDebug() << "Setting tree column width from Lua: column" << column << "width" << width;
    tree->setColumnWidth(column, width);
    lua_pushboolean(L, 1);
    return 1;
}

int lua_set_tree_indentation(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    int indentation = lua_tointeger(L, 2);

    if (!widget) {
        qWarning() << "Invalid tree widget in set_tree_indentation";
        lua_pushboolean(L, 0);
        return 1;
    }

    QTreeWidget* tree = qobject_cast<QTreeWidget*>(widget);
    if (!tree) {
        qWarning() << "Widget is not a QTreeWidget in set_tree_indentation";
        lua_pushboolean(L, 0);
        return 1;
    }

    // // qDebug() << "Setting tree indentation from Lua:" << indentation;
    tree->setIndentation(indentation);
    lua_pushboolean(L, 1);
    return 1;
}

int lua_set_tree_expands_on_double_click(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    bool enabled = lua_toboolean(L, 2);

    if (!widget) {
        qWarning() << "Invalid tree widget in set_tree_expands_on_double_click";
        lua_pushboolean(L, 0);
        return 1;
    }

    QTreeWidget* tree = qobject_cast<QTreeWidget*>(widget);
    if (!tree) {
        qWarning() << "Widget is not a QTreeWidget in set_tree_expands_on_double_click";
        lua_pushboolean(L, 0);
        return 1;
    }

    tree->setExpandsOnDoubleClick(enabled);
    lua_pushboolean(L, 1);
    return 1;
}

static QHash<qulonglong, QTreeWidgetItem*> g_treeItemMap;
static QHash<QTreeWidgetItem*, qulonglong> g_treeItemReverseMap;
static qulonglong g_nextTreeItemId = 1;

int lua_add_tree_item(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);

    if (!widget) {
        qWarning() << "Invalid tree widget in add_tree_item";
        lua_pushinteger(L, -1);
        return 1;
    }

    QTreeWidget* tree = qobject_cast<QTreeWidget*>(widget);
    if (!tree) {
        qWarning() << "Widget is not a QTreeWidget in add_tree_item";
        lua_pushinteger(L, -1);
        return 1;
    }

    if (!lua_istable(L, 2)) {
        qWarning() << "Expected table for tree item values";
        lua_pushinteger(L, -1);
        return 1;
    }

    QStringList values;
    int len = lua_objlen(L, 2);
    for (int i = 1; i <= len; i++) {
        lua_rawgeti(L, 2, i);
        if (lua_isstring(L, -1)) {
            values.append(QString::fromUtf8(lua_tostring(L, -1)));
        } else {
            values.append("");
        }
        lua_pop(L, 1);
    }

    // // qDebug() << "Adding tree item from Lua:" << values;
    QTreeWidgetItem* item = new QTreeWidgetItem(tree, values);
    tree->addTopLevelItem(item);
    lua_Integer assigned_id = makeTreeItemId(item);

    // Set up auto-updating triangles and click-to-expand for items with children
    // Connect signals only once per tree widget
    static QSet<QTreeWidget*> connectedTrees;
    if (!connectedTrees.contains(tree)) {
        // Update triangle on expand/collapse
        QObject::connect(tree, &QTreeWidget::itemExpanded, [](QTreeWidgetItem* expandedItem) {
            QString text = expandedItem->text(0);
            text.replace(QString::fromUtf8("▶"), QString::fromUtf8("▼"));
            expandedItem->setText(0, text);
        });
        QObject::connect(tree, &QTreeWidget::itemCollapsed, [](QTreeWidgetItem* collapsedItem) {
            QString text = collapsedItem->text(0);
            text.replace(QString::fromUtf8("▼"), QString::fromUtf8("▶"));
            collapsedItem->setText(0, text);
        });

        connectedTrees.insert(tree);
    }

    // Return the index of the added item
    lua_pushinteger(L, assigned_id);
    return 1;
}

static lua_Integer makeTreeItemId(QTreeWidgetItem* item)
{
    if (!item) {
        return -1;
    }

    if (g_treeItemReverseMap.contains(item)) {
        return static_cast<lua_Integer>(g_treeItemReverseMap.value(item));
    }

    qulonglong id = g_nextTreeItemId++;
    g_treeItemMap.insert(id, item);
    g_treeItemReverseMap.insert(item, id);
    return static_cast<lua_Integer>(id);
}

static QTreeWidgetItem* getTreeItemById(QTreeWidget* tree, lua_Integer item_id)
{
    Q_UNUSED(tree);
    if (item_id <= 0) {
        return nullptr;
    }
    return g_treeItemMap.value(static_cast<qulonglong>(item_id), nullptr);
}

static void removeTreeItemFromMap(QTreeWidgetItem* item)
{
    if (!item) {
        return;
    }

    if (g_treeItemReverseMap.contains(item)) {
        qulonglong id = g_treeItemReverseMap.take(item);
        g_treeItemMap.remove(id);
    }
    const int childCount = item->childCount();
    for (int i = 0; i < childCount; ++i) {
        removeTreeItemFromMap(item->child(i));
    }
}


int lua_add_tree_child_item(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    lua_Integer parent_id = lua_tointeger(L, 2);

    if (!widget) {
        qWarning() << "Invalid tree widget in add_tree_child_item";
        lua_pushinteger(L, 0);
        return 1;
    }

    QTreeWidget* tree = qobject_cast<QTreeWidget*>(widget);
    if (!tree) {
        qWarning() << "Widget is not a QTreeWidget in add_tree_child_item";
        lua_pushinteger(L, 0);
        return 1;
    }

    QTreeWidgetItem* parent = getTreeItemById(tree, parent_id);

    if (!parent) {
        qWarning() << "Invalid parent ID in add_tree_child_item:" << parent_id;
        lua_pushinteger(L, 0);
        return 1;
    }

    if (!lua_istable(L, 3)) {
        qWarning() << "Expected table for tree item values";
        lua_pushboolean(L, 0);
        return 1;
    }

    QStringList values;
    int len = lua_objlen(L, 3);
    for (int i = 1; i <= len; i++) {
        lua_rawgeti(L, 3, i);
        if (lua_isstring(L, -1)) {
            values.append(QString::fromUtf8(lua_tostring(L, -1)));
        } else {
            values.append("");
        }
        lua_pop(L, 1);
    }

    // // qDebug() << "Adding tree child item from Lua:" << values << "to parent" << parent_id;
    QTreeWidgetItem* child = new QTreeWidgetItem(parent, values);
    parent->addChild(child);

    lua_pushinteger(L, makeTreeItemId(child));
    return 1;
}

int lua_get_tree_selected_index(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);

    if (!widget) {
        qWarning() << "Invalid tree widget in get_tree_selected_index";
        lua_pushinteger(L, -1);
        return 1;
    }

    QTreeWidget* tree = qobject_cast<QTreeWidget*>(widget);
    if (!tree) {
        qWarning() << "Widget is not a QTreeWidget in get_tree_selected_index";
        lua_pushinteger(L, -1);
        return 1;
    }

    QList<QTreeWidgetItem*> selected = tree->selectedItems();
    if (selected.isEmpty()) {
        lua_pushinteger(L, -1);
        return 1;
    }

    int index = tree->indexOfTopLevelItem(selected.first());
    // // qDebug() << "Getting tree selected index from Lua:" << index;
    lua_pushinteger(L, index);
    return 1;
}

int lua_clear_tree(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);

    if (!widget) {
        qWarning() << "Invalid tree widget in clear_tree";
        lua_pushboolean(L, 0);
        return 1;
    }

    QTreeWidget* tree = qobject_cast<QTreeWidget*>(widget);
    if (!tree) {
        qWarning() << "Widget is not a QTreeWidget in clear_tree";
        lua_pushboolean(L, 0);
        return 1;
    }

    const int topLevelCount = tree->topLevelItemCount();
    for (int i = 0; i < topLevelCount; ++i) {
        removeTreeItemFromMap(tree->topLevelItem(i));
    }

    // // qDebug() << "Clearing tree from Lua";
    tree->clear();
    lua_pushboolean(L, 1);
    return 1;
}

int lua_set_tree_item_expanded(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    int item_index = lua_tointeger(L, 2);
    bool expanded = lua_toboolean(L, 3);

    if (!widget) {
        qWarning() << "Invalid tree widget in set_tree_item_expanded";
        lua_pushboolean(L, 0);
        return 1;
    }

    QTreeWidget* tree = qobject_cast<QTreeWidget*>(widget);
    if (!tree) {
        qWarning() << "Widget is not a QTreeWidget in set_tree_item_expanded";
        lua_pushboolean(L, 0);
        return 1;
    }

    QTreeWidgetItem* item = getTreeItemById(tree, item_index);
    if (!item) {
        qWarning() << "Invalid item index in set_tree_item_expanded:" << item_index;
        lua_pushboolean(L, 0);
        return 1;
    }

    item->setExpanded(expanded);

    // Update the triangle character in the item text
    QString text = item->text(0);
    if (expanded) {
        // Change ▶ to ▼
        text.replace(QString::fromUtf8("▶"), QString::fromUtf8("▼"));
    } else {
        // Change ▼ to ▶
        text.replace(QString::fromUtf8("▼"), QString::fromUtf8("▶"));
    }
    item->setText(0, text);

    lua_pushboolean(L, 1);
    return 1;
}

int lua_is_tree_item_expanded(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    if (!widget) {
        qWarning() << "Invalid tree widget in is_tree_item_expanded";
        lua_pushboolean(L, 0);
        return 1;
    }

    QTreeWidget* tree = qobject_cast<QTreeWidget*>(widget);
    if (!tree) {
        qWarning() << "Widget is not a QTreeWidget in is_tree_item_expanded";
        lua_pushboolean(L, 0);
        return 1;
    }

    lua_Integer item_id = lua_tointeger(L, 2);
    QTreeWidgetItem* item = getTreeItemById(tree, item_id);
    if (!item) {
        lua_pushboolean(L, 0);
        return 1;
    }

    lua_pushboolean(L, item->isExpanded());
    return 1;
}

int lua_set_tree_item_data(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    lua_Integer item_id = luaL_checkinteger(L, 2);
    const char* value = luaL_checkstring(L, 3);

    if (!widget) {
        qWarning() << "Invalid tree widget in set_tree_item_data";
        lua_pushboolean(L, 0);
        return 1;
    }

    QTreeWidget* tree = qobject_cast<QTreeWidget*>(widget);
    if (!tree) {
        qWarning() << "Widget is not a QTreeWidget in set_tree_item_data";
        lua_pushboolean(L, 0);
        return 1;
    }

    QTreeWidgetItem* item = getTreeItemById(tree, item_id);
    if (!item) {
        qWarning() << "Invalid item id in set_tree_item_data:" << item_id;
        lua_pushboolean(L, 0);
        return 1;
    }

    item->setData(0, Qt::UserRole, QString::fromUtf8(value));
    lua_pushboolean(L, 1);
    return 1;
}

int lua_get_tree_item_data(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    lua_Integer item_id = luaL_checkinteger(L, 2);

    if (!widget) {
        qWarning() << "Invalid tree widget in get_tree_item_data";
        lua_pushnil(L);
        return 1;
    }

    QTreeWidget* tree = qobject_cast<QTreeWidget*>(widget);
    if (!tree) {
        qWarning() << "Widget is not a QTreeWidget in get_tree_item_data";
        lua_pushnil(L);
        return 1;
    }

    QTreeWidgetItem* item = getTreeItemById(tree, item_id);
    if (!item) {
        lua_pushnil(L);
        return 1;
    }

    QVariant data = item->data(0, Qt::UserRole);
    if (!data.isValid()) {
        lua_pushnil(L);
        return 1;
    }

    QByteArray bytes = data.toString().toUtf8();
    lua_pushlstring(L, bytes.constData(), bytes.size());
    return 1;
}

int lua_set_tree_item_text(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    lua_Integer item_id = luaL_checkinteger(L, 2);
    const char* text = luaL_checkstring(L, 3);
    int column = 0;
    if (lua_gettop(L) >= 4 && lua_isnumber(L, 4)) {
        column = lua_tointeger(L, 4);
        if (column < 0) {
            column = 0;
        }
    }

    if (!widget) {
        qWarning() << "Invalid tree widget in set_tree_item_text";
        lua_pushboolean(L, 0);
        return 1;
    }

    QTreeWidget* tree = qobject_cast<QTreeWidget*>(widget);
    if (!tree) {
        qWarning() << "Widget is not a QTreeWidget in set_tree_item_text";
        lua_pushboolean(L, 0);
        return 1;
    }

    QTreeWidgetItem* item = getTreeItemById(tree, item_id);
    if (!item) {
        qWarning() << "Invalid item id in set_tree_item_text:" << item_id;
        lua_pushboolean(L, 0);
        return 1;
    }

    if (column >= item->columnCount()) {
        column = 0;
    }

    item->setText(column, QString::fromUtf8(text));
    lua_pushboolean(L, 1);
    return 1;
}

int lua_set_tree_current_item(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    if (!widget) {
        qWarning() << "Invalid tree widget in set_tree_current_item";
        lua_pushboolean(L, 0);
        return 1;
    }

    QTreeWidget* tree = qobject_cast<QTreeWidget*>(widget);
    if (!tree) {
        qWarning() << "Widget is not a QTreeWidget in set_tree_current_item";
        lua_pushboolean(L, 0);
        return 1;
    }

    int top = lua_gettop(L);
    if (top < 2 || lua_isnil(L, 2)) {
        tree->clearSelection();
        tree->setCurrentItem(nullptr);
        lua_pushboolean(L, 1);
        return 1;
    }

    lua_Integer item_id = luaL_checkinteger(L, 2);
    bool select_item = true;
    bool clear_previous = true;

    if (top >= 3 && !lua_isnil(L, 3)) {
        select_item = lua_toboolean(L, 3);
    }
    if (top >= 4 && !lua_isnil(L, 4)) {
        clear_previous = lua_toboolean(L, 4);
    }

    QTreeWidgetItem* item = getTreeItemById(tree, item_id);
    if (!item) {
        lua_pushboolean(L, 0);
        return 1;
    }

    QItemSelectionModel::SelectionFlag flag;
    if (select_item) {
        flag = clear_previous ? QItemSelectionModel::ClearAndSelect : QItemSelectionModel::Select;
    } else {
        flag = clear_previous ? QItemSelectionModel::Clear : QItemSelectionModel::Deselect;
    }

    tree->setCurrentItem(item, 0, flag);
    item->setSelected(select_item);
    tree->scrollToItem(item);

    lua_pushboolean(L, 1);
    return 1;
}

static LuaTreeWidget* castToLuaTree(QWidget* widget)
{
    if (!widget) {
        return nullptr;
    }
    if (auto luaTree = dynamic_cast<LuaTreeWidget*>(widget)) {
        return luaTree;
    }
    if (auto baseTree = qobject_cast<QTreeWidget*>(widget)) {
        return dynamic_cast<LuaTreeWidget*>(baseTree);
    }
    return nullptr;
}

int lua_set_tree_drag_drop_mode(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    const char* mode_str = luaL_optstring(L, 2, "none");

    LuaTreeWidget* tree = castToLuaTree(widget);
    if (!tree) {
        qWarning() << "set_tree_drag_drop_mode: widget is not a LuaTreeWidget";
        lua_pushboolean(L, 0);
        return 1;
    }

    QString mode = QString::fromUtf8(mode_str).toLower();
    if (mode == "internal") {
        tree->setDragDropEnabled(true);
        tree->setDefaultDropAction(Qt::MoveAction);
        tree->setDragDropMode(QAbstractItemView::InternalMove);
    } else if (mode == "drag_drop") {
        tree->setDragDropEnabled(true);
        tree->setDefaultDropAction(Qt::MoveAction);
        tree->setDragDropMode(QAbstractItemView::DragDrop);
    } else {
        tree->setDragDropEnabled(false);
        tree->setDragDropMode(QAbstractItemView::NoDragDrop);
    }

    lua_pushboolean(L, 1);
    return 1;
}

int lua_set_tree_drop_handler(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    const char* handler_name = lua_tostring(L, 2);

    LuaTreeWidget* tree = castToLuaTree(widget);
    if (!tree) {
        qWarning() << "set_tree_drop_handler: widget is not a LuaTreeWidget";
        lua_pushboolean(L, 0);
        return 1;
    }

    if (!handler_name) {
        tree->setDropHandler(std::string());
    } else {
        tree->setDropHandler(handler_name);
    }

    lua_pushboolean(L, 1);
    return 1;
}

int lua_set_tree_key_handler(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    const char* handler_name = lua_tostring(L, 2);

    LuaTreeWidget* tree = castToLuaTree(widget);
    if (!tree) {
        qWarning() << "set_tree_key_handler: widget is not a LuaTreeWidget";
        lua_pushboolean(L, 0);
        return 1;
    }

    if (!handler_name) {
        tree->setKeyHandler(std::string());
    } else {
        tree->setKeyHandler(handler_name);
    }

    lua_pushboolean(L, 1);
    return 1;
}

int lua_get_tree_item_at(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    if (!widget) {
        qWarning() << "Invalid tree widget in get_tree_item_at";
        lua_pushnil(L);
        return 1;
    }

    QTreeWidget* tree = qobject_cast<QTreeWidget*>(widget);
    if (!tree) {
        qWarning() << "Widget is not a QTreeWidget in get_tree_item_at";
        lua_pushnil(L);
        return 1;
    }

    int x = luaL_checkint(L, 2);
    int y = luaL_checkint(L, 3);
    QTreeWidgetItem* item = tree->itemAt(QPoint(x, y));
    if (!item) {
        lua_pushnil(L);
        return 1;
    }

    lua_pushinteger(L, makeTreeItemId(item));
    return 1;
}

int lua_set_tree_item_editable(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    lua_Integer item_id = luaL_checkinteger(L, 2);
    bool editable = lua_toboolean(L, 3);

    if (!widget) {
        qWarning() << "Invalid tree widget in set_tree_item_editable";
        lua_pushboolean(L, 0);
        return 1;
    }

    QTreeWidget* tree = qobject_cast<QTreeWidget*>(widget);
    if (!tree) {
        qWarning() << "Widget is not a QTreeWidget in set_tree_item_editable";
        lua_pushboolean(L, 0);
        return 1;
    }

    QTreeWidgetItem* item = getTreeItemById(tree, item_id);
    if (!item) {
        qWarning() << "Invalid item id in set_tree_item_editable:" << item_id;
        lua_pushboolean(L, 0);
        return 1;
    }

    Qt::ItemFlags flags = item->flags();
    if (editable) {
        flags |= Qt::ItemIsEditable;
    } else {
        flags &= ~Qt::ItemIsEditable;
    }
    item->setFlags(flags);

    lua_pushboolean(L, 1);
    return 1;
}

int lua_edit_tree_item(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    lua_Integer item_id = luaL_checkinteger(L, 2);
    int column = 0;
    if (lua_gettop(L) >= 3 && lua_isnumber(L, 3)) {
        column = lua_tointeger(L, 3);
        if (column < 0) {
            column = 0;
        }
    }

    if (!widget) {
        qWarning() << "Invalid tree widget in edit_tree_item";
        lua_pushboolean(L, 0);
        return 1;
    }

    QTreeWidget* tree = qobject_cast<QTreeWidget*>(widget);
    if (!tree) {
        qWarning() << "Widget is not a QTreeWidget in edit_tree_item";
        lua_pushboolean(L, 0);
        return 1;
    }

    QTreeWidgetItem* item = getTreeItemById(tree, item_id);
    if (!item) {
        qWarning() << "Invalid item id in edit_tree_item:" << item_id;
        lua_pushboolean(L, 0);
        return 1;
    }

    if (column >= item->columnCount()) {
        column = 0;
    }

    item->setFlags(item->flags() | Qt::ItemIsEditable);
    tree->setCurrentItem(item);
    tree->editItem(item, column);

    lua_pushboolean(L, 1);
    return 1;
}

int lua_set_tree_selection_mode(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    const char* mode_str = luaL_checkstring(L, 2);

    if (!widget) {
        qWarning() << "Invalid tree widget in set_tree_selection_mode";
        lua_pushboolean(L, 0);
        return 1;
    }

    QTreeWidget* tree = qobject_cast<QTreeWidget*>(widget);
    if (!tree) {
        qWarning() << "Widget is not a QTreeWidget in set_tree_selection_mode";
        lua_pushboolean(L, 0);
        return 1;
    }

    QAbstractItemView::SelectionMode mode = QAbstractItemView::SingleSelection;
    if (strcasecmp(mode_str, "extended") == 0) {
        mode = QAbstractItemView::ExtendedSelection;
    } else if (strcasecmp(mode_str, "multi") == 0 || strcasecmp(mode_str, "multiple") == 0) {
        mode = QAbstractItemView::MultiSelection;
    } else if (strcasecmp(mode_str, "contiguous") == 0) {
        mode = QAbstractItemView::ContiguousSelection;
    } else if (strcasecmp(mode_str, "none") == 0) {
        mode = QAbstractItemView::NoSelection;
    } else {
        mode = QAbstractItemView::SingleSelection;
    }

    tree->setSelectionMode(mode);
    lua_pushboolean(L, 1);
    return 1;
}

int lua_set_tree_item_changed_handler(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    const char* handler_name = luaL_checkstring(L, 2);

    if (!widget) {
        qWarning() << "Invalid tree widget in set_tree_item_changed_handler";
        lua_pushboolean(L, 0);
        return 1;
    }

    QTreeWidget* tree = qobject_cast<QTreeWidget*>(widget);
    if (!tree) {
        qWarning() << "Widget is not a QTreeWidget in set_tree_item_changed_handler";
        lua_pushboolean(L, 0);
        return 1;
    }

    std::string handler(handler_name);

    QObject::connect(tree, &QTreeWidget::itemChanged, [L, handler](QTreeWidgetItem* item, int column) {
        if (!item) {
            return;
        }

        lua_getglobal(L, handler.c_str());
        if (!lua_isfunction(L, -1)) {
            lua_pop(L, 1);
            return;
        }

        lua_newtable(L);

        lua_pushstring(L, "item_id");
            lua_pushinteger(L, makeTreeItemId(item));
        lua_settable(L, -3);

        lua_pushstring(L, "column");
        lua_pushinteger(L, column);
        lua_settable(L, -3);

        lua_pushstring(L, "text");
        QByteArray bytes = item->text(column).toUtf8();
        lua_pushlstring(L, bytes.constData(), bytes.size());
        lua_settable(L, -3);

        if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
            qWarning() << "Error calling Lua tree item changed handler:" << lua_tostring(L, -1);
            lua_pop(L, 1);
        }
    });

    lua_pushboolean(L, 1);
    return 1;
}

int lua_set_tree_selection_changed_handler(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    const char* handler_name = luaL_checkstring(L, 2);

    if (!widget) {
        qWarning() << "Invalid tree widget in set_tree_selection_changed_handler";
        lua_pushboolean(L, 0);
        return 1;
    }

    QTreeWidget* tree = qobject_cast<QTreeWidget*>(widget);
    if (!tree) {
        qWarning() << "Widget is not a QTreeWidget in set_tree_selection_changed_handler";
        lua_pushboolean(L, 0);
        return 1;
    }

    std::string handler(handler_name);

    QObject::connect(tree, &QTreeWidget::itemSelectionChanged, [tree, L, handler]() {
        lua_getglobal(L, handler.c_str());
        if (!lua_isfunction(L, -1)) {
            lua_pop(L, 1);
            return;
        }

        lua_newtable(L);

        QList<QTreeWidgetItem*> selected = tree->selectedItems();

        lua_pushstring(L, "items");
        lua_newtable(L);

        int index = 1;
        for (QTreeWidgetItem* item : selected) {
            lua_newtable(L);

            lua_pushstring(L, "item_id");
            lua_pushinteger(L, makeTreeItemId(item));
            lua_settable(L, -3);

            QVariant data = item->data(0, Qt::UserRole);
            if (data.isValid()) {
                QByteArray bytes = data.toString().toUtf8();
                lua_pushstring(L, "data");
                lua_pushlstring(L, bytes.constData(), bytes.size());
                lua_settable(L, -3);
            }

            lua_rawseti(L, -2, index);
            index++;
        }

        lua_settable(L, -3);

        if (!selected.isEmpty()) {
            QTreeWidgetItem* first = selected.first();
            lua_pushstring(L, "item_id");
            lua_pushinteger(L, makeTreeItemId(first));
            lua_settable(L, -3);

            QVariant data = first->data(0, Qt::UserRole);
            if (data.isValid()) {
                QByteArray bytes = data.toString().toUtf8();
                lua_pushstring(L, "data");
                lua_pushlstring(L, bytes.constData(), bytes.size());
                lua_settable(L, -3);
            }
        }

        if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
            qWarning() << "Error calling Lua selection handler:" << lua_tostring(L, -1);
            lua_pop(L, 1);
        }
    });

    lua_pushboolean(L, 1);
    return 1;
}

int lua_set_tree_item_icon(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    lua_Integer item_id = luaL_checkinteger(L, 2);
    const char* icon_name = luaL_checkstring(L, 3);

    if (!widget) {
        qWarning() << "Invalid tree widget in set_tree_item_icon";
        lua_pushboolean(L, 0);
        return 1;
    }

    QTreeWidget* tree = qobject_cast<QTreeWidget*>(widget);
    if (!tree) {
        qWarning() << "Widget is not a QTreeWidget in set_tree_item_icon";
        lua_pushboolean(L, 0);
        return 1;
    }

    QTreeWidgetItem* item = getTreeItemById(tree, item_id);
    if (!item) {
        qWarning() << "Invalid item id in set_tree_item_icon:" << item_id;
        lua_pushboolean(L, 0);
        return 1;
    }

    QStyle* style = QApplication::style();
    if (!style) {
        lua_pushboolean(L, 0);
        return 1;
    }

    QString name = QString::fromUtf8(icon_name);
    QIcon icon;
    if (name == "timeline") {
        icon = style->standardIcon(QStyle::SP_FileDialogDetailedView);
    } else if (name == "bin") {
        icon = style->standardIcon(QStyle::SP_DirIcon);
    } else {
        icon = style->standardIcon(QStyle::SP_FileIcon);
    }

    item->setIcon(0, icon);
    lua_pushboolean(L, 1);
    return 1;
}

int lua_set_tree_item_double_click_handler(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    const char* handler_name = luaL_checkstring(L, 2);

    if (!widget) {
        qWarning() << "Invalid tree widget in set_tree_double_click_handler";
        lua_pushboolean(L, 0);
        return 1;
    }

    QTreeWidget* tree = qobject_cast<QTreeWidget*>(widget);
    if (!tree) {
        qWarning() << "Widget is not a QTreeWidget in set_tree_double_click_handler";
        lua_pushboolean(L, 0);
        return 1;
    }

    std::string handler(handler_name);

    QObject::connect(tree, &QTreeWidget::itemDoubleClicked, [L, handler](QTreeWidgetItem* item, int column) {
        lua_getglobal(L, handler.c_str());
        if (!lua_isfunction(L, -1)) {
            lua_pop(L, 1);
            return;
        }

        lua_newtable(L);
        lua_pushstring(L, "item_id");
        lua_pushinteger(L, makeTreeItemId(item));
        lua_settable(L, -3);

        QVariant data = item->data(0, Qt::UserRole);
        if (data.isValid()) {
            QByteArray bytes = data.toString().toUtf8();
            lua_pushstring(L, "data");
            lua_pushlstring(L, bytes.constData(), bytes.size());
            lua_settable(L, -3);
        }

        lua_pushstring(L, "column");
        lua_pushinteger(L, column);
        lua_settable(L, -3);

        if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
            qWarning() << "Error calling Lua double click handler:" << lua_tostring(L, -1);
            lua_pop(L, 1);
        }
    });

    lua_pushboolean(L, 1);
    return 1;
}

// Signal handler for QLineEdit text changed
int lua_set_line_edit_text_changed_handler(lua_State* L)
{
    // Extract widget using existing helper
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    if (!widget) {
        qWarning() << "Invalid widget in lua_set_line_edit_text_changed_handler";
        return 0;
    }

    // Cast to QLineEdit
    QLineEdit* lineEdit = qobject_cast<QLineEdit*>(widget);
    if (!lineEdit) {
        qWarning() << "Widget is not a QLineEdit in lua_set_line_edit_text_changed_handler";
        return 0;
    }

    // Get handler name from Lua
    const char* handler_name = luaL_checkstring(L, 2);
    std::string handler_str(handler_name);

    // // qDebug() << "Setting text changed handler for QLineEdit:" << handler_str.c_str();

    // Connect signal, capturing L state for callback
    QObject::connect(lineEdit, &QLineEdit::textChanged, [L, handler_str](const QString& /*text*/) {
        lua_getglobal(L, handler_str.c_str());
        if (lua_isfunction(L, -1)) {
            if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
                qWarning() << "Error calling" << QString::fromStdString(handler_str)
                          << ":" << lua_tostring(L, -1);
                lua_pop(L, 1);
            }
        } else {
            lua_pop(L, 1);
        }
    });

    return 0;
}

int lua_set_line_edit_editing_finished_handler(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    if (!widget) {
        qWarning() << "Invalid widget in lua_set_line_edit_editing_finished_handler";
        return 0;
    }

    QLineEdit* lineEdit = qobject_cast<QLineEdit*>(widget);
    if (!lineEdit) {
        qWarning() << "Widget is not a QLineEdit in lua_set_line_edit_editing_finished_handler";
        return 0;
    }

    const char* handler_name = luaL_checkstring(L, 2);
    std::string handler_str(handler_name);

    QObject::connect(lineEdit, &QLineEdit::editingFinished, [L, handler_str]() {
        lua_getglobal(L, handler_str.c_str());
        if (lua_isfunction(L, -1)) {
            if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
                qWarning() << "Error calling" << QString::fromStdString(handler_str)
                          << ":" << lua_tostring(L, -1);
                lua_pop(L, 1);
            }
        } else {
            lua_pop(L, 1);
        }
    });

    lua_pushboolean(L, 1);
    return 1;
}

// Update widget geometry and force repaint
int lua_update_widget(lua_State* L)
{
    QWidget* widget = (QWidget*)lua_to_widget(L, 1);
    if (!widget) {
        qWarning() << "Invalid widget in lua_update_widget";
        return 0;
    }

    // Update geometry to recalculate layout
    widget->updateGeometry();
    // Force immediate repaint
    widget->update();

    return 0;
}

// QTimer single-shot function
int lua_create_single_shot_timer(lua_State* L)
{
    int interval_ms = luaL_checkint(L, 1);

    if (!lua_isfunction(L, 2)) {
        return luaL_error(L, "qt_create_single_shot_timer: second argument must be a function");
    }

    // Store callback function in registry
    lua_pushvalue(L, 2);  // Push function to top of stack
    int callback_ref = luaL_ref(L, LUA_REGISTRYINDEX);  // Pop and store in registry

    // Create timer (will be deleted automatically after firing)
    QTimer* timer = new QTimer();
    timer->setSingleShot(true);

    // Connect timer to lambda that calls Lua callback
    QObject::connect(timer, &QTimer::timeout, [L, callback_ref, timer]() {
        // Retrieve callback from registry
        lua_rawgeti(L, LUA_REGISTRYINDEX, callback_ref);

        // Call the Lua function
        if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
            const char* error = lua_tostring(L, -1);
            qDebug() << "Error in timer callback:" << error;
            lua_pop(L, 1);
        }

        // Clean up
        luaL_unref(L, LUA_REGISTRYINDEX, callback_ref);
        timer->deleteLater();
    });

    // Start timer
    timer->start(interval_ms);

    // Return timer object (for potential cancellation)
    lua_push_widget(L, timer);
    return 1;
}
