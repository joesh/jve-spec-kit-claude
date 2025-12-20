#include "timeline_renderer.h"
#include "qt_bindings.h"
#include <QPaintEvent>
#include <QResizeEvent>
#include <QApplication>
#include <QWheelEvent>
#include <QtDebug>

namespace JVE {

TimelineRenderer::TimelineRenderer(const std::string& widget_id, QWidget* parent)
    : QWidget(parent), widget_id_(widget_id)
{
    // No hardcoded minimum size - let layout system and content determine size
    setMouseTracking(true);
    setFocusPolicy(Qt::StrongFocus);
    setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);
}

QSize TimelineRenderer::sizeHint() const
{
    // Return QWIDGETSIZE_MAX for width so layout gives us maximum space
    // Height: 150px default (3 tracks @ 50px each)
    return QSize(QWIDGETSIZE_MAX, 150);
}

void TimelineRenderer::clearCommands()
{
    drawing_commands_.clear();
}

void TimelineRenderer::addRect(int x, int y, int width, int height, const QString& color)
{
    DrawCommand cmd;
    cmd.type = DrawCommand::RECT;
    cmd.x = x;
    cmd.y = y;
    cmd.width = width;
    cmd.height = height;
    cmd.color = QColor(color);
    drawing_commands_.push_back(cmd);
}

void TimelineRenderer::addText(int x, int y, const QString& text, const QString& color)
{
    DrawCommand cmd;
    cmd.type = DrawCommand::TEXT;
    cmd.x = x;
    cmd.y = y;
    cmd.text = text;
    cmd.color = QColor(color);
    drawing_commands_.push_back(cmd);
}

void TimelineRenderer::addLine(int x1, int y1, int x2, int y2, const QString& color, int width)
{
    DrawCommand cmd;
    cmd.type = DrawCommand::LINE;
    cmd.x = x1;
    cmd.y = y1;
    cmd.x2 = x2;
    cmd.y2 = y2;
    cmd.color = QColor(color);
    cmd.line_width = width;
    drawing_commands_.push_back(cmd);
}

void TimelineRenderer::renderTestTimeline()
{
    clearCommands();
    
    // Draw ruler
    addRect(0, 0, 800, 30, "#444444");
    
    // Draw time markers
    for (int i = 0; i <= 8; ++i) {
        int x = 150 + i * 100;
        addLine(x, 20, x, 30, "#cccccc", 1);
        addText(x + 2, 15, QString("%1s").arg(i), "#cccccc");
    }
    
    // Draw track headers
    addRect(0, 30, 150, 50, "#333333");
    addText(10, 55, "Video 1", "#cccccc");
    
    addRect(0, 80, 150, 50, "#333333");
    addText(10, 105, "Audio 1", "#cccccc");
    
    // Draw track areas
    addRect(150, 30, 650, 50, "#252525");
    addRect(150, 80, 650, 50, "#2a2a2a");
    
    // Draw sample clips
    addRect(250, 35, 200, 40, "#4a90e2");
    addText(255, 55, "Beach Scene", "#cccccc");
    
    addRect(350, 85, 300, 40, "#4a90e2");
    addText(355, 105, "Music Track", "#cccccc");
    
    // Draw playhead
    addLine(400, 0, 400, 130, "#ff6b6b", 2);
    addRect(395, 0, 10, 10, "#ff6b6b");
    
    update(); // Trigger repaint
}

void TimelineRenderer::paintEvent(QPaintEvent* /* event */)
{
    QPainter painter(this);
    painter.setRenderHint(QPainter::Antialiasing);

    // Fill background
    painter.fillRect(rect(), QColor(35, 35, 35));

    // Execute all drawing commands from Lua
    executeDrawingCommands(painter);
}

