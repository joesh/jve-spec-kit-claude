#pragma once

#include <QWidget>
#include <QPainter>
#include <QColor>
#include <QString>
#include <QMouseEvent>
#include <QKeyEvent>
#include <vector>

extern "C" {
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
}

namespace JVE {

/**
 * Scriptable Timeline Widget - Minimal C++ rendering surface for command-based timeline
 * 
 * This widget implements the principle: "only performance-heavy stuff in C++, everything else in scripts"
 * 
 * C++ responsibilities:
 * - Execute drawing commands efficiently in paintEvent()
 * - Provide simple interface for sending drawing commands
 * 
 * Script responsibilities (future Lua integration):
 * - All timeline logic (playhead, ruler, tracks, clips)
 * - All user interaction handling
 * - All business logic and state management
 */
class ScriptableTimeline : public QWidget
{
    Q_OBJECT

public:
    explicit ScriptableTimeline(const std::string& widget_id, QWidget* parent = nullptr);
    ~ScriptableTimeline() = default;

    // Set Lua state for callbacks
    void setLuaState(lua_State* L) { lua_state_ = L; }

    // Drawing command interface (for future Lua integration)
    void clearCommands();
    void addRect(int x, int y, int width, int height, const QString& color);
    void addText(int x, int y, const QString& text, const QString& color);
    void addLine(int x1, int y1, int x2, int y2, const QString& color, int width = 1);
    
    // Test method to demonstrate command system
    void renderTestTimeline();
    
    // Playhead position management (called from Lua)
    void setPlayheadPosition(qint64 timeMs);
    qint64 getPlayheadPosition() const;

    // Get widget dimensions (for Lua coordinate calculations)
    int getWidth() const { return width(); }
    int getHeight() const { return height(); }

    // Trigger repaint (called from Lua after adding drawing commands)
    void requestUpdate() { update(); }

    // Set Lua event handlers (called from Lua)
    void setMouseEventHandler(const std::string& handler_name);
    void setKeyEventHandler(const std::string& handler_name);
    void setResizeEventHandler(const std::string& handler_name);

    // Qt layout system integration
    QSize sizeHint() const override;

    // Set desired height for layout system (called from Lua)
    void setDesiredHeight(int height);

protected:
    void paintEvent(QPaintEvent* event) override;
    void mousePressEvent(QMouseEvent* event) override;
    void mouseReleaseEvent(QMouseEvent* event) override;
    void mouseMoveEvent(QMouseEvent* event) override;
    void keyPressEvent(QKeyEvent* event) override;
    void resizeEvent(QResizeEvent* event) override;

private:
    // Drawing command structure
    struct DrawCommand {
        enum Type { RECT, TEXT, LINE } type;
        int x, y, width, height;
        int x2, y2; // For lines
        QString text;
        QColor color;
        int line_width = 1;
    };

    // Execute all drawing commands
    void executeDrawingCommands(QPainter& painter);

    // Drawing commands queue
    std::vector<DrawCommand> drawing_commands_;

    // Widget identifier for Lua integration
    std::string widget_id_;

    // Essential timeline state
    qint64 playhead_position_ = 0;  // Current playhead position in milliseconds

    // Desired height for layout system (set from Lua)
    int desired_height_ = 150;

    // Lua state for callbacks
    lua_State* lua_state_ = nullptr;

    // Lua event handlers
    std::string mouse_event_handler_;
    std::string key_event_handler_;
    std::string resize_event_handler_;
};

} // namespace JVE

// Lua bindings for ScriptableTimeline
extern "C" {
    void registerTimelineBindings(lua_State* L);

    int lua_timeline_clear_commands(lua_State* L);
    int lua_timeline_add_rect(lua_State* L);
    int lua_timeline_add_text(lua_State* L);
    int lua_timeline_add_line(lua_State* L);
    int lua_timeline_get_dimensions(lua_State* L);
    int lua_timeline_set_playhead(lua_State* L);
    int lua_timeline_get_playhead(lua_State* L);
    int lua_timeline_update(lua_State* L);
    int lua_timeline_set_mouse_event_handler(lua_State* L);
    int lua_timeline_set_key_event_handler(lua_State* L);
    int lua_timeline_set_resize_event_handler(lua_State* L);
    int lua_timeline_set_lua_state(lua_State* L);
}