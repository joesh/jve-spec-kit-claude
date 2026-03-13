-- NSF test: Edit command → clip reload via RELOAD_ALL_CLIPS.
--
-- Verifies that when content_changed signal fires for our sequence,
-- the PlaybackController reloads all clips so C++ re-queries
-- clip data after timeline edits (insert/delete/ripple).
--
-- Black-box observable: RELOAD_ALL_CLIPS called on the controller.

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
        SET_CLIP_PROVIDER = function() end,
        SET_POSITION_CALLBACK = function() end,
        SET_CLIP_TRANSITION_CALLBACK = function() end,
        SET_SHUTTLE_MODE = function() end,
        PLAY = function() end,
        STOP = function() end,
        SEEK = function() end,
        PARK = function(pc, frame) track_playback("PARK", pc, frame) end,
        ACTIVATE_AUDIO = function() end,
        DEACTIVATE_AUDIO = function() end,
        HAS_AUDIO = function() return false end,
        RELOAD_ALL_CLIPS = function(pc)
            track_playback("RELOAD_ALL_CLIPS", pc)
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
            get_video_in_range = function() return {} end,
            get_audio_in_range = function() return {} end,
            get_track_indices = function() return { 0 } end,
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
-- 1. content_changed for our sequence → RELOAD_ALL_CLIPS
--------------------------------------------------------------------------------
print("\n--- 1. content_changed for our sequence → reload ---")
do
    local engine = make_engine()
    engine:load_sequence("seq_test", 100)
    -- Verify controller is operational by checking seek works
    engine:seek(0)
    assert(find_call("PARK"), "controller must be operational (PARK callable)")

    reset_playback_calls()

    -- Simulate edit command completing
    Signals.emit("content_changed", "seq_test")

    -- Verify RELOAD_ALL_CLIPS was called
    assert(find_call("RELOAD_ALL_CLIPS"),
        "content_changed must trigger RELOAD_ALL_CLIPS")

    print("  PASS: edit on our sequence → RELOAD_ALL_CLIPS called")

    engine:destroy()
end

--------------------------------------------------------------------------------
-- 2. content_changed for DIFFERENT sequence → no reload
--------------------------------------------------------------------------------
print("\n--- 2. content_changed for different sequence → no reload ---")
do
    local engine = make_engine()
    engine:load_sequence("seq_test", 100)
    -- Verify controller is operational by checking seek works
    engine:seek(0)
    assert(find_call("PARK"), "controller must be operational (PARK callable)")

    reset_playback_calls()

    -- Simulate edit command on DIFFERENT sequence
    Signals.emit("content_changed", "other_sequence_id")

    -- Should NOT reload
    assert(not find_call("RELOAD_ALL_CLIPS"),
        "content_changed for other sequence must NOT call RELOAD_ALL_CLIPS")

    print("  PASS: edit on other sequence → no reload")

    engine:destroy()
end

--------------------------------------------------------------------------------
-- 3. Multiple edits → multiple reloads (not coalesced)
--------------------------------------------------------------------------------
print("\n--- 3. multiple edits → multiple reloads ---")
do
    local engine = make_engine()
    engine:load_sequence("seq_test", 100)

    reset_playback_calls()

    -- Simulate 3 rapid edits
    Signals.emit("content_changed", "seq_test")
    Signals.emit("content_changed", "seq_test")
    Signals.emit("content_changed", "seq_test")

    local total = count_calls("RELOAD_ALL_CLIPS")
    assert(total == 3, string.format(
        "3 edits must produce 3 RELOAD_ALL_CLIPS, got %d", total))

    print("  PASS: each edit triggers reload")

    engine:destroy()
end

--------------------------------------------------------------------------------
-- 4. destroy() disconnects signal (no crash after destroy)
--------------------------------------------------------------------------------
print("\n--- 4. destroy() disconnects content_changed signal ---")
do
    local engine = make_engine()
    engine:load_sequence("seq_test", 100)
    engine:destroy()

    reset_playback_calls()

    -- Emit after destroy — should be no-op (no crash, no invalidation)
    Signals.emit("content_changed", "seq_test")

    assert(not find_call("RELOAD_ALL_CLIPS"),
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

    -- WHITE-BOX: Simulate no controller (test environment) — need to nil private
    -- field because there's no public API to remove the controller
    engine._playback_controller = nil  -- luacheck: ignore

    reset_playback_calls()

    -- Should not crash
    Signals.emit("content_changed", "seq_test")

    -- No RELOAD call (no controller)
    assert(not find_call("RELOAD_ALL_CLIPS"),
        "no controller → no RELOAD_ALL_CLIPS call")

    print("  PASS: safe no-op without controller")
end

--------------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------------
print("\n✅ test_playback_edit_invalidation.lua passed")