void TimelineRenderer::executeDrawingCommands(QPainter& painter)
{
    for (const auto& cmd : drawing_commands_) {
        painter.setPen(QPen(cmd.color, cmd.line_width));
        painter.setBrush(QBrush(cmd.color));
        
        switch (cmd.type) {
            case DrawCommand::RECT:
                painter.fillRect(cmd.x, cmd.y, cmd.width, cmd.height, cmd.color);
                break;
                
            case DrawCommand::TEXT:
                painter.setPen(cmd.color);
                painter.drawText(cmd.x, cmd.y, cmd.text);
                break;
                
            case DrawCommand::LINE:
                painter.setPen(QPen(cmd.color, cmd.line_width));
                painter.drawLine(cmd.x, cmd.y, cmd.x2, cmd.y2);
                break;
        }
    }
}

void TimelineRenderer::setPlayheadPosition(qint64 timeMs)
{
    playhead_position_ = timeMs;
    update(); // Redraw to show new playhead position
}

qint64 TimelineRenderer::getPlayheadPosition() const
{
    return playhead_position_;
}

void TimelineRenderer::setMouseEventHandler(const std::string& handler_name)
{
    mouse_event_handler_ = handler_name;
}

void TimelineRenderer::setKeyEventHandler(const std::string& handler_name)
{
    key_event_handler_ = handler_name;
}

void TimelineRenderer::setResizeEventHandler(const std::string& handler_name)
{
    resize_event_handler_ = handler_name;
}

void TimelineRenderer::mousePressEvent(QMouseEvent* event)
{
    if (!mouse_event_handler_.empty() && lua_state_) {
        lua_getglobal(lua_state_, mouse_event_handler_.c_str());
        if (lua_isfunction(lua_state_, -1)) {
            // Create event table
            lua_newtable(lua_state_);
            lua_pushstring(lua_state_, "press");
            lua_setfield(lua_state_, -2, "type");
            lua_pushnumber(lua_state_, event->position().x());
            lua_setfield(lua_state_, -2, "x");
            lua_pushnumber(lua_state_, event->position().y());
            lua_setfield(lua_state_, -2, "y");
            lua_pushnumber(lua_state_, event->globalPosition().x());
            lua_setfield(lua_state_, -2, "gx");
            lua_pushnumber(lua_state_, event->globalPosition().y());
            lua_setfield(lua_state_, -2, "gy");
            lua_pushnumber(lua_state_, event->globalPosition().x());
            lua_setfield(lua_state_, -2, "gx");
            lua_pushnumber(lua_state_, event->globalPosition().y());
            lua_setfield(lua_state_, -2, "gy");

            Qt::KeyboardModifiers mods = event->modifiers();
            Qt::KeyboardModifiers globalMods = QApplication::keyboardModifiers();
#if defined(Q_OS_MACOS) || defined(Q_OS_MAC)
            bool is_command = mods.testFlag(Qt::ControlModifier) ||
                              globalMods.testFlag(Qt::ControlModifier);
            bool is_ctrl = mods.testFlag(Qt::MetaModifier) ||
                           globalMods.testFlag(Qt::MetaModifier);
#else
            bool is_command = mods.testFlag(Qt::MetaModifier) ||
                              globalMods.testFlag(Qt::MetaModifier);
            bool is_ctrl = mods.testFlag(Qt::ControlModifier) ||
                           globalMods.testFlag(Qt::ControlModifier);
#endif

            lua_pushboolean(lua_state_, is_ctrl);
            lua_setfield(lua_state_, -2, "ctrl");
            lua_pushboolean(lua_state_, event->modifiers() & Qt::ShiftModifier);
            lua_setfield(lua_state_, -2, "shift");
            lua_pushboolean(lua_state_, event->modifiers() & Qt::AltModifier);
            lua_setfield(lua_state_, -2, "alt");
            lua_pushboolean(lua_state_, is_command);
            lua_setfield(lua_state_, -2, "command");
            lua_pushinteger(lua_state_, event->button());
            lua_setfield(lua_state_, -2, "button");

            int result = lua_pcall(lua_state_, 1, 0, 0);
            if (result != 0) {
                const char* error_msg = lua_tostring(lua_state_, -1);
                qWarning() << "Lua error in mousePressEvent:" << (error_msg ? error_msg : "unknown error");
                lua_pop(lua_state_, 1);
            }
        } else {
            lua_pop(lua_state_, 1);
        }
    }
    QWidget::mousePressEvent(event);
}

