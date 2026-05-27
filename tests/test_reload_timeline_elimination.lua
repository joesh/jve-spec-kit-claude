#!/usr/bin/env luajit

-- Verify that commands produce proper __timeline_mutations instead of
-- calling reload_timeline (brute-force cache invalidation).
-- Tests: DeleteMasterClip (executor + undoer), RenameItem (executor + undoer)

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
local command_helper = require('core.command_helper')

local TEST_DB = "/tmp/jve/test_reload_elimination.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")

database.init(TEST_DB)
local db = database.get_connection()
db:exec(require('import_schema'))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at) VALUES ('proj', 'P', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
                           audio_sample_rate, width, height,
                           playhead_frame, view_start_frame, view_duration_frames,
                           selected_clip_ids, selected_edge_infos, selected_gap_infos,
                           current_sequence_number, created_at, modified_at)
    VALUES ('seq', 'proj', 'S', 'sequence', 25, 1, 48000, 1920, 1080,
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

-- Insert a clip on the timeline
local cmd = Command.create("Insert", "proj")
cmd:set_parameter("sequence_id", "seq")
cmd:set_parameter("target_video_track_id", "v1")
cmd:set_parameter("source_sequence_id", mc_id)
cmd:set_parameter("clip_name", "clip_a")
cmd:set_parameter("sequence_start_frame", 100)
local r = command_manager.execute(cmd)
assert(r and r.success, "Insert failed: " .. tostring(r and r.error_message))

-- V13: Insert generates a uuid; resolve via persisted created_clip_ids.
local clip_a_id
do
    local cmd_obj = Command.deserialize(r.result_data)
    clip_a_id = cmd_obj.parameters.created_clip_ids
        and cmd_obj.parameters.created_clip_ids[1]
end
assert(clip_a_id, "Insert should record created_clip_ids")

-- Track reload_timeline calls
local reload_calls = {}
local original_reload = command_helper.reload_timeline
command_helper.reload_timeline = function(seq_id)
    table.insert(reload_calls, {seq_id = seq_id, trace = debug.traceback("", 2)})
    return original_reload(seq_id)
end

local function reset_reload_tracking()
    reload_calls = {}
end

local function assert_no_reload(context)
    assert(#reload_calls == 0, string.format(
        "%s: reload_timeline called %d time(s) — should use mutations instead.\n  First call: %s",
        context, #reload_calls, reload_calls[1] and reload_calls[1].trace or ""))
end

-- ============================================================
-- Test 1: RenameItem (master_clip) — executor + undoer
-- ============================================================
print("Test 1: RenameItem master_clip — no reload_timeline")
reset_reload_tracking()

r = command_manager.execute("RenameItem", {
    project_id = "proj",
    target_type = "master_clip",
    target_id = mc_id,
    new_name = "Renamed MC",
    previous_name = "MC1",
})
assert(r and r.success, "RenameItem failed: " .. tostring(r and r.error_message))

-- Verify the rename took effect in the cache
local renamed_clip = timeline_state.get_tab_strip():clip_by_id(clip_a_id)
assert(renamed_clip, "clip_a must still be in cache after rename")
assert(renamed_clip.name == "Renamed MC",
    string.format("clip name should be 'Renamed MC', got '%s'", tostring(renamed_clip.name)))

assert_no_reload("RenameItem executor")

-- Undo rename
reset_reload_tracking()
r = command_manager.undo()
assert(r and r.success, "Undo RenameItem failed: " .. tostring(r and r.error_message))

local reverted_clip = timeline_state.get_tab_strip():clip_by_id(clip_a_id)
assert(reverted_clip, "clip_a must still be in cache after undo rename")

assert_no_reload("RenameItem undoer")
print("  ✅ RenameItem: no reload_timeline in executor or undoer")

-- Redo rename to restore state for next test
r = command_manager.redo()
assert(r and r.success, "Redo RenameItem failed")

-- ============================================================
-- Test 2: DeleteMasterClip (force=true) — executor + undoer
-- ============================================================
print("\nTest 2: DeleteMasterClip force — no reload_timeline")
reset_reload_tracking()

r = command_manager.execute("DeleteMasterClip", {
    project_id = "proj",
    master_sequence_id = mc_id,
    force = true,
})
assert(r and r.success, "DeleteMasterClip failed: " .. tostring(r and r.error_message))

-- clip_a should be gone from cache
local deleted = timeline_state.get_tab_strip():clip_by_id(clip_a_id)
assert(not deleted, "clip_a should be deleted from cache")

assert_no_reload("DeleteMasterClip executor")

-- Undo delete
reset_reload_tracking()
r = command_manager.undo()
assert(r and r.success, "Undo DeleteMasterClip failed: " .. tostring(r and r.error_message))

-- clip_a should be back
local restored = timeline_state.get_tab_strip():clip_by_id(clip_a_id)
assert(restored, "clip_a must be back in cache after undo")

assert_no_reload("DeleteMasterClip undoer")
print("  ✅ DeleteMasterClip: no reload_timeline in executor or undoer")

-- Restore original
command_helper.reload_timeline = original_reload

print("\n✅ test_reload_timeline_elimination.lua passed")
