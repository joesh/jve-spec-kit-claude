#!/usr/bin/env luajit

-- Test source monitor viewport zoom: zoom_by, zoom_to_fit, playhead follow,
-- mark bar viewport-aware rendering (frame_to_x / x_to_frame).
-- Uses real SequenceMonitor with mock Qt/media infrastructure.

require("test_env")

--------------------------------------------------------------------------------
-- Mock Infrastructure (same pattern as test_sequence_monitor.lua)
--------------------------------------------------------------------------------

local timer_callbacks = {}
_G.qt_create_single_shot_timer = function(interval, callback)
    timer_callbacks[#timer_callbacks + 1] = callback
end

local qt_log = {}

package.loaded["core.qt_constants"] = {
    EMP = {
        SET_DECODE_MODE = function() end,
        MEDIA_FILE_OPEN = function() return nil end,
        MEDIA_FILE_INFO = function() return nil end,
        MEDIA_FILE_CLOSE = function() end,
        READER_CREATE = function() return nil end,
        READER_CLOSE = function() end,
        READER_DECODE_FRAME = function() return nil end,
        FRAME_RELEASE = function() end,
        PCM_RELEASE = function() end,
        TMB_CREATE = function() return "mock_tmb" end,
        TMB_CLOSE = function() end,
        TMB_PARK_READERS = function() end,
        TMB_SET_SEQUENCE_RATE = function() end,
        TMB_SET_AUDIO_FORMAT = function() end,
        TMB_SET_TRACK_CLIPS = function() end,
        TMB_SET_PLAYHEAD = function() end,
        TMB_GET_VIDEO_FRAME = function() return nil, { offline = false } end,
        SURFACE_SET_FRAME = function(surface, frame)
            qt_log[#qt_log + 1] = { type = "set_frame", surface = surface, frame = frame }
        end,
        SURFACE_SET_ROTATION = function() end,
        SURFACE_SET_PAR = function() end,
    },
    WIDGET = {
        CREATE = function() return { _type = "widget" } end,
        CREATE_LABEL = function(text) return { _type = "label", _text = text } end,
        CREATE_GPU_VIDEO_SURFACE = function() return { _type = "gpu_surface" } end,
        CREATE_TIMELINE = function() return { _type = "timeline_widget" } end,
    },
    LAYOUT = {
        CREATE_VBOX = function() return { _type = "vbox" } end,
        SET_SPACING = function() end,
        SET_MARGINS = function() end,
        ADD_WIDGET = function() end,
        SET_ON_WIDGET = function() end,
        SET_STRETCH_FACTOR = function() end,
    },
    PROPERTIES = {
        SET_STYLE = function() end,
        SET_TEXT = function(label, text) if label then label._text = text end end,
    },
    GEOMETRY = { SET_SIZE_POLICY = function() end },
    CONTROL = { SET_WIDGET_SIZE_POLICY = function() end },
    PLAYBACK = {
        CREATE = function() return "mock_pc" end,
        CLOSE = function() end,
        SET_TMB = function() end,
        SET_BOUNDS = function() end,
        SET_CLIP_PROVIDER = function() end,
        RELOAD_ALL_CLIPS = function() end,
        SET_SURFACE = function() end,
        SET_POSITION_CALLBACK = function() end,
        SET_CLIP_TRANSITION_CALLBACK = function() end,
        PARK = function() end,
        SEEK = function() end,
        STOP = function() end,
        PLAY = function() end,
        HAS_AUDIO = function() return false end,
        SET_SHUTTLE_MODE = function() end,
        ACTIVATE_AUDIO = function() end,
        DEACTIVATE_AUDIO = function() end,
        PLAY_BURST = function() end,
        TICK = function() end,
    },
}

_G.timeline = {
    get_dimensions = function() return 400, 20 end,
    clear_commands = function() end,
    add_rect = function() end,
    add_line = function() end,
    add_triangle = function() end,
    add_text = function() end,
    update = function() end,
    set_lua_state = function() end,
    set_mouse_event_handler = function() end,
    set_resize_event_handler = function() end,
    set_desired_height = function() end,
}

package.loaded["core.logger"] = {
    for_area = function() return {
        event = function() end, detail = function() end,
        warn = function() end, error = function() end,
    } end,
}

local mock_renderer_info = {}
package.loaded["core.renderer"] = {
    get_sequence_info = function(seq_id)
        if mock_renderer_info[seq_id] then return mock_renderer_info[seq_id] end
        return { fps_num = 24, fps_den = 1, kind = "masterclip",
                 name = "Test", audio_sample_rate = 48000 }
    end,
    get_video_frame = function() return nil, nil end,
}

package.loaded["core.mixer"] = {
    resolve_audio_sources = function() return {}, {} end,
}

local signal_handlers = {}
package.loaded["core.signals"] = {
    connect = function(name, handler)
        signal_handlers[name] = signal_handlers[name] or {}
        local id = #signal_handlers[name] + 1
        signal_handlers[name][id] = handler
        return id
    end,
    disconnect = function() end,
    emit = function(name, ...)
        for _, handler in ipairs(signal_handlers[name] or {}) do handler(...) end
    end,
}

--------------------------------------------------------------------------------
-- Initialize real DB + models
--------------------------------------------------------------------------------

local database = require("core.database")
local test_env = require("test_env")

local TEST_DB = "/tmp/jve/test_source_zoom.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")

database.init(TEST_DB)
local db = database.get_connection()
db:exec(require("import_schema"))

-- Create a project + media + masterclip sequence
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('proj1', 'Test Project', %d, %d);

    INSERT INTO media (id, project_id, file_path, name, duration_frames,
        fps_numerator, fps_denominator, width, height, created_at, modified_at)
    VALUES ('media1', 'proj1', '/test/clip.mov', 'TestClip', 300, 24, 1,
        1920, 1080, %d, %d);
]], now, now, now, now))

