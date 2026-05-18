#!/usr/bin/env luajit

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local SCHEMA_SQL = require("import_schema")

local function setup_db(db_path)
    os.remove(db_path)
    assert(database.init(db_path))
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
        VALUES ('default_sequence', 'default_project', 'Timeline', 'sequence', 1000, 1, 48000, 1920, 1080, 0, 600, 0, %d, %d);

        INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
        VALUES ('track_v1', 'default_sequence', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
        VALUES ('track_v2', 'default_sequence', 'V2', 'VIDEO', 2, 1, 0, 0, 0, 1.0, 0.0);

        INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, metadata, created_at, modified_at)
        VALUES ('media1', 'default_project', 'Media', 'synthetic://media1', 120000, 1000, 1, 1920, 1080, 0, 'raw', '{}', %d, %d);

        -- Track V1: left clip then a gap, then right clip
        -- V13 master sequence + track + media_ref for media1
INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate, width, height, created_at, modified_at)
VALUES ('master_media1', 'default_project', 'media1_master', 'master', 30, 1, NULL, 1920, 1080, 0, 0);
INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
VALUES ('master_v_media1', 'master_media1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
UPDATE sequences SET default_video_layer_track_id = 'master_v_media1' WHERE id = 'master_media1';
INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, source_in_frame, source_out_frame, sequence_start_frame, duration_frames, enabled, volume, playhead_frame, created_at, modified_at)
VALUES ('mr_media1', 'default_project', 'master_media1', 'master_v_media1', 'media1', 0, 120000, 0, 120000, 1, 1.0, 0, 0, 0);

INSERT INTO clips (id, project_id, name, track_id, sequence_id, owner_sequence_id, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame)
VALUES
    ('v1_left', 'default_project', 'V1 Left', 'track_v1', 'master_media1', 'default_sequence', 2000, 2000, 0, 2000, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
    ('v1_right', 'default_project', 'V1 Right', 'track_v1', 'master_media1', 'default_sequence', 8000, 2000, 2000, 4000, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);

        -- Track V2: upstream clip ending at 3000, downstream clip that will be pulled left by ripple
        INSERT INTO clips (id, project_id, name, track_id, sequence_id, owner_sequence_id, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame)
VALUES
    ('v2_left', 'default_project', 'V2 Left', 'track_v2', 'master_media1', 'default_sequence', 0, 6000, 0, 6000, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
    ('v2_right', 'default_project', 'V2 Right', 'track_v2', 'master_media1', 'default_sequence', 9000, 2000, 3000, 5000, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
    ]],
        now, now,     -- projects
        now, now,     -- sequences
        now, now,     -- media
        now, now,     -- v1_left
        now, now,     -- v1_right
        now, now,     -- v2_left
        now, now      -- v2_right
    )))

    command_manager.init("default_sequence", "default_project")
    return db
end

local function fetch_start(db, id)
    local stmt = db:prepare("SELECT sequence_start_frame FROM clips WHERE id = ?")
    stmt:bind_value(1, id)
    assert(stmt:exec() and stmt:next(), "clip not found " .. tostring(id))
    local v = tonumber(stmt:value(0)) or 0
    stmt:finalize()
    return v
end

local db = setup_db("/tmp/jve/test_ripple_multitrack_overlap_blocks.db")

-- Gap on V1 between v1_left (end=4000) and v1_right (start=8000): gap_track_v1_4000
-- Gap on V2 between v2_left (end=6000) and v2_right (start=9000): gap_track_v2_6000
local v1_gap_id = string.format("gap_track_v1_%d", 4000)
local v2_gap_id = string.format("gap_track_v2_%d", 6000)

-- Drag gap out-edge on both right clips (BatchRippleEdit), large delta. A single delta is used,
-- so clamp must pick the tightest gap (V2's 3s) to keep tracks in sync.
local cmd = Command.create("BatchRippleEdit", "default_project")
cmd:set_parameter("edge_infos", {
    {clip_id = v1_gap_id, edge_type = "out", track_id = "track_v1"},
    {clip_id = v2_gap_id, edge_type = "out", track_id = "track_v2"},
})
cmd:set_parameter("delta_frames", -6000) -- Drag ] LEFT to close both gaps (clamp to 3s)
cmd:set_parameter("sequence_id", "default_sequence")

local result = command_manager.execute(cmd)
assert(result.success, result.error_message or "BatchRippleEdit failed")

local _ = fetch_start(db, "v1_left") + 2000 -- duration of v1_left (unused, for doc)
local v1_right_start = fetch_start(db, "v1_right")

local v2_left_end = fetch_start(db, "v2_left") + 6000 -- duration of v2_left
local v2_right_start = fetch_start(db, "v2_right")

-- Smallest gap is 3s on V2: expect both moves clamped to that delta.
assert(v2_right_start == v2_left_end, string.format(
    "V2 should butt after clamp (expected %d, got %d)", v2_left_end, v2_right_start))
assert(v1_right_start == 5000, string.format(
    "V1 should move by the same clamped delta (expected 5000, got %d)", v1_right_start))

print("✅ Batch ripple clamps to the tightest gap to keep tracks in sync (no overlaps)")
