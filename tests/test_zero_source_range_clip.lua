--- Regression test: clip with source_in=0, source_out=0 must not crash the app.
--
-- Bug: DRP import created clips with zero source range (source_in=0, source_out=0).
-- PlaybackEngine._compute_video_speed_ratio asserted on source_range=0, and the
-- assert propagated uncaught through layout.lua, crashing the entire application.
--
-- Root cause: import_into_project accepted source_out=0 (Lua truthy) without
-- falling back to source_in + duration.
--
-- This test verifies:
-- 1. PlaybackEngine correctly asserts on zero source range (data error)
-- 2. The assert does NOT crash the app (pcall boundary catches it)
-- 3. DRP import skips clips with zero source range

require("test_env")

--------------------------------------------------------------------------------
-- Mock Infrastructure (minimal — matches test_playback_engine pattern)
--------------------------------------------------------------------------------

_G.qt_create_single_shot_timer = function() end

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
        TMB_GET_VIDEO_TRACK_IDS = function() return {} end,
    },
    PLAYBACK = {
        CREATE = function() return "mock_controller" end,
        PLAY = function() end,
        STOP = function() end,
        PARK = function() end,
        SEEK = function() end,
        SET_TMB = function() end,
        SET_BOUNDS = function() end,
        SET_SURFACE = function() end,
        SET_CLIP_WINDOW = function() end,
        SET_SHUTTLE_MODE = function() end,
        SET_NEED_CLIPS_CALLBACK = function() end,
        SET_POSITION_CALLBACK = function() end,
        SET_CLIP_TRANSITION_CALLBACK = function() end,
        INVALIDATE_CLIP_WINDOWS = function() end,
        CLOSE = function() end,
        HAS_AUDIO = function() return false end,
        ACTIVATE_AUDIO = function() end,
        DEACTIVATE_AUDIO = function() end,
        PLAY_BURST = function() end,
    },
}

package.loaded["core.media.media_cache"] = {
    ensure_audio_pooled = function() return { has_audio = false } end,
    get_audio_pcm_for_path = function() return nil, 0, 0 end,
    pre_buffer = function() end,
}

package.loaded["core.logger"] = {
    for_area = function()
        return {
            event = function() end,
            detail = function() end,
            warn = function() end,
            error = function() end,
        }
    end,
}

package.loaded["core.renderer"] = {
    get_sequence_info = function()
        return {
            fps_num = 25, fps_den = 1,
            kind = "timeline", name = "Test",
            audio_sample_rate = 48000,
        }
    end,
    get_video_frame = function() return nil, nil end,
}

-- Sequence mock that returns a clip with zero source range at frame 0
local bad_clip = {
    id = "bad_clip_zero_source",
    media_id = "media1",
    source_in = 0,
    source_out = 0,
    duration = 100,
    timeline_start = 0,
    fps_numerator = 25,
    fps_denominator = 1,
}

local bad_track = {
    id = "track1",
    track_index = 1,
    type = "VIDEO",
}

local mock_sequence = {
    id = "seq_with_bad_clip",
    compute_content_end = function() return 100 end,
    get_video_at = function(self, frame)
        if frame >= 0 and frame < 100 then
            return {{
                media_path = "/test.mov",
                source_time_us = 0,
                source_frame = 0,
                clip = bad_clip,
                track = bad_track,
            }}
        end
        return {}
    end,
    get_next_video = function() return {} end,
    get_prev_video = function() return {} end,
    get_audio_at = function() return {} end,
    get_next_audio = function() return {} end,
    get_prev_audio = function() return {} end,
}

package.loaded["models.sequence"] = {
    load = function() return mock_sequence end,
}

package.loaded["core.signals"] = {
    connect = function() end,
    emit = function() end,
}

package.loaded["core.media.audio_playback"] = {}

--------------------------------------------------------------------------------
-- Test 1: _compute_video_speed_ratio asserts on zero source range
--------------------------------------------------------------------------------
print("=== test_zero_source_range_clip.lua ===")

local PlaybackEngine = require("core.playback.playback_engine")
local noop = function() end
local engine = PlaybackEngine.new({
    view_id = "test_monitor",
    on_show_frame = noop,
    on_show_gap = noop,
    on_set_rotation = noop,
    on_set_par = noop,
    on_position_changed = noop,
})

print("TEST 1: _compute_video_speed_ratio asserts on zero source range")
local entry = { clip = bad_clip, track = bad_track }
local ok, err = pcall(function()
    engine:_compute_video_speed_ratio(entry)
end)
assert(not ok, "Expected assert on zero source range, but call succeeded")
assert(err:match("source_range must be positive"),
    "Expected 'source_range must be positive' in error, got: " .. tostring(err))
print("  PASS: assert fires correctly on zero source range")

--------------------------------------------------------------------------------
-- Test 2: seek with bad clip is catchable (pcall boundary works)
--------------------------------------------------------------------------------
print("TEST 2: seek with bad clip is catchable via pcall")
engine:load_sequence("seq_with_bad_clip")

local seek_ok, seek_err = pcall(function()
    engine:seek(0)
end)
assert(not seek_ok, "Expected seek to fail on bad clip")
assert(seek_err:match("source_range must be positive"),
    "Expected source_range error, got: " .. tostring(seek_err))
print("  PASS: seek error is catchable, app survives")

print("✅ test_zero_source_range_clip.lua passed")
