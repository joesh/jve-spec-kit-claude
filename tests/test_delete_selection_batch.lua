#!/usr/bin/env luajit

-- Black-box: DeleteSelection non-ripple path (batch delete multiple clips).
-- Verifies: clips removed from DB, undo restores all, redo re-deletes.

require("test_env")

_G.qt_create_single_shot_timer = function() end

-- Stub Qt-only modules
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}
package.loaded["ui.project_browser"] = false

local database = require("core.database")
local command_manager = require("core.command_manager")
local timeline_state = require("ui.timeline.timeline_state")
local focus_manager = require("ui.focus_manager")

local SCHEMA_SQL = require("import_schema")

local function setup_db(path)
    os.remove(path)
    os.remove(path .. "-wal")
    os.remove(path .. "-shm")
    assert(database.init(path))
    local conn = database.get_connection()
    assert(conn:exec(SCHEMA_SQL))

    local now = os.time()
    assert(conn:exec(string.format([[
        INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
        VALUES ('proj', 'Test', 'resample', %d, %d);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate,
            width, height, playhead_frame,
            view_start_frame, view_duration_frames,
            created_at, modified_at)
        VALUES ('seq', 'proj', 'Timeline', 'sequence',
            24, 1, 48000, 1920, 1080, 0, 0, 10000, %d, %d);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
        VALUES ('v1', 'seq', 'V1', 'VIDEO', 1, 1);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
        VALUES ('v2', 'seq', 'V2', 'VIDEO', 2, 1);
    ]], now, now, now, now)))

    command_manager.init('seq', 'proj')
    timeline_state.set_playhead_position(0)
    timeline_state.set_selection({})
    focus_manager.set_focused_panel("timeline")
    return conn
end

local test_env = require("test_env")

local function insert_clip(conn, id, track_id, start_frames, dur_frames, media_id)
    media_id = media_id or (id .. "_media")
    local now = os.time()

    test_env.create_test_media({
        id = media_id,
        project_id = "proj",
        name = media_id .. ".mov",
        file_path = "/tmp/jve/" .. media_id .. ".mov",
        duration_frames = dur_frames,
        fps_numerator = 24,
        fps_denominator = 1,
        width = 1920,
        height = 1080,
        codec = "prores",
    })
    -- V13: clip references a master sequence wrapping the media.
    local master_id = test_env.create_test_masterclip_sequence(
        "proj", media_id, 24, 1, dur_frames, media_id)

    assert(conn:exec(string.format([[
        INSERT INTO clips (
            id, project_id, name, track_id,
            owner_sequence_id, sequence_id,
            sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame,
            created_at, modified_at
        ) VALUES (
            '%s', 'proj', '%s', '%s',
            'seq', '%s',
            %d, %d,
            0, %d,
            NULL, NULL, 'resample',
            1, 1.0, 0,
            %d, %d
        )
    ]], id, id, track_id, master_id,
        start_frames, dur_frames, dur_frames,
        now, now)))
end

local function count_timeline_clips(conn)
    local q = conn:prepare("SELECT COUNT(*) FROM clips WHERE owner_sequence_id = 'seq'")
    assert(q:exec() and q:next())
    local c = q:value(0)
    q:finalize()
    return c
end

local function clip_exists(conn, id)
    local q = conn:prepare("SELECT 1 FROM clips WHERE id = ?")
    q:bind_value(1, id)
    local exists = q:exec() and q:next()
    q:finalize()
    return exists
end

----------------------------------------------------------------------
-- Test 1: Batch delete 3 clips across 2 tracks, verify undo/redo
----------------------------------------------------------------------

local DB = "/tmp/jve/test_delete_selection_batch.db"
local conn = setup_db(DB)

-- Non-trivial layout: 3 clips, 2 tracks, non-zero offsets
insert_clip(conn, "c1", "v1", 10,  48)  -- V1: frame 10..58
insert_clip(conn, "c2", "v1", 100, 72)  -- V1: frame 100..172
insert_clip(conn, "c3", "v2", 50,  36)  -- V2: frame 50..86

-- Reload timeline_state so clips are visible
timeline_state.reload_clips("seq")

assert(count_timeline_clips(conn) == 3, "precondition: 3 clips")

