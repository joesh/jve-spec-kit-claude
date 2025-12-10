#!/usr/bin/env luajit

require("test_env")

local command_manager = require("core.command_manager")
local Command = require("command")
local Clip = require("models.clip")
local ripple_layout = require("tests.helpers.ripple_layout")

--[[
BUG: Opposing brackets logic (lines 782-787) negates delta for ALL edges with opposing brackets,
but it should ONLY negate for edges that form an EDIT POINT (adjacent clips, same track, touching boundaries).

In this test:
- V2 out ] at t=2600 (lead edge)
- V1 gap_after [ at t=1500 (NOT adjacent to V2, different track)

When dragging right +200:
- V2 should extend by 200 (correct)
- V1 gap should ALSO close by 200 (both move same direction for multi-track trim)
- But currently: V1 gap GROWS by 200 because delta gets negated (incorrect!)

Expected behavior (professional NLE):
- Multi-track trim applies SAME delta to all edges (no negation)
- Opposing bracket negation ONLY for edit points (adjacent clips on same track)
]]--

local TEST_DB = "/tmp/jve/test_opposing_brackets_bug.db"
local layout = ripple_layout.create({
    db_path = TEST_DB,
    clips = {
        v1_right = {timeline_start = 2500},  -- Gap from 1500-2500
        v2 = {timeline_start = 1800, duration = 800}  -- Ends at 2600, NOT adjacent to V1 gap
    }
})
local db = layout.db
local clips = layout.clips
local tracks = layout.tracks

print("BEFORE:")
print(string.format("  V1 gap:  1500-2500 (1000 frames)"))
print(string.format("  V2:      1800-2600 (800 frames)"))

-- Drag right +200 with V2 out ] as lead
local cmd = Command.create("BatchRippleEdit", layout.project_id)
cmd:set_parameter("sequence_id", layout.sequence_id)
cmd:set_parameter("edge_infos", {
    {clip_id = clips.v1_left.id, edge_type = "gap_after", track_id = tracks.v1.id, trim_type = "ripple"},
    {clip_id = clips.v2.id, edge_type = "out", track_id = tracks.v2.id, trim_type = "ripple"}
})
cmd:set_parameter("lead_edge", {clip_id = clips.v2.id, edge_type = "out", track_id = tracks.v2.id, trim_type = "ripple"})
cmd:set_parameter("delta_frames", 200)

local result = command_manager.execute(cmd)
assert(result.success, result.error_message or "Command failed")

local v1_left = Clip.load(clips.v1_left.id, db)
local v1_right = Clip.load(clips.v1_right.id, db)
local v2 = Clip.load(clips.v2.id, db)

local gap_size = v1_right.timeline_start.frames - (v1_left.timeline_start.frames + v1_left.duration.frames)

print("\nAFTER:")
print(string.format("  V1 gap:  %d-%d (%d frames)",
    v1_left.timeline_start.frames + v1_left.duration.frames,
    v1_right.timeline_start.frames,
    gap_size))
print(string.format("  V2:      %d-%d (%d frames)",
    v2.timeline_start.frames,
    v2.timeline_start.frames + v2.duration.frames,
    v2.duration.frames))

-- CORRECT: V2 extends by 200
assert(v2.duration.frames == 1000,
    string.format("V2 should extend by 200 (800→1000), got %d", v2.duration.frames))

-- BUG: Gap should close by 200 (1000→800), but instead grows by 200 (1000→1200)!
-- Professional NLEs apply same delta to multi-track selections (no negation)
local expected_gap = 800  -- Should close by same amount V2 extended
local bug_gap = 1200      -- Incorrectly grows due to delta negation

if gap_size == expected_gap then
    print("✅ FIXED: Gap closed by 200 frames (correct multi-track trim)")
elseif gap_size == bug_gap then
    print("❌ BUG: Gap grew by 200 frames due to incorrect opposing bracket negation")
    print("   Opposing bracket negation should ONLY apply to edit points (adjacent clips, same track)")
    error("Gap behavior incorrect - should be 800, got 1200")
else
    print(string.format("❌ UNEXPECTED: Gap is %d frames (expected 800 or 1200)", gap_size))
    error("Unexpected gap size")
end

layout:cleanup()
