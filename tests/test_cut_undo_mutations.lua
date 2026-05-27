#!/usr/bin/env luajit

-- Cut undoer must produce __timeline_mutations (insert mutations)
-- to update the UI cache, not rely on reload_timeline fallback.

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

local TEST_DB = "/tmp/jve/test_cut_undo_mutations.db"
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

local media = Media.create({
    id = "m1", project_id = "proj",
    file_path = "/tmp/jve/m1.mov", name = "m1.mov",
    duration_frames = 500,
    fps_numerator = 25, fps_denominator = 1,
    width = 1920, height = 1080,
})
assert(media and media:save(db), "media save")

local mc_id = test_env.create_test_masterclip_sequence('proj', 'MC1', 25, 1, 500, "m1")

-- Insert a clip
local cmd = Command.create("Insert", "proj")
cmd:set_parameter("sequence_id", "seq")
cmd:set_parameter("target_video_track_id", "v1")
cmd:set_parameter("source_sequence_id", mc_id)
cmd:set_parameter("clip_name", "clip_a")
cmd:set_parameter("sequence_start_frame", 100)

local r = command_manager.execute(cmd)
assert(r and r.success, "Insert failed: " .. tostring(r and r.error_message))

-- V13: Insert generates a uuid for the new clip; resolve via the
-- command's persisted created_clip_ids[1] rather than relying on
-- clip_name being used as id (V8 behavior).
local cmd_obj = Command.deserialize(r.result_data)
local created = cmd_obj.parameters.created_clip_ids
local new_clip_id = created and created[1]
assert(new_clip_id, "Insert should record created_clip_ids[1]")
local clip = timeline_state.get_tab_strip():clip_by_id(new_clip_id)
assert(clip, "Inserted clip must be in timeline cache")
local original_start = clip.sequence_start
local original_duration = clip.duration
print(string.format("Clip after Insert: start=%d dur=%d", original_start, original_duration))

-- Select and Cut
timeline_state.set_selection({clip})

r = command_manager.execute("Cut", {project_id = "proj"})
assert(r and r.success, "Cut failed: " .. tostring(r and r.error_message))

-- Intercept reload_clips to detect if the reload fallback fires
local reload_called = false
local original_reload = timeline_state.reload_clips
timeline_state.reload_clips = function(seq_id)
    reload_called = true
    return original_reload(seq_id)
end

-- Undo Cut
local undo_result = command_manager.undo()
assert(undo_result and undo_result.success, "Undo failed: " .. tostring(undo_result and undo_result.error_message))

-- Restore original
timeline_state.reload_clips = original_reload

-- The undoer should produce proper mutations, NOT trigger reload_clips fallback
assert(not reload_called,
    "Cut undoer must produce __timeline_mutations, not rely on reload_clips fallback")

-- Verify clip was restored in the UI cache via mutations
local restored = timeline_state.get_tab_strip():clip_by_id(new_clip_id)
assert(restored, "Inserted clip must be back in timeline cache after undo")

assert(restored.sequence_start == original_start,
    string.format("clip_a.sequence_start should be %d, got %s", original_start, tostring(restored.sequence_start)))
assert(restored.duration == original_duration,
    string.format("clip_a.duration should be %d, got %s", original_duration, tostring(restored.duration)))

print("\n✅ test_cut_undo_mutations.lua passed")
