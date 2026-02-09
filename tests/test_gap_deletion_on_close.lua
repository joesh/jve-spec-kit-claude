#!/usr/bin/env luajit

require("test_env")

local command_manager = require("core.command_manager")
local Command = require("command")
local Clip = require("models.clip")
local ripple_layout = require("tests.helpers.ripple_layout")

-- Test that gaps are deleted when closed to zero duration, not left as 0-frame zombie clips
local TEST_DB = "/tmp/jve/test_gap_deletion_on_close.db"
local layout = ripple_layout.create({
    db_path = TEST_DB,
    clips = {
        v1_right = {
            timeline_start = 2000  -- Creates 500-frame gap (2000 - 1500)
        }
    }
})
local db = layout.db
local clips = layout.clips
local tracks = layout.tracks

-- Close the gap completely by dragging gap_after edge right by 500 frames
local cmd = Command.create("BatchRippleEdit", layout.project_id)
cmd:set_parameter("sequence_id", layout.sequence_id)
cmd:set_parameter("edge_infos", {
    {clip_id = clips.v1_left.id, edge_type = "gap_after", track_id = tracks.v1.id, trim_type = "ripple"}
})
cmd:set_parameter("delta_frames", 500)

local result = command_manager.execute(cmd)
assert(result.success, "Gap closure should succeed")

-- Verify downstream clip moved to close the gap
local left = Clip.load(clips.v1_left.id, db)
local right = Clip.load(clips.v1_right.id, db)

assert(left.timeline_start == 0, "Upstream clip should stay anchored")
assert(left.duration == 1500, "Upstream clip duration unchanged")
assert(right.timeline_start == 1500,
    string.format("Downstream clip should be adjacent; expected 1500, got %d", right.timeline_start))

-- CRITICAL: Check that no temp gap clip exists with 0 or negative duration
local stmt = db:prepare([[
    SELECT id, timeline_start_frame, duration_frames
    FROM clips
    WHERE track_id = ?
    AND timeline_start_frame >= ?
    AND timeline_start_frame < ?
    ORDER BY timeline_start_frame
]])
stmt:bind_value(1, tracks.v1.id)
stmt:bind_value(2, left.timeline_start + left.duration)
stmt:bind_value(3, right.timeline_start)

local gap_exists = false
if stmt:exec() then
    while stmt:next() do
        local gap_id = stmt:value(0)
        local gap_start = stmt:value(1)
        local gap_duration = stmt:value(2)
        print(string.format("WARNING: Found gap clip %s at t=%d with duration=%d (should be deleted)",
            gap_id:sub(1,8), gap_start, gap_duration))
        gap_exists = true
    end
end
stmt:finalize()

assert(not gap_exists, "Gap should be deleted when closed to zero, not left as 0-frame zombie clip")

layout:cleanup()
print("✅ Gaps correctly deleted when closed to zero duration")
