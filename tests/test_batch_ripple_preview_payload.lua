#!/usr/bin/env luajit

require("test_env")

local command_manager = require("core.command_manager")
local Command = require("command")
local ripple_layout = require("tests.helpers.ripple_layout")

local TEST_DB = "/tmp/jve/test_batch_ripple_preview_payload.db"
local layout = ripple_layout.create({db_path = TEST_DB})
local clips = layout.clips
local tracks = layout.tracks

local executor = command_manager.get_executor("BatchRippleEdit")
assert(executor, "BatchRippleEdit executor missing")

local cmd = Command.create("BatchRippleEdit", layout.project_id)
cmd:set_parameter("sequence_id", layout.sequence_id)
cmd:set_parameter("edge_infos", {
    {clip_id = clips.v1_left.id, edge_type = "gap_after", track_id = tracks.v1.id, trim_type = "ripple"},
    {clip_id = clips.v2.id, edge_type = "out", track_id = tracks.v2.id, trim_type = "ripple"}
})
cmd:set_parameter("lead_edge", {clip_id = clips.v2.id, edge_type = "out", track_id = tracks.v2.id, trim_type = "ripple"})
cmd:set_parameter("delta_frames", -800)
cmd:set_parameter("dry_run", true)

local ok, payload = executor(cmd)
assert(ok and type(payload) == "table", "Dry run should return payload table")

local function assert_entries(entries, label)
    assert(type(entries) == "table" and #entries > 0, label .. " should contain entries")
    for _, entry in ipairs(entries) do
        assert(entry.clip_id, label .. " entry missing clip_id")
        assert(entry.new_start_value or entry.timeline_start or entry.start_value,
            label .. " entry missing start value")
    end
end

assert_entries(payload.affected_clips, "affected_clips")
assert_entries(payload.shifted_clips, "shifted_clips")

layout:cleanup()
print("✅ BatchRippleEdit dry run returns affected_clips and shifted_clips arrays")
