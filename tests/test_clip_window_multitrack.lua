--- Test: clip window computation with multi-track timelines.
--
-- Regression test for multi-track clip transition stutter: when multiple
-- video tracks have different clip coverage ranges, the clip window must
-- use the MINIMUM per-track end (not the max). Otherwise NeedClips never
-- fires before the shortest track runs out → GAP → 200ms+ stutter.
--
-- Scenario: Track 1 has clips covering frames 0-200, Track 2 has clips
-- covering frames 0-500. Both C++ window and Lua cache hi = 200 (MIN),
-- so NeedClips fires before Track 1 runs dry.

require("test_env")

--------------------------------------------------------------------------------
-- Mocks — minimal, focused on clip window computation
--------------------------------------------------------------------------------

-- Capture SET_CLIP_WINDOW calls
local clip_window_calls = {}
local set_track_clips_calls = {}

package.loaded["core.qt_constants"] = {
    EMP = {
        SET_DECODE_MODE = function() end,
        TMB_CREATE = function() return "mock_tmb" end,
        TMB_CLOSE = function() end,
        TMB_PARK_READERS = function() end,
        TMB_SET_SEQUENCE_RATE = function() end,
        TMB_SET_AUDIO_FORMAT = function() end,
        TMB_SET_TRACK_CLIPS = function(tmb, track_type, idx, clips)
            set_track_clips_calls[#set_track_clips_calls + 1] = {
                type = track_type, idx = idx, clips = clips,
            }
        end,
    },
    PLAYBACK = {
        CREATE = function() return "mock_controller" end,
        PLAY = function() end,
        STOP = function() end,
        PARK = function() end,
        SEEK = function() end,
        SET_TMB = function() end,
        SET_BOUNDS = function() end,
        SET_VIDEO_TRACKS = function() end,
        SET_SURFACE = function() end,
        SET_CLIP_WINDOW = function(pc, track_type, lo, hi)
            clip_window_calls[#clip_window_calls + 1] = {
                type = track_type, lo = lo, hi = hi,
            }
        end,
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

-- Mock Renderer
package.loaded["core.renderer"] = {
    get_sequence_info = function()
        return {
            fps_num = 25, fps_den = 1, kind = "timeline",
            name = "Test", audio_sample_rate = 48000,
        }
    end,
    get_video_frame = function() return nil, nil end,  -- gap (display not under test)
}

-- Multi-track mock Sequence: two video tracks with different coverage
-- Track 1: clip A [0, 200)
-- Track 2: clip B [0, 500)
-- After frame 200, only Track 2 has coverage.
local mock_track1 = { id = "t1", track_index = 1, track_type = "video",
    volume = 1.0, muted = false, soloed = false }
local mock_track2 = { id = "t2", track_index = 2, track_type = "video",
    volume = 1.0, muted = false, soloed = false }

local clip_a = {
    id = "clip-a", timeline_start = 0, duration = 200,
    source_in = 0, source_out = 200, rate = { fps_numerator = 25, fps_denominator = 1 },
}
local clip_b = {
    id = "clip-b", timeline_start = 0, duration = 500,
    source_in = 0, source_out = 500, rate = { fps_numerator = 25, fps_denominator = 1 },
}

local mock_sequence = {
    id = "seq-multitrack",
    compute_content_end = function() return 500 end,
    get_video_at = function(self, frame)
        local results = {}
        -- Track 1: clip A covers [0, 200)
        if frame >= clip_a.timeline_start and frame < clip_a.timeline_start + clip_a.duration then
            results[#results + 1] = {
                clip = clip_a, track = mock_track1,
                media_path = "/media/a.mov",
                media_fps_num = 25, media_fps_den = 1,
            }
        end
        -- Track 2: clip B covers [0, 500)
        if frame >= clip_b.timeline_start and frame < clip_b.timeline_start + clip_b.duration then
            results[#results + 1] = {
                clip = clip_b, track = mock_track2,
                media_path = "/media/b.mov",
                media_fps_num = 25, media_fps_den = 1,
            }
        end
        return results
    end,
    get_next_video = function(self, from_frame)
        -- No next clips (only one clip per track)
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

package.loaded["core.signals"] = {
    connect = function() return "conn_id" end,
    disconnect = function() end,
    emit = function() end,
}

--------------------------------------------------------------------------------
-- Load PlaybackEngine
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
-- Tests
--------------------------------------------------------------------------------

print("=== test_clip_window_multitrack.lua ===")

-- ─── Test 1: clip window hi = min per-track coverage, not max ───
print("\n--- 1. clip window hi uses minimum per-track coverage ---")
do
    local engine = make_engine()
    engine:load_sequence("seq-multitrack")

    -- Clear captured calls from load_sequence setup
    clip_window_calls = {}

    -- Seek to frame 50 — both tracks have clips
    engine:seek(50)

    -- Find the video clip window call
    local video_window = nil
    for _, call in ipairs(clip_window_calls) do
        if call.type == "video" then
            video_window = call
        end
    end

    assert(video_window, "SET_CLIP_WINDOW for video was never called")

    -- Both C++ clip window and Lua cache use MIN per-track end (200).
    -- NeedClips fires before ANY track's clips expire, not just when ALL expire.
    -- NeedClips is debounced (need_clips_pending), so extra calls are <5ms overhead.
    print(string.format("  C++ video window: lo=%d hi=%d", video_window.lo, video_window.hi))
    assert(video_window.hi == 200, string.format(
        "C++ clip window hi must be min per-track end (200), got %d",
        video_window.hi))

    local cache = engine._tmb_clip_window
    assert(cache, "Lua _tmb_clip_window not set")
    print(string.format("  Lua cache: lo=%d hi=%d", cache.lo, cache.hi))
    assert(cache.hi == 200, string.format(
        "Lua cache hi must be min per-track end (200), got %d",
        cache.hi))

    print("  PASS: C++ window=200 (min), Lua cache=200 (min) — NeedClips fires for ANY track")
    engine:destroy()
end

-- ─── Test 2: single track — window hi = that track's coverage ───
print("\n--- 2. single video track — window hi = track coverage end ---")
do
    -- Override to return only track 2
    local orig_get_video_at = mock_sequence.get_video_at
    mock_sequence.get_video_at = function(self, frame)
        if frame >= 0 and frame < 500 then
            return {{
                clip = clip_b, track = mock_track2,
                media_path = "/media/b.mov",
                media_fps_num = 25, media_fps_den = 1,
            }}
        end
        return {}
    end

    local engine = make_engine()
    engine:load_sequence("seq-multitrack")
    clip_window_calls = {}

    engine:seek(50)

    local video_window = nil
    for _, call in ipairs(clip_window_calls) do
        if call.type == "video" then video_window = call end
    end

    assert(video_window, "SET_CLIP_WINDOW for video was never called")
    assert(video_window.hi == 500, string.format(
        "single track: window hi should be 500, got %d", video_window.hi))

    print(string.format("  video window: lo=%d hi=%d", video_window.lo, video_window.hi))
    print("  PASS: single track window hi = 500")
    engine:destroy()
    mock_sequence.get_video_at = orig_get_video_at
end

-- ─── Test 3: no video clips at seek → no clip window set ───
print("\n--- 3. gap at seek position — no clip window ---")
do
    local orig = mock_sequence.get_video_at
    mock_sequence.get_video_at = function() return {} end

    local engine = make_engine()
    engine:load_sequence("seq-multitrack")
    clip_window_calls = {}

    engine:seek(999)

    -- No video SET_CLIP_WINDOW call should have been made (no clips)
    local video_window_count = 0
    for _, call in ipairs(clip_window_calls) do
        if call.type == "video" then video_window_count = video_window_count + 1 end
    end
    assert(video_window_count == 0, string.format(
        "SET_CLIP_WINDOW for video should not fire on gap, got %d calls",
        video_window_count))

    -- Lua cache should be nil (gap → don't cache, re-query next seek)
    assert(engine._tmb_clip_window == nil,
        "Lua cache must be nil when no clips at seek position")

    print("  PASS: gap at seek → no cache, no C++ window")
    engine:destroy()
    mock_sequence.get_video_at = orig
end

-- ─── Test 4: Lua cache hi == C++ window hi (both MIN-based) ───
print("\n--- 4. Lua cache hi == C++ window hi (unified MIN invariant) ---")
do
    local engine = make_engine()
    engine:load_sequence("seq-multitrack")
    clip_window_calls = {}

    engine:seek(50)

    local cpp_window = nil
    for _, call in ipairs(clip_window_calls) do
        if call.type == "video" then cpp_window = call end
    end
    local cache = engine._tmb_clip_window

    assert(cpp_window and cache, "both windows must exist")
    assert(cache.hi == cpp_window.hi, string.format(
        "Lua cache hi (%d) must equal C++ window hi (%d) — both MIN-based",
        cache.hi, cpp_window.hi))

    print(string.format("  cache_hi=%d == cpp_hi=%d", cache.hi, cpp_window.hi))
    print("  PASS: unified MIN invariant holds")
    engine:destroy()
end

print("\n✅ test_clip_window_multitrack.lua passed")
