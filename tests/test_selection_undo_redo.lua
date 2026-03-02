#!/usr/bin/env luajit

-- Verifies that clip selection is restored correctly across
-- multiple undo/redo operations so that the command stream
-- remains idempotent.
--
-- Scenario:
--   1. Execute a command that sets selection to Clip A.
--   2. User manually changes selection to Clip B (no command logged).
--   3. Execute a second command that depends on Clip B being selected.
--   4. Undo twice, then redo twice.
-- Expectation:
--   After the first redo, selection should already be Clip B so that
--   the second redo (or command replay) sees the exact same context
--   that existed originally.
-- Uses REAL timeline_state — no mock.

require('test_env')

-- No-op timer: prevent debounced persistence from firing mid-command
_G.qt_create_single_shot_timer = function() end

-- Only mock needed: panel_manager (Qt widget management)
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

local command_manager = require('core.command_manager')
local Command = require('command')
local database = require('core.database')
local timeline_state = require('ui.timeline.timeline_state')

print("=== Selection Undo/Redo Tests ===\n")

-- Set up isolated database
local test_db_path = "/tmp/jve/test_selection_undo_redo.db"
os.remove(test_db_path)
os.remove(test_db_path .. "-wal")
os.remove(test_db_path .. "-shm")

database.init(test_db_path)
local db = database.get_connection()

db:exec(require('import_schema'))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at) VALUES ('test_project', 'Test Project', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at)
    VALUES ('test_sequence', 'test_project', 'Test Sequence', 'timeline', 30, 1, 48000, 1920, 1080, 0, 600, 0,
        '[]', '[]', '[]', 0, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_test_v1', 'test_sequence', 'Track', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator,
        width, height, audio_channels, codec, created_at, modified_at, metadata)
    VALUES ('media_clip', 'test_project', 'Test Clip', '/tmp/jve/media_clip.mov', 1000, 30, 1,
        1920, 1080, 2, 'prores', %d, %d, '{}');
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES ('clip0', 'test_project', 'timeline', '', 'track_test_v1', 'media_clip', 'test_sequence',
        0, 1000, 0, 1000, 30, 1, 1, 0, %d, %d);
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES ('clip1', 'test_project', 'timeline', '', 'track_test_v1', 'media_clip', 'test_sequence',
        2000, 1000, 0, 1000, 30, 1, 1, 0, %d, %d);
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES ('clip2', 'test_project', 'timeline', '', 'track_test_v1', 'media_clip', 'test_sequence',
        4000, 1000, 0, 1000, 30, 1, 1, 0, %d, %d);
]], now, now, now, now, now, now, now, now, now, now, now, now))

command_manager.init('test_sequence', 'test_project')

-- Lightweight command executors for this test only.
command_manager.register_executor("TestSelectClip", function(command)
    local clip_id = command:get_parameter("clip_id")
    timeline_state.set_selection({{id = clip_id}})
    return true
end, function()
    return true
end, {
    args = {
        project_id = { required = true },
        clip_id = {},
    }
})

command_manager.register_executor("TestNoOp", function()
    return true
end, function()
    return true
end, {
    args = {
        project_id = { required = true },
    }
})

local function current_selection()
    local clips = timeline_state.get_selected_clips() or {}
    local ids = {}
    for _, clip in ipairs(clips) do
        table.insert(ids, clip.id)
    end
    return table.concat(ids, ",")
end

local function assert_selection(expected, context)
    local actual = current_selection()
    assert(actual == expected,
        string.format("FAIL: %s\nExpected selection: %s\nActual selection:   %s", context, expected, actual))
    print(string.format("  PASS: %s (%s)", context, expected))
end

-- Initial state: select Clip 0.
timeline_state.set_selection({{id = "clip0"}})
assert_selection("clip0", "Initial selection")

-- Command 1 sets selection to Clip 1.
local cmd1 = Command.create("TestSelectClip", "test_project")
cmd1:set_parameter("clip_id", "clip1")
local result1 = command_manager.execute(cmd1)
assert(result1.success, "Command 1 execution failed: " .. tostring(result1.error_message))
assert_selection("clip1", "After command 1")

-- User manually changes selection to Clip 2 (outside of command system).
timeline_state.set_selection({{id = "clip2"}})
assert_selection("clip2", "Manual selection change before command 2")

-- Command 2 records the current selection but does not mutate it.
local cmd2 = Command.create("TestNoOp", "test_project")
local result2 = command_manager.execute(cmd2)
assert(result2.success, "Command 2 execution failed: " .. tostring(result2.error_message))
assert_selection("clip2", "After command 2")

-- Undo twice: should return to initial selection.
command_manager.undo()
assert_selection("clip2", "After undoing command 2 (restores pre-state)")
command_manager.undo()
assert_selection("clip0", "After undoing command 1")

-- Redo command 1.
command_manager.redo()
assert_selection("clip1", "After redoing command 1 (restores command post-state)")

-- Redo command 2.
command_manager.redo()
assert_selection("clip2", "After redoing command 2 (head state)")

-- Test 4: Redo gracefully handles missing selection clips
print("\nTest 4: Redo skips missing selection clips")

local select_clip0 = Command.create("TestSelectClip", "test_project")
select_clip0:set_parameter("clip_id", "clip0")
assert(command_manager.execute(select_clip0).success, "Selecting clip0 should succeed")

local noop_cmd = Command.create("TestNoOp", "test_project")
assert(command_manager.execute(noop_cmd).success, "Executing no-op command should succeed")

-- Delete clip0 from DB — redo should handle missing clip gracefully
assert(db:exec("DELETE FROM clips WHERE id = 'clip0'"), "Failed to delete clip0 from database")

local undo_result = command_manager.undo()
assert(undo_result.success, "Undo after deleting clip should succeed")

local redo_result = command_manager.redo()
assert(redo_result.success, "Redo should succeed even if selection clip was deleted")

-- Selection should be empty since clip0 no longer exists in DB
local sel_after_redo = current_selection()
assert(sel_after_redo == "", string.format("Selection after redo should be empty, got '%s'", sel_after_redo))

print("  Redo gracefully handles missing selection clips")

command_manager.unregister_executor("TestSelectClip")
command_manager.unregister_executor("TestNoOp")

print("\n✅ test_selection_undo_redo.lua passed")