-- Select all three clips (simulating Cmd+A then Delete)
local c1 = timeline_state.get_clip_by_id("c1")
local c2 = timeline_state.get_clip_by_id("c2")
local c3 = timeline_state.get_clip_by_id("c3")
assert(c1 and c2 and c3, "all clips should be loaded in timeline_state")
timeline_state.set_selection({c1, c2, c3})

-- Execute DeleteSelection (non-ripple = batch delete path)
local result = command_manager.execute("DeleteSelection", {
    project_id = "proj",
    sequence_id = "seq",
})
assert(result.success, "DeleteSelection should succeed: " .. tostring(result.error_message))

-- Verify: all 3 clips gone
assert(count_timeline_clips(conn) == 0,
    string.format("all clips should be deleted (got %d)", count_timeline_clips(conn)))
assert(not clip_exists(conn, "c1"), "c1 should be deleted")
assert(not clip_exists(conn, "c2"), "c2 should be deleted")
assert(not clip_exists(conn, "c3"), "c3 should be deleted")

-- Undo: all 3 clips restored
local undo = command_manager.undo()
assert(undo.success, "undo should succeed: " .. tostring(undo.error_message))
assert(count_timeline_clips(conn) == 3,
    string.format("undo should restore 3 clips (got %d)", count_timeline_clips(conn)))
assert(clip_exists(conn, "c1"), "c1 should be restored")
assert(clip_exists(conn, "c2"), "c2 should be restored")
assert(clip_exists(conn, "c3"), "c3 should be restored")

-- Verify positions restored correctly
local function clip_start(cid)
    local q = conn:prepare("SELECT sequence_start_frame FROM clips WHERE id = ?")
    q:bind_value(1, cid)
    assert(q:exec() and q:next(), "clip not found: " .. cid)
    local v = q:value(0)
    q:finalize()
    return v
end

assert(clip_start("c1") == 10,  "c1 start should be 10 after undo")
assert(clip_start("c2") == 100, "c2 start should be 100 after undo")
assert(clip_start("c3") == 50,  "c3 start should be 50 after undo")

-- Redo: clips deleted again
local redo = command_manager.redo()
assert(redo.success, "redo should succeed: " .. tostring(redo.error_message))
assert(count_timeline_clips(conn) == 0,
    string.format("redo should delete all clips again (got %d)", count_timeline_clips(conn)))

print("✅ test_delete_selection_batch.lua: batch delete 3 clips + undo/redo")

----------------------------------------------------------------------
-- Test 2: Delete with mixed selection (some clips on same track)
----------------------------------------------------------------------

local DB2 = "/tmp/jve/test_delete_selection_batch2.db"
conn = setup_db(DB2)

-- 4 clips: 3 on v1, 1 on v2. Delete only 2 from v1.
insert_clip(conn, "d1", "v1", 0,   24)
insert_clip(conn, "d2", "v1", 48,  24)
insert_clip(conn, "d3", "v1", 96,  24)
insert_clip(conn, "d4", "v2", 0,   48)

timeline_state.reload_clips("seq")
assert(count_timeline_clips(conn) == 4, "precondition: 4 clips")

-- Select only d1 and d3 (leaving d2 and d4 untouched)
local d1 = timeline_state.get_clip_by_id("d1")
local d3 = timeline_state.get_clip_by_id("d3")
assert(d1 and d3, "d1 and d3 should be loaded")
timeline_state.set_selection({d1, d3})

result = command_manager.execute("DeleteSelection", {
    project_id = "proj",
    sequence_id = "seq",
})
assert(result.success, "partial delete should succeed")

-- d1 and d3 gone, d2 and d4 remain
assert(not clip_exists(conn, "d1"), "d1 should be deleted")
assert(clip_exists(conn, "d2"), "d2 should remain")
assert(not clip_exists(conn, "d3"), "d3 should be deleted")
assert(clip_exists(conn, "d4"), "d4 should remain")
assert(count_timeline_clips(conn) == 2, "2 clips should remain")

-- Undo restores the deleted ones without disturbing the survivors
undo = command_manager.undo()
assert(undo.success, "undo partial delete should succeed")
assert(count_timeline_clips(conn) == 4, "undo should restore to 4 clips")
assert(clip_start("d2") == 48, "d2 should be untouched at frame 48")
assert(clip_start("d4") == 0,  "d4 should be untouched at frame 0")

print("✅ test_delete_selection_batch.lua: partial delete preserves unselected clips")

print("\n✅ test_delete_selection_batch.lua passed")