local mc_id = test_env.create_test_masterclip_sequence(
    "proj1", "TestClip", 24, 1, 300, "media1")

mock_renderer_info[mc_id] = {
    fps_num = 24, fps_den = 1,
    kind = "masterclip", name = "TestClip",
    audio_sample_rate = 48000,
}

--------------------------------------------------------------------------------
-- Load SequenceMonitor
--------------------------------------------------------------------------------

local SequenceMonitor = require("ui.sequence_monitor")

print("=== Source Monitor Zoom Tests ===")

--------------------------------------------------------------------------------
-- Test 1: Viewport initializes to full extent on load_sequence
--------------------------------------------------------------------------------
print("\n--- Test 1: viewport init ---")
local sm = SequenceMonitor.new({ view_id = "source_monitor" })
sm:load_sequence(mc_id)
assert(sm.total_frames == 300, "total_frames should be 300, got " .. sm.total_frames)
assert(sm.viewport_start == 0, "viewport_start should be 0, got " .. sm.viewport_start)
assert(sm.viewport_duration == 300, "viewport_duration should be 300, got " .. sm.viewport_duration)
print("  ok: viewport = [0, 300)")

--------------------------------------------------------------------------------
-- Test 2: zoom_by(0.8) reduces viewport by 20%, centered on playhead
--------------------------------------------------------------------------------
print("\n--- Test 2: zoom_by(0.8) ---")
sm.playhead = 150  -- center
sm:zoom_by(0.8)
assert(sm.viewport_duration == 240, "viewport_duration should be 240, got " .. sm.viewport_duration)
-- Centered on playhead=150: start = 150 - 120 = 30
assert(sm.viewport_start == 30, "viewport_start should be 30, got " .. sm.viewport_start)
print("  ok: viewport = [30, 270) dur=240")

--------------------------------------------------------------------------------
-- Test 3: zoom_by(1.25) increases viewport by 25%
--------------------------------------------------------------------------------
print("\n--- Test 3: zoom_by(1.25) ---")
sm:zoom_by(1.25)
-- 240 * 1.25 = 300 (full extent)
assert(sm.viewport_duration == 300, "viewport_duration should be 300, got " .. sm.viewport_duration)
assert(sm.viewport_start == 0, "viewport_start should be 0, got " .. sm.viewport_start)
print("  ok: viewport = [0, 300) dur=300")