void TimelineRenderer::mouseReleaseEvent(QMouseEvent* event)
{
    if (!mouse_event_handler_.empty() && lua_state_) {
        lua_getglobal(lua_state_, mouse_event_handler_.c_str());
        if (lua_isfunction(lua_state_, -1)) {
            lua_newtable(lua_state_);
            lua_pushstring(lua_state_, "release");
            lua_setfield(lua_state_, -2, "type");
            lua_pushnumber(lua_state_, event->position().x());
            lua_setfield(lua_state_, -2, "x");
            lua_pushnumber(lua_state_, event->position().y());
            lua_setfield(lua_state_, -2, "y");
            lua_pushnumber(lua_state_, event->globalPosition().x());
            lua_setfield(lua_state_, -2, "gx");
            lua_pushnumber(lua_state_, event->globalPosition().y());
            lua_setfield(lua_state_, -2, "gy");

            Qt::KeyboardModifiers mods = event->modifiers();
            Qt::KeyboardModifiers globalMods = QApplication::keyboardModifiers();
#if defined(Q_OS_MACOS) || defined(Q_OS_MAC)
            bool is_command_rel = mods.testFlag(Qt::ControlModifier) ||
                                  globalMods.testFlag(Qt::ControlModifier);
            bool is_ctrl_rel = mods.testFlag(Qt::MetaModifier) ||
                               globalMods.testFlag(Qt::MetaModifier);
#else
            bool is_command_rel = mods.testFlag(Qt::MetaModifier) ||
                                  globalMods.testFlag(Qt::MetaModifier);
            bool is_ctrl_rel = mods.testFlag(Qt::ControlModifier) ||
                               globalMods.testFlag(Qt::ControlModifier);
#endif

            lua_pushboolean(lua_state_, is_ctrl_rel);
            lua_setfield(lua_state_, -2, "ctrl");
            lua_pushboolean(lua_state_, event->modifiers() & Qt::ShiftModifier);
            lua_setfield(lua_state_, -2, "shift");
            lua_pushboolean(lua_state_, event->modifiers() & Qt::AltModifier);
            lua_setfield(lua_state_, -2, "alt");
            lua_pushboolean(lua_state_, is_command_rel);
            lua_setfield(lua_state_, -2, "command");

            int result = lua_pcall(lua_state_, 1, 0, 0);
            if (result != 0) {
                const char* error_msg = lua_tostring(lua_state_, -1);
                qWarning() << "Lua error in mouseReleaseEvent:" << (error_msg ? error_msg : "unknown error");
                lua_pop(lua_state_, 1);
            }
        } else {
            lua_pop(lua_state_, 1);
        }
    }
    QWidget::mouseReleaseEvent(event);
}

void TimelineRenderer::mouseMoveEvent(QMouseEvent* event)
{
    if (!mouse_event_handler_.empty() && lua_state_) {
        lua_getglobal(lua_state_, mouse_event_handler_.c_str());
        if (lua_isfunction(lua_state_, -1)) {
            lua_newtable(lua_state_);
            lua_pushstring(lua_state_, "move");
            lua_setfield(lua_state_, -2, "type");
            lua_pushnumber(lua_state_, event->position().x());
            lua_setfield(lua_state_, -2, "x");
            lua_pushnumber(lua_state_, event->position().y());
            lua_setfield(lua_state_, -2, "y");
            lua_pushnumber(lua_state_, event->globalPosition().x());
            lua_setfield(lua_state_, -2, "gx");
            lua_pushnumber(lua_state_, event->globalPosition().y());
            lua_setfield(lua_state_, -2, "gy");

            Qt::KeyboardModifiers mods = event->modifiers();
            Qt::KeyboardModifiers globalMods = QApplication::keyboardModifiers();
#if defined(Q_OS_MACOS) || defined(Q_OS_MAC)
            bool is_command_move = mods.testFlag(Qt::ControlModifier) ||
                                   globalMods.testFlag(Qt::ControlModifier);
            bool is_ctrl_move = mods.testFlag(Qt::MetaModifier) ||
                                globalMods.testFlag(Qt::MetaModifier);
#else
            bool is_command_move = mods.testFlag(Qt::MetaModifier) ||
                                   globalMods.testFlag(Qt::MetaModifier);
            bool is_ctrl_move = mods.testFlag(Qt::ControlModifier) ||
                                globalMods.testFlag(Qt::ControlModifier);
#endif

            lua_pushboolean(lua_state_, is_ctrl_move);
            lua_setfield(lua_state_, -2, "ctrl");
            lua_pushboolean(lua_state_, event->modifiers() & Qt::ShiftModifier);
            lua_setfield(lua_state_, -2, "shift");
            lua_pushboolean(lua_state_, event->modifiers() & Qt::AltModifier);
            lua_setfield(lua_state_, -2, "alt");
            lua_pushboolean(lua_state_, is_command_move);
            lua_setfield(lua_state_, -2, "command");

            int result = lua_pcall(lua_state_, 1, 0, 0);
            if (result != 0) {
                const char* error_msg = lua_tostring(lua_state_, -1);
                qWarning() << "Lua error in mouseMoveEvent:" << (error_msg ? error_msg : "unknown error");
                lua_pop(lua_state_, 1);
            }
        } else {
            lua_pop(lua_state_, 1);
        }
    }
    QWidget::mouseMoveEvent(event);
}

