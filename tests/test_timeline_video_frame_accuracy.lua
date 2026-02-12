--- Test: timeline resolve_and_display shows the correct source frame
--
-- BUG: In timeline mode, resolve_and_display calls show_frame_at_time(source_time_us)
-- which round-trips through microseconds. At 24fps, most frames lose 1 frame:
--
--   frame 50 → floor(50*1e6/24) = 2083333us → C++ floor(2083333*24/1e6) = 49 ← WRONG
--
-- Source mode calls show_frame(integer) which doesn't have this issue.
--
-- FIX: Return source_frame from resolver, use show_frame(source_frame).

require("test_env")

print("=== test_timeline_video_frame_accuracy.lua ===")

-- Mock logger
package.loaded["core.logger"] = {
    info = function() end,
    debug = function() end,
    warn = function() end,
    error = function() end,
    trace = function() end,
}

-- Mock media_cache
package.loaded["core.media.media_cache"] = {
    is_loaded = function() return true end,
    set_playhead = function() end,
    get_asset_info = function()
        return { fps_num = 24, fps_den = 1, rotation = 0 }
    end,
    activate = function() end,
}

-- Mock timeline_resolver — returns video clip with known parameters
local mock_clip = {
    id = "clip_video_1",
    timeline_start = 0,
    source_in = 0,
    rate = { fps_numerator = 24, fps_denominator = 1 },
}
package.loaded["core.playback.timeline_resolver"] = {
    resolve_at_time = function(playhead_frame, sequence_id)
        -- "Frames are frames": source_frame = source_in + timeline_offset (1:1)
        local source_frame = mock_clip.source_in + (playhead_frame - mock_clip.timeline_start)
        local source_time_us = math.floor(
            source_frame * 1000000 * mock_clip.rate.fps_denominator / mock_clip.rate.fps_numerator
        )
        return {
            media_path = "/test/clip.mov",
            source_time_us = source_time_us,
            source_frame = source_frame,
            clip = mock_clip,
        }
    end,
    resolve_all_audio_at_time = function()
        return {}
    end,
}

-- Prevent timer creation
_G.qt_create_single_shot_timer = function() end

-- Mock qt_constants
package.loaded["core.qt_constants"] = {
    EMP = { SET_DECODE_MODE = function() end },
}

-- Track which viewer API is called and with what value
local viewer_calls = {}
local mock_viewer = {
    show_frame = function(frame_idx)
        table.insert(viewer_calls, { api = "show_frame", value = frame_idx })
    end,
    show_frame_at_time = function(time_us)
        table.insert(viewer_calls, { api = "show_frame_at_time", value = time_us })
    end,
    show_gap = function()
        table.insert(viewer_calls, { api = "show_gap" })
    end,
    set_rotation = function() end,
    has_media = function() return true end,
}

-- Load timeline_playback fresh
package.loaded["core.playback.timeline_playback"] = nil
local timeline_playback = require("core.playback.timeline_playback")

--------------------------------------------------------------------------------
-- Helper: simulate what the C++ decoder does with show_frame_at_time
--------------------------------------------------------------------------------
local function c_decoder_frame(time_us, fps_num, fps_den)
    return math.floor(time_us * fps_num / (fps_den * 1000000))
end

--------------------------------------------------------------------------------
-- Test 1: Frames at 24fps that lose precision in time round-trip
--
-- At 24fps, frame N's start time = N * 1e6 / 24.
-- For N not a multiple of 3, this is not an integer → floor truncates.
-- The C++ decoder then floors the truncated time back, getting N-1.
--------------------------------------------------------------------------------
print("\nTest 1: show_frame called with correct integer source frame")

local test_frames = { 1, 2, 4, 5, 7, 8, 10, 11, 49, 50, 100, 101 }

for _, expected_frame in ipairs(test_frames) do
    viewer_calls = {}
    mock_clip.timeline_start = 0
    mock_clip.source_in = 0

    timeline_playback.resolve_and_display(
        24, 1,              -- fps
        "seq_1",            -- sequence_id
        nil,                -- current_clip_id (force activate)
        nil, nil,           -- direction, speed (parked)
        mock_viewer,        -- viewer_panel
        nil,                -- audio_playback
        expected_frame      -- frame_idx
    )

    assert(#viewer_calls > 0,
        string.format("Frame %d: no viewer call made", expected_frame))

    local call = viewer_calls[1]

    -- The viewer must receive the exact integer frame
    if call.api == "show_frame" then
        assert(call.value == expected_frame,
            string.format("Frame %d: show_frame(%d) — wrong frame",
                expected_frame, call.value))
    elseif call.api == "show_frame_at_time" then
        -- If show_frame_at_time is used, verify the C++ decoder would get the right frame
        local decoded_frame = c_decoder_frame(call.value, 24, 1)
        assert(decoded_frame == expected_frame,
            string.format("Frame %d: show_frame_at_time(%d) → C++ decodes frame %d (off by %d)",
                expected_frame, call.value, decoded_frame, expected_frame - decoded_frame))
    end
end
print("  ✓ All test frames displayed correctly at 24fps")

--------------------------------------------------------------------------------
-- Test 2: With non-zero source_in and timeline_start
--------------------------------------------------------------------------------
print("\nTest 2: non-zero source_in/timeline_start")

mock_clip.timeline_start = 100
mock_clip.source_in = 200

local playhead = 112  -- 12 frames into clip
local expected_source = 200 + (112 - 100)  -- = 212

viewer_calls = {}
timeline_playback.resolve_and_display(
    24, 1, "seq_1", nil, nil, nil, mock_viewer, nil, playhead)

assert(#viewer_calls > 0, "No viewer call")
local call = viewer_calls[1]

if call.api == "show_frame" then
    assert(call.value == expected_source,
        string.format("Expected show_frame(%d), got show_frame(%d)",
            expected_source, call.value))
elseif call.api == "show_frame_at_time" then
    local decoded = c_decoder_frame(call.value, 24, 1)
    assert(decoded == expected_source,
        string.format("source_frame=%d but C++ decodes %d from time %dus",
            expected_source, decoded, call.value))
end
print(string.format("  ✓ source_frame=%d displayed correctly", expected_source))

--------------------------------------------------------------------------------
-- Test 3: Systematic check — verify NO frame at 24fps loses precision
--------------------------------------------------------------------------------
print("\nTest 3: systematic check for first 240 frames at 24fps")

mock_clip.timeline_start = 0
mock_clip.source_in = 0
local errors = 0

for f = 0, 239 do
    viewer_calls = {}
    timeline_playback.resolve_and_display(
        24, 1, "seq_1", "clip_video_1", nil, nil, mock_viewer, nil, f)

    local vc = viewer_calls[1]
    local displayed
    if vc.api == "show_frame" then
        displayed = vc.value
    else
        displayed = c_decoder_frame(vc.value, 24, 1)
    end

    if displayed ~= f then
        errors = errors + 1
        if errors <= 5 then
            print(string.format("    Frame %d: displayed %d (off by %d)", f, displayed, f - displayed))
        end
    end
end

assert(errors == 0,
    string.format("  ✗ %d/%d frames displayed incorrectly", errors, 240))
print("  ✓ All 240 frames accurate")

--------------------------------------------------------------------------------
print("\n✅ test_timeline_video_frame_accuracy.lua passed")
