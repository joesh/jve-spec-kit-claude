#include "timeline_renderer.h"
#include "qt_bindings.h"
#include "jve_log.h"
#include "assert_handler.h"
#include "jve_lua_callback.h"
#include <QPaintEvent>
#include <QResizeEvent>
#include <QApplication>
#include <QWheelEvent>
#include <QPolygon>
#include <cmath>

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
    // Width: 800px default (reasonable minimum for timeline views)
    // Height: desired_height_ (default 150, configurable via setDesiredHeight)
    return QSize(800, desired_height_);
}

void TimelineRenderer::setDesiredHeight(int height)
{
    desired_height_ = height;
    setMinimumHeight(height);
    setMaximumHeight(height);
    updateGeometry();  // Tell layout to recalculate with new sizeHint
}

void TimelineRenderer::clearCommands()
{
    drawing_commands_.clear();
}

void TimelineRenderer::addRect(qreal x, qreal y, qreal width, qreal height, const QString& color)
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

void TimelineRenderer::addText(qreal x, qreal y, const QString& text, const QString& color)
{
    DrawCommand cmd;
    cmd.type = DrawCommand::TEXT;
    cmd.x = x;
    cmd.y = y;
    cmd.text = text;
    cmd.color = QColor(color);
    drawing_commands_.push_back(cmd);
}

void TimelineRenderer::addLine(qreal x1, qreal y1, qreal x2, qreal y2, const QString& color, int width)
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

void TimelineRenderer::addTriangle(qreal x1, qreal y1, qreal x2, qreal y2, qreal x3, qreal y3, const QString& color)
{
    DrawCommand cmd;
    cmd.type = DrawCommand::TRIANGLE;
    cmd.x = x1;
    cmd.y = y1;
    cmd.x2 = x2;
    cmd.y2 = y2;
    cmd.x3 = x3;
    cmd.y3 = y3;
    cmd.color = QColor(color);
    drawing_commands_.push_back(cmd);
}

void TimelineRenderer::addWaveform(qreal x, qreal y, qreal width, qreal height,
                                    const float* peaks, int peak_count,
                                    const QString& color, bool reversed)
{
    DrawCommand cmd;
    cmd.type = DrawCommand::WAVEFORM;
    cmd.x = x;
    cmd.y = y;
    cmd.width = width;
    cmd.height = height;
    cmd.color = QColor(color);
    cmd.peak_count = peak_count;
    cmd.reversed = reversed;
    if (peaks && peak_count > 0) {
        cmd.peak_data.assign(peaks, peaks + peak_count * 2);
    }
    drawing_commands_.push_back(std::move(cmd));
}

void TimelineRenderer::paintEvent(QPaintEvent* /* event */)
{
    QPainter painter(this);
    painter.setRenderHint(QPainter::Antialiasing);

    // Fill background — cool-tinted timeline canvas (#232329, B=R+6), matches
    // ui_constants TIMELINE_CANVAS_BG so the C++ base agrees with the Lua chrome.
    painter.fillRect(rect(), QColor(35, 35, 41));

    // Execute all drawing commands from Lua
    executeDrawingCommands(painter);
}

