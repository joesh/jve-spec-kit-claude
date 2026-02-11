#!/usr/bin/env luajit

-- Test: Selection normalization when a clip is rolled/rippled to zero length
-- What happens to selected edges on a clip that no longer exists or has duration=0?

require("test_env")

local command_manager = require("core.command_manager")
local timeline_state = require("ui.timeline.timeline_state")
local _ = require("ui.timeline.state.selection_state")  -- luacheck: ignore 211
local Clip = require("models.clip")
local ripple_layout = require("tests.helpers.ripple_layout")

local TEST_DB = "/tmp/jve/test_clip_trimmed_zero.db"

-- Layout: left [0..1000), middle [1000..1100), right [1100..2100)
-- middle clip is only 100 frames - we'll roll it to zero
local layout = ripple_layout.create({
    db_path = TEST_DB,
    clips = {
        order = {"v1_left", "v1_middle", "v1_right"},
        v1_left = {
            timeline_start = 0,
            duration = 1000,
            source_in = 500,
        },
        v1_middle = {
            id = "clip_v1_middle",
            timeline_start = 1000,
            duration = 100,  -- Small clip
            source_in = 500,
        },
        v1_right = {
            timeline_start = 1100,
            duration = 1000,
            source_in = 500,
        },
    }
})

layout:init_timeline_state()
local clips = layout.clips
local tracks = layout.tracks

-- Select out edge on middle clip for roll
-- Rolling the out edge LEFT by 100 frames would make duration = 0
local edge_infos = {
    {clip_id = clips.v1_middle.id, edge_type = "out", track_id = tracks.v1.id, trim_type = "roll"},
    {clip_id = clips.v1_right.id, edge_type = "in", track_id = tracks.v1.id, trim_type = "roll"},
}
timeline_state.set_edge_selection(edge_infos)

print("Before edit:")
local middle = Clip.load(clips.v1_middle.id, layout.db)
print(string.format("  middle clip: [%d..%d) duration=%d",
    middle.timeline_start, middle.timeline_start + middle.duration, middle.duration))

print("  selection:")
for i, edge in ipairs(timeline_state.get_selected_edges()) do
    print(string.format("    [%d] clip=%s edge_type=%s", i, edge.clip_id, edge.edge_type))
end

-- Roll the middle clip's out edge to meet its in edge (duration → 0)
-- This should make the middle clip disappear or have 0 duration
local result1 = command_manager.execute("ExtendEdit", {
    edge_infos = edge_infos,
    playhead_frame = 1000,  -- Roll out to meet in at 1000
    project_id = layout.project_id,
    sequence_id = layout.sequence_id,
})

print("\nAfter edit:")
middle = Clip.load_optional(clips.v1_middle.id, layout.db)
if middle then
    print(string.format("  middle clip: [%d..%d) duration=%d",
        middle.timeline_start, middle.timeline_start + middle.duration, middle.duration))
else
    print("  middle clip: DELETED or not found")
end

local normalized = timeline_state.get_selected_edges()
print("  selection:")
for i, edge in ipairs(normalized) do
    print(string.format("    [%d] clip=%s edge_type=%s trim_type=%s",
        i, edge.clip_id, edge.edge_type, edge.trim_type or "nil"))
end

-- Key questions:
-- 1. Did the edit succeed or fail?
-- 2. What happened to the middle clip? (duration=0? deleted?)
-- 3. What does the selection look like now?

assert(result1 and result1.success, "Edit should succeed")

-- BUG CHECK: Clip should be deleted when trimmed to zero, not clamped to 1
middle = Clip.load_optional(clips.v1_middle.id, layout.db)
assert(middle == nil or middle.duration == 0,
    string.format("Clip trimmed to zero should be deleted, but got duration=%d",
        middle and middle.duration or -1))

-- Selection should NOT reference deleted/zero-length clips
for _, edge in ipairs(normalized) do
    assert(edge.clip_id ~= clips.v1_middle.id,
        "Selection should not reference deleted clip")
end

layout:cleanup()
print("\n✅ test_selection_normalization_clip_trimmed_to_zero.lua passed")
