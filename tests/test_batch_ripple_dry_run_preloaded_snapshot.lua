#!/usr/bin/env luajit

require("test_env")

local command_manager = require("core.command_manager")
local Command = require("command")
local database = require("core.database")
local TimelineActiveRegion = require("core.timeline_active_region")
local ripple_layout = require("tests.helpers.ripple_layout")

local TEST_DB = "/tmp/jve/test_batch_ripple_dry_run_preloaded_snapshot.db"
local layout = ripple_layout.create({db_path = TEST_DB})
local state = layout:init_timeline_state()

local clips = layout.clips
local tracks = layout.tracks

local executor = command_manager.get_executor("BatchRippleEdit")
assert(executor, "BatchRippleEdit executor missing")

local edges = {
    {clip_id = clips.v1_left.id, edge_type = "gap_after", track_id = tracks.v1.id, trim_type = "ripple"},
    {clip_id = clips.v2.id, edge_type = "out", track_id = tracks.v2.id, trim_type = "ripple"}
}

local region = TimelineActiveRegion.compute_for_edge_drag(state, edges, {pad_frames = 200})
local snapshot = TimelineActiveRegion.build_snapshot_for_region(state, region)

-- Guard: dry-run must not load all clips from DB when snapshot provided.
local original_load_clips = database.load_clips
database.load_clips = function()
    error("database.load_clips must not be called when __preloaded_clip_snapshot is provided", 2)
end

local cmd = Command.create("BatchRippleEdit", layout.project_id)
cmd:set_parameter("sequence_id", layout.sequence_id)
cmd:set_parameter("edge_infos", edges)
cmd:set_parameter("lead_edge", {clip_id = clips.v2.id, edge_type = "out", track_id = tracks.v2.id, trim_type = "ripple"})
cmd:set_parameter("delta_frames", -800)
cmd:set_parameter("dry_run", true)
cmd:set_parameter("__preloaded_clip_snapshot", snapshot)
cmd:set_parameter("__timeline_active_region", region)

local ok_call, ok, payload = pcall(executor, cmd)
database.load_clips = original_load_clips
assert(ok_call, "Dry run threw unexpectedly: " .. tostring(ok))

assert(ok and type(payload) == "table", "Expected dry-run payload table")
assert(type(payload.shift_blocks) == "table" and #payload.shift_blocks > 0, "Expected shift_blocks for ripple preview")

-- We intentionally do not enumerate all downstream shifted clips in preview.
local shifted = payload.shifted_clips or {}
assert(#shifted <= 20, "Expected shifted_clips to be small when shift_blocks present")

layout:cleanup()
print("✅ BatchRippleEdit dry-run uses preloaded snapshot and returns shift_blocks")