void TimelineRenderer::wheelEvent(QWheelEvent* event)
{
    if (!mouse_event_handler_.empty() && lua_state_) {
        lua_getglobal(lua_state_, mouse_event_handler_.c_str());
        if (lua_isfunction(lua_state_, -1)) {
            lua_newtable(lua_state_);
            lua_pushstring(lua_state_, "wheel");
            lua_setfield(lua_state_, -2, "type");

            QPoint pixelDelta = event->pixelDelta();
            QPoint angleDelta = event->angleDelta();
            double deltaX = 0.0;
            double deltaY = 0.0;
            if (!pixelDelta.isNull()) {
                deltaX = pixelDelta.x();
                deltaY = pixelDelta.y();
            } else {
                deltaX = angleDelta.x() / 8.0; // convert from eighths of a degree roughly to "steps"
                deltaY = angleDelta.y() / 8.0;
            }

            lua_pushnumber(lua_state_, deltaX);
            lua_setfield(lua_state_, -2, "delta_x");
            lua_pushnumber(lua_state_, deltaY);
            lua_setfield(lua_state_, -2, "delta_y");

            Qt::KeyboardModifiers mods = event->modifiers();
#if defined(Q_OS_MACOS) || defined(Q_OS_MAC)
            bool is_command = mods.testFlag(Qt::ControlModifier);
            bool is_ctrl = mods.testFlag(Qt::MetaModifier);
#else
            bool is_command = mods.testFlag(Qt::MetaModifier);
            bool is_ctrl = mods.testFlag(Qt::ControlModifier);
#endif

            lua_pushboolean(lua_state_, is_ctrl);
            lua_setfield(lua_state_, -2, "ctrl");
            lua_pushboolean(lua_state_, mods.testFlag(Qt::ShiftModifier));
            lua_setfield(lua_state_, -2, "shift");
            lua_pushboolean(lua_state_, mods.testFlag(Qt::AltModifier));
            lua_setfield(lua_state_, -2, "alt");
            lua_pushboolean(lua_state_, is_command);
            lua_setfield(lua_state_, -2, "command");

            int result = lua_pcall(lua_state_, 1, 0, 0);
            if (result != 0) {
                const char* error_msg = lua_tostring(lua_state_, -1);
                qWarning() << "Lua error in wheelEvent:" << (error_msg ? error_msg : "unknown error");
                lua_pop(lua_state_, 1);
            }
        } else {
            lua_pop(lua_state_, 1);
        }
    }

    QWidget::wheelEvent(event);
}

