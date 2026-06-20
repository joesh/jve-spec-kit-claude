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
 * Timeline Renderer - Minimal C++ rendering surface for command-based timeline
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
class TimelineRenderer : public QWidget
{
    Q_OBJECT

public:
    explicit TimelineRenderer(const std::string& widget_id, QWidget* parent = nullptr);
    ~TimelineRenderer() = default;

    // Set Lua state for callbacks
    void setLuaState(lua_State* L) { lua_state_ = L; }

    // Drawing command interface. Coordinates are qreal: the Lua side maps
    // time→pixel with an exact linear function (no integer snapping — see
    // viewport_state.time_to_pixel), and the antialiased painter resolves
    // fractional coverage. Quantizing here would reintroduce the ±1 px
    // boundary jiggle during zoom that the float pipeline exists to fix.
    void clearCommands();
    void addRect(qreal x, qreal y, qreal width, qreal height, const QString& color);
    void addText(qreal x, qreal y, const QString& text, const QString& color);
    void addLine(qreal x1, qreal y1, qreal x2, qreal y2, const QString& color, int width = 1);
    void addTriangle(qreal x1, qreal y1, qreal x2, qreal y2, qreal x3, qreal y3, const QString& color);
    void addWaveform(qreal x, qreal y, qreal width, qreal height,
                     const float* peaks, int peak_count, const QString& color,
                     bool reversed = false);

    // Horizontal pan offset in float logical pixels: viewport_start mapped
    // at the current pixels-per-frame scale. Paint-time x-snapping anchors
    // to the CONTENT grid (x + pan) and translates by the offset rounded
    // to whole device pixels, so panning is a rigid translation — no clip
    // width may breathe between N and N+1 device columns as the fractional
    // phase walks. Set once per frame alongside the draw commands. Pinned
    // by testClipWidthRigidWhilePanning.
    void setPanOffsetPx(qreal px) { pan_offset_px_ = px; }

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

    // Drawing command structure. Public so the get_commands binding can
    // expose the real pending queue to Lua — renderer tests assert on
    // what will actually be painted instead of stubbing the timeline
    // global (the queue is the widget's output contract with the painter).
    struct DrawCommand {
        enum Type { RECT, TEXT, LINE, TRIANGLE, WAVEFORM } type;
        qreal x, y, width, height;
        qreal x2, y2; // For lines
        qreal x3, y3; // For triangles (third point)
        QString text;
        QColor color;
        int line_width = 1;
        std::vector<float> peak_data; // For WAVEFORM: [min0, max0, min1, max1, ...]
        int peak_count = 0;           // Number of min/max pairs
        bool reversed = false;        // For WAVEFORM: if true, draw peaks right-to-left (reverse clip)
    };

    const std::vector<DrawCommand>& commands() const { return drawing_commands_; }

protected:
    void paintEvent(QPaintEvent* event) override;
    void mousePressEvent(QMouseEvent* event) override;
    void mouseDoubleClickEvent(QMouseEvent* event) override;
    void mouseReleaseEvent(QMouseEvent* event) override;
    void mouseMoveEvent(QMouseEvent* event) override;
    void wheelEvent(QWheelEvent* event) override;
    void keyPressEvent(QKeyEvent* event) override;
    void resizeEvent(QResizeEvent* event) override;

private:
    // Execute all drawing commands
    void executeDrawingCommands(QPainter& painter);

    // Shared body for mousePressEvent + mouseDoubleClickEvent — both build
    // the same Lua event-table shape, differing only in the dispatched
    // type string. Helper exists to avoid a 50-line copy between two
    // virtual overrides that must stay in lockstep.
    void dispatchMousePressLikeEvent(QMouseEvent* event,
                                     const char* type_str,
                                     const char* callsite);

    // See setPanOffsetPx.
    qreal pan_offset_px_ = 0.0;

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

// Lua bindings for TimelineRenderer
extern "C" {
    void registerTimelineBindings(lua_State* L);

    int lua_timeline_clear_commands(lua_State* L);
    int lua_timeline_add_rect(lua_State* L);
    int lua_timeline_add_text(lua_State* L);
    int lua_timeline_add_line(lua_State* L);
    int lua_timeline_add_triangle(lua_State* L);
    int lua_timeline_add_waveform(lua_State* L);
    int lua_timeline_get_dimensions(lua_State* L);
    int lua_timeline_set_playhead(lua_State* L);
    int lua_timeline_get_playhead(lua_State* L);
    int lua_timeline_update(lua_State* L);
    int lua_timeline_set_mouse_event_handler(lua_State* L);
    int lua_timeline_set_key_event_handler(lua_State* L);
    int lua_timeline_set_resize_event_handler(lua_State* L);
    int lua_timeline_set_lua_state(lua_State* L);
    int lua_timeline_set_desired_height(lua_State* L);
    int lua_timeline_set_pan_offset_px(lua_State* L);
    int lua_timeline_get_commands(lua_State* L);
}
