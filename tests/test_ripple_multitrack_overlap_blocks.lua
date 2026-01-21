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
        INSERT INTO projects (id, name, created_at, modified_at)
        VALUES ('default_project', 'Default Project', %d, %d);

        INSERT INTO sequences (
            id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_rate,
            width, height, view_start_frame, view_duration_frames, playhead_frame,
            created_at, modified_at
        )
        VALUES ('default_sequence', 'default_project', 'Timeline', 'timeline', 1000, 1, 48000, 1920, 1080, 0, 600, 0, %d, %d);

        INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
        VALUES ('track_v1', 'default_sequence', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
        VALUES ('track_v2', 'default_sequence', 'V2', 'VIDEO', 2, 1, 0, 0, 0, 1.0, 0.0);

        INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, metadata, created_at, modified_at)
        VALUES ('media1', 'default_project', 'Media', 'synthetic://media1', 120000, 1000, 1, 1920, 1080, 0, 'raw', '{}', %d, %d);

        -- Track V1: left clip then a gap, then right clip
        INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id,
                           timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                           fps_numerator, fps_denominator, enabled, offline,
                           created_at, modified_at)
        VALUES ('v1_left', 'default_project', 'timeline', 'V1 Left', 'track_v1', 'media1', 'default_sequence',
                2000, 2000, 0, 2000, 1000, 1, 1, 0, %d, %d),
               ('v1_right', 'default_project', 'timeline', 'V1 Right', 'track_v1', 'media1', 'default_sequence',
                8000, 2000, 2000, 4000, 1000, 1, 1, 0, %d, %d);

        -- Track V2: upstream clip ending at 3000, downstream clip that will be pulled left by ripple
        INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id,
                           timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                           fps_numerator, fps_denominator, enabled, offline,
                           created_at, modified_at)
        VALUES ('v2_left', 'default_project', 'timeline', 'V2 Left', 'track_v2', 'media1', 'default_sequence',
                0, 6000, 0, 6000, 1000, 1, 1, 0, %d, %d),
               ('v2_right', 'default_project', 'timeline', 'V2 Right', 'track_v2', 'media1', 'default_sequence',
                9000, 2000, 3000, 5000, 1000, 1, 1, 0, %d, %d);
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
    local stmt = db:prepare("SELECT timeline_start_frame FROM clips WHERE id = ?")
    stmt:bind_value(1, id)
    assert(stmt:exec() and stmt:next(), "clip not found " .. tostring(id))
    local v = tonumber(stmt:value(0)) or 0
    stmt:finalize()
    return v
end

local db = setup_db("/tmp/jve/test_ripple_multitrack_overlap_blocks.db")

-- Drag gap_before on both right clips (BatchRippleEdit), large delta. A single delta is used,
-- so clamp must pick the tightest gap (V2's 4s) to keep tracks in sync.
local cmd = Command.create("BatchRippleEdit", "default_project")
cmd:set_parameter("edge_infos", {
    {clip_id = "v1_right", edge_type = "gap_before", track_id = "track_v1"},
    {clip_id = "v2_right", edge_type = "gap_before", track_id = "track_v2"},
})
cmd:set_parameter("delta_frames", -6000) -- Drag ] LEFT to close both gaps (clamp to 3s)
cmd:set_parameter("sequence_id", "default_sequence")

local result = command_manager.execute(cmd)
assert(result.success, result.error_message or "BatchRippleEdit failed")

local v1_left_end = fetch_start(db, "v1_left") + 2000 -- duration of v1_left
local v1_right_start = fetch_start(db, "v1_right")

local v2_left_end = fetch_start(db, "v2_left") + 6000 -- duration of v2_left
local v2_right_start = fetch_start(db, "v2_right")

-- Smallest gap is 3s on V2: expect both moves clamped to that delta.
assert(v2_right_start == v2_left_end, string.format(
    "V2 should butt after clamp (expected %d, got %d)", v2_left_end, v2_right_start))
assert(v1_right_start == 5000, string.format(
    "V1 should move by the same clamped delta (expected 5000, got %d)", v1_right_start))

print("✅ Batch ripple clamps to the tightest gap to keep tracks in sync (no overlaps)")
