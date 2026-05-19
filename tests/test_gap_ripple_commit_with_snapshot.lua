#!/usr/bin/env luajit

-- Regression: BatchRippleEdit commit with __preloaded_clip_snapshot must find
-- gap clips. The snapshot path loads clips via Clip.load_optional which returns
-- nil for gap clips (in-memory only). Gap clips must be loaded from the snapshot
-- instead.

require("test_env")

local command_manager = require("core.command_manager")
require("ui.timeline.timeline_state") -- luacheck: ignore 211 (side-effect require)
local ripple_layout = require("tests.helpers.ripple_layout")
local TimelineActiveRegion = require("core.timeline_active_region")
local Clip = require("models.clip")
local Command = require("command")

local TEST_DB = "/tmp/jve/test_gap_ripple_commit_snapshot.db"
local layout = ripple_layout.create({
    db_path = TEST_DB,
    clips = {
        order = {"v1_left", "v1_right"},
        v1_left = { sequence_start = 0, duration = 500, source_in = 200 },
        v1_right = { sequence_start = 1000, duration = 500, source_in = 200 },
    }
})
local ts = layout:init_timeline_state()
local tracks = layout.tracks
local gap_id = layout:gap_id("v1", 500)

-- Build edge selection (simulating what the UI does on click)
local gap_edge = {
    clip_id = gap_id,
    edge_type = "out",
    track_id = tracks.v1.id,
    trim_type = "ripple",
}

-- Compute active region + snapshot (simulating what the drag handler does)
local region = TimelineActiveRegion.compute_for_edge_drag(ts, {gap_edge}, {pad_frames = 200})
local snapshot = TimelineActiveRegion.build_snapshot_for_region(ts, region)

-- Verify gap clip IS in the snapshot
assert(snapshot.clip_lookup[gap_id],
    "Gap clip should be in preloaded snapshot clip_lookup")

-- Execute commit with preloaded snapshot (this is the drag release path)
local cmd = Command.create("BatchRippleEdit", layout.project_id)
cmd:set_parameter("sequence_id", layout.sequence_id)
cmd:set_parameter("edge_infos", {gap_edge})
cmd:set_parameter("lead_edge", gap_edge)
cmd:set_parameter("delta_frames", -200)
cmd:set_parameter("__preloaded_clip_snapshot", snapshot)
cmd:set_parameter("__timeline_active_region", region)
cmd:set_parameter("__use_timeline_state_cache", true)

local executor = command_manager.get_executor("BatchRippleEdit")
local ok = executor(cmd)
assert(ok, "BatchRippleEdit commit with snapshot should succeed")

-- Verify the ripple worked: right clip should shift left by 200
local right = Clip.load(layout.clips.v1_right.id)
assert(right.sequence_start == 800,
    string.format("Right clip should shift to 800, got %d", right.sequence_start))

layout:cleanup()
print("✅ Gap ripple commit with preloaded snapshot works correctly")
