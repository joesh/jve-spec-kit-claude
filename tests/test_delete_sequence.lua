#!/usr/bin/env luajit

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local command_impl = require("core.command_implementations")
local timeline_state = require("ui.timeline.timeline_state")
local Command = require("command")

local TEST_DB = "/tmp/jve/test_delete_sequence.db"
os.remove(TEST_DB)

assert(database.init(TEST_DB))
local db = database.get_connection()

assert(db:exec(require('import_schema')))

local now = os.time()

local seed_sql = string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('default_project', 'Default Project', %d, %d);

    INSERT INTO sequences (
        id, project_id, name, kind, frame_rate, audio_sample_rate, width, height,
        timecode_start_frame, playhead_value, viewport_start_value, viewport_duration_frames_value,
        mark_in_value, mark_out_value, current_sequence_number
    )
    VALUES
    ('default_sequence', 'default_project', 'Primary Timeline', 'timeline', 30.0, 48000, 1920, 1080,
     0, 0, 0, 240, NULL, NULL, 0),
    ('sequence_to_delete', 'default_project', 'Temp Timeline', 'timeline', 24.0, 48000, 1280, 720,
     0, 0, 0, 240, NULL, NULL, 5);

    INSERT INTO tracks (id, sequence_id, name, track_type, timebase_type, timebase_rate, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_video_1', 'sequence_to_delete', 'Video 1', 'VIDEO', 'video_frames', 24.0, 1, 1, 0, 0, 0, 1.0, 0.0);

    INSERT INTO media (id, project_id, name, file_path, duration_value, timebase_type, timebase_rate, frame_rate, width, height, audio_channels, codec, created_at, modified_at, metadata)
    VALUES ('media_1', 'default_project', 'Clip Media', '/tmp/jve/clip.mov', 24000, 'video_frames', 24.0, 24.0, 1280, 720, 2, 'h264', %d, %d, '{}');

    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id,
                       start_value, duration_value, source_in_value, source_out_value, timebase_type, timebase_rate,
                       enabled, offline, created_at, modified_at)
    VALUES ('clip_1', 'default_project', 'timeline', 'Temp Clip', 'track_video_1', 'media_1', 'sequence_to_delete',
            0, 24000, 0, 24000, 'video_frames', 24.0, 1, 0, %d, %d);

    INSERT INTO properties (id, clip_id, property_name, property_value, property_type, default_value)
    VALUES ('prop_1', 'clip_1', 'opacity', '{"value":0.5}', 'NUMBER', '{"value":1.0}');

    INSERT INTO clip_links (link_group_id, clip_id, role, time_offset, timebase_type, timebase_rate, enabled)
    VALUES ('group_1', 'clip_1', 'VIDEO', 0, 'video_frames', 24.0, 1);

    INSERT INTO snapshots (id, sequence_id, sequence_number, clips_state, created_at)
    VALUES ('snapshot_1', 'sequence_to_delete', 5, '[]', %d);
]], now, now, now, now, now, now, now)

assert(db:exec(seed_sql))

local function stub_timeline_state()
    timeline_state.capture_viewport = function()
        return {start_value = 0, duration = 10000}
    end
    timeline_state.push_viewport_guard = function() end
    timeline_state.pop_viewport_guard = function() end
    timeline_state.restore_viewport = function(_) end
    timeline_state.set_selection = function(_) end
    timeline_state.set_edge_selection = function(_) end
    timeline_state.set_gap_selection = function(_) end
    timeline_state.get_selected_clips = function() return {} end
    timeline_state.get_selected_edges = function() return {} end
    timeline_state.set_playhead_value = function(_) end
    timeline_state.get_playhead_value = function() return 0 end
    timeline_state.get_project_id = function() return "default_project" end
    timeline_state.get_sequence_id = function() return "default_sequence" end
timeline_state.reload_clips = function(_) end
end

stub_timeline_state()