void TimelineRenderer::keyPressEvent(QKeyEvent* event)
{
    if (!key_event_handler_.empty() && lua_state_) {
        lua_getglobal(lua_state_, key_event_handler_.c_str());
        if (lua_isfunction(lua_state_, -1)) {
            lua_newtable(lua_state_);
            lua_pushstring(lua_state_, "press");
            lua_setfield(lua_state_, -2, "type");
            lua_pushinteger(lua_state_, event->key());
            lua_setfield(lua_state_, -2, "key");
            lua_pushstring(lua_state_, event->text().toStdString().c_str());
            lua_setfield(lua_state_, -2, "text");
            lua_pushboolean(lua_state_, event->modifiers() & Qt::ControlModifier);
            lua_setfield(lua_state_, -2, "ctrl");
            lua_pushboolean(lua_state_, event->modifiers() & Qt::ShiftModifier);
            lua_setfield(lua_state_, -2, "shift");
            lua_pushboolean(lua_state_, event->modifiers() & Qt::AltModifier);
            lua_setfield(lua_state_, -2, "alt");

            int result = lua_pcall(lua_state_, 1, 0, 0);
            if (result != 0) {
                const char* error_msg = lua_tostring(lua_state_, -1);
                qWarning() << "Lua error in keyPressEvent:" << (error_msg ? error_msg : "unknown error");
                lua_pop(lua_state_, 1);
            }
        } else {
            lua_pop(lua_state_, 1);
        }
    }
    QWidget::keyPressEvent(event);
}

void TimelineRenderer::resizeEvent(QResizeEvent* event)
{
    if (!resize_event_handler_.empty() && lua_state_) {
        lua_getglobal(lua_state_, resize_event_handler_.c_str());
        if (lua_isfunction(lua_state_, -1)) {
            lua_newtable(lua_state_);
            lua_pushnumber(lua_state_, event->size().width());
            lua_setfield(lua_state_, -2, "width");
            lua_pushnumber(lua_state_, event->size().height());
            lua_setfield(lua_state_, -2, "height");
            lua_pushnumber(lua_state_, event->oldSize().width());
            lua_setfield(lua_state_, -2, "old_width");
            lua_pushnumber(lua_state_, event->oldSize().height());
            lua_setfield(lua_state_, -2, "old_height");

            int result = lua_pcall(lua_state_, 1, 0, 0);
            if (result != 0) {
                const char* error_msg = lua_tostring(lua_state_, -1);
                qWarning() << "Lua error in resizeEvent:" << (error_msg ? error_msg : "unknown error");
                lua_pop(lua_state_, 1);
            }
        } else {
            lua_pop(lua_state_, 1);
        }
    }
    QWidget::resizeEvent(event);
}

} // namespace JVE

// Lua bindings implementation
void registerTimelineBindings(lua_State* L)
{

    // Create timeline namespace
    lua_newtable(L);

    lua_pushcfunction(L, lua_timeline_clear_commands);
    lua_setfield(L, -2, "clear_commands");

    lua_pushcfunction(L, lua_timeline_add_rect);
    lua_setfield(L, -2, "add_rect");

    lua_pushcfunction(L, lua_timeline_add_text);
    lua_setfield(L, -2, "add_text");

    lua_pushcfunction(L, lua_timeline_add_line);
    lua_setfield(L, -2, "add_line");

    lua_pushcfunction(L, lua_timeline_get_dimensions);
    lua_setfield(L, -2, "get_dimensions");

    lua_pushcfunction(L, lua_timeline_set_playhead);
    lua_setfield(L, -2, "set_playhead");

    lua_pushcfunction(L, lua_timeline_get_playhead);
    lua_setfield(L, -2, "get_playhead");

    lua_pushcfunction(L, lua_timeline_update);
    lua_setfield(L, -2, "update");

    lua_pushcfunction(L, lua_timeline_set_mouse_event_handler);
    lua_setfield(L, -2, "set_mouse_event_handler");

    lua_pushcfunction(L, lua_timeline_set_key_event_handler);
    lua_setfield(L, -2, "set_key_event_handler");

    lua_pushcfunction(L, lua_timeline_set_resize_event_handler);
    lua_setfield(L, -2, "set_resize_event_handler");

    lua_pushcfunction(L, lua_timeline_set_lua_state);
    lua_setfield(L, -2, "set_lua_state");

    lua_setglobal(L, "timeline");

}

