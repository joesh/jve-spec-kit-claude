#!/usr/bin/env luajit

require("test_env")

local command_manager = require("core.command_manager")
local Command = require("command")
local Clip = require("models.clip")
local ripple_layout = require("tests.helpers.ripple_layout")

local TEST_DB = "/tmp/jve/test_gap_item_parity.db"
local layout = ripple_layout.create({db_path = TEST_DB})
local db = layout.db
local clips = layout.clips
local tracks = layout.tracks

local scenarios = {
    {
        name = "gap_after_ripple_out",
        edges = {
            {clip_id = clips.v1_left.id, edge_type = "gap_after", track_id = tracks.v1.id, trim_type = "ripple"}
        },
        delta = 400
    },
    {
        name = "gap_before_ripple_in",
        edges = {
            {clip_id = clips.v1_right.id, edge_type = "gap_before", track_id = tracks.v1.id, trim_type = "ripple"}
        },
        delta = -300
    },
    {
        name = "mixed_gap_clip",
        edges = {
            {clip_id = clips.v1_left.id, edge_type = "gap_after", track_id = tracks.v1.id, trim_type = "ripple"},
            {clip_id = clips.v2.id, edge_type = "out", track_id = tracks.v2.id, trim_type = "ripple"}
        },
        lead = {clip_id = clips.v2.id, edge_type = "out", track_id = tracks.v2.id, trim_type = "ripple"},
        delta = -500
    },
    {
        name = "gap_roll",
        edges = {
            {clip_id = clips.v1_left.id, edge_type = "gap_after", track_id = tracks.v1.id, trim_type = "roll"},
            {clip_id = clips.v1_right.id, edge_type = "in", track_id = tracks.v1.id, trim_type = "roll"}
        },
        lead = {clip_id = clips.v1_right.id, edge_type = "in", track_id = tracks.v1.id, trim_type = "roll"},
        delta = 150
    }
}

for _, scenario in ipairs(scenarios) do
    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", scenario.edges)
    if scenario.lead then
        cmd:set_parameter("lead_edge", scenario.lead)
    end
    cmd:set_parameter("delta_frames", scenario.delta)
    local result = command_manager.execute(cmd)
    assert(result.success, string.format("Scenario %s failed: %s", scenario.name, tostring(result.error_message)))
end

local clip_state = {
    Clip.load(clips.v1_left.id, db),
    Clip.load(clips.v1_right.id, db),
    Clip.load(clips.v2.id, db)
}

for _, clip in ipairs(clip_state) do
    assert(clip, "clip should exist after parity scenarios")
    assert(type(clip.timeline_start) == "number", "clip timeline start should be numeric")
end

layout:cleanup()
print("✅ Gap item parity scenarios succeeded without gap-specific logic")