void TimelineRenderer::executeDrawingCommands(QPainter& painter)
{
    // Rect/line geometry snaps to the DEVICE pixel grid here, in the one
    // place that knows the device resolution. The Lua side delivers exact
    // float coordinates (viewport_state.time_to_pixel does no snapping);
    // a single round of that monotonic value keeps motion monotonic under
    // zoom — unlike the old difference-of-floors grid — while unsnapped
    // fractional edges under AA would paint partial-alpha seams between
    // abutting clips and make 1px boundary stripes pulse while panning.
    // Edges snap INDEPENDENTLY (left and right, not position+width), so
    // rects that share a float edge keep sharing the snapped edge —
    // gapless and seamless tiling. Pinned by testHairlineCrisp… and
    // testAbuttingRectsNoSeam.
    //
    // X snapping anchors to the CONTENT grid, not the viewport: scrolling
    // moves viewport_start in whole frames but ppf is fractional, so every
    // x coordinate shifts by a fractional device-pixel amount per step —
    // snapping viewport coordinates directly makes each clip's width
    // breathe between N and N+1 device columns at scroll positions that
    // differ per clip (the field shimmers while panning). snapX rounds
    // (v + pan) on the device grid and translates back by the pan offset
    // rounded to whole device pixels: panning becomes a rigid translation
    // (widths invariant), results stay on the device grid (crisp), and a
    // single round of a monotonic value keeps zoom motion monotonic.
    // Pinned by testClipWidthRigidWhilePanning. Y needs no anchor:
    // vertical scroll offsets are whole logical pixels.
    const qreal dpr = devicePixelRatioF();
    const qreal pan = pan_offset_px_;
    const qreal pan_snapped = std::round(pan * dpr) / dpr;
    const auto snapX = [dpr, pan, pan_snapped](qreal v) {
        return std::round((v + pan) * dpr) / dpr - pan_snapped;
    };
    const auto snapY = [dpr](qreal v) { return std::round(v * dpr) / dpr; };

    for (const auto& cmd : drawing_commands_) {
        painter.setPen(QPen(cmd.color, cmd.line_width));
        painter.setBrush(QBrush(cmd.color));

        switch (cmd.type) {
            case DrawCommand::RECT: {
                const qreal left = snapX(cmd.x);
                const qreal top = snapY(cmd.y);
                const qreal right = snapX(cmd.x + cmd.width);
                const qreal bottom = snapY(cmd.y + cmd.height);
                painter.fillRect(QRectF(left, top, right - left, bottom - top), cmd.color);
                break;
            }

            case DrawCommand::TEXT:
                painter.setPen(cmd.color);
                painter.drawText(QPointF(cmd.x, cmd.y), cmd.text);
                break;

            case DrawCommand::LINE:
                painter.setPen(QPen(cmd.color, cmd.line_width));
                painter.drawLine(QLineF(snapX(cmd.x), snapY(cmd.y), snapX(cmd.x2), snapY(cmd.y2)));
                break;

            case DrawCommand::TRIANGLE: {
                QPolygonF triangle;
                triangle << QPointF(cmd.x, cmd.y)
                         << QPointF(cmd.x2, cmd.y2)
                         << QPointF(cmd.x3, cmd.y3);
                painter.setPen(Qt::NoPen);
                painter.setBrush(cmd.color);
                painter.drawPolygon(triangle);
                break;
            }

            case DrawCommand::WAVEFORM: {
                if (cmd.peak_count <= 0 || cmd.width <= 0) break;
                if (static_cast<int>(cmd.peak_data.size()) < cmd.peak_count * 2) break;
                qreal center_y = cmd.y + cmd.height * 0.5;
                qreal half_h = cmd.height * 0.5;
                qreal px_step = cmd.width / cmd.peak_count;
                // Each peak fills a vertical band [px_start, px_end) so when
                // peak_count < width (the common case — mipmaps return one
                // peak per N source samples, often fewer than the visible
                // pixel column count) adjacent bands tile without leaving
                // 1-pixel "comb teeth" gaps. Pre-fix used drawLine(px,y0,px,y1)
                // which only painted the line's anchor column.
                painter.setPen(Qt::NoPen);
                painter.setBrush(cmd.color);
                for (int i = 0; i < cmd.peak_count; ++i) {
                    // Reverse clips: peak[0] is still the earliest source sample
                    // but the leftmost pixel should show the LATEST source sample,
                    // so walk the peak array backward.
                    int pi = cmd.reversed ? (cmd.peak_count - 1 - i) : i;
                    float mn = cmd.peak_data[pi * 2];
                    float mx = cmd.peak_data[pi * 2 + 1];
                    if (mn >= mx) continue;   // true silence: nothing to draw
                    qreal y0 = center_y - mx * half_h;
                    qreal y1 = center_y - mn * half_h;
                    // At small wave_heights, low-amplitude peaks have
                    // (mx - mn) * half_h < 1. Without clamping to 1 here,
                    // the band thins toward invisibility at small track
                    // heights. NLE convention is to compress (not hide)
                    // low-amp peaks.
                    qreal band_h = y1 - y0;
                    if (band_h < 1) band_h = 1;
                    // band_w < 1 happens when px_step < 1 (peak_count >
                    // width, i.e. extreme zoom-out). Clamp to 1 so the peak
                    // is still visible — overlapping peaks then paint over
                    // each other, which is the right semantic for "too
                    // zoomed out to see each peak". Not a fallback hiding
                    // a bug.
                    qreal band_w = px_step;
                    if (band_w < 1) band_w = 1;
                    // Same device-grid edge snapping as RECT — adjacent
                    // bands share float edges, so they keep tiling.
                    const qreal bl = snapX(cmd.x + i * px_step);
                    const qreal br = snapX(cmd.x + i * px_step + band_w);
                    painter.drawRect(QRectF(bl, snapY(y0), br - bl, snapY(y0 + band_h) - snapY(y0)));
                }
                break;
            }
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

void TimelineRenderer::dispatchMousePressLikeEvent(QMouseEvent* event,
                                                   const char* type_str,
                                                   const char* callsite)
{
    if (mouse_event_handler_.empty() || !lua_state_) return;

    lua_getglobal(lua_state_, mouse_event_handler_.c_str());
    if (!lua_isfunction(lua_state_, -1)) {
        jve_discard_non_function_handler(lua_state_, mouse_event_handler_.c_str(), callsite);
        return;
    }

    lua_newtable(lua_state_);
    lua_pushstring(lua_state_, type_str);
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

    JveLuaStateGuard guard(lua_state_);
    if (lua_pcall(lua_state_, 1, 0, 0) != LUA_OK) {
        jve_handle_lua_callback_error(lua_state_, callsite);
    }
}

void TimelineRenderer::mousePressEvent(QMouseEvent* event)
{
    dispatchMousePressLikeEvent(event, "press", "TimelineRenderer.mouse_press");
    QWidget::mousePressEvent(event);
}

// 019 FR-026: timeline clip double-click routes through the same Lua
// mouse-event handler as press, with type="double_click". The Lua side
// (timeline_view_input.handle_mouse) branches on the type field.
void TimelineRenderer::mouseDoubleClickEvent(QMouseEvent* event)
{
    dispatchMousePressLikeEvent(event, "double_click", "TimelineRenderer.mouse_double_click");
    QWidget::mouseDoubleClickEvent(event);
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

            {
                JveLuaStateGuard guard(lua_state_);
                if (lua_pcall(lua_state_, 1, 0, 0) != LUA_OK) {
                    jve_handle_lua_callback_error(lua_state_, "TimelineRenderer.mouse_release");
                }
            }
        } else {
            jve_discard_non_function_handler(lua_state_, mouse_event_handler_.c_str(), "TimelineRenderer.mouse_release");
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

            {
                JveLuaStateGuard guard(lua_state_);
                if (lua_pcall(lua_state_, 1, 0, 0) != LUA_OK) {
                    jve_handle_lua_callback_error(lua_state_, "TimelineRenderer.mouse_move");
                }
            }
        } else {
            jve_discard_non_function_handler(lua_state_, mouse_event_handler_.c_str(), "TimelineRenderer.mouse_move");
        }
    }
    QWidget::mouseMoveEvent(event);
}

void TimelineRenderer::wheelEvent(QWheelEvent* event)
{
    // Propagate the wheel event to the parent QScrollArea by default.
    // The Lua handler may opt out by returning false — used by the timeline
    // view's asymmetric axis lock to pin vertical position when it judges
    // the gesture to be horizontal-dominant. Without that opt-out, the
    // parent QScrollArea would scroll vertically using the original raw dy
    // even after Lua suppressed it for the horizontal-only viewport path.
    bool propagate = true;

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

            // Forward Qt's scroll-phase enum so Lua can detect a fresh
            // fingers-down touch (ScrollBegin) and hard-reset its axis
            // lock. On macOS the momentum tail (ScrollMomentum) emits
            // events at ~60Hz for 1-2s after fingers lift, bridging
            // any timestamp-gap heuristic; phase is the only authoritative
            // signal that a new gesture has started.
            const char* phase_str = nullptr;
            switch (event->phase()) {
                case Qt::ScrollBegin:        phase_str = "begin";    break;
                case Qt::ScrollUpdate:       phase_str = "update";   break;
                case Qt::ScrollEnd:          phase_str = "end";      break;
                case Qt::ScrollMomentum:     phase_str = "momentum"; break;
                case Qt::NoScrollPhase:      phase_str = "none";     break;
            }
            // The Lua-side axis lock keys ONLY on phase=="begin" to
            // reset; an unrecognised value would silently behave as
            // "not begin" (the bug we are trying to fix) so refuse it
            // here rather than substitute a default. The enum is closed
            // in Qt 6.x; this fires only if Qt adds a new value.
            JVE_ASSERT(phase_str != nullptr,
                "TimelineRenderer.wheel: unrecognised Qt::ScrollPhase value");
            lua_pushstring(lua_state_, phase_str);
            lua_setfield(lua_state_, -2, "scroll_phase");

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

            {
                JveLuaStateGuard guard(lua_state_);
                if (lua_pcall(lua_state_, 1, 1, 0) != LUA_OK) {
                    jve_handle_lua_callback_error(lua_state_, "TimelineRenderer.wheel");
                } else {
                    // Wheel handler protocol: must return a boolean
                    // indicating whether C++ should propagate the event
                    // to the parent QScrollArea. Non-boolean return is a
                    // contract violation — log loudly (matches the
                    // log-and-continue pattern used by every other Lua
                    // callback site so the editor stays running for the
                    // user's session) and fall back to propagate=false
                    // (event consumed; safest non-surprising default
                    // since wheel handlers exist precisely to do
                    // something with the event).
                    if (lua_isboolean(lua_state_, -1)) {
                        propagate = lua_toboolean(lua_state_, -1) != 0;
                    } else {
                        JVE_LOG_ERROR(Ui,
                            "TimelineRenderer.wheel: Lua handler '%s' must return "
                            "a boolean (got %s) — defaulting to propagate=false",
                            mouse_event_handler_.c_str(),
                            lua_typename(lua_state_, lua_type(lua_state_, -1)));
                    }
                    lua_pop(lua_state_, 1);
                }
            }
        } else {
            jve_discard_non_function_handler(lua_state_, mouse_event_handler_.c_str(), "TimelineRenderer.wheel");
        }
    }

    if (propagate) {
        QWidget::wheelEvent(event);
    } else {
        event->accept();
    }
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

            {
                JveLuaStateGuard guard(lua_state_);
                if (lua_pcall(lua_state_, 1, 0, 0) != LUA_OK) {
                    jve_handle_lua_callback_error(lua_state_, "TimelineRenderer.key_press");
                }
            }
        } else {
            jve_discard_non_function_handler(lua_state_, key_event_handler_.c_str(), "TimelineRenderer.key_press");
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

            {
                JveLuaStateGuard guard(lua_state_);
                if (lua_pcall(lua_state_, 1, 0, 0) != LUA_OK) {
                    jve_handle_lua_callback_error(lua_state_, "TimelineRenderer.resize");
                }
            }
        } else {
            jve_discard_non_function_handler(lua_state_, resize_event_handler_.c_str(), "TimelineRenderer.resize");
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

    lua_pushcfunction(L, lua_timeline_add_triangle);
    lua_setfield(L, -2, "add_triangle");

    lua_pushcfunction(L, lua_timeline_add_waveform);
    lua_setfield(L, -2, "add_waveform");

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

    lua_pushcfunction(L, lua_timeline_set_desired_height);
    lua_setfield(L, -2, "set_desired_height");

    lua_pushcfunction(L, lua_timeline_set_pan_offset_px);
    lua_setfield(L, -2, "set_pan_offset_px");

    lua_pushcfunction(L, lua_timeline_get_commands);
    lua_setfield(L, -2, "get_commands");

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
    qreal x = lua_tonumber(L, 2);
    qreal y = lua_tonumber(L, 3);
    qreal width = lua_tonumber(L, 4);
    qreal height = lua_tonumber(L, 5);
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
    qreal x = lua_tonumber(L, 2);
    qreal y = lua_tonumber(L, 3);
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
    qreal x1 = lua_tonumber(L, 2);
    qreal y1 = lua_tonumber(L, 3);
    qreal x2 = lua_tonumber(L, 4);
    qreal y2 = lua_tonumber(L, 5);
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

int lua_timeline_add_triangle(lua_State* L)
{
    JVE::TimelineRenderer* timeline = (JVE::TimelineRenderer*)lua_to_widget(L, 1);
    qreal x1 = lua_tonumber(L, 2);
    qreal y1 = lua_tonumber(L, 3);
    qreal x2 = lua_tonumber(L, 4);
    qreal y2 = lua_tonumber(L, 5);
    qreal x3 = lua_tonumber(L, 6);
    qreal y3 = lua_tonumber(L, 7);
    const char* color = lua_tostring(L, 8);

    if (timeline && color) {
        timeline->addTriangle(x1, y1, x2, y2, x3, y3, QString(color));
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_timeline_add_waveform(lua_State* L)
{
    JVE::TimelineRenderer* timeline = (JVE::TimelineRenderer*)lua_to_widget(L, 1);
    qreal x = lua_tonumber(L, 2);
    qreal y = lua_tonumber(L, 3);
    qreal width = lua_tonumber(L, 4);
    qreal height = lua_tonumber(L, 5);
    // Arg 6: lightuserdata pointer to float array [min0,max0,min1,max1,...]
    const float* peaks = nullptr;
    if (lua_islightuserdata(L, 6)) {
        peaks = static_cast<const float*>(lua_touserdata(L, 6));
    }
    int peak_count = lua_tointeger(L, 7);
    const char* color = lua_tostring(L, 8);
    // Arg 9 (optional): boolean — draw peaks right-to-left for reverse clips.
    bool reversed = lua_toboolean(L, 9) != 0;

    if (timeline && peaks && peak_count > 0 && color) {
        timeline->addWaveform(x, y, width, height, peaks, peak_count, QString(color), reversed);
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

int lua_timeline_set_desired_height(lua_State* L)
{
    JVE::TimelineRenderer* timeline = (JVE::TimelineRenderer*)lua_to_widget(L, 1);
    int height = luaL_checkinteger(L, 2);

    if (timeline) {
        timeline->setDesiredHeight(height);
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_timeline_set_pan_offset_px(lua_State* L)
{
    JVE::TimelineRenderer* timeline = (JVE::TimelineRenderer*)lua_to_widget(L, 1);
    qreal pan_px = luaL_checknumber(L, 2);

    if (timeline) {
        timeline->setPanOffsetPx(pan_px);
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

// Read back the real pending draw-command queue as an array of tables.
// Test witness: renderer tests assert on what will actually be painted —
// produced through the real bindings — instead of stubbing the timeline
// global. Fields mirror DrawCommand; type is "rect"|"text"|"line"|
// "triangle"|"waveform".
int lua_timeline_get_commands(lua_State* L)
{
    JVE::TimelineRenderer* timeline = (JVE::TimelineRenderer*)lua_to_widget(L, 1);
    if (!timeline) {
        lua_pushnil(L);
        return 1;
    }

    const auto& cmds = timeline->commands();
    lua_createtable(L, static_cast<int>(cmds.size()), 0);
    int index = 1;
    for (const auto& cmd : cmds) {
        lua_newtable(L);

        const char* type_name = nullptr;
        switch (cmd.type) {
            case JVE::TimelineRenderer::DrawCommand::RECT:     type_name = "rect"; break;
            case JVE::TimelineRenderer::DrawCommand::TEXT:     type_name = "text"; break;
            case JVE::TimelineRenderer::DrawCommand::LINE:     type_name = "line"; break;
            case JVE::TimelineRenderer::DrawCommand::TRIANGLE: type_name = "triangle"; break;
            case JVE::TimelineRenderer::DrawCommand::WAVEFORM: type_name = "waveform"; break;
        }
        lua_pushstring(L, type_name);
        lua_setfield(L, -2, "type");

        lua_pushnumber(L, cmd.x);  lua_setfield(L, -2, "x");
        lua_pushnumber(L, cmd.y);  lua_setfield(L, -2, "y");
        lua_pushnumber(L, cmd.width);  lua_setfield(L, -2, "width");
        lua_pushnumber(L, cmd.height); lua_setfield(L, -2, "height");
        lua_pushnumber(L, cmd.x2); lua_setfield(L, -2, "x2");
        lua_pushnumber(L, cmd.y2); lua_setfield(L, -2, "y2");
        lua_pushnumber(L, cmd.x3); lua_setfield(L, -2, "x3");
        lua_pushnumber(L, cmd.y3); lua_setfield(L, -2, "y3");

        lua_pushstring(L, cmd.color.name().toUtf8().constData());
        lua_setfield(L, -2, "color");
        lua_pushinteger(L, cmd.line_width);
        lua_setfield(L, -2, "line_width");

        if (cmd.type == JVE::TimelineRenderer::DrawCommand::TEXT) {
            lua_pushstring(L, cmd.text.toUtf8().constData());
            lua_setfield(L, -2, "text");
        }
        if (cmd.type == JVE::TimelineRenderer::DrawCommand::WAVEFORM) {
            lua_pushinteger(L, cmd.peak_count);
            lua_setfield(L, -2, "peak_count");
            lua_pushboolean(L, cmd.reversed);
            lua_setfield(L, -2, "reversed");
        }

        lua_rawseti(L, -2, index++);
    }
    return 1;
}