--------------------------------------------------------------------------------
-- Test 4: zoom_by enforces minimum 30 frames
--------------------------------------------------------------------------------
print("\n--- Test 4: minimum viewport ---")
sm.playhead = 150
-- Zoom way in: start at 300, multiply by 0.1 repeatedly
sm:zoom_by(0.1)
assert(sm.viewport_duration == 30, "minimum viewport should be 30, got " .. sm.viewport_duration)
print("  ok: clamped to 30 frames")

--------------------------------------------------------------------------------
-- Test 5: zoom_to_fit resets to full extent
--------------------------------------------------------------------------------
print("\n--- Test 5: zoom_to_fit ---")
sm:zoom_to_fit()
assert(sm.viewport_start == 0, "viewport_start should be 0, got " .. sm.viewport_start)
assert(sm.viewport_duration == 300, "viewport_duration should be 300, got " .. sm.viewport_duration)
print("  ok: reset to [0, 300)")

--------------------------------------------------------------------------------
-- Test 6: set_viewport clamping
--------------------------------------------------------------------------------
print("\n--- Test 6: set_viewport clamps ---")
sm:set_viewport(-10, 500)
assert(sm.viewport_start == 0, "start clamped to 0, got " .. sm.viewport_start)
assert(sm.viewport_duration == 300, "dur clamped to 300, got " .. sm.viewport_duration)

sm:set_viewport(280, 100)
-- start clamped: 300 - 100 = 200
assert(sm.viewport_start == 200, "start clamped to 200, got " .. sm.viewport_start)
assert(sm.viewport_duration == 100, "dur should be 100, got " .. sm.viewport_duration)
print("  ok: clamping works")

--------------------------------------------------------------------------------
-- Test 7: zoom_by centers on playhead near start
--------------------------------------------------------------------------------
print("\n--- Test 7: zoom_by near start ---")
sm:zoom_to_fit()
sm.playhead = 10
sm:zoom_by(0.5)
-- dur = 150, center on 10: start = 10 - 75 = -65 → clamped to 0
assert(sm.viewport_start == 0, "start clamped to 0, got " .. sm.viewport_start)
assert(sm.viewport_duration == 150, "dur should be 150, got " .. sm.viewport_duration)
print("  ok: clamped start to 0")

--------------------------------------------------------------------------------
-- Test 8: zoom_by centers on playhead near end
--------------------------------------------------------------------------------
print("\n--- Test 8: zoom_by near end ---")
sm:zoom_to_fit()
sm.playhead = 290
sm:zoom_by(0.5)
-- dur = 150, center on 290: start = 290 - 75 = 215 → clamped to 300-150 = 150
assert(sm.viewport_start == 150, "start clamped to 150, got " .. sm.viewport_start)
assert(sm.viewport_duration == 150, "dur should be 150, got " .. sm.viewport_duration)
print("  ok: clamped start to 150")

--------------------------------------------------------------------------------
-- Test 9: Playhead follow — playhead exits viewport right
--------------------------------------------------------------------------------
print("\n--- Test 9: playhead follow right ---")
sm:set_viewport(0, 100)
sm:set_playhead(120)
-- Playhead at 120, viewport was [0, 100). Should shift right.
assert(sm.viewport_start > 0, "viewport should shift right, start=" .. sm.viewport_start)
assert(sm.playhead >= sm.viewport_start,
    "playhead should be >= viewport_start")
assert(sm.playhead < sm.viewport_start + sm.viewport_duration,
    "playhead should be < viewport end")
print("  ok: viewport shifted to contain playhead")

--------------------------------------------------------------------------------
-- Test 10: Playhead follow — playhead exits viewport left
--------------------------------------------------------------------------------
print("\n--- Test 10: playhead follow left ---")
sm:set_viewport(100, 100)
sm:set_playhead(50)
assert(sm.viewport_start == 50, "viewport_start should be 50, got " .. sm.viewport_start)
print("  ok: viewport shifted left to playhead")

--------------------------------------------------------------------------------
-- Test 11: Playhead follow — no shift when zoomed to fit
--------------------------------------------------------------------------------
print("\n--- Test 11: no shift at full zoom ---")
sm:zoom_to_fit()
sm:set_playhead(150)
assert(sm.viewport_start == 0, "viewport_start should stay 0, got " .. sm.viewport_start)
assert(sm.viewport_duration == 300, "viewport_duration should stay 300, got " .. sm.viewport_duration)
print("  ok: no shift at full extent")

