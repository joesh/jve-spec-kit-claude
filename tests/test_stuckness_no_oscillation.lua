#!/usr/bin/env luajit
-- Regression test: stuckness detection must not oscillate.
--
-- BUG: When audio is stuck (exhaustion, J-cut), video should advance
-- monotonically via frame-based timing. With the wrong tracker (using
-- displayed frame instead of audio frame), stuckness oscillates:
--   tick 1: audio=X, last=X  → stuck → frame-based → pos=X+1
--   tick 2: audio=X, last=X+1 → NOT stuck → audio-driven → pos=X
--   tick 3: audio=X, last=X  → stuck again → oscillates forever
--
-- FIX: Track last_audio_frame separately. Only update when audio is
-- actually driving (not stuck). Stuckness stays triggered until audio
-- catches up.

require('test_env')

-- Mock dependencies that timeline_playback requires
local mock_media_cache = {
    activate = function() end,
    get_asset_info = function() return { fps_num = 24, fps_den = 1, rotation = 0 } end,
    set_playhead = function() end,
}
package.loaded["core.media.media_cache"] = mock_media_cache

-- Mock timeline_resolver: always resolves a clip (we're testing mid-clip stuckness)
local mock_resolver = {
    resolve_at_time = function(frame_idx)
        return {
            clip = { id = "clip_1" },
            media_path = "/test/clip.mov",
            source_time_us = frame_idx * 1000000 / 24,
        }
    end,
}
package.loaded["core.playback.timeline_resolver"] = mock_resolver

-- Load timeline_playback (after mocks are in place)
package.loaded["core.playback.timeline_playback"] = nil
local timeline_playback = require("core.playback.timeline_playback")

-- Mock viewer panel
local displayed_frames = {}
local mock_viewer = {
    show_frame_at_time = function(t) table.insert(displayed_frames, t) end,
    show_gap = function() table.insert(displayed_frames, "gap") end,
    set_rotation = function() end,
}

-- Mock audio_playback stuck at a fixed frame
local STUCK_FRAME = 50
local STUCK_TIME_US = STUCK_FRAME * 1000000 / 24  -- ~2.083s

local mock_audio = {
    playing = true,
    has_audio = true,
    session_initialized = true,
}
function mock_audio.is_ready() return true end
function mock_audio.get_time_us() return STUCK_TIME_US end

print("=== Test: Stuckness detection no oscillation ===")

--------------------------------------------------------------------------------
-- TEST 1: Audio stuck → video advances monotonically (no oscillation)
--------------------------------------------------------------------------------
print("\nTest 1: Audio stuck at frame 50 — video must advance, not oscillate")

local last_audio_frame = nil  -- Simulates controller's _last_audio_frame
local pos = STUCK_FRAME       -- Start at the stuck frame
local positions = {}

for i = 1, 10 do
    local tick_in = {
        pos = pos,
        direction = 1,
        speed = 1,
        fps_num = 24,
        fps_den = 1,
        total_frames = 100,
        sequence_id = "seq_1",
        current_clip_id = "clip_1",
        last_audio_frame = last_audio_frame,
    }

    local result = timeline_playback.tick(tick_in, mock_audio, mock_viewer)
    table.insert(positions, result.frame_idx)

    -- Simulate controller logic: only update audio tracker when audio-driven
    if result.audio_frame ~= nil then
        last_audio_frame = result.audio_frame
    end

    -- Update pos for next tick (controller does this)
    pos = result.new_pos
end

-- Verify monotonic advance (no oscillation)
print("  Positions: " .. table.concat(positions, ", "))
for i = 2, #positions do
    assert(positions[i] > positions[i-1],
        string.format("Position must advance monotonically: positions[%d]=%d <= positions[%d]=%d (oscillation!)",
            i, positions[i], i-1, positions[i-1]))
end

-- First tick: audio=50, last_audio=nil → audio drives → pos=50
-- Second tick: audio=50, last_audio=50 → stuck → frame-based → pos=51
-- Third tick: audio=50, last_audio=50 (unchanged!) → stuck → frame-based → pos=52
-- ... continues advancing
assert(positions[1] == STUCK_FRAME, "First frame should be audio-driven to 50")
assert(positions[5] > STUCK_FRAME + 2, "Should have advanced well past stuck point by tick 5")
print("  ✓ Video advances monotonically when audio is stuck")

--------------------------------------------------------------------------------
-- TEST 2: Audio unsticks → video switches back to audio-driven
--------------------------------------------------------------------------------
print("\nTest 2: Audio unsticks at frame 60 — video follows audio again")

-- Now let audio advance to frame 60
local UNSTICK_FRAME = 60
local UNSTICK_TIME_US = UNSTICK_FRAME * 1000000 / 24
function mock_audio.get_time_us() return UNSTICK_TIME_US end

local tick_in = {
    pos = pos,  -- wherever we ended up from test 1
    direction = 1,
    speed = 1,
    fps_num = 24,
    fps_den = 1,
    total_frames = 100,
    sequence_id = "seq_1",
    current_clip_id = "clip_1",
    last_audio_frame = last_audio_frame,  -- still 50 from test 1
}

local result = timeline_playback.tick(tick_in, mock_audio, mock_viewer)

-- Audio reports 60, last_audio was 50 → NOT stuck → audio-driven → pos=60
assert(result.audio_frame == UNSTICK_FRAME,
    "Should return audio_frame=60, got " .. tostring(result.audio_frame))
assert(result.frame_idx == UNSTICK_FRAME,
    "Frame should jump to audio position 60, got " .. result.frame_idx)
print("  ✓ Video follows audio again after unstick")

--------------------------------------------------------------------------------
-- TEST 3: No audio → frame-based (no stuckness check needed)
--------------------------------------------------------------------------------
print("\nTest 3: No audio — pure frame-based advance")

local no_audio_positions = {}
pos = 10
for i = 1, 5 do
    local ti = {
        pos = pos,
        direction = 1,
        speed = 1,
        fps_num = 24,
        fps_den = 1,
        total_frames = 100,
        sequence_id = "seq_1",
        current_clip_id = "clip_1",
        last_audio_frame = nil,
    }
    local r = timeline_playback.tick(ti, nil, mock_viewer)  -- no audio_playback
    table.insert(no_audio_positions, r.frame_idx)
    assert(r.audio_frame == nil, "audio_frame should be nil when no audio")
    pos = r.new_pos
end

print("  Positions: " .. table.concat(no_audio_positions, ", "))
assert(no_audio_positions[1] == 11 and no_audio_positions[5] == 15,
    "Should advance 1 frame per tick")
print("  ✓ Frame-based advance works without audio")

--------------------------------------------------------------------------------
-- TEST 4: Content boundary stops playback when audio stuck
--------------------------------------------------------------------------------
print("\nTest 4: Audio stuck near content end — playback stops at boundary")

-- Audio stuck at frame 98, content_end = 100 (last frame = 99)
local BOUNDARY_FRAME = 98
function mock_audio.get_time_us() return BOUNDARY_FRAME * 1000000 / 24 end

last_audio_frame = nil
pos = BOUNDARY_FRAME

local stopped = false
for i = 1, 5 do
    local ti = {
        pos = pos,
        direction = 1,
        speed = 1,
        fps_num = 24,
        fps_den = 1,
        total_frames = 100,
        sequence_id = "seq_1",
        current_clip_id = "clip_1",
        last_audio_frame = last_audio_frame,
    }
    local r = timeline_playback.tick(ti, mock_audio, mock_viewer)

    if r.audio_frame ~= nil then
        last_audio_frame = r.audio_frame
    end

    if not r.continue then
        stopped = true
        assert(r.frame_idx == 99,
            "Should stop at last frame 99, got " .. r.frame_idx)
        break
    end
    pos = r.new_pos
end

assert(stopped, "Playback must stop at content boundary")
print("  ✓ Stops at content end when audio is stuck")

print("\n✅ test_stuckness_no_oscillation.lua passed")
