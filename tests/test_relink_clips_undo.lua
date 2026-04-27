#!/usr/bin/env luajit
--- T012: RelinkClips command undo test
-- Verifies execute + undo restores all clip/media state.
require("test_env")

-- No-op timer
_G.qt_create_single_shot_timer = function() end

-- Mock panel_manager
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

print("=== test_relink_clips_undo.lua ===")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local uuid = require("uuid")

local TEST_DB = "/tmp/jve/test_relink_clips_undo.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")

database.init(TEST_DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
local project_id = "proj-relink"
local seq_id = uuid.generate()
local track_id = uuid.generate()
local media_id = "media-orig"
local clip_id_1 = uuid.generate()
local clip_id_2 = uuid.generate()

-- Seed: project, sequence, track, media. V13 master + media_ref are
-- created via Sequence.ensure_master after the media row exists, so
-- the test stays focused on relink behavior rather than the exact V13
-- master-anchor SQL.
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at, settings)
    VALUES ('%s', 'Relink Project', 'resample', %d, %d, '{}');

    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height,
        view_start_frame, view_duration_frames, playhead_frame, selected_clip_ids, selected_edge_infos,
        selected_gap_infos, current_sequence_number, created_at, modified_at)
    VALUES ('%s', '%s', 'Seq', 'nested', 25, 1, 48000, 1920, 1080, 0, 240, 0, '[]', '[]', '[]', 0, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('%s', '%s', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);

    INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator,
        width, height, audio_channels, codec, created_at, modified_at, metadata)
    VALUES ('%s', '%s', 'A026_C007.mov', '/offline/A026_C007.mov', 1000, 25, 1,
        1920, 1080, 0, 'prores', %d, %d, '{"start_tc_value":89750,"start_tc_rate":25}');
]], project_id, now, now,
    seq_id, project_id, now, now,
    track_id, seq_id,
    media_id, project_id, now, now))

local _Sequence = require("models.sequence")
local master_seq_id = _Sequence.ensure_master(media_id, project_id)

db:exec(string.format([[
    INSERT INTO clips (id, project_id, name, track_id, nested_sequence_id, owner_sequence_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, playhead_frame, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume)
    VALUES ('%s', '%s', 'Clip1', '%s', '%s', '%s', 0, 100, 100, 200, 1, 0, %d, %d, NULL, NULL, 'resample', 1.0);
    INSERT INTO clips (id, project_id, name, track_id, nested_sequence_id, owner_sequence_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, playhead_frame, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume)
    VALUES ('%s', '%s', 'Clip2', '%s', '%s', '%s', 100, 50, 300, 350, 1, 0, %d, %d, NULL, NULL, 'resample', 1.0);
]], clip_id_1, project_id, track_id, master_seq_id, seq_id, now, now,
    clip_id_2, project_id, track_id, master_seq_id, seq_id, now, now))

command_manager.init(seq_id, project_id)

local Clip = require("models.clip")
local Media = require("models.media")

---------------------------------------------------------------------------------
-- Test 1: Execute RelinkClips — update paths + source ranges
---------------------------------------------------------------------------------
print("\n--- Test 1: Execute RelinkClips ---")
do
    local cmd = Command.create("RelinkClips", project_id)
    cmd:set_parameter("project_id", project_id)
    cmd:set_parameter("clip_relink_map", {
        [clip_id_1] = { new_source_in = 75, new_source_out = 175 },
        [clip_id_2] = { new_source_in = 275, new_source_out = 325 },
    })
    cmd:set_parameter("media_path_changes", {
        [media_id] = "/new/A026_C007.mov",
    })

    local result = command_manager.execute(cmd)
    assert(result.success, "RelinkClips should succeed: " .. tostring(result.error_message))

    -- Verify clips updated
    local c1 = Clip.load(clip_id_1)
    assert(c1.source_in == 75, string.format("clip1 source_in: expected 75, got %d", c1.source_in))
    assert(c1.source_out == 175, string.format("clip1 source_out: expected 175, got %d", c1.source_out))

    local c2 = Clip.load(clip_id_2)
    assert(c2.source_in == 275, string.format("clip2 source_in: expected 275, got %d", c2.source_in))
    assert(c2.source_out == 325, string.format("clip2 source_out: expected 325, got %d", c2.source_out))

    -- Verify media path updated
    local m = Media.load(media_id)
    assert(m:get_file_path() == "/new/A026_C007.mov",
        "media path should be updated to /new/A026_C007.mov")

    print("  ✓ clips source ranges updated")
    print("  ✓ media path updated")
