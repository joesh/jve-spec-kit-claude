#!/usr/bin/env luajit
--- Test: multi-edge same-track ripple preview must not show false-positive
--- clamped edges on other tracks when those tracks have real gaps that can
--- absorb the shift.
---
--- Scenario: V1 has clips A(0-35) B(35-66). A1 has D(0-28) E(35-59).
--- Real gap on A1 from 28-35 (7 frames). Select both V1 out-edges, trim
--- left by 7. The gap can absorb the per-track shift. No edge should be
--- marked as clamped/blocked.

require("test_env")

local Command = require("command")
local command_manager = require("core.command_manager")
local ripple_layout = require("tests.helpers.ripple_layout")

local layout = ripple_layout.create({
    db_path = "/tmp/jve/test_ripple_multi_edge_no_false_clamp.db",
    tracks = {
        order = {"v1", "a1"},
        v1 = {id = "track_v1", name = "V1", track_type = "VIDEO", track_index = 1, enabled = 1},
        a1 = {id = "track_a1", name = "A1", track_type = "AUDIO", track_index = 2, enabled = 1},
    },
    clips = {
        order = {"A", "B", "D", "E"},
        A = {id = "clip_A", name = "A", track_key = "v1", media_key = "main",
             sequence_start = 0, duration = 35, source_in = 100},
        B = {id = "clip_B", name = "B", track_key = "v1", media_key = "main",
             sequence_start = 35, duration = 31, source_in = 700},
        D = {id = "clip_D", name = "D", track_key = "a1", media_key = "main",
             sequence_start = 0, duration = 28, source_in = 100},
        E = {id = "clip_E", name = "E", track_key = "a1", media_key = "main",
             sequence_start = 35, duration = 24, source_in = 700},
    },
})

local executor = command_manager.get_executor("BatchRippleEdit")
assert(executor, "BatchRippleEdit executor missing")

-- Dry run: trim both V1 out-edges left by 7
local cmd = Command.create("BatchRippleEdit", layout.project_id)
cmd:set_parameter("sequence_id", layout.sequence_id)
cmd:set_parameter("edge_infos", {
    {clip_id = "clip_A", edge_type = "out", trim_type = "ripple", track_id = "track_v1"},
    {clip_id = "clip_B", edge_type = "out", trim_type = "ripple", track_id = "track_v1"},
})
cmd:set_parameter("lead_edge", {clip_id = "clip_A", edge_type = "out", trim_type = "ripple", track_id = "track_v1"})
cmd:set_parameter("delta_frames", -7)
cmd:set_parameter("dry_run", true)

local ok, payload = executor(cmd)
assert(ok and type(payload) == "table", "Dry run should succeed")

-- The A1 gap (28-35) can fully absorb the per-track shift of -7.
-- No edges should be marked as clamped/blocked.
if payload.clamped_edges and next(payload.clamped_edges) then
    local keys = {}
    for k in pairs(payload.clamped_edges) do
        table.insert(keys, k)
    end
    error("No edges should be clamped but got: " .. table.concat(keys, ", "))
end

-- Verify the preview positions are correct
local preview_clips = payload.affected_clips or {}
local found = {}
for _, pc in ipairs(preview_clips) do
    found[pc.clip_id] = {start = pc.new_start_value, dur = pc.new_duration}
end

-- A: trimmed from 35 to 28
assert(found["clip_A"], "clip_A should be in preview")
assert(found["clip_A"].dur == 28,
    string.format("A duration: expected 28, got %s", tostring(found["clip_A"].dur)))

-- B: shifted left by 7 (A's ripple), trimmed by 7 → start=28, dur=24
assert(found["clip_B"], "clip_B should be in preview")
assert(found["clip_B"].start == 28,
    string.format("B start: expected 28, got %s", tostring(found["clip_B"].start)))
assert(found["clip_B"].dur == 24,
    string.format("B duration: expected 24, got %s", tostring(found["clip_B"].dur)))

layout:cleanup()
print("✅ test_ripple_multi_edge_no_false_clamp.lua passed")
