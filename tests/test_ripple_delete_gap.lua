#!/usr/bin/env luajit

-- Test RippleDelete gap behavior (cross-track ripple)
-- Uses REAL timeline_state — no mock.

require('test_env')

-- No-op timer: prevent debounced persistence from firing mid-command
_G.qt_create_single_shot_timer = function() end

-- Only mock needed: panel_manager (Qt widget management)
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

local database = require('core.database')
local command_manager = require('core.command_manager')
require('core.command_implementations')
local Command = require('command')

local TEST_DB = "/tmp/jve/test_ripple_delete_gap.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")

database.init(TEST_DB)
local db = database.get_connection()

assert(db:exec(require('import_schema')))

local now = os.time()
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('default_project', 'Default Project', %d, %d);

    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_rate,
        width, height, view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at
    )
    VALUES ('default_sequence', 'default_project', 'Default Sequence', 'timeline',
        30, 1, 48000, 1920, 1080, 0, 240, 0,
        '[]', '[]', '[]', 0, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_v1', 'default_sequence', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0),
           ('track_v2', 'default_sequence', 'V2', 'VIDEO', 2, 1, 0, 0, 0, 1.0, 0.0);
]], now, now, now, now)))

local function ensure_media(id, duration_value)
    local stmt = db:prepare([[
        INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator,
            width, height, audio_channels, codec, metadata, created_at, modified_at)
        VALUES (?, 'default_project', ?, ?, ?, 30, 1, 1920, 1080, 0, 'raw', '{}',
            strftime('%s','now'), strftime('%s','now'))
    ]])
    assert(stmt, "failed to prepare media insert")
    assert(stmt:bind_value(1, id))
    assert(stmt:bind_value(2, id))
    assert(stmt:bind_value(3, "/tmp/jve/" .. id .. ".mov"))
    assert(stmt:bind_value(4, duration_value))
    assert(stmt:exec(), "failed to insert media")
    stmt:finalize()
    return id
end

local function insert_clip(id, track_id, start_value, duration_value)
    local media_id = ensure_media(id .. "_media", duration_value)
    local stmt = db:prepare([[
        INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, master_clip_id, owner_sequence_id,
                           timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                           fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
        VALUES (?, 'default_project', 'timeline', ?, ?, ?, NULL, 'default_sequence',
                ?, ?, 0, ?, 30, 1, 1, 0, strftime('%s','now'), strftime('%s','now'))
    ]])
    assert(stmt, "failed to prepare clip insert")
    assert(stmt:bind_value(1, id))
    assert(stmt:bind_value(2, id))
    assert(stmt:bind_value(3, track_id))
    assert(stmt:bind_value(4, media_id))
    assert(stmt:bind_value(5, start_value))
    assert(stmt:bind_value(6, duration_value))
    assert(stmt:bind_value(7, duration_value))  -- source_out = source_in(0) + duration
    assert(stmt:exec(), "failed to insert clip " .. id)
    stmt:finalize()
end

local function fetch_clip_start(id)
    local stmt = db:prepare("SELECT timeline_start_frame FROM clips WHERE id = ?")
    stmt:bind_value(1, id)
    assert(stmt:exec() and stmt:next(), "clip not found: " .. tostring(id))
    local value = stmt:value(0)
    stmt:finalize()
    return value
end

insert_clip("clip_a", "track_v1", 0, 1000)
insert_clip("clip_b", "track_v1", 2000, 500)
insert_clip("clip_c", "track_v2", 2000, 500)

command_manager.init('default_sequence', 'default_project')

local function exec_ripple()
    local cmd = Command.create("RippleDelete", "default_project")
    cmd:set_parameter("track_id", "track_v1")
    cmd:set_parameter("sequence_id", "default_sequence")
    cmd:set_parameter("gap_start", 1000)
    cmd:set_parameter("gap_duration", 1000)
    local result = command_manager.execute(cmd)
    assert(result.success, result.error_message or "RippleDelete failed")
end

-- Execute ripple delete: both tracks should shift
exec_ripple()
assert(fetch_clip_start("clip_b") == 1000,
    string.format("clip_b start expected 1000, got %d", fetch_clip_start("clip_b")))
assert(fetch_clip_start("clip_c") == 1000,
    string.format("clip_c start expected 1000, got %d", fetch_clip_start("clip_c")))

-- Undo should restore original positions
local undo_result = command_manager.undo()
assert(undo_result.success, undo_result.error_message or "Undo failed")
assert(fetch_clip_start("clip_b") == 2000,
    string.format("clip_b undo start expected 2000, got %d", fetch_clip_start("clip_b")))
assert(fetch_clip_start("clip_c") == 2000,
    string.format("clip_c undo start expected 2000, got %d", fetch_clip_start("clip_c")))

-- Redo should shift again on all tracks
local redo_result = command_manager.redo()
assert(redo_result.success, redo_result.error_message or "Redo failed")
assert(fetch_clip_start("clip_b") == 1000,
    string.format("clip_b redo start expected 1000, got %d", fetch_clip_start("clip_b")))
assert(fetch_clip_start("clip_c") == 1000,
    string.format("clip_c redo start expected 1000, got %d", fetch_clip_start("clip_c")))

print("✅ RippleDelete gap ripple test passed")
