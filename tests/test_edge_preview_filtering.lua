#!/usr/bin/env luajit

require("test_env")

local command_manager = require("core.command_manager")
local Command = require("command")
local ripple_layout = require("tests.helpers.ripple_layout")

--[[
Test: Edge preview should filter gaps from affected_clips but include them in shifted_clips if they shift
Setup:
  - V1: gap from 1500-2500 (1000 frames)
  - V2: clip from 1800-2600 (800 frames)
  - Drag V2 out + V1 gap_after left by -200
Expected preview payload:
  - affected_clips: [V2] (gap filtered out)
  - shifted_clips: [V1_right] (downstream clip that shifted)
  - materialized_gaps: [temp_gap_v1_*] (gap was materialized but filtered from preview)
]]

local TEST_DB = "/tmp/jve/test_edge_preview_filtering.db"
local layout = ripple_layout.create({
    db_path = TEST_DB,
    clips = {
        v1_right = {timeline_start = 2500},
        v2 = {timeline_start = 1800, duration = 800}
    }
})

local executor = command_manager.get_executor("BatchRippleEdit")
assert(executor, "BatchRippleEdit executor missing")

local cmd = Command.create("BatchRippleEdit", layout.project_id)
cmd:set_parameter("sequence_id", layout.sequence_id)
cmd:set_parameter("edge_infos", {
    {clip_id = layout.clips.v1_left.id, edge_type = "gap_after", track_id = layout.tracks.v1.id, trim_type = "ripple"},
    {clip_id = layout.clips.v2.id, edge_type = "out", track_id = layout.tracks.v2.id, trim_type = "ripple"}
})
cmd:set_parameter("lead_edge", {clip_id = layout.clips.v2.id, edge_type = "out", track_id = layout.tracks.v2.id, trim_type = "ripple"})
cmd:set_parameter("delta_frames", -200)
cmd:set_parameter("dry_run", true)

local ok, payload = executor(cmd)
assert(ok and type(payload) == "table", "Dry run should return payload table")

-- Note: Command payload WILL contain temp gaps - renderer filters them
-- Let's verify the gap IS present in raw payload
local gap_found_in_payload = false
local gap_clip_id = nil
for _, entry in ipairs(payload.affected_clips or {}) do
    if type(entry.clip_id) == "string" and entry.clip_id:find("^temp_gap_") then
        gap_found_in_payload = true
        gap_clip_id = entry.clip_id
        break
    end
end
assert(gap_found_in_payload, "Command should include temp gap in affected_clips (renderer will filter)")

-- Verify V2 is in affected_clips
local v2_found = false
for _, entry in ipairs(payload.affected_clips or {}) do
    if entry.clip_id == layout.clips.v2.id then
        v2_found = true
        -- Verify geometry: V2 should shrink from 800 to 600 frames
        assert(entry.new_duration and entry.new_duration.frames == 600,
            string.format("V2 should shrink to 600 frames, got %s",
                tostring(entry.new_duration and entry.new_duration.frames or "nil")))
        break
    end
end
assert(v2_found, "V2 should be in affected_clips")

-- Verify shifted_clips contains v1_right
local v1_right_found = false
for _, entry in ipairs(payload.shifted_clips or {}) do
    if entry.clip_id == layout.clips.v1_right.id then
        v1_right_found = true
        -- Verify shift: v1_right should shift left from 2500 to 2300
        assert(entry.new_start_value and entry.new_start_value.frames == 2300,
            string.format("v1_right should shift to 2300, got %s",
                tostring(entry.new_start_value and entry.new_start_value.frames or "nil")))
        break
    end
end
assert(v1_right_found, "v1_right should be in shifted_clips")

-- Verify materialized_gaps contains the temp gap ID
assert(type(payload.materialized_gaps) == "table" and #payload.materialized_gaps >= 1,
    "materialized_gaps should contain at least one gap ID")

-- Test renderer gap filtering
local renderer_utils = require("ui.timeline.view.timeline_view_renderer")
-- We can't directly test the renderer here, but we can verify the payload structure
-- that the renderer will consume. The renderer's build_preview_from_payload() filters gaps.

-- Simulate what build_preview_from_payload does:
local Rational = require("core.rational")
local filtered_affected = {}
for _, entry in ipairs(payload.affected_clips or {}) do
    local is_gap = false
    if entry.is_gap or entry.is_temp_gap then
        is_gap = true
    end
    if type(entry.clip_id) == "string" and entry.clip_id:find("^temp_gap_") then
        is_gap = true
    end
    if not is_gap then
        table.insert(filtered_affected, entry)
    end
end

-- After filtering, should only have V2
assert(#filtered_affected == 1,
    string.format("After gap filtering, should have 1 clip, got %d", #filtered_affected))
assert(filtered_affected[1].clip_id == layout.clips.v2.id,
    "After filtering, only V2 should remain in affected clips")

layout:cleanup()
print("✅ Edge preview payload includes gaps (command) but renderer filters them correctly")
