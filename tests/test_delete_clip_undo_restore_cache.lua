#!/usr/bin/env luajit

-- Regression: DeleteClip undo must restore clip to DB and timeline cache.
-- Uses REAL timeline_state — no mock. Verifies DB + cache side effects (black-box).

require("test_env")

-- No-op timer: prevent debounced persistence from firing mid-command
_G.qt_create_single_shot_timer = function() end

-- Only mock needed: panel_manager (Qt widget management)
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

local database = require("core.database")
local Command = require("command")
local command_manager = require("core.command_manager")
local timeline_state = require("ui.timeline.timeline_state")

local DB_PATH = "/tmp/jve/test_delete_clip_undo_restore_cache.db"
os.remove(DB_PATH)
os.remove(DB_PATH .. "-wal")
os.remove(DB_PATH .. "-shm")
assert(database.init(DB_PATH))
local db = database.get_connection()

db:exec(require("import_schema"))

db:exec([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('default_project', 'Default Project', strftime('%s','now'), strftime('%s','now'));
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, width, height, created_at, modified_at)
    VALUES ('media_test', 'default_project', 'Test Media', 'synthetic://test',
        1000, 30, 1, 1920, 1080, strftime('%s','now'), strftime('%s','now'));
    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_rate,
        width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at
    )
    VALUES (
        'default_sequence', 'default_project', 'Default Sequence', 'timeline',
        30, 1, 48000,
        1920, 1080,
        0, 300, 0,
        '[]', '[]', '[]',
        0, strftime('%s','now'), strftime('%s','now')
    );
    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_rate,
        width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at
    )
    VALUES (
        'mc_seq', 'default_project', 'Test Master', 'masterclip',
        30, 1, 48000,
        1920, 1080,
        0, 300, 0,
        '[]', '[]', '[]',
        0, strftime('%s','now'), strftime('%s','now')
    );
    INSERT INTO tracks (
        id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan
    )
    VALUES (
        'track_v1', 'default_sequence', 'V1', 'VIDEO', 1,
        1, 0, 0, 0, 1.0, 0.0
    );
    INSERT INTO clips (
        id, project_id, clip_kind, master_clip_id, owner_sequence_id,
        track_id, media_id, name,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, enabled, offline,
        created_at, modified_at
    )
    VALUES (
        'clip_delete_test', 'default_project', 'timeline', 'mc_seq', 'default_sequence',
        'track_v1', 'media_test', 'Test Clip',
        0, 30, 0, 30,
        30, 1, 1, 0,
        strftime('%s','now'), strftime('%s','now')
    );
]])

-- Init with REAL timeline_state
command_manager.init("default_sequence", "default_project")
command_manager.begin_command_event("script")

-- Verify clip exists in timeline cache before delete
local function find_clip_in_cache(clip_id)
    for _, c in ipairs(timeline_state.get_clips()) do
        if c.id == clip_id then return true end
    end
    return false
end

local function find_clip_in_db(clip_id)
    for _, c in ipairs(database.load_clips("default_sequence")) do
        if c.id == clip_id then return true end
    end
    return false
end

assert(find_clip_in_cache("clip_delete_test"), "Clip should exist in timeline cache before delete")
assert(find_clip_in_db("clip_delete_test"), "Clip should exist in DB before delete")

-- Execute DeleteClip
local delete_cmd = Command.create("DeleteClip", "default_project")
delete_cmd:set_parameter("clip_id", "clip_delete_test")
delete_cmd:set_parameter("sequence_id", "default_sequence")

local delete_result = command_manager.execute(delete_cmd)
assert(delete_result.success, delete_result.error_message or "DeleteClip execute failed")

-- Black-box: clip gone from DB
assert(not find_clip_in_db("clip_delete_test"), "Clip should be removed from DB after delete")

-- Black-box: clip gone from timeline cache
assert(not find_clip_in_cache("clip_delete_test"), "Clip should be removed from timeline cache after delete")

-- Undo
local undo_result = command_manager.undo()
assert(undo_result.success, undo_result.error_message or "Undo failed")

-- Black-box: clip restored in DB
assert(find_clip_in_db("clip_delete_test"), "Clip should be restored in DB after undo")

-- Black-box: clip restored in timeline cache (undo applied insert mutation)
assert(find_clip_in_cache("clip_delete_test"),
    "Clip should be restored in timeline cache after undo (insert mutation)")

command_manager.end_command_event()
print("✅ DeleteClip undo restores timeline cache insert mutation")