--------------------------------------------------------------------------------
-- Test 12: Viewport resets on load_sequence
--------------------------------------------------------------------------------
print("\n--- Test 12: viewport resets on load ---")
sm:set_viewport(50, 100)
assert(sm.viewport_start == 50, "pre-condition")
sm:load_sequence(mc_id)
assert(sm.viewport_start == 0, "viewport_start should reset to 0, got " .. sm.viewport_start)
assert(sm.viewport_duration == 300, "viewport_duration should reset to 300, got " .. sm.viewport_duration)
print("  ok: viewport reset on load")

--------------------------------------------------------------------------------
-- Test 13: Mark bar frame_to_x with viewport
--------------------------------------------------------------------------------
print("\n--- Test 13: mark bar frame_to_x ---")
-- Test the viewport-aware conversion math directly
-- Simulates what monitor_mark_bar does internally
local function frame_to_x(frame, width, vp_start, vp_dur)
    if vp_dur <= 0 then return 0 end
    return math.floor(((frame - vp_start) / vp_dur) * width + 0.5)
end

local function x_to_frame(x, width, vp_start, vp_dur, total)
    if vp_dur <= 0 or width <= 0 then return 0 end
    local frame = math.floor(vp_start + (x / width) * vp_dur + 0.5)
    return math.max(0, math.min(frame, total - 1))
end

-- Full extent: [0, 300), width=400
assert(frame_to_x(0, 400, 0, 300) == 0, "frame 0 at full zoom")
assert(frame_to_x(150, 400, 0, 300) == 200, "frame 150 at full zoom")
assert(frame_to_x(300, 400, 0, 300) == 400, "frame 300 at full zoom")

-- Zoomed in: viewport [100, 200), width=400
assert(frame_to_x(100, 400, 100, 100) == 0, "frame 100 at viewport start")
assert(frame_to_x(150, 400, 100, 100) == 200, "frame 150 at viewport center")
assert(frame_to_x(200, 400, 100, 100) == 400, "frame 200 at viewport end")

-- Outside viewport renders off-screen
assert(frame_to_x(50, 400, 100, 100) == -200, "frame 50 below viewport")
assert(frame_to_x(250, 400, 100, 100) == 600, "frame 250 above viewport")

print("  ok: frame_to_x viewport math")

--------------------------------------------------------------------------------
-- Test 14: Mark bar x_to_frame with viewport
--------------------------------------------------------------------------------
print("\n--- Test 14: mark bar x_to_frame ---")
-- Full extent: click at x=200 in 400px wide bar, total=300
assert(x_to_frame(200, 400, 0, 300, 300) == 150, "click center at full zoom")

-- Zoomed: viewport [100, 200), click at x=200
assert(x_to_frame(200, 400, 100, 100, 300) == 150, "click center when zoomed")
assert(x_to_frame(0, 400, 100, 100, 300) == 100, "click left when zoomed")
assert(x_to_frame(400, 400, 100, 100, 300) == 200, "click right when zoomed")

-- Clamp to valid range
assert(x_to_frame(0, 400, 0, 300, 300) == 0, "x=0 maps to frame 0")
assert(x_to_frame(400, 400, 0, 300, 300) == 299, "x=width clamps to total-1")

print("  ok: x_to_frame viewport math")

--------------------------------------------------------------------------------
-- Test 15: Viewport accessors
--------------------------------------------------------------------------------
print("\n--- Test 15: viewport accessors ---")
sm:set_viewport(50, 100)
assert(sm:get_viewport_start() == 50, "get_viewport_start")
assert(sm:get_viewport_duration() == 100, "get_viewport_duration")
print("  ok: accessors work")

--------------------------------------------------------------------------------
-- NSF: Error paths
--------------------------------------------------------------------------------

print("\n--- Test 16: zoom_by rejects invalid factor ---")
local expect_error = test_env.expect_error
expect_error(function() sm:zoom_by(0) end, "positive number")
expect_error(function() sm:zoom_by(-1) end, "positive number")
expect_error(function() sm:zoom_by(nil) end, "positive number")
expect_error(function() sm:zoom_by("two") end, "positive number")
print("  ok: zoom_by rejects 0, negative, nil, string")

