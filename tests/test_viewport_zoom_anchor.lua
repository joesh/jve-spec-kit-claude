#!/usr/bin/env luajit

-- Test: viewport_state.set_viewport_duration anchor behavior.
--
-- Domain rule: when the viewport duration changes, an "anchor" point in the
-- timeline stays at the same pixel fraction within the viewport. Which frame
-- is chosen as the anchor depends on opts:
--   opts = nil                           → auto: playhead if visible, else viewport center
--   opts = { zoom_around = "playhead" }  → playhead (always, even if off-screen)
--   opts = { zoom_around = "center" }    → old viewport center
--   opts = { zoom_around = "frame",
--            anchor_frame = N }          → explicit frame N
--
-- These tests describe behavior in domain terms (pixel fractions, centers)
-- and do NOT reference implementation details.

package.path = "src/lua/?.lua;src/lua/?/init.lua;tests/?.lua;" .. package.path

local data = require("ui.timeline.state.timeline_state_data")
local viewport_state = require("ui.timeline.state.viewport_state")

-- Baseline state used by every case. A large content extent so clamp never
-- interferes with the math we care about.
local function reset_state(start_time, duration, playhead)
    data.state.sequence_frame_rate = { fps_numerator = 24, fps_denominator = 1 }
    data.state.sequence_timecode_start_frame = 0
    data.state.clips = {
        { id = "bg", track_id = "t1", sequence_start = 0, duration = 100000 },
    }
    data.state.viewport_start_time = start_time
    data.state.viewport_duration = duration
    data.state.playhead_position = playhead
    data.state.is_playing = false
end

local function pixel_fraction(frame, start, duration)
    return (frame - start) / duration
end

-- =============================================================================
-- Test 1: auto (no opts), playhead visible → playhead stays at same fraction
-- =============================================================================
reset_state(100, 200, 150)  -- viewport [100..300], playhead at 150 (25% from left)
local old_fraction = pixel_fraction(150, 100, 200)
viewport_state.set_viewport_duration(400)
local new_start = data.state.viewport_start_time
local new_duration = data.state.viewport_duration
assert(new_duration == 400, "duration should update to 400")
local new_fraction = pixel_fraction(150, new_start, new_duration)
assert(math.abs(new_fraction - old_fraction) < 0.01,
    string.format("playhead fraction should stay ~%.3f, got %.3f (start=%d dur=%d)",
        old_fraction, new_fraction, new_start, new_duration))
print("  PASS: auto anchor keeps playhead at same pixel fraction when visible")

-- =============================================================================
-- Test 2: auto (no opts), playhead off-screen → viewport CENTER stays fixed
-- =============================================================================
reset_state(100, 200, 5000)  -- playhead way off-screen (5000), viewport [100..300]
local old_center = 100 + 200 / 2  -- = 200
viewport_state.set_viewport_duration(400)
new_start = data.state.viewport_start_time
new_duration = data.state.viewport_duration
local new_center = new_start + new_duration / 2
assert(new_duration == 400, "duration should update")
assert(math.abs(new_center - old_center) < 1,
    string.format("center should stay at %d, got %d", old_center, new_center))
print("  PASS: auto anchor preserves viewport center when playhead off-screen")

-- =============================================================================
-- Test 3: explicit zoom_around = "playhead" (even when off-screen)
-- =============================================================================
reset_state(100, 200, 5000)  -- playhead off-screen
viewport_state.set_viewport_duration(400, { zoom_around = "playhead" })
new_start = data.state.viewport_start_time
new_duration = data.state.viewport_duration
-- Playhead should end up inside the viewport (centered, modulo clamp)
local ph = data.state.playhead_position
assert(ph >= new_start and ph <= new_start + new_duration,
    string.format("playhead %d should be inside viewport [%d..%d]",
        ph, new_start, new_start + new_duration))
print("  PASS: explicit playhead anchor moves viewport to contain playhead")

-- =============================================================================
-- Test 4: explicit zoom_around = "center"
-- =============================================================================
reset_state(100, 200, 150)  -- playhead visible, but we force center anyway
old_center = 100 + 200 / 2  -- 200
viewport_state.set_viewport_duration(400, { zoom_around = "center" })
new_start = data.state.viewport_start_time
new_duration = data.state.viewport_duration
new_center = new_start + new_duration / 2
assert(math.abs(new_center - old_center) < 1,
    string.format("center should stay at %d, got %d", old_center, new_center))
print("  PASS: explicit center anchor preserves viewport center")

-- =============================================================================
-- Test 5: explicit zoom_around = "frame" with anchor_frame
-- =============================================================================
reset_state(100, 200, 150)  -- viewport [100..300]
local anchor = 250  -- 75% from the left
local old_anchor_fraction = pixel_fraction(anchor, 100, 200)
viewport_state.set_viewport_duration(100, {
    zoom_around = "frame",
    anchor_frame = anchor,
})
new_start = data.state.viewport_start_time
new_duration = data.state.viewport_duration
assert(new_duration == 100, "duration should be 100")
local new_anchor_fraction = pixel_fraction(anchor, new_start, new_duration)
assert(math.abs(new_anchor_fraction - old_anchor_fraction) < 0.01,
    string.format("anchor frame fraction should stay ~%.3f, got %.3f",
        old_anchor_fraction, new_anchor_fraction))
print("  PASS: explicit frame anchor preserves fraction of anchor_frame")

-- =============================================================================
-- Test 6: zoom_around = "frame" without anchor_frame → assert (no fallback)
-- =============================================================================
reset_state(100, 200, 150)
local ok, err = pcall(viewport_state.set_viewport_duration, 100,
    { zoom_around = "frame" })
assert(not ok, "frame anchor without anchor_frame must assert")
assert(tostring(err):find("anchor_frame") or tostring(err):find("required"),
    "error must mention anchor_frame; got: " .. tostring(err))
print("  PASS: frame anchor without anchor_frame asserts (no silent fallback)")

-- =============================================================================
-- Test 7: unknown zoom_around enum → assert
-- =============================================================================
reset_state(100, 200, 150)
ok = pcall(viewport_state.set_viewport_duration, 100,
    { zoom_around = "invalid" })
assert(not ok, "unknown zoom_around must assert")
print("  PASS: unknown zoom_around value asserts")

-- =============================================================================
-- Test 8: duration unchanged → still a no-op (backward-compat of early-exit)
-- =============================================================================
reset_state(100, 200, 150)
local before_start = data.state.viewport_start_time
viewport_state.set_viewport_duration(200)  -- same as current
assert(data.state.viewport_start_time == before_start,
    "start should not change when duration unchanged")
print("  PASS: setting same duration is a no-op")

print("\n✅ test_viewport_zoom_anchor.lua passed")
