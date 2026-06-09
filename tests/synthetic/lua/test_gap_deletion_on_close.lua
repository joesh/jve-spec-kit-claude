#!/usr/bin/env luajit

require("test_env")

local command_manager = require("core.command_manager")
local Command = require("command")
local Clip = require("models.clip")
local ripple_layout = require("synthetic.helpers.ripple_layout")

-- Test that gaps close to zero correctly — no zombie clips in DB
local TEST_DB = "/tmp/jve/test_gap_deletion_on_close.db"
local layout = ripple_layout.create({
    db_path = TEST_DB,
    clips = {
        v1_right = {
            sequence_start = 2000  -- Creates 500-frame gap (2000 - 1500)
        }
    }
})
local db = layout.db
local clips = layout.clips
local tracks = layout.tracks

-- Gap is [1500, 2000], 500 frames
local gap_id = layout:gap_id("v1", 1500)

-- Close the gap completely by rippling gap's in edge right by 500
local cmd = Command.create("BatchRippleEdit", layout.project_id)
cmd:set_parameter("sequence_id", layout.sequence_id)
cmd:set_parameter("edge_infos", {
    {clip_id = gap_id, edge_type = "in", track_id = tracks.v1.id, trim_type = "ripple"}
})
cmd:set_parameter("delta_frames", 500)

local result = command_manager.execute(cmd)
assert(result.success, "Gap closure should succeed")

-- Verify downstream clip moved to close the gap
local left = Clip.load(clips.v1_left.id, db)
local right = Clip.load(clips.v1_right.id, db)

assert(left.sequence_start == 0, "Upstream clip should stay anchored")
assert(left.duration == 1500, "Upstream clip duration unchanged")
assert(right.sequence_start == 1500,
    string.format("Downstream clip should be adjacent; expected 1500, got %d", right.sequence_start))

-- CRITICAL: Check that no zombie clips exist between the two clips in DB
-- (Gap clips are in-memory only, never in DB)
local stmt = db:prepare([[
    SELECT id, sequence_start_frame, duration_frames
    FROM clips
    WHERE track_id = ?
    AND sequence_start_frame >= ?
    AND sequence_start_frame < ?
    ORDER BY sequence_start_frame
]])
stmt:bind_value(1, tracks.v1.id)
stmt:bind_value(2, left.sequence_start + left.duration)
stmt:bind_value(3, right.sequence_start)

local gap_exists = false
if stmt:exec() then
    while stmt:next() do
        local zombie_id = stmt:value(0)
        local zombie_start = stmt:value(1)
        local zombie_dur = stmt:value(2)
        print(string.format("WARNING: Found zombie clip %s at t=%d with duration=%d",
            zombie_id:sub(1,8), zombie_start, zombie_dur))
        gap_exists = true
    end
end
stmt:finalize()

assert(not gap_exists, "No zombie clips should exist between adjacent clips after gap closure")

layout:cleanup()
print("✅ Gaps correctly deleted when closed to zero duration")