end

---------------------------------------------------------------------------------
-- Test 2: Undo RelinkClips — restore all state
---------------------------------------------------------------------------------
print("\n--- Test 2: Undo RelinkClips ---")
do
    command_manager.undo()

    -- Verify clips restored
    local c1 = Clip.load(clip_id_1)
    assert(c1.source_in == 100, string.format("undo clip1 source_in: expected 100, got %d", c1.source_in))
    assert(c1.source_out == 200, string.format("undo clip1 source_out: expected 200, got %d", c1.source_out))

    local c2 = Clip.load(clip_id_2)
    assert(c2.source_in == 300, string.format("undo clip2 source_in: expected 300, got %d", c2.source_in))
    assert(c2.source_out == 350, string.format("undo clip2 source_out: expected 350, got %d", c2.source_out))

    -- Verify media path restored
    local m = Media.load(media_id)
    assert(m:get_file_path() == "/offline/A026_C007.mov",
        "media path should be restored to /offline/A026_C007.mov, got: " .. m:get_file_path())

    print("  ✓ clips source ranges restored")
    print("  ✓ media path restored")
end

---------------------------------------------------------------------------------
-- Test 3: Redo → re-applies
---------------------------------------------------------------------------------
print("\n--- Test 3: Redo RelinkClips ---")
do
    command_manager.redo()

    local c1 = Clip.load(clip_id_1)
    assert(c1.source_in == 75, "redo: clip1 source_in should be 75")

    local m = Media.load(media_id)
    assert(m:get_file_path() == "/new/A026_C007.mov", "redo: media path should be /new/A026_C007.mov")

    print("  ✓ redo re-applies relink")

    -- Undo again to leave clean state
    command_manager.undo()
end

---------------------------------------------------------------------------------
-- Test 4: RelinkClips with new media record — undo deletes it
---------------------------------------------------------------------------------
print("\n--- Test 4: New media record creation + undo deletion ---")
do
    local new_media_id = uuid.generate()

    local cmd = Command.create("RelinkClips", project_id)
    cmd:set_parameter("project_id", project_id)
    cmd:set_parameter("clip_relink_map", {
        [clip_id_1] = {
            new_media_id = new_media_id,
            new_source_in = 0,
            new_source_out = 100,
        },
    })
    cmd:set_parameter("new_media_records", {
        {
            id = new_media_id,
            path = "/new/A026_C007_001.mov",
            name = "A026_C007_001.mov",
            duration_frames = 500,
            fps_num = 25,
            fps_den = 1,
            width = 1920,
            height = 1080,
            start_tc_value = 89800,
            start_tc_rate = 25,
        },
    })

    local result = command_manager.execute(cmd)
    assert(result.success, "RelinkClips with new media: " .. tostring(result.error_message))

    -- Verify new media exists
    local new_m = Media.load(new_media_id)
    assert(new_m, "new media record should exist")
    assert(new_m:get_file_path() == "/new/A026_C007_001.mov", "new media path")

    -- Verify clip points to new media
    local c1 = Clip.load(clip_id_1)
    assert(c1.resolved_media and c1.resolved_media.id == new_media_id,
        "clip should point to new media")
    assert(c1.source_in == 0, "clip source_in should be 0")

    print("  ✓ new media record created, clip reassigned")

    -- Undo
    command_manager.undo()

    -- Verify clip restored to original media
    c1 = Clip.load(clip_id_1)
    assert(c1.resolved_media and c1.resolved_media.id == media_id,
        "undo: clip should point back to original media")
    assert(c1.source_in == 100, "undo: clip source_in should be 100")

    -- Verify new media record deleted
    local deleted_m = Media.load(new_media_id)
    assert(deleted_m == nil, "undo: new media record should be deleted")

    print("  ✓ undo: clip restored, new media deleted")
end

print("\n✅ test_relink_clips_undo.lua passed")
