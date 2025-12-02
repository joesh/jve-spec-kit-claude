#!/usr/bin/env luajit

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local SCHEMA_SQL = require("import_schema")

local function setup()
    local db_path = "/tmp/jve/test_ripple_multitrack_collision.db"
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
        VALUES ('media1', 'default_project', 'Media', 'synthetic://media1', 10000, 1000, 1, 1920, 1080, 0, 'raw', '{}', %d, %d);

        -- Track 1: single clip with gap before
        INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id,
                           timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                           fps_numerator, fps_denominator, enabled, offline,
                           created_at, modified_at)
        VALUES ('clip_v1_right', 'default_project', 'timeline', 'V1 Right', 'track_v1', 'media1', 'default_sequence',
                5000, 2000, 0, 2000, 1000, 1, 1, 0, %d, %d);

        -- Track 2: upstream and downstream clips
        INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id,
                           timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                           fps_numerator, fps_denominator, enabled, offline,
                           created_at, modified_at)
        VALUES ('clip_v2_left', 'default_project', 'timeline', 'V2 Left', 'track_v2', 'media1', 'default_sequence',
                0, 2000, 0, 2000, 1000, 1, 1, 0, %d, %d),
               ('clip_v2_right', 'default_project', 'timeline', 'V2 Right', 'track_v2', 'media1', 'default_sequence',
                5000, 2000, 2000, 4000, 1000, 1, 1, 0, %d, %d);
    ]], 
        now, now,     -- projects
        now, now,     -- sequences
        now, now,     -- media
        now, now,     -- clip_v1_right
        now, now,     -- clip_v2_left
        now, now      -- clip_v2_right
    )))

    command_manager.init(db, "default_sequence", "default_project")
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

local db = setup()

-- Attempt to close a 3000ms gap (actual gap is 5000ms→0ms before clip_v1_right),
-- but ripple shift must not drag V2 Right into V2 Left.
local cmd = Command.create("RippleEdit", "default_project")
cmd:set_parameter("edge_info", {clip_id = "clip_v1_right", edge_type = "gap_before", track_id = "track_v1"})
cmd:set_parameter("delta_frames", -3000) -- fps=1000, so 3000ms -> 3000 frames
cmd:set_parameter("sequence_id", "default_sequence")

local result = command_manager.execute(cmd)
assert(result.success, result.error_message or "RippleEdit failed")

-- Track 2 downstream clip should clamp to butt against upstream (0ms gap) not overlap
local start_v2_right = fetch_start(db, "clip_v2_right")
assert(start_v2_right == 2000, string.format("multitrack ripple should clamp to avoid overlapping V2 Left (got %d)", start_v2_right))

print("✅ Multitrack ripple clamp prevents overlap onto upstream clip on another track")
