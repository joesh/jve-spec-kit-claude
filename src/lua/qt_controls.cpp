#include "qt_controls.h"
#include "qt_bindings.h"
#include "simple_lua_engine.h"
#include <QtWidgets>
#include <QEvent>
#include <QMouseEvent>

namespace QtControls {

using namespace JVE::FFIConstants;
using FFIParameterValidator = JVE::FFIParameterValidator;
using QtCore = JVE::QtCore;
using LuaErrorHelper = JVE::LuaErrorHelper;

// Scroll area functions
int qt_set_scroll_area_widget(lua_State* L) {
    auto args = FFIParameterValidator::validate(L, JVE::FFIConstants::QT_SET_SCROLL_AREA_WIDGET, {
        {JVE::FFIArgType::WIDGET, PARAM_SCROLL_AREA},
        {JVE::FFIArgType::WIDGET, PARAM_WIDGET}
    });

    QtCore::validateWidget(*args.widget_ptrs[0], QString("qt_set_scroll_area_widget"), L);
    QtCore::validateWidget(*args.widget_ptrs[1], QString("qt_set_scroll_area_widget"), L);

    QScrollArea* scrollArea = qobject_cast<QScrollArea*>(*args.widget_ptrs[0]);
    if (!scrollArea) {
        LuaErrorHelper::throwWidgetCastError(L, "qt_set_scroll_area_widget", *args.widget_ptrs[0], "QScrollArea");
        return 0;
    }

    QWidget* widget = *args.widget_ptrs[1];
    scrollArea->setWidget(widget);
    
    // Verify the setWidget actually worked
    QWidget* verify_widget = scrollArea->widget();
    if (verify_widget != widget) {
        LuaErrorHelper::throwQtError(L, "scrollArea->setWidget()", widget, 
                                   "Widget assignment verification failed - setWidget() did not set the widget correctly");
    }

    return 0;
}

// Numeric control functions
int qt_set_widget_range(lua_State* L) {
    auto args = FFIParameterValidator::validate(L, JVE::FFIConstants::QT_SET_WIDGET_RANGE, {
        {JVE::FFIArgType::WIDGET, PARAM_WIDGET},
        {JVE::FFIArgType::INTEGER, PARAM_MINIMUM},
        {JVE::FFIArgType::INTEGER, PARAM_MAXIMUM}
    });

    QtCore::validateWidget(*args.widget_ptrs[0], QString("qt_set_widget_range"), L);
    QWidget* widget = *args.widget_ptrs[0];

    int minimum = args.integers[0];
    int maximum = args.integers[1];

    // Try different numeric widget types
    if (QSpinBox* spinBox = qobject_cast<QSpinBox*>(widget)) {
        spinBox->setRange(minimum, maximum);
    } else if (QDoubleSpinBox* doubleSpinBox = qobject_cast<QDoubleSpinBox*>(widget)) {
        doubleSpinBox->setRange(minimum, maximum);
    } else if (QSlider* slider = qobject_cast<QSlider*>(widget)) {
        slider->setRange(minimum, maximum);
    } else {
        LuaErrorHelper::throwQtError(L, "setRange()", widget, 
                                   "Widget type does not support range setting - requires QSpinBox, QDoubleSpinBox, or QSlider");
        return 0;
    }

    return 0;
}

int qt_set_widget_decimals(lua_State* L) {
    auto args = FFIParameterValidator::validate(L, JVE::FFIConstants::QT_SET_WIDGET_DECIMALS, {
        {JVE::FFIArgType::WIDGET, PARAM_WIDGET},
        {JVE::FFIArgType::POSITIVE_INTEGER, PARAM_DECIMALS}
    });

    QtCore::validateWidget(*args.widget_ptrs[0], QString("qt_set_widget_decimals"), L);
    QWidget* widget = *args.widget_ptrs[0];

    int decimals = args.integers[0];

    QDoubleSpinBox* doubleSpinBox = qobject_cast<QDoubleSpinBox*>(widget);
    if (!doubleSpinBox) {
        LuaErrorHelper::throwWidgetCastError(L, "qt_set_widget_decimals", widget, "QDoubleSpinBox");
        return 0;
    }

    doubleSpinBox->setDecimals(decimals);
    return 0;
}

int qt_set_widget_increment(lua_State* L) {
    auto args = FFIParameterValidator::validate(L, JVE::FFIConstants::QT_SET_WIDGET_INCREMENT, {
        {JVE::FFIArgType::WIDGET, PARAM_WIDGET},
        {JVE::FFIArgType::INTEGER, PARAM_INCREMENT}
    });

    QtCore::validateWidget(*args.widget_ptrs[0], QString("qt_set_widget_increment"), L);
    QWidget* widget = *args.widget_ptrs[0];

    int increment = args.integers[0];

    // Try different numeric widget types
    if (QSpinBox* spinBox = qobject_cast<QSpinBox*>(widget)) {
        spinBox->setSingleStep(increment);
    } else if (QDoubleSpinBox* doubleSpinBox = qobject_cast<QDoubleSpinBox*>(widget)) {
        doubleSpinBox->setSingleStep(increment);
    } else if (QSlider* slider = qobject_cast<QSlider*>(widget)) {
        slider->setSingleStep(increment);
    } else {
        LuaErrorHelper::throwQtError(L, "setSingleStep()", widget, 
                                   "Widget type does not support increment setting - requires QSpinBox, QDoubleSpinBox, or QSlider");
        return 0;
    }

    return 0;
}

// Combo box functions
int qt_add_combobox_item(lua_State* L) {
    auto args = FFIParameterValidator::validate(L, JVE::FFIConstants::QT_ADD_COMBOBOX_ITEM, {
        {JVE::FFIArgType::WIDGET, PARAM_WIDGET},
        {JVE::FFIArgType::STRING, PARAM_TEXT}
    });

    QtCore::validateWidget(*args.widget_ptrs[0], QString("qt_add_combobox_item"), L);

    QComboBox* comboBox = qobject_cast<QComboBox*>(*args.widget_ptrs[0]);
    if (!comboBox) {
        LuaErrorHelper::throwWidgetCastError(L, "qt_combobox_add_item", *args.widget_ptrs[0], "QComboBox");
        return 0;
    }

    QString text = QString::fromStdString(args.strings[0]);
    comboBox->addItem(text);

    return 0;
}

int qt_set_combo_current_index(lua_State* L) {
    auto args = FFIParameterValidator::validate(L, JVE::FFIConstants::QT_SET_COMBO_CURRENT_INDEX, {
        {JVE::FFIArgType::WIDGET, PARAM_WIDGET},
        {JVE::FFIArgType::INTEGER, PARAM_INDEX}
    });

    QtCore::validateWidget(*args.widget_ptrs[0], QString("qt_set_combo_current_index"), L);

    QComboBox* comboBox = qobject_cast<QComboBox*>(*args.widget_ptrs[0]);
    if (!comboBox) {
        LuaErrorHelper::throwWidgetCastError(L, "qt_set_combo_current_index", *args.widget_ptrs[0], "QComboBox");
        return 0;
    }

    int index = args.integers[0];
    if (index >= 0 && index < comboBox->count()) {
        comboBox->setCurrentIndex(index);
    } else {
        LuaErrorHelper::throwQtError(L, "qt_set_combo_current_index", comboBox, 
                                   QString("Index %1 out of range [0, %2]").arg(index).arg(comboBox->count() - 1).toStdString());
    }

    return 0;
}

// Container functions
int qt_embed_widget(lua_State* L) {
    auto args = FFIParameterValidator::validate(L, JVE::FFIConstants::QT_EMBED_WIDGET, {
        {JVE::FFIArgType::WIDGET, PARAM_CONTAINER},
        {JVE::FFIArgType::WIDGET, PARAM_WIDGET}
    });

    QtCore::validateWidget(*args.widget_ptrs[0], QString("qt_embed_widget"), L);
    QtCore::validateWidget(*args.widget_ptrs[1], QString("qt_embed_widget"), L);

    QWidget* container = *args.widget_ptrs[0];
    QWidget* widget = *args.widget_ptrs[1];

    // Set the container as the widget's parent
    widget->setParent(container);

    // If container has a layout, add the widget to it
    if (QLayout* layout = container->layout()) {
        layout->addWidget(widget);
    }

    return 0;
}

// Scroll position functions
int qt_get_scroll_position(lua_State* L) {
    auto args = FFIParameterValidator::validate(L, "qt_get_scroll_position", {
        {JVE::FFIArgType::WIDGET, PARAM_SCROLL_AREA}
    });

    QtCore::validateWidget(*args.widget_ptrs[0], QString("qt_get_scroll_position"), L);

    QScrollArea* scrollArea = qobject_cast<QScrollArea*>(*args.widget_ptrs[0]);
    if (!scrollArea) {
        LuaErrorHelper::throwWidgetCastError(L, "qt_get_scroll_position", *args.widget_ptrs[0], "QScrollArea");
        return 0;
    }

    // Get the vertical scroll bar position
    int position = scrollArea->verticalScrollBar()->value();
    
    lua_pushinteger(L, position);
    return 1;
}

int qt_set_scroll_position(lua_State* L) {
    auto args = FFIParameterValidator::validate(L, "qt_set_scroll_position", {
        {JVE::FFIArgType::WIDGET, PARAM_SCROLL_AREA},
        {JVE::FFIArgType::INTEGER, PARAM_POSITION}
    });

    QtCore::validateWidget(*args.widget_ptrs[0], QString("qt_set_scroll_position"), L);

    QScrollArea* scrollArea = qobject_cast<QScrollArea*>(*args.widget_ptrs[0]);
    if (!scrollArea) {
        LuaErrorHelper::throwWidgetCastError(L, "qt_set_scroll_position", *args.widget_ptrs[0], "QScrollArea");
        return 0;
    }

    int position = args.integers[0];
    
    // Set the vertical scroll bar position
    scrollArea->verticalScrollBar()->setValue(position);
    
    return 0;
}

// Click handler functions
int qt_set_button_click_handler(lua_State* L) {
    auto args = FFIParameterValidator::validate(L, "qt_set_button_click_handler", {
        {JVE::FFIArgType::WIDGET, PARAM_WIDGET},
        {JVE::FFIArgType::STRING, PARAM_HANDLER}
    });

    QtCore::validateWidget(*args.widget_ptrs[0], QString("qt_set_button_click_handler"), L);

    QAbstractButton* button = qobject_cast<QAbstractButton*>(*args.widget_ptrs[0]);
    if (!button) {
        LuaErrorHelper::throwWidgetCastError(L, "qt_set_button_click_handler", *args.widget_ptrs[0], "QAbstractButton");
        return 0;
    }

    std::string handler_name = args.strings[0];

    // Connect Qt clicked signal to Lua function call
    QObject::connect(button, &QAbstractButton::clicked, [handler_name]() {
        if (JVE::g_lua_engine) {
            JVE::Parameters empty_params;
            JVE::g_lua_engine->call_lua_function(handler_name, empty_params);
        }
    });

    return 0;
}

int qt_set_line_edit_text_changed_handler(lua_State* L) {
    auto args = FFIParameterValidator::validate(L, "qt_set_line_edit_text_changed_handler", {
        {JVE::FFIArgType::WIDGET, PARAM_WIDGET},
        {JVE::FFIArgType::STRING, PARAM_HANDLER}
    });

    QtCore::validateWidget(*args.widget_ptrs[0], QString("qt_set_line_edit_text_changed_handler"), L);

    QLineEdit* lineEdit = qobject_cast<QLineEdit*>(*args.widget_ptrs[0]);
    if (!lineEdit) {
        LuaErrorHelper::throwWidgetCastError(L, "qt_set_line_edit_text_changed_handler", *args.widget_ptrs[0], "QLineEdit");
        return 0;
    }

    std::string handler_name = args.strings[0];

    // Connect Qt textChanged signal to Lua function call
    // TODO: Create proper parameter passing pattern for Qt signals with data
    // For now, Lua callbacks can fetch current text using qt_get_widget_text()
    QObject::connect(lineEdit, &QLineEdit::textChanged, [handler_name](const QString& /*text*/) {
        if (JVE::g_lua_engine) {
            JVE::Parameters empty_params;
            JVE::g_lua_engine->call_lua_function(handler_name, empty_params);
        }
    });

    return 0;
}

int qt_set_widget_click_handler(lua_State* L) {
    auto args = FFIParameterValidator::validate(L, "qt_set_widget_click_handler", {
        {JVE::FFIArgType::WIDGET, PARAM_WIDGET},
        {JVE::FFIArgType::STRING, PARAM_HANDLER}
    });

    QtCore::validateWidget(*args.widget_ptrs[0], QString("qt_set_widget_click_handler"), L);

    QWidget* widget = *args.widget_ptrs[0];
    std::string handler_name = args.strings[0];

    qDebug() << "qt_set_widget_click_handler: widget=" << widget << "handler=" << QString::fromStdString(handler_name);

    // Install event filter to handle mouse clicks and releases on generic widgets
    class ClickEventFilter : public QObject {
    public:
        ClickEventFilter(const std::string& handler, QObject* parent = nullptr)
            : QObject(parent), handler_name(handler) {}

    protected:
        bool eventFilter(QObject* obj, QEvent* event) override {
            if (event->type() == QEvent::MouseButtonPress || event->type() == QEvent::MouseButtonRelease) {
                QMouseEvent* mouseEvent = static_cast<QMouseEvent*>(event);
                if (mouseEvent->button() == Qt::LeftButton) {
                    qDebug() << "ClickEventFilter: Event" << (event->type() == QEvent::MouseButtonPress ? "press" : "release")
                             << "at y=" << mouseEvent->pos().y() << "calling" << QString::fromStdString(handler_name);
                    if (JVE::g_lua_engine) {
                        JVE::Parameters params;
                        // Pass event type ("press" or "release")
                        params.strings.push_back(event->type() == QEvent::MouseButtonPress ? "press" : "release");
                        // Pass Y position
                        params.numbers.push_back(static_cast<double>(mouseEvent->pos().y()));
                        JVE::g_lua_engine->call_lua_function(handler_name, params);
                    }
                    return false;  // Let event propagate so splitter can handle drag
                }
            }
            return QObject::eventFilter(obj, event);
        }

    private:
        std::string handler_name;
    };

    // Create and install the event filter
    ClickEventFilter* filter = new ClickEventFilter(handler_name, widget);
    widget->installEventFilter(filter);
    qDebug() << "  -> Event filter installed on widget" << widget;

    return 0;
}

void register_bindings(lua_State* L) {
    // Scroll area functions
    lua_pushcfunction(L, qt_set_scroll_area_widget);
    lua_setglobal(L, JVE::FFIConstants::QT_SET_SCROLL_AREA_WIDGET);

    // Numeric control functions
    lua_pushcfunction(L, qt_set_widget_range);
    lua_setglobal(L, JVE::FFIConstants::QT_SET_WIDGET_RANGE);

    lua_pushcfunction(L, qt_set_widget_decimals);
    lua_setglobal(L, JVE::FFIConstants::QT_SET_WIDGET_DECIMALS);

    lua_pushcfunction(L, qt_set_widget_increment);
    lua_setglobal(L, JVE::FFIConstants::QT_SET_WIDGET_INCREMENT);

    // Combo box functions
    lua_pushcfunction(L, qt_add_combobox_item);
    lua_setglobal(L, JVE::FFIConstants::QT_ADD_COMBOBOX_ITEM);
    
    lua_pushcfunction(L, qt_set_combo_current_index);
    lua_setglobal(L, JVE::FFIConstants::QT_SET_COMBO_CURRENT_INDEX);

    // Container functions
    lua_pushcfunction(L, qt_embed_widget);
    lua_setglobal(L, JVE::FFIConstants::QT_EMBED_WIDGET);

    // Scroll position functions
    lua_pushcfunction(L, qt_get_scroll_position);
    lua_setglobal(L, JVE::FFIConstants::QT_GET_SCROLL_POSITION);

    lua_pushcfunction(L, qt_set_scroll_position);
    lua_setglobal(L, JVE::FFIConstants::QT_SET_SCROLL_POSITION);

    // Click handler functions
    lua_pushcfunction(L, qt_set_button_click_handler);
    lua_setglobal(L, JVE::FFIConstants::QT_SET_BUTTON_CLICK_HANDLER);

    lua_pushcfunction(L, qt_set_line_edit_text_changed_handler);
    lua_setglobal(L, "qt_set_line_edit_text_changed_handler");

    lua_pushcfunction(L, qt_set_widget_click_handler);
    lua_setglobal(L, JVE::FFIConstants::QT_SET_WIDGET_CLICK_HANDLER);
}

} // namespace QtControls