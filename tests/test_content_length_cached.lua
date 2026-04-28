#!/usr/bin/env luajit
--- Regression: content-length is derived state. Reading it must NOT scan
--- all clips. Pre-fix (TSO 2026-04-28): every viewport-math call walked
--- `data.state.clips` (8495 entries in Joe's project) — scrollbar render
--- at 60Hz × ruler render × every clamp inside set_viewport_start_time.
---
--- Domain rules pinned here:
---
---   * After a clip write, content-length is the max of every clip's
---     (timeline_start + duration). Empty clips → 0.
---
---   * Viewport-math reads (`get_timeline_extent`, `set_viewport_start_time`,
---     etc.) read the cached value WITHOUT re-scanning clips. The scan
---     happens at write time, not read time.
---
---   * The canonical clip-list setter (`set_clips`) refreshes the cache
---     atomically — callers cannot bypass the invariant by forgetting an
---     explicit refresh.
---
---   * In-place mutation of the clip table still requires an explicit
---     `update_content_length()` call (gap injection's pattern).
require("test_env")

local data = require("ui.timeline.state.timeline_state_data")
local viewport_state = require("ui.timeline.state.viewport_state")

-- Stub frame rate so calculate_timeline_extent can compute its buffer.
data.state.sequence_frame_rate = { fps_numerator = 24, fps_denominator = 1 }
data.state.viewport_start_time = 0
data.state.viewport_duration = 100
data.state.playhead_position = 0

-- ----------------------------------------------------------------------
-- Probe: count how often the recompute helper actually walks the clips.
-- The helper exists at the data layer because the gesture lifecycle of
-- "clips changed → content_length needs refresh" is owned by writers,
-- not readers.
-- ----------------------------------------------------------------------
assert(type(data.update_content_length) == "function",
    "timeline_state_data.update_content_length must exist (the recompute "
    .. "helper writers call after mutating clips)")
local recompute_calls = 0
local original_update = data.update_content_length
data.update_content_length = function(...)
    recompute_calls = recompute_calls + 1
    return original_update(...)
end

-- ----------------------------------------------------------------------
-- Set up a clip list and refresh the cache once.
-- ----------------------------------------------------------------------
data.state.clips = {
    { timeline_start = 0,    duration = 100, track_id = "t1" },
    { timeline_start = 200,  duration = 50,  track_id = "t1" },
    { timeline_start = 1000, duration = 250, track_id = "t2" },
}
data.update_content_length()
local baseline_recomputes = recompute_calls

-- max(0+100, 200+50, 1000+250) = 1250
assert(data.state.content_length == 1250, string.format(
    "content_length must equal max(timeline_start + duration) over all clips; "
    .. "expected 1250, got %s", tostring(data.state.content_length)))

-- ----------------------------------------------------------------------
-- 1000 viewport-math reads must NOT trigger a re-scan.
-- ----------------------------------------------------------------------
for _ = 1, 1000 do
    viewport_state.get_timeline_extent()
end
assert(recompute_calls == baseline_recomputes, string.format(
    "1000 viewport-math reads must not re-scan the clip list; "
    .. "recompute_calls jumped from %d to %d", baseline_recomputes, recompute_calls))

-- ----------------------------------------------------------------------
-- The canonical setter refreshes the cache in one atomic call —
-- callers cannot accidentally leave the cache stale.
-- ----------------------------------------------------------------------
assert(type(data.set_clips) == "function",
    "timeline_state_data.set_clips must exist (the canonical setter that "
    .. "keeps content_length in sync with the clip list)")
data.set_clips({
    { timeline_start = 0, duration = 50, track_id = "t1" },
})
assert(data.state.content_length == 50, string.format(
    "set_clips must refresh content_length to the new max immediately; got %s",
    tostring(data.state.content_length)))

-- ----------------------------------------------------------------------
-- Empty clips → content_length is 0 (no content to span).
-- ----------------------------------------------------------------------
data.set_clips({})
assert(data.state.content_length == 0, string.format(
    "empty clip list must yield content_length == 0; got %s",
    tostring(data.state.content_length)))

-- ----------------------------------------------------------------------
-- set_clips rejects non-table input (rule 1.14).
-- ----------------------------------------------------------------------
local ok = pcall(data.set_clips, "not a table")
assert(not ok, "set_clips must assert when given a non-table")
ok = pcall(data.set_clips, nil)
assert(not ok, "set_clips must assert when given nil")

print("\n✅ test_content_length_cached.lua passed")
