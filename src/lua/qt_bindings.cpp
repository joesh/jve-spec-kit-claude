#include "qt_bindings.h"
#include "simple_lua_engine.h"
#include <QWidget>
#include <QMainWindow>
#include <QLabel>
#include <QLineEdit>
#include <QCheckBox>
#include <QComboBox>
#include <QSlider>
#include <QTreeWidget>
#include <QTreeWidgetItem>
#include <QHBoxLayout>
#include <QVBoxLayout>
#include <QSplitter>
#include <QScrollArea>
#include <QPushButton>
#include <QSizePolicy>
#include <QSet>
#include <QMap>
#include <QDebug>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QJsonValue>

// Include existing UI components
#include "ui/timeline/scriptable_timeline.h"  // Performance-critical timeline rendering

// Widget userdata metatable name
static const char* WIDGET_METATABLE = "JVE.Widget";

// Forward declarations
int lua_create_scriptable_timeline(lua_State* L);
int lua_set_line_edit_text_changed_handler(lua_State* L);
int lua_update_widget(lua_State* L);
int lua_get_widget_size(lua_State* L);
int lua_set_minimum_width(lua_State* L);
int lua_set_maximum_width(lua_State* L);
int lua_set_minimum_height(lua_State* L);
int lua_set_maximum_height(lua_State* L);
int lua_get_splitter_sizes(lua_State* L);
int lua_set_splitter_moved_handler(lua_State* L);
int lua_set_scroll_area_widget_resizable(lua_State* L);
int lua_set_splitter_stretch_factor(lua_State* L);
int lua_get_splitter_handle(lua_State* L);

// Helper function to convert Lua table to QJsonValue
static QJsonValue luaTableToJsonValue(lua_State* L, int index);

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
    lua_pushcfunction(L, lua_add_combobox_item);
    lua_setfield(L, -2, "ADD_COMBOBOX_ITEM");
    lua_pushcfunction(L, lua_set_combobox_current_text);
    lua_setfield(L, -2, "SET_COMBOBOX_CURRENT_TEXT");
    lua_pushcfunction(L, lua_set_slider_range);
    lua_setfield(L, -2, "SET_SLIDER_RANGE");
    lua_pushcfunction(L, lua_set_slider_value);
    lua_setfield(L, -2, "SET_SLIDER_VALUE");
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
    lua_pushcfunction(L, lua_set_style_sheet);
    lua_setfield(L, -2, "SET_STYLE");
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
    lua_pushcfunction(L, lua_set_layout_spacing);
    lua_setfield(L, -2, "SET_LAYOUT_SPACING");
    lua_pushcfunction(L, lua_set_layout_margins);
    lua_setfield(L, -2, "SET_LAYOUT_MARGINS");
    lua_pushcfunction(L, lua_set_widget_size_policy);
    lua_setfield(L, -2, "SET_WIDGET_SIZE_POLICY");
    lua_pushcfunction(L, lua_set_tree_headers);
    lua_setfield(L, -2, "SET_TREE_HEADERS");
    lua_pushcfunction(L, lua_set_tree_column_width);
    lua_setfield(L, -2, "SET_TREE_COLUMN_WIDTH");
    lua_pushcfunction(L, lua_set_tree_indentation);
    lua_setfield(L, -2, "SET_TREE_INDENTATION");
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
    lua_setfield(L, -2, "CONTROL");
    
    // Register signal handler functions globally for qt_signals module
    lua_pushcfunction(L, lua_set_button_click_handler);
    lua_setglobal(L, "qt_set_button_click_handler");
    lua_pushcfunction(L, lua_set_widget_click_handler);
    lua_setglobal(L, "qt_set_widget_click_handler");
    lua_pushcfunction(L, lua_set_line_edit_text_changed_handler);
    lua_setglobal(L, "qt_set_line_edit_text_changed_handler");
    lua_pushcfunction(L, lua_set_splitter_moved_handler);
    lua_setglobal(L, "qt_set_splitter_moved_handler");
    lua_pushcfunction(L, lua_get_splitter_handle);
    lua_setglobal(L, "qt_get_splitter_handle");
    lua_pushcfunction(L, lua_update_widget);
    lua_setglobal(L, "qt_update_widget");

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
    QTreeWidget* tree = new QTreeWidget();
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

    qDebug() << "get_splitter_handle: splitter=" << splitter << "index=" << index << "count=" << splitter->count();

    // Get the handle widget at the given index
    QSplitterHandle* handle = splitter->handle(index);
    qDebug() << "  -> handle(" << index << ") returned:" << handle;

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
        if (event->type() == QEvent::MouseButtonPress || event->type() == QEvent::MouseButtonRelease) {
            QMouseEvent* mouseEvent = static_cast<QMouseEvent*>(event);
            if (mouseEvent->button() == Qt::LeftButton) {
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
    qDebug() << "qt_set_widget_click_handler: widget=" << widget << "handler=" << QString::fromStdString(handler_str);
    ClickEventFilter* filter = new ClickEventFilter(handler_str, L, widget);
    widget->installEventFilter(filter);
    qDebug() << "  -> Event filter installed on widget" << widget;

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

        if (strcasecmp(vertical, "expanding") == 0) vPolicy = QSizePolicy::Expanding;
        else if (strcasecmp(vertical, "fixed") == 0) vPolicy = QSizePolicy::Fixed;
        else if (strcasecmp(vertical, "minimum") == 0) vPolicy = QSizePolicy::Minimum;
        else if (strcasecmp(vertical, "maximum") == 0) vPolicy = QSizePolicy::Maximum;

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
    } else {
        qWarning() << "Unknown widget attribute:" << attr_name;
        lua_pushboolean(L, 0);
        return 1;
    }

    widget->setAttribute(attr, value);
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

        // Make clicking on folder items toggle expansion
        QObject::connect(tree, &QTreeWidget::itemClicked, [](QTreeWidgetItem* clickedItem, int) {
            if (clickedItem && clickedItem->childCount() > 0) {
                clickedItem->setExpanded(!clickedItem->isExpanded());
            }
        });

        connectedTrees.insert(tree);
    }

    // Return the index of the added item
    int index = tree->indexOfTopLevelItem(item);
    lua_pushinteger(L, index);
    return 1;
}

// Global map to track all tree items (both top-level and children)
static QMap<quintptr, QTreeWidgetItem*> g_treeItemMap;

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

    // Try to find parent - could be a top-level index (small number) or item ID (pointer address)
    QTreeWidgetItem* parent = nullptr;
    if (parent_id < 1000) {
        // Looks like a top-level index
        parent = tree->topLevelItem(static_cast<int>(parent_id));
    } else {
        // Looks like an item ID
        parent = g_treeItemMap.value(static_cast<quintptr>(parent_id), nullptr);
    }

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

    // Return a unique ID for this child item (use pointer address as ID)
    quintptr childId = reinterpret_cast<quintptr>(child);
    g_treeItemMap[childId] = child;

    lua_pushinteger(L, static_cast<lua_Integer>(childId));
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

    QTreeWidgetItem* item = tree->topLevelItem(item_index);
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