int lua_timeline_clear_commands(lua_State* L)
{
    JVE::TimelineRenderer* timeline = (JVE::TimelineRenderer*)lua_to_widget(L, 1);
    if (timeline) {
        timeline->clearCommands();
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_timeline_add_rect(lua_State* L)
{
    JVE::TimelineRenderer* timeline = (JVE::TimelineRenderer*)lua_to_widget(L, 1);
    int x = lua_tointeger(L, 2);
    int y = lua_tointeger(L, 3);
    int width = lua_tointeger(L, 4);
    int height = lua_tointeger(L, 5);
    const char* color = lua_tostring(L, 6);

    if (timeline && color) {
        timeline->addRect(x, y, width, height, QString(color));
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_timeline_add_text(lua_State* L)
{
    JVE::TimelineRenderer* timeline = (JVE::TimelineRenderer*)lua_to_widget(L, 1);
    int x = lua_tointeger(L, 2);
    int y = lua_tointeger(L, 3);
    const char* text = lua_tostring(L, 4);
    const char* color = lua_tostring(L, 5);

    if (timeline && text && color) {
        timeline->addText(x, y, QString(text), QString(color));
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_timeline_add_line(lua_State* L)
{
    JVE::TimelineRenderer* timeline = (JVE::TimelineRenderer*)lua_to_widget(L, 1);
    int x1 = lua_tointeger(L, 2);
    int y1 = lua_tointeger(L, 3);
    int x2 = lua_tointeger(L, 4);
    int y2 = lua_tointeger(L, 5);
    const char* color = lua_tostring(L, 6);
    int width = lua_tointeger(L, 7);

    if (timeline && color) {
        timeline->addLine(x1, y1, x2, y2, QString(color), width);
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_timeline_get_dimensions(lua_State* L)
{
    JVE::TimelineRenderer* timeline = (JVE::TimelineRenderer*)lua_to_widget(L, 1);
    if (timeline) {
        lua_pushinteger(L, timeline->getWidth());
        lua_pushinteger(L, timeline->getHeight());
        return 2;
    } else {
        lua_pushnil(L);
        lua_pushnil(L);
        return 2;
    }
}

int lua_timeline_set_playhead(lua_State* L)
{
    JVE::TimelineRenderer* timeline = (JVE::TimelineRenderer*)lua_to_widget(L, 1);
    qint64 timeMs = lua_tointeger(L, 2);

    if (timeline) {
        timeline->setPlayheadPosition(timeMs);
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_timeline_get_playhead(lua_State* L)
{
    JVE::TimelineRenderer* timeline = (JVE::TimelineRenderer*)lua_to_widget(L, 1);
    if (timeline) {
        lua_pushinteger(L, timeline->getPlayheadPosition());
    } else {
        lua_pushnil(L);
    }
    return 1;
}

int lua_timeline_update(lua_State* L)
{
    JVE::TimelineRenderer* timeline = (JVE::TimelineRenderer*)lua_to_widget(L, 1);
    if (timeline) {
        timeline->requestUpdate();
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_timeline_set_mouse_event_handler(lua_State* L)
{
    JVE::TimelineRenderer* timeline = (JVE::TimelineRenderer*)lua_to_widget(L, 1);
    const char* handler = lua_tostring(L, 2);

    if (timeline && handler) {
        timeline->setMouseEventHandler(std::string(handler));
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_timeline_set_key_event_handler(lua_State* L)
{
    JVE::TimelineRenderer* timeline = (JVE::TimelineRenderer*)lua_to_widget(L, 1);
    const char* handler = lua_tostring(L, 2);

    if (timeline && handler) {
        timeline->setKeyEventHandler(std::string(handler));
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_timeline_set_resize_event_handler(lua_State* L)
{
    JVE::TimelineRenderer* timeline = (JVE::TimelineRenderer*)lua_to_widget(L, 1);
    const char* handler = lua_tostring(L, 2);

    if (timeline && handler) {
        timeline->setResizeEventHandler(std::string(handler));
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_timeline_set_lua_state(lua_State* L)
{
    JVE::TimelineRenderer* timeline = (JVE::TimelineRenderer*)lua_to_widget(L, 1);

    if (timeline) {
        timeline->setLuaState(L);
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}
