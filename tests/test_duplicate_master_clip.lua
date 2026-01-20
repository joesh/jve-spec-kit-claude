#!/usr/bin/env luajit

require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')
local command_impl = require('core.command_implementations')
local Command = require('command')

local TEST_DB = "/tmp/jve/test_duplicate_master_clip.db"
os.remove(TEST_DB)

database.init(TEST_DB)
local db = database.get_connection()

db:exec(require('import_schema'))

db:exec([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('default_project', 'Default Project', strftime('%s','now'), strftime('%s','now'));
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height,
                           view_start_frame, view_duration_frames, playhead_frame, mark_in_frame, mark_out_frame,
                           selected_clip_ids, selected_edge_infos, selected_gap_infos, current_sequence_number, created_at, modified_at)
    VALUES ('default_sequence', 'default_project', 'Sequence', 'timeline', 24, 1, 48000, 1920, 1080,
            0, 240, 0, NULL, NULL, '[]', '[]', '[]', 0, strftime('%s','now'), strftime('%s','now'));
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('video1', 'default_sequence', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, metadata, created_at, modified_at)
    VALUES ('media_master', 'default_project', 'Master Source', '/tmp/jve/master.mov', 2000, 24, 1, 1920, 1080, 2, 'h264', '{}', strftime('%s','now'), strftime('%s','now'));
    INSERT INTO clips (id, project_id, clip_kind, name, media_id, owner_sequence_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES ('master_clip', 'default_project', 'master', 'Master Clip', 'media_master', NULL, 0, 2000, 0, 2000, 24, 1, 1, 0, strftime('%s','now'), strftime('%s','now'));

    INSERT INTO tag_namespaces (id, display_name) VALUES ('bin', 'Bins');
    INSERT INTO tags (id, project_id, namespace_id, name, path, sort_index)
    VALUES ('bin_target', 'default_project', 'bin', 'Target Bin', 'Target Bin', 1);
]])

local timeline_state_stub = {
    get_selected_clips = function() return {} end,
    get_clip_by_id = function() return nil end,
    get_sequence_id = function() return "default_sequence" end,
    get_project_id = function() return "default_project" end,
    get_selected_edges = function() return {} end,
    set_selection = function() end,
    reload_clips = function() end,
    persist_state_to_db = function() end,
    get_playhead_position = function() return 0 end,
    set_playhead_position = function() end,
    get_sequence_frame_rate = function() return 24.0 end,
    get_clips = function() return {} end,
    capture_viewport = function() return {start_value = 0, duration_value = 240, timebase_type = "video_frames", timebase_rate = 24.0} end,
    restore_viewport = function() end,
    push_viewport_guard = function() return 0 end,
    pop_viewport_guard = function() return 0 end
}

package.loaded["ui.timeline.timeline_state"] = timeline_state_stub
package.loaded["ui.focus_manager"] = {
    get_focused_panel = function() return "project_browser" end,
    set_focused_panel = function() end
}

local executors = {}
local undoers = {}
command_impl.register_commands(executors, undoers, db)
assert(type(undoers["DuplicateMasterClip"]) == "function", "DuplicateMasterClip undoer not registered")
command_manager.init(db, 'default_sequence', 'default_project')

local snapshot = {
    name = "Master Clip",
    media_id = "media_master",
    fps_numerator = 24,
    fps_denominator = 1,
    duration_value = 2000,
    source_in_value = 0,
    source_out_value = 2000,
    source_sequence_id = nil,
    start_value = 0,
    enabled = true,
    offline = false,
    project_id = "default_project"
}

local cmd = Command.create("DuplicateMasterClip", "default_project")
cmd:set_parameter("clip_snapshot", snapshot)
cmd:set_parameter("bin_id", "bin_target")
cmd:set_parameter("new_clip_id", "master_clip_copy")
cmd:set_parameter("name", "Master Clip Copy")
cmd:set_parameter("copied_properties", {
    {property_name = "ColorBalance", property_value = '{"value":"warm"}', property_type = "STRING", default_value = '{}'}
})

local result = command_manager.execute(cmd)
assert(result.success, result.error_message or "DuplicateMasterClip failed")

local verify_stmt = db:prepare([[SELECT clip_kind, media_id FROM clips WHERE id = 'master_clip_copy']])
assert(verify_stmt:exec() and verify_stmt:next())
local clip_kind = verify_stmt:value(0)
local media_id = verify_stmt:value(1)
verify_stmt:finalize()
assert(clip_kind == "master", "duplicated clip should be a master clip")
assert(media_id == "media_master", "duplicated clip should reference original media")

local bin_map = database.load_master_clip_bin_map("default_project")
assert(bin_map["master_clip_copy"] == "bin_target", "duplicated clip should be assigned to target bin")

local undo_result = command_manager.undo()
assert(undo_result.success, "Undo DuplicateMasterClip should succeed")

local check_stmt = db:prepare([[SELECT COUNT(*) FROM clips WHERE id = 'master_clip_copy']])
assert(check_stmt:exec() and check_stmt:next())
assert(check_stmt:value(0) == 0, "duplicated clip should be removed after undo")
check_stmt:finalize()

local bin_map_after = database.load_master_clip_bin_map("default_project")
assert(bin_map_after["master_clip_copy"] == nil, "bin map entry should be cleared after undo")

print("✅ DuplicateMasterClip command creates master clips with bin assignment and undoes cleanly")
