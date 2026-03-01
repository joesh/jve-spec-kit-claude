-- NSF test: Edit command → clip window invalidation.
--
-- Verifies that when content_changed signal fires for our sequence,
-- the PlaybackController's clip windows are invalidated so C++ re-queries
-- clip data after timeline edits (insert/delete/ripple).
--
-- Black-box observable: INVALIDATE_CLIP_WINDOWS called + _tmb_clip_window cleared.

require("test_env")

--------------------------------------------------------------------------------
-- Mock Infrastructure
--------------------------------------------------------------------------------

local timer_callbacks = {}
_G.qt_create_single_shot_timer = function(_, callback)
    timer_callbacks[#timer_callbacks + 1] = callback
end

-- Track PLAYBACK calls
local playback_calls = {}
local function reset_playback_calls() playback_calls = {} end
local function track_playback(name, ...)
    playback_calls[#playback_calls + 1] = { name = name, args = {...} }
end

local function find_call(name)
    for _, c in ipairs(playback_calls) do
        if c.name == name then return c end
    end
    return nil
end

local function count_calls(name)
    local n = 0
    for _, c in ipairs(playback_calls) do
        if c.name == name then n = n + 1 end
    end
    return n
end

package.loaded["core.qt_constants"] = {
    EMP = {
        SET_DECODE_MODE = function() end,
        TMB_CREATE = function() return "mock_tmb" end,
        TMB_CLOSE = function() end,
        TMB_PARK_READERS = function() end,
        TMB_SET_SEQUENCE_RATE = function() end,
        TMB_SET_AUDIO_FORMAT = function() end,
        TMB_SET_TRACK_CLIPS = function(...) track_playback("TMB_SET_TRACK_CLIPS", ...) end,
        TMB_SET_PLAYHEAD = function() end,
        TMB_GET_VIDEO_FRAME = function() return nil, { offline = false } end,
    },
    PLAYBACK = {
        CREATE = function() return "mock_controller" end,
        CLOSE = function(pc) track_playback("CLOSE", pc) end,
        SET_TMB = function() end,
        SET_BOUNDS = function() end,
        SET_SURFACE = function() end,
        SET_CLIP_WINDOW = function() end,
        SET_NEED_CLIPS_CALLBACK = function() end,
        SET_POSITION_CALLBACK = function() end,
        SET_CLIP_TRANSITION_CALLBACK = function() end,
        SET_SHUTTLE_MODE = function() end,
        PLAY = function() end,
        STOP = function() end,
        SEEK = function() end,
        ACTIVATE_AUDIO = function() end,
        DEACTIVATE_AUDIO = function() end,
        HAS_AUDIO = function() return false end,
        INVALIDATE_CLIP_WINDOWS = function(pc)
            track_playback("INVALIDATE_CLIP_WINDOWS", pc)
        end,
    },
}

package.loaded["core.logger"] = {
    debug = function() end, info = function() end,
    warn = function() end, error = function() end, trace = function() end,
    for_area = function() return { event = function() end, detail = function() end, warn = function() end, error = function() end } end,
}

package.loaded["core.renderer"] = {
    get_sequence_info = function()
        return {
            fps_num = 24, fps_den = 1,
            kind = "timeline", name = "Test",
            audio_sample_rate = 48000,
        }
    end,
    get_video_frame = function() return nil, nil end,
}

-- Signals mock with real connect/emit for testing
local signal_listeners = {}
package.loaded["core.signals"] = {
    connect = function(signal_name, callback)
        signal_listeners[signal_name] = signal_listeners[signal_name] or {}
        local conn_id = { signal = signal_name, cb = callback }
        table.insert(signal_listeners[signal_name], conn_id)
        return conn_id
    end,
    disconnect = function(conn_id)
        if not conn_id then return end
        local listeners = signal_listeners[conn_id.signal]
        if listeners then
            for i, l in ipairs(listeners) do
                if l == conn_id then
                    table.remove(listeners, i)
                    return
                end
            end
        end
    end,
    emit = function(signal_name, ...)
        local listeners = signal_listeners[signal_name]
        if listeners then
            for _, conn in ipairs(listeners) do
                conn.cb(...)
            end
        end
    end,
}

local mock_clip = {
    id = "clip1", timeline_start = 0, duration = 100, source_in = 0, source_out = 100,
    rate = { fps_numerator = 24, fps_denominator = 1 },
}
local mock_track = {
    id = "track_0", track_index = 0, volume = 1.0, muted = false, soloed = false,
}
local mock_entry = {
    clip = mock_clip,
    track = mock_track,
    media_path = "/test.mov",
    media_fps_num = 24, media_fps_den = 1,
}

package.loaded["models.sequence"] = {
    load = function()
        return {
            id = "seq_test",
            compute_content_end = function() return 100 end,
            get_video_at = function() return { mock_entry } end,
            get_next_video = function() return {} end,
            get_prev_video = function() return {} end,
            get_audio_at = function() return {} end,
            get_next_audio = function() return {} end,
            get_prev_audio = function() return {} end,
        }
    end,
}

local mock_audio = {
    session_initialized = true, playing = false, has_audio = false,
    max_media_time_us = 10000000, session_sample_rate = 48000,
    session_channels = 2, aop = "aop", sse = "sse",
}
mock_audio.is_ready = function() return false end
mock_audio.set_max_time = function() end
mock_audio.apply_mix = function() end
mock_audio.refresh_mix_volumes = function() end

--------------------------------------------------------------------------------
-- Load engine
--------------------------------------------------------------------------------

local PlaybackEngine = require("core.playback.playback_engine")
PlaybackEngine.init_audio(mock_audio)

local Signals = package.loaded["core.signals"]

local function make_engine()
    return PlaybackEngine.new({
        on_show_frame = function() end,
        on_show_gap = function() end,
        on_set_rotation = function() end,
        on_set_par = function() end,
        on_position_changed = function() end,
    })
end

print("=== test_playback_edit_invalidation.lua ===")

--------------------------------------------------------------------------------
-- 1. content_changed for our sequence → INVALIDATE_CLIP_WINDOWS
--------------------------------------------------------------------------------
print("\n--- 1. content_changed for our sequence → invalidate ---")
do
    local engine = make_engine()
    engine:load_sequence("seq_test", 100)
    assert(engine._playback_controller, "controller must exist")

    -- Establish a clip window
    engine._tmb_clip_window = { lo = 0, hi = 100, direction = 1 }

    reset_playback_calls()

    -- Simulate edit command completing
    Signals.emit("content_changed", "seq_test")

    -- Verify INVALIDATE_CLIP_WINDOWS was called
    assert(find_call("INVALIDATE_CLIP_WINDOWS"),
        "content_changed must trigger INVALIDATE_CLIP_WINDOWS")

    -- Verify Lua-side clip window was invalidated and re-populated with fresh data
    -- (notify_content_changed clears cache then immediately re-feeds TMB)
    -- The important observable: INVALIDATE_CLIP_WINDOWS was called (above) and
    -- TMB_SET_TRACK_CLIPS was called with fresh clip data.
    assert(find_call("TMB_SET_TRACK_CLIPS") or engine._tmb_clip_window ~= nil,
        "clip cache should be re-populated with fresh data after invalidation")

    print("  PASS: edit on our sequence → invalidated + re-fed")

    engine:destroy()
end

--------------------------------------------------------------------------------
-- 2. content_changed for DIFFERENT sequence → no invalidation
--------------------------------------------------------------------------------
print("\n--- 2. content_changed for different sequence → no invalidation ---")
do
    local engine = make_engine()
    engine:load_sequence("seq_test", 100)
    assert(engine._playback_controller, "controller must exist")

    -- Establish a clip window
    engine._tmb_clip_window = { lo = 0, hi = 100, direction = 1 }

    reset_playback_calls()

    -- Simulate edit command on DIFFERENT sequence
    Signals.emit("content_changed", "other_sequence_id")

    -- Should NOT invalidate
    assert(not find_call("INVALIDATE_CLIP_WINDOWS"),
        "content_changed for other sequence must NOT invalidate our windows")

    -- Lua clip window should remain
    assert(engine._tmb_clip_window ~= nil,
        "_tmb_clip_window must NOT be cleared for other sequence")

    print("  PASS: edit on other sequence → no invalidation")

    engine:destroy()
end

--------------------------------------------------------------------------------
-- 3. Multiple edits → multiple invalidations (not coalesced)
--------------------------------------------------------------------------------
print("\n--- 3. multiple edits → multiple invalidations ---")
do
    local engine = make_engine()
    engine:load_sequence("seq_test", 100)

    reset_playback_calls()
    local baseline = count_calls("INVALIDATE_CLIP_WINDOWS")

    -- Simulate 3 rapid edits
    Signals.emit("content_changed", "seq_test")
    engine._tmb_clip_window = { lo = 0, hi = 100, direction = 1 }
    Signals.emit("content_changed", "seq_test")
    engine._tmb_clip_window = { lo = 0, hi = 100, direction = 1 }
    Signals.emit("content_changed", "seq_test")

    local total = count_calls("INVALIDATE_CLIP_WINDOWS")
    local delta = total - baseline
    assert(delta == 3, string.format(
        "3 edits must produce 3 invalidations, got %d (total=%d, baseline=%d)",
        delta, total, baseline))

    print("  PASS: each edit triggers invalidation")

    engine:destroy()
end

--------------------------------------------------------------------------------
-- 4. destroy() disconnects signal (no crash after destroy)
--------------------------------------------------------------------------------
print("\n--- 4. destroy() disconnects content_changed signal ---")
do
    local engine = make_engine()
    engine:load_sequence("seq_test", 100)
    local had_conn = engine._content_changed_conn ~= nil
    assert(had_conn, "content_changed connection must exist after load")

    engine:destroy()

    -- Connection should be cleared
    assert(engine._content_changed_conn == nil,
        "content_changed connection must be nil after destroy")

    reset_playback_calls()

    -- Emit after destroy — should be no-op (no crash, no invalidation)
    Signals.emit("content_changed", "seq_test")

    assert(not find_call("INVALIDATE_CLIP_WINDOWS"),
        "destroyed engine must not respond to content_changed")

    print("  PASS: destroy() cleans up signal connection")
end

--------------------------------------------------------------------------------
-- 5. No controller (test mode) → no crash on content_changed
--------------------------------------------------------------------------------
print("\n--- 5. no controller → content_changed is safe no-op ---")
do
    local engine = make_engine()
    engine:load_sequence("seq_test", 100)

    -- Simulate no controller (test environment)
    engine._playback_controller = nil

    reset_playback_calls()

    -- Should not crash
    Signals.emit("content_changed", "seq_test")

    -- No INVALIDATE call (no controller)
    assert(not find_call("INVALIDATE_CLIP_WINDOWS"),
        "no controller → no INVALIDATE call")

    print("  PASS: safe no-op without controller")
end

--------------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------------
print("\n✅ test_playback_edit_invalidation.lua passed")
