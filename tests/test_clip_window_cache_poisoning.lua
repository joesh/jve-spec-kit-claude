-- Regression test: load_sequence → _send_clips_to_tmb(0) poisons the clip
-- window cache, causing seek(far_playhead) to skip re-querying TMB.
--
-- Scenario: clips at frame 0 and frame 5000. load_sequence calls
-- _send_clips_to_tmb(0), which loads the clip at frame 0, then
-- get_next_video returns the clip at frame 5000. Clip window = [0, 5100).
-- When seek(5000) calls _send_clips_to_tmb(5000), the cache check sees
-- 5000 ∈ [0, 5100) and returns early. TMB never receives the actual clip
-- at frame 5000 — deliverFrame sees a gap.
--
-- Expected: after load_sequence + seek(5000), TMB must have the clip at
-- frame 5000 fed via TMB_SET_TRACK_CLIPS.

require("test_env")

print("=== test_clip_window_cache_poisoning.lua ===")

--------------------------------------------------------------------------------
-- Mock Infrastructure (same pattern as test_playback_controller_audio_guards)
--------------------------------------------------------------------------------

_G.qt_create_single_shot_timer = function() end

local playback_calls = {}
local function track_playback(name, ...)
    playback_calls[#playback_calls + 1] = { name = name, args = {...} }
end

-- Track which clips were fed to TMB per track
local tmb_clips_set = {}

package.loaded["core.qt_constants"] = {
    EMP = {
        SET_DECODE_MODE = function() end,
        TMB_CREATE = function() return "mock_tmb" end,
        TMB_CLOSE = function() end,
        TMB_PARK_READERS = function() end,
        TMB_SET_SEQUENCE_RATE = function() end,
        TMB_SET_AUDIO_FORMAT = function() end,
        TMB_SET_TRACK_CLIPS = function(_, media_type, track_idx, clips)
            tmb_clips_set[#tmb_clips_set + 1] = {
                media_type = media_type,
                track_idx = track_idx,
                clips = clips,
            }
        end,
        TMB_SET_PLAYHEAD = function() end,
        TMB_GET_VIDEO_FRAME = function() return nil, { offline = false } end,
    },
    PLAYBACK = {
        CREATE = function() return "mock_controller" end,
        CLOSE = function() end,
        SET_TMB = function() end,
        SET_BOUNDS = function() end,
        SET_VIDEO_TRACKS = function(pc, indices)
            track_playback("SET_VIDEO_TRACKS", pc, indices)
        end,
        SET_SURFACE = function() end,
        SET_CLIP_WINDOW = function(pc, mtype, lo, hi)
            track_playback("SET_CLIP_WINDOW", pc, mtype, lo, hi)
        end,
        SET_NEED_CLIPS_CALLBACK = function() end,
        SET_POSITION_CALLBACK = function() end,
        SET_CLIP_TRANSITION_CALLBACK = function() end,
        SEEK = function() end,
        INVALIDATE_CLIP_WINDOWS = function() end,
    },
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

package.loaded["core.signals"] = {
    connect = function() return "conn_id" end,
    disconnect = function() end,
    emit = function() end,
}

--------------------------------------------------------------------------------
-- Frame-dependent mock sequence
--
-- Two clips on track 0:
--   clip_A at [0, 100)     — near frame 0
--   clip_B at [5000, 5100) — near the "saved playhead"
--
-- get_video_at(frame) returns clip at that frame.
-- get_next_video(boundary) returns the next clip after boundary.
--------------------------------------------------------------------------------

local clip_A = {
    clip = {
        id = "clip_A", timeline_start = 0, duration = 100,
        source_in = 0, source_out = 100,
        rate = { fps_numerator = 25, fps_denominator = 1 },
    },
    track = { id = "track_v1", track_index = 0 },
    media_path = "/clip_a.mov",
    media_fps_num = 25, media_fps_den = 1,
}

local clip_B = {
    clip = {
        id = "clip_B", timeline_start = 5000, duration = 100,
        source_in = 0, source_out = 100,
        rate = { fps_numerator = 25, fps_denominator = 1 },
    },
    track = { id = "track_v1", track_index = 0 },
    media_path = "/clip_b.mov",
    media_fps_num = 25, media_fps_den = 1,
}

local mock_sequence = {
    id = "seq1",
    compute_content_end = function() return 6000 end,

    get_video_at = function(_, frame)
        if frame >= 0 and frame < 100 then
            return { clip_A }
        elseif frame >= 5000 and frame < 5100 then
            return { clip_B }
        end
        return {}
    end,

    get_next_video = function(_, boundary)
        -- Return clip_B as "next" if boundary <= 5000
        if boundary <= 5000 then
            return { clip_B }
        end
        return {}
    end,

    get_prev_video = function() return {} end,
    get_audio_at = function() return {} end,
    get_next_audio = function() return {} end,
    get_prev_audio = function() return {} end,
}

package.loaded["models.sequence"] = {
    load = function() return mock_sequence end,
}

--------------------------------------------------------------------------------
-- Load engine
--------------------------------------------------------------------------------

local PlaybackEngine = require("core.playback.playback_engine")

local function make_engine()
    return PlaybackEngine.new({
        on_show_frame = function() end,
        on_show_gap = function() end,
        on_set_rotation = function() end,
        on_set_par = function() end,
        on_position_changed = function() end,
    })
end

--------------------------------------------------------------------------------
-- Test: seek to saved playhead after load_sequence must feed TMB with clips
-- at the playhead position, NOT skip due to cached clip window from frame 0.
--------------------------------------------------------------------------------

print("\n--- Regression: _send_clips_to_tmb(0) cache poisoning ---")
do
    tmb_clips_set = {}
    playback_calls = {}

    local engine = make_engine()
    engine:load_sequence("seq1", 6000)

    -- After load_sequence, NO clips should be fed (fix: no _send_clips_to_tmb(0))
    local load_clip_count = 0
    for _, entry in ipairs(tmb_clips_set) do
        if entry.media_type == "video" then load_clip_count = load_clip_count + 1 end
    end
    assert(load_clip_count == 0,
        string.format("load_sequence must NOT pre-feed TMB clips, but fed %d", load_clip_count))
    assert(engine._tmb_clip_window == nil,
        "clip window must be nil after load_sequence (no pre-load)")
    print("  ✓ load_sequence did not pre-feed TMB (no cache poisoning)")

    -- Seek to the saved playhead at frame 5000 (inside clip_B).
    -- This is what SequenceMonitor does after load_sequence.
    tmb_clips_set = {}
    engine:seek(5000)

    -- With fix: _send_clips_to_tmb(5000) runs fresh (no cache) → feeds clip_B.
    -- With bug: _send_clips_to_tmb(0) poisoned cache → seek skips → no clip_B.
    local seek_clip_ids = {}
    for _, entry in ipairs(tmb_clips_set) do
        if entry.media_type == "video" then
            for _, c in ipairs(entry.clips) do
                seek_clip_ids[c.clip_id] = true
            end
        end
    end

    assert(seek_clip_ids["clip_B"],
        "REGRESSION: seek(5000) must feed clip_B to TMB, but clip window cache " ..
        "from _send_clips_to_tmb(0) caused skip. TMB has no clip at playhead!")
    print("  ✓ seek(5000) fed clip_B to TMB (no cache poisoning)")
end

print("\n✅ test_clip_window_cache_poisoning.lua passed")