command_manager.init(db, "default_sequence", "default_project")
do
    local delete_module = require("core.commands.delete_sequence")
    local temp_executors = {}
    local temp_undoers = {}
    local exports = delete_module.register(temp_executors, temp_undoers, db, command_manager.set_last_error)
    if not exports or type(exports.executor) ~= "function" then
        error("DeleteSequence executor not available from delete_sequence module")
    end
    command_manager.register_executor("DeleteSequence", exports.executor, exports.undoer)
end

local function scalar(sql, value)
    local stmt = db:prepare(sql)
    assert(stmt, "Failed to prepare statement: " .. sql)
    if value ~= nil then
        stmt:bind_value(1, value)
    end
    local result = 0
    if stmt:exec() and stmt:next() then
        result = tonumber(stmt:value(0)) or 0
    end
    stmt:finalize()
    return result
end

local function fetch_property_value()
    local stmt = db:prepare("SELECT property_value FROM properties WHERE id = 'prop_1'")
    assert(stmt and stmt:exec(), "Failed to query property")
    local value = nil
    if stmt:next() then
        value = stmt:value(0)
    end
    stmt:finalize()
    return value
end

local delete_cmd = Command.create("DeleteSequence", "default_project")
delete_cmd:set_parameter("sequence_id", "sequence_to_delete")

local exec_result = command_manager.execute(delete_cmd)
assert(exec_result.success, exec_result.error_message or "delete sequence failed")

assert(scalar("SELECT COUNT(*) FROM sequences WHERE id = ?", "sequence_to_delete") == 0, "Sequence should be deleted")
assert(scalar("SELECT COUNT(*) FROM tracks WHERE sequence_id = ?", "sequence_to_delete") == 0, "Tracks should cascade delete")
assert(scalar("SELECT COUNT(*) FROM clips WHERE owner_sequence_id = ?", "sequence_to_delete") == 0, "Clips should cascade delete")
assert(scalar("SELECT COUNT(*) FROM properties WHERE clip_id = 'clip_1'") == 0, "Clip properties should be removed")
assert(scalar("SELECT COUNT(*) FROM clip_links WHERE clip_id = 'clip_1'") == 0, "Clip links should be removed")
assert(scalar("SELECT COUNT(*) FROM snapshots WHERE sequence_id = ?", "sequence_to_delete") == 0, "Snapshots should be removed")

local undo_result = command_manager.undo()
assert(undo_result.success, undo_result.error_message or "Undo failed")

assert(scalar("SELECT COUNT(*) FROM sequences WHERE id = ?", "sequence_to_delete") == 1, "Sequence should be restored on undo")
assert(scalar("SELECT COUNT(*) FROM tracks WHERE sequence_id = ?", "sequence_to_delete") == 1, "Track should be restored on undo")
assert(scalar("SELECT COUNT(*) FROM clips WHERE owner_sequence_id = ?", "sequence_to_delete") == 1, "Clip should be restored on undo")
assert(fetch_property_value() == '{"value":0.5}', "Property value should be restored")
assert(scalar("SELECT COUNT(*) FROM clip_links WHERE clip_id = 'clip_1'") == 1, "Clip links should be restored")
assert(scalar("SELECT COUNT(*) FROM snapshots WHERE sequence_id = ?", "sequence_to_delete") == 1, "Snapshot should be restored")

local redo_result = command_manager.redo()
assert(redo_result.success, redo_result.error_message or "Redo failed")

assert(scalar("SELECT COUNT(*) FROM sequences WHERE id = ?", "sequence_to_delete") == 0, "Sequence should be deleted after redo")
assert(scalar("SELECT COUNT(*) FROM tracks WHERE sequence_id = ?", "sequence_to_delete") == 0, "Tracks should be removed after redo")
assert(scalar("SELECT COUNT(*) FROM clips WHERE owner_sequence_id = ?", "sequence_to_delete") == 0, "Clips should be removed after redo")
assert(scalar("SELECT COUNT(*) FROM clip_links WHERE clip_id = 'clip_1'") == 0, "Clip links should be removed after redo")

os.remove(TEST_DB)
print("✅ DeleteSequence command deletes and restores timeline state correctly")
