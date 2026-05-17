#!/usr/bin/env luajit

-- Regression: bulk_shift mutations apply forward and revert cleanly.
-- Canonical shape: { type, track_id, shift_frames, start_frame }. Every
-- clip on the named track with sequence_start_frame >= start_frame gets
-- shifted by shift_frames; the undo finds clips at the post-shift
-- position and moves them back.

require("test_env")

local database = require("core.database")
local command_helper = require("core.command_helper")
local SCHEMA_SQL = require("import_schema")

local TEST_DB = "/tmp/jve/test_command_helper_bulk_shift_undo.db"
os.remove(TEST_DB)

assert(database.init(TEST_DB))
local db = database.get_connection()
assert(db:exec(SCHEMA_SQL))

local now = os.time()
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('default_project', 'Default Project', 'resample', %d, %d);

    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, view_start_frame, view_duration_frames, playhead_frame,
        created_at, modified_at
    )
    VALUES ('default_sequence', 'default_project', 'Timeline', 'sequence', 30, 1, 48000, 1920, 1080, 0, 600, 0, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_v1', 'default_sequence', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);

    INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, metadata, created_at, modified_at)
    VALUES ('media1', 'default_project', 'Media', 'synthetic://media1', 10000, 30, 1, 1920, 1080, 0, 'raw', '{}', %d, %d);

    -- V13 master sequence + track + media_ref for media1
INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate, width, height, created_at, modified_at)
VALUES ('master_media1', 'default_project', 'media1_master', 'master', 30, 1, 48000, 1920, 1080, 0, 0);
INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
VALUES ('master_v_media1', 'master_media1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
UPDATE sequences SET default_video_layer_track_id = 'master_v_media1' WHERE id = 'master_media1';
INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, source_in_frame, source_out_frame, sequence_start_frame, duration_frames, enabled, volume, playhead_frame, created_at, modified_at)
VALUES ('mr_media1', 'default_project', 'master_media1', 'master_v_media1', 'media1', 0, 10000, 0, 10000, 1, 1.0, 0, 0, 0);

INSERT INTO clips (id, project_id, name, track_id, sequence_id, owner_sequence_id, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame)
VALUES
    ('clip_a', 'default_project', 'A', 'track_v1', 'master_media1', 'default_sequence', 0, 100, 0, 100, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
    ('clip_b', 'default_project', 'B', 'track_v1', 'master_media1', 'default_sequence', 1000, 100, 0, 100, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
    ('clip_c', 'default_project', 'C', 'track_v1', 'master_media1', 'default_sequence', 2000, 100, 0, 100, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], now, now, now, now, now, now, now, now, now, now, now, now)))

local function get_start(clip_id)
    local stmt = db:prepare("SELECT sequence_start_frame FROM clips WHERE id = ?")
    assert(stmt, "failed to prepare start query")
    stmt:bind_value(1, clip_id)
    assert(stmt:exec() and stmt:next(), "missing clip row for " .. tostring(clip_id))
    local value = stmt:value(0)
    stmt:finalize()
    return value
end

local mutations = {
    {
        type = "bulk_shift",
        track_id = "track_v1",
        shift_frames = 100,
        start_frame = 1000,  -- clip_b sits here; clip_a at 0 is untouched
    }
}

local ok, err = command_helper.apply_mutations(db, mutations)
assert(ok, err or "apply_mutations failed")
assert(get_start("clip_a") == 0, "bulk_shift should not move clips before start_frame")
assert(get_start("clip_b") == 1100, "bulk_shift should move clip_b")
assert(get_start("clip_c") == 2100, "bulk_shift should move clip_c")

local ok_undo, undo_err = command_helper.revert_mutations(db, mutations, nil, nil)
assert(ok_undo, undo_err or "revert_mutations failed")
assert(get_start("clip_a") == 0, "undo should leave clip_a")
assert(get_start("clip_b") == 1000, "undo should restore clip_b")
assert(get_start("clip_c") == 2000, "undo should restore clip_c")

os.remove(TEST_DB)
print("✅ command_helper bulk_shift applies and undoes correctly")
