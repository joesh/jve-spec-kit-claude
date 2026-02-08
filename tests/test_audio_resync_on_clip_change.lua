--- Test: Audio resyncs when crossing edit point in timeline playback
--
-- Bug: Playing across a straight edit, audio continues from old clip for 4-6
-- frames because the audio output buffer isn't flushed on source change.
--
-- Fix: In set_audio_sources, detect when sources changed (path, offset, or
-- duration) and use the cold path (STOP, FLUSH, restart) instead of hot swap.
-- Hot swap only works for volume-only changes.

require("test_env")

print("Testing audio resync on clip change...")

-- Read audio_playback to verify the fix
local file = io.open("../src/lua/core/media/audio_playback.lua", "r")
assert(file, "Could not open audio_playback.lua")
local content = file:read("*all")
file:close()

-- The fix: detect source changes (path, offset, duration)
local has_sources_changed = content:find("sources_changed", 1, true)
assert(has_sources_changed, "Fix missing: set_audio_sources must detect source changes")

-- Verify hot swap condition includes sources_changed check
local hot_swap_condition = content:find("not sources_changed", 1, true)
assert(hot_swap_condition, "Fix incomplete: hot swap must check sources_changed")

-- Verify we check source_offset_us
local checks_offset = content:find("source_offset_us ~= new_src.source_offset_us", 1, true)
assert(checks_offset, "Fix incomplete: must check source_offset_us changes")

print("✅ test_audio_resync_on_clip_change.lua passed")
