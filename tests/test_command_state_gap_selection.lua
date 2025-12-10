#!/usr/bin/env luajit

package.path = "./?.lua;./src/lua/?.lua;./tests/?.lua;" .. package.path

require("test_env")

local command_state = require("core.command_state")
local database = require("core.database")
local timeline_state = require("ui.timeline.timeline_state")
local ripple_layout = require("tests.helpers.ripple_layout")
local dkjson = require("dkjson")

local layout = ripple_layout.create()
layout:init_timeline_state()

local db = database.get_connection()
command_state.init(db)

local clips = layout.clips
local tracks = layout.tracks
local gap_start = clips.v1_left.timeline_start + clips.v1_left.duration
local gap_end = clips.v1_right.timeline_start
local gap_id = string.format("temp_gap_%s_%d_%d", tracks.v1.id, gap_start, gap_end)

timeline_state.set_edge_selection_raw({
    {clip_id = gap_id, edge_type = "gap_after", trim_type = "ripple"}
})

local _, edges_json = command_state.capture_selection_snapshot()
local decoded = dkjson.decode(edges_json)
assert(decoded and decoded[1], "capture should include an edge entry")
assert(decoded[1].clip_id == clips.v1_left.id, string.format("Expected capture to resolve gap to clip id %s, got %s", clips.v1_left.id, tostring(decoded[1].clip_id)))

local legacy_edges_json = string.format("[{\"clip_id\":\"%s\",\"edge_type\":\"gap_after\",\"trim_type\":\"ripple\"}]", gap_id)
command_state.restore_selection_from_serialized("[]", legacy_edges_json, "[]")
local restored = timeline_state.get_selected_edges()
assert(restored and restored[1], "restore should set a gap edge selection")
assert(restored[1].clip_id == clips.v1_left.id, string.format("Expected restore to resolve to clip id %s, got %s", clips.v1_left.id, tostring(restored[1].clip_id)))
assert(restored[1].edge_type == "gap_after", "restore should keep gap edge type")

layout:cleanup()
print("✅ Command state captures and restores gap edge selections")
