#!/usr/bin/env luajit

-- Regression: double-clicking a history entry (Cut/Paste) after undo
-- should redo forward to that point. Before fix, redo failed because
-- the executor re-read live selection (empty) instead of stored params.

local test_env = require('test_env')

_G.qt_create_single_shot_timer = function() end

package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

local database = require('core.database')
local command_manager = require('core.command_manager')
local Command = require('command')
local Media = require('models.media')
local timeline_state = require('ui.timeline.timeline_state')

local TEST_DB = "/tmp/jve/test_history_jump_redo.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")

database.init(TEST_DB)
local db = database.get_connection()
db:exec(require('import_schema'))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) VALUES ('proj', 'P', 'resample', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
                           audio_sample_rate, width, height,
                           playhead_frame, view_start_frame, view_duration_frames,
                           selected_clip_ids, selected_edge_infos, selected_gap_infos,
                           current_sequence_number, created_at, modified_at)
    VALUES ('seq', 'proj', 'S', 'nested', 25, 1, 48000, 1920, 1080,
            0, 0, 240, '[]', '[]', '[]', 0, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('v1', 'seq', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]], now, now, now, now))

command_manager.init('seq', 'proj')

-- Create media + masterclip
local media = Media.create({
    id = "m1", project_id = "proj",
    file_path = "/tmp/jve/m1.mov", name = "m1.mov",
    duration_frames = 500,
    fps_numerator = 25, fps_denominator = 1,
    width = 1920, height = 1080,
})
assert(media and media:save(db), "media save")

local mc_id = test_env.create_test_masterclip_sequence('proj', 'MC1', 25, 1, 500, "m1")

-- Insert a clip (recorded as command seq=1)
local cmd = Command.create("Insert", "proj")
cmd:set_parameter("sequence_id", "seq")
cmd:set_parameter("target_video_track_id", "v1")
cmd:set_parameter("nested_sequence_id", mc_id)
cmd:set_parameter("clip_name", "clip_a")
cmd:set_parameter("timeline_start_frame", 100)

local r = command_manager.execute(cmd)
assert(r and r.success, "Insert failed: " .. tostring(r and r.error_message))

local insert_seq = command_manager.get_current_sequence_number()
print(string.format("After Insert: cursor at seq %d", insert_seq))

-- V13: Insert generates a uuid; resolve via persisted created_clip_ids.
local cmd_obj = Command.deserialize(r.result_data)
local new_clip_id = cmd_obj.parameters.created_clip_ids
    and cmd_obj.parameters.created_clip_ids[1]
assert(new_clip_id, "Insert should record created_clip_ids[1]")

-- Select the clip and Cut it (recorded as command seq=2+)
local clip = timeline_state.get_clip_by_id(new_clip_id)
assert(clip, "Inserted clip must be in timeline cache")
timeline_state.set_selection({clip})

local sel_before_cut = timeline_state.get_selected_clips()
assert(#sel_before_cut == 1, "1 clip selected before Cut")

r = command_manager.execute("Cut", {project_id = "proj"})
assert(r and r.success, "Cut failed: " .. tostring(r and r.error_message))

local cut_seq = command_manager.get_current_sequence_number()
print(string.format("After Cut: cursor at seq %d", cut_seq))

-- Verify clip is deleted
local function clip_exists(id)
    local stmt = db:prepare("SELECT COUNT(*) FROM clips WHERE id = ?")
    stmt:bind_value(1, id)
    assert(stmt:exec() and stmt:next())
    local c = stmt:value(0)
    stmt:finalize()
    return c > 0
end

assert(not clip_exists(new_clip_id), "clip_a should be gone after Cut")

-- Undo Cut
r = command_manager.undo()
assert(r and r.success, "Undo failed: " .. tostring(r and r.error_message))
assert(clip_exists(new_clip_id), "clip_a should be restored after undo")

local undo_seq = command_manager.get_current_sequence_number()
print(string.format("After Undo: cursor at seq %d", undo_seq))

-- Verify selection was restored by undo ceremony
local sel_after_undo = timeline_state.get_selected_clips()
print(string.format("Selection after undo: %d clips", #sel_after_undo))
assert(#sel_after_undo == 1, string.format(
    "Selection should be restored after undo (got %d, expected 1)", #sel_after_undo))
assert(sel_after_undo[1].id == new_clip_id or sel_after_undo[1].clip_id == new_clip_id,
    "Restored selection should contain clip_a")

-- Simulate user interaction clearing selection (clicking elsewhere, changing focus, etc.)
-- In the real app, the user double-clicks the history panel — enough time may pass
-- that selection has changed. The redo should work regardless of current selection
-- because it should use stored command parameters, not live UI state.
timeline_state.set_selection({})
local sel_cleared = timeline_state.get_selected_clips()
assert(#sel_cleared == 0, "Selection should be empty after clearing")

-- NOW: simulate history panel double-click — jump forward to the Cut position
print(string.format("\nJumping from seq %d to seq %d (Cut position)...", undo_seq, cut_seq))
local ok, err = command_manager:jump_to_sequence_number(cut_seq)
assert(ok, string.format("jump_to_sequence_number failed: %s", tostring(err)))

-- Verify we're at the Cut position
local final_seq = command_manager.get_current_sequence_number()
assert(final_seq == cut_seq, string.format(
    "After jump, cursor should be at %d but is at %d", cut_seq, final_seq))

-- Verify clip was cut again
assert(not clip_exists(new_clip_id), "clip_a should be gone after jump-to-Cut")

print("\n✅ test_history_jump_redo.lua passed")
