#!/usr/bin/env luajit

-- Regression: bulk_shift undo must update clips in an order that avoids
-- VIDEO_OVERLAP triggers. For a positive undo delta (original shift was
-- negative), clips move right — process DESC (highest first). For a
-- negative undo delta (original shift was positive), clips move left —
-- process ASC (lowest first). This test exercises the latter case.

require("test_env")

local database = require("core.database")
local command_helper = require("core.command_helper")
local SCHEMA_SQL = require("import_schema")

local TEST_DB = "/tmp/jve/test_command_helper_bulk_shift_undo_ordering.db"
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
    VALUES ('default_sequence', 'default_project', 'Timeline', 'nested', 25, 1, 48000, 1920, 1080, 0, 600, 0, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_v1', 'default_sequence', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);

    INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, metadata, created_at, modified_at)
    VALUES ('media1', 'default_project', 'Media', 'synthetic://media1', 10000, 25, 1, 1920, 1080, 0, 'raw', '{}', %d, %d);

    -- Pre-shifted state: clip_b and clip_c already moved +50 frames.
    -- V13 master sequence + track + media_ref for media1
INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate, width, height, created_at, modified_at)
VALUES ('master_media1', 'default_project', 'media1_master', 'master', 30, 1, 48000, 1920, 1080, 0, 0);
INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
VALUES ('master_v_media1', 'master_media1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
UPDATE sequences SET default_video_layer_track_id = 'master_v_media1' WHERE id = 'master_media1';
INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, source_in_frame, source_out_frame, timeline_start_frame, duration_frames, enabled, volume, playhead_frame, created_at, modified_at)
VALUES ('mr_media1', 'default_project', 'master_media1', 'master_v_media1', 'media1', 0, 10000, 0, 10000, 1, 1.0, 0, 0, 0);

INSERT INTO clips (id, project_id, name, track_id, nested_sequence_id, owner_sequence_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame)
VALUES
    ('clip_a', 'default_project', 'A', 'track_v1', 'master_media1', 'default_sequence', 0, 100, 0, 100, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
    ('clip_b', 'default_project', 'B', 'track_v1', 'master_media1', 'default_sequence', 150, 100, 0, 100, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
    ('clip_c', 'default_project', 'C', 'track_v1', 'master_media1', 'default_sequence', 250, 100, 0, 100, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], now, now, now, now, now, now, now, now, now, now, now, now)))

local function get_start(clip_id)
    local stmt = db:prepare("SELECT timeline_start_frame FROM clips WHERE id = ?")
    assert(stmt, "failed to prepare start query")
    stmt:bind_value(1, clip_id)
    assert(stmt:exec() and stmt:next(), "missing clip row for " .. tostring(clip_id))
    local value = stmt:value(0)
    stmt:finalize()
    return value
end

-- Forward shift was +50 from start_frame=100 (pre-shift position of
-- clip_b). DB was then manually set to the post-shift state (clip_b=150,
-- clip_c=250). The undo must find clips at >= 150 and move them back.
-- Leftward order requires ASC — otherwise the first UPDATE would land
-- clip_c at 200 where clip_b still sits, tripping VIDEO_OVERLAP.
local mutations = {
    {
        type = "bulk_shift",
        track_id = "track_v1",
        shift_frames = 50,
        start_frame = 100,
    }
}

local ok_undo, undo_err = command_helper.revert_mutations(db, mutations, nil, nil)
assert(ok_undo, undo_err or "revert_mutations failed")
assert(get_start("clip_a") == 0, "undo should leave clip_a")
assert(get_start("clip_b") == 100, "undo should restore clip_b without overlap")
assert(get_start("clip_c") == 200, "undo should restore clip_c without overlap")

os.remove(TEST_DB)
print("✅ bulk_shift undo orders per-clip updates safely")
