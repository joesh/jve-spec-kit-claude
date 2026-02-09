#!/usr/bin/env luajit
-- Regression: Redo of wrapper command must restore selection from root, not nested command.
--
-- Bug: Nested commands got parent_sequence_number = history position (130) instead of
-- root command sequence (143). This broke the parent chain:
--   - ExtendEdit (143): parent=130 ✓
--   - BatchRippleEdit (144): parent=130 ✗ (should be 143!)
--
-- Result: redo_group found BatchRippleEdit first (via find_latest_child_command),
-- treated it as root, and restored its nil selection instead of ExtendEdit's.
--
-- Fix: Nested commands must use root_command_sequence_number as parent.

require("test_env")

local command_manager = require("core.command_manager")
local command_history = require("core.command_history")
local ripple_layout = require("tests.helpers.ripple_layout")
local timeline_state = require("ui.timeline.timeline_state")

local TEST_DB = "/tmp/jve/test_nested_command_redo_selection.db"

-- Create layout with two adjacent clips for roll edit
-- Override default clips completely to avoid conflicts
local layout = ripple_layout.create({
    db_path = TEST_DB,
    clips = {
        order = {"left", "right"},
        left = {
            id = "clip_left",
            name = "Left",
            track_key = "v1",
            media_key = "main",
            timeline_start = 0,
            duration = 1000,
            source_in = 0,
            fps_numerator = 1000,
            fps_denominator = 1
        },
        right = {
            id = "clip_right",
            name = "Right",
            track_key = "v1",
            media_key = "main",
            timeline_start = 1000,
            duration = 1000,
            source_in = 0,
            fps_numerator = 1000,
            fps_denominator = 1
        },
    },
})

local left_clip_id = layout.clips.left.id
local right_clip_id = layout.clips.right.id
local track_id = layout.tracks.v1.id

-- Set up roll edge selection at the edit point between clips
timeline_state.set_edge_selection({
    { clip_id = left_clip_id, edge_type = "out", trim_type = "roll" },
    { clip_id = right_clip_id, edge_type = "in", trim_type = "roll" },
})

-- Verify initial selection
local initial_edges = timeline_state.get_selected_edges()
assert(#initial_edges == 2, "Should have 2 edges selected initially, got " .. #initial_edges)

-- CRITICAL: Execute some commands BEFORE ExtendEdit so history position is non-nil.
-- The bug only manifests when get_current_sequence_number() returns a value,
-- because then the fallback to root_command_sequence_number doesn't trigger.
command_manager.execute("InsertGap", {
    project_id = layout.project_id,
    sequence_id = layout.sequence_id,
    position = 5000,
    duration = 100,
})

-- Re-select edges (InsertGap might have cleared selection)
timeline_state.set_edge_selection({
    { clip_id = left_clip_id, edge_type = "out", trim_type = "roll" },
    { clip_id = right_clip_id, edge_type = "in", trim_type = "roll" },
})

-- Execute ExtendEdit (wrapper that creates nested BatchRippleEdit)
local playhead = 1100  -- Move edit point 100 frames right (from 1000 to 1100)
timeline_state.set_playhead_position(playhead)

local result = command_manager.execute("ExtendEdit", {
    project_id = layout.project_id,
    sequence_id = layout.sequence_id,
    edge_infos = {
        { clip_id = left_clip_id, edge_type = "out", track_id = track_id, trim_type = "roll" },
        { clip_id = right_clip_id, edge_type = "in", track_id = track_id, trim_type = "roll" },
    },
    playhead_frame = playhead,
})

assert(result.success, "ExtendEdit should succeed: " .. tostring(result.error_message))

-- Verify the edit happened
local Clip = require("models.clip")
local left_after = Clip.load(left_clip_id)
assert(left_after.duration == 1100, "Left clip should have duration 1100 after extend, got " .. left_after.duration)

-- Undo
local undo_result = command_manager.undo()
assert(undo_result.success, "Undo should succeed: " .. tostring(undo_result.error_message))

-- Verify undo worked
local left_undone = Clip.load(left_clip_id)
assert(left_undone.duration == 1000, "Left clip should have duration 1000 after undo, got " .. left_undone.duration)

-- Verify selection restored after undo
local edges_after_undo = timeline_state.get_selected_edges()
assert(#edges_after_undo == 2,
    "Should have 2 edges selected after undo, got " .. #edges_after_undo)

-- Redo - THIS IS WHERE THE BUG MANIFESTS
-- Bug: nested command's parent_sequence_number = history position (1) instead of
-- root command sequence (2). Both ExtendEdit and BatchRippleEdit have parent=1,
-- so find_latest_child_command(1) returns BatchRippleEdit (seq=3) instead of
-- ExtendEdit (seq=2), causing redo_group to restore nil selection.
local redo_result = command_manager.redo()
assert(redo_result.success, "Redo should succeed: " .. tostring(redo_result.error_message))

-- Verify redo worked
local left_redone = Clip.load(left_clip_id)
assert(left_redone.duration == 1100, "Left clip should have duration 1100 after redo, got " .. left_redone.duration)

-- THE CRITICAL CHECK: Selection must be restored after redo
-- Bug: nested command (BatchRippleEdit) was treated as root, its nil selection was restored
local edges_after_redo = timeline_state.get_selected_edges()
assert(#edges_after_redo == 2,
    string.format("Should have 2 edges selected after redo, got %d. " ..
        "Bug: redo_group restored selection from nested command (nil) instead of root command.",
        #edges_after_redo))

-- Verify the correct edges are selected
local found_left_out = false
local found_right_in = false
for _, edge in ipairs(edges_after_redo) do
    if edge.clip_id == left_clip_id and edge.edge_type == "out" then
        found_left_out = true
    end
    if edge.clip_id == right_clip_id and edge.edge_type == "in" then
        found_right_in = true
    end
end
assert(found_left_out and found_right_in,
    "After redo, should have left:out and right:in edges selected")

print("✅ test_nested_command_redo_selection.lua passed")