print("\n--- Test 17: set_viewport rejects non-numbers ---")
expect_error(function() sm:set_viewport(nil, 100) end, "must be numbers")
expect_error(function() sm:set_viewport(0, nil) end, "must be numbers")
expect_error(function() sm:set_viewport("a", 100) end, "must be numbers")
print("  ok: set_viewport rejects nil and string")

print("\n--- Test 18: zoom_by no-op on unloaded monitor ---")
local sm2 = SequenceMonitor.new({ view_id = "test_unloaded" })
-- total_frames = 0, viewport_duration = 0
sm2:zoom_by(0.8)  -- should silently no-op (total_frames <= 0)
assert(sm2.viewport_duration == 0, "unloaded monitor: viewport_duration stays 0")
assert(sm2.viewport_start == 0, "unloaded monitor: viewport_start stays 0")
sm2:destroy()
print("  ok: zoom_by no-op on unloaded monitor")

print("\n--- Test 19: zoom_by(1.0) preserves viewport ---")
sm:load_sequence(mc_id)
sm:set_viewport(50, 100)
sm.playhead = 100
sm:zoom_by(1.0)
-- factor=1.0: new_dur = floor(100*1.0) = 100 (unchanged)
-- Center on playhead=100: start = 100 - 50 = 50
assert(sm.viewport_duration == 100, "zoom_by(1.0) preserves duration, got " .. sm.viewport_duration)
assert(sm.viewport_start == 50, "zoom_by(1.0) re-centers on playhead, got " .. sm.viewport_start)
print("  ok: zoom_by(1.0) preserves duration")

--------------------------------------------------------------------------------
-- NSF: Output invariant — content_changed shrinks total below viewport
--------------------------------------------------------------------------------

print("\n--- Test 20: content_changed shrinks total below viewport range ---")
sm:load_sequence(mc_id)
sm:set_viewport(100, 100)
-- viewport = [100, 200). Simulate total_frames shrinking to 150 via signal.
-- viewport_start(100) + viewport_duration(100) = 200 > 150.
-- The handler must clamp so viewport doesn't extend past total_frames.
-- Override notify_content_changed so engine.total_frames sticks at 150.
local orig_notify = sm.engine.notify_content_changed
sm.engine.notify_content_changed = function() end
sm.engine.total_frames = 150
package.loaded["core.signals"].emit("content_changed", sm.sequence_id)
assert(sm.total_frames == 150, "total_frames should be 150, got " .. sm.total_frames)
local vp_end = sm.viewport_start + sm.viewport_duration
assert(vp_end <= sm.total_frames,
    string.format("viewport must not extend past total: vp_end=%d total=%d",
        vp_end, sm.total_frames))
assert(sm.viewport_start >= 0, "viewport_start must be >= 0")
print("  ok: viewport clamped after content shrink")
-- Restore
sm.engine.notify_content_changed = orig_notify
sm.engine.total_frames = 300

--------------------------------------------------------------------------------
-- NSF: Output invariant — viewport bounds postcondition
--------------------------------------------------------------------------------

print("\n--- Test 21: zoom_by postcondition invariants ---")
sm:load_sequence(mc_id)
-- Reset to known state
sm.playhead = 50
for _, factor in ipairs({0.1, 0.5, 0.8, 1.0, 1.25, 2.0, 10.0}) do
    sm:zoom_by(factor)
    assert(sm.viewport_start >= 0,
        string.format("postcond: viewport_start >= 0 (got %d, factor=%.1f)",
            sm.viewport_start, factor))
    assert(sm.viewport_duration >= 30,
        string.format("postcond: viewport_duration >= MIN (got %d, factor=%.1f)",
            sm.viewport_duration, factor))
    assert(sm.viewport_start + sm.viewport_duration <= sm.total_frames,
        string.format("postcond: viewport end <= total (got %d+%d=%d > %d, factor=%.1f)",
            sm.viewport_start, sm.viewport_duration,
            sm.viewport_start + sm.viewport_duration, sm.total_frames, factor))
end
print("  ok: all zoom factors maintain viewport invariants")

--------------------------------------------------------------------------------
-- Cleanup
--------------------------------------------------------------------------------
sm:destroy()
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")

print("\n✅ test_source_zoom.lua passed")